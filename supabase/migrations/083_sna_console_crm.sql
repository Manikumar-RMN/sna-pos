-- 083: the SNA console as a simple client book (CRM)
--
-- SNA's own records about each restaurant: licence dates, who looks after the
-- client, contacts, notes and follow-ups, and what SNA has sold them.
--
-- Nothing here is part of the restaurant's own data and nothing here changes
-- how the restaurant app behaves. In particular a licence date that has passed
-- only shows in the console: it does not lock or limit the restaurant.
--
-- Additive only: four new tables and new functions. No existing table,
-- function, trigger or grant is changed, so sign-up and billing are untouched.
-- A new restaurant shows in the console by itself because the list reads the
-- restaurants table; no trigger on sign-up is needed.
--
-- Access: no signed-in person can read or write these tables directly. Every
-- function below first checks the SNA staff list (app.sna_require).

begin;

------------------------------------------------------------------
-- 1. Tables
------------------------------------------------------------------

create table public.sna_accounts (
  restaurant_id  uuid primary key references public.restaurants(id) on delete cascade,
  licence_start  date,
  licence_expiry date,
  account_manager uuid references public.sna_staff(id) on delete set null,
  sales_person    uuid references public.sna_staff(id) on delete set null,
  support_person  uuid references public.sna_staff(id) on delete set null,
  last_contact   date,
  next_contact   date,
  updated_at     timestamptz not null default now(),
  updated_by     uuid references public.sna_staff(id) on delete set null,
  constraint sna_accounts_licence_order check (licence_start is null or licence_expiry is null or licence_expiry >= licence_start)
);
comment on table public.sna_accounts is
  'SNA''s own record for a restaurant: licence dates, the SNA people who look after it, last and next contact. One row per restaurant, made the first time something is saved. Read and written only by the sna_ functions.';

create table public.sna_contacts (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  kind          text not null default 'contact' check (kind in ('owner', 'billing', 'accounts', 'manager', 'it', 'contact')),
  full_name     text not null check (length(trim(full_name)) between 1 and 120),
  job_title     text check (job_title is null or length(job_title) <= 120),
  phone         text check (phone is null or length(phone) <= 40),
  email         text check (email is null or length(email) <= 200),
  created_at    timestamptz not null default clock_timestamp(),
  created_by    uuid references public.sna_staff(id) on delete set null,
  removed_at    timestamptz
);
create index sna_contacts_restaurant on public.sna_contacts (restaurant_id) where removed_at is null;
comment on table public.sna_contacts is
  'People SNA deals with at a restaurant. Removing one hides it (removed_at); it is not deleted. Read and written only by the sna_ functions.';

create table public.sna_notes (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  kind          text not null default 'note' check (kind in ('note', 'call', 'visit', 'message', 'email')),
  body          text not null check (length(trim(body)) between 1 and 2000),
  staff_id      uuid references public.sna_staff(id) on delete set null,
  created_at    timestamptz not null default clock_timestamp()
);
create index sna_notes_restaurant on public.sna_notes (restaurant_id, created_at desc);
comment on table public.sna_notes is
  'Notes SNA staff write about a restaurant, and a log of calls, visits and messages. Never edited or deleted. Read and written only by the sna_ functions.';

create table public.sna_sales (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  sale_date     date not null,
  kind          text not null check (kind in ('new', 'renewal', 'upgrade', 'addon', 'outlet', 'hardware', 'service', 'other')),
  description   text not null check (length(trim(description)) between 1 and 200),
  amount        numeric(14,2) not null check (amount >= 0),
  currency_code char(3) not null,
  period_from   date,
  period_to     date,
  invoice_no    text check (invoice_no is null or length(invoice_no) <= 60),
  paid_on       date,
  note          text check (note is null or length(note) <= 500),
  staff_id      uuid references public.sna_staff(id) on delete set null,
  created_at    timestamptz not null default clock_timestamp(),
  cancelled_at  timestamptz,
  cancelled_by  uuid references public.sna_staff(id) on delete set null,
  cancel_reason text,
  constraint sna_sales_period_order check (period_from is null or period_to is null or period_to >= period_from)
);
create index sna_sales_restaurant on public.sna_sales (restaurant_id, sale_date desc);
comment on table public.sna_sales is
  'What SNA sold to a restaurant: licence, renewal, add-on, hardware, service. A wrong entry is cancelled with a reason, never edited or deleted. This is a sales record for SNA staff, not an invoice or a payment. Read and written only by the sna_ functions.';

alter table public.sna_accounts enable row level security;
alter table public.sna_contacts enable row level security;
alter table public.sna_notes    enable row level security;
alter table public.sna_sales    enable row level security;
revoke all on public.sna_accounts, public.sna_contacts, public.sna_notes, public.sna_sales from public, anon, authenticated;

------------------------------------------------------------------
-- 2. Helpers
------------------------------------------------------------------

-- "Today" for SNA staff (India). Licence days-left and follow-ups are counted from this.
create function app.sna_today() returns date
language sql stable set search_path to 'public', 'pg_temp'
as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- Makes sure the restaurant exists and has its SNA record; returns nothing.
create function app.sna_account_row(p_restaurant uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if not exists (select 1 from public.restaurants where id = p_restaurant and deleted_at is null) then
    raise exception 'Restaurant not found.';
  end if;
  insert into public.sna_accounts (restaurant_id) values (p_restaurant) on conflict (restaurant_id) do nothing;
end $$;
revoke all on function app.sna_today(), app.sna_account_row(uuid) from public, anon, authenticated;

------------------------------------------------------------------
-- 3. Reading
------------------------------------------------------------------

-- The client list. Every restaurant is in it from the moment it signs up.
create function public.sna_clients(p_search text default null, p_filter text default 'all') returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_today date := app.sna_today();
  v_q text := nullif(trim(coalesce(p_search, '')), '');
  v_counts jsonb; v_rows jsonb;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  if coalesce(p_filter, 'all') not in ('all', 'new', 'expiring', 'expired', 'nolicence', 'followup') then
    raise exception 'Unknown list.';
  end if;

  select jsonb_build_object(
           'all',       count(*),
           'new',       count(*) filter (where (r.created_at at time zone 'Asia/Kolkata')::date > v_today - 14),
           'expiring',  count(*) filter (where a.licence_expiry between v_today and v_today + 30),
           'expired',   count(*) filter (where a.licence_expiry < v_today),
           'nolicence', count(*) filter (where a.licence_expiry is null),
           'followup',  count(*) filter (where a.next_contact <= v_today))
    into v_counts
    from public.restaurants r left join public.sna_accounts a on a.restaurant_id = r.id
   where r.deleted_at is null;

  select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb) into v_rows from (
    select r.created_at, jsonb_build_object(
             'id', r.id, 'client_code', r.client_code, 'trading_name', r.trading_name, 'legal_name', r.legal_name,
             'country_code', r.country_code, 'currency', r.currency_code, 'edition', r.edition, 'status', r.subscription_status,
             'signed_up', (r.created_at at time zone 'Asia/Kolkata')::date,
             'is_new', (r.created_at at time zone 'Asia/Kolkata')::date > v_today - 14,
             'outlets', (select count(*) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null),
             'monthly', app.monthly_charge(r.id),
             'licence_expiry', a.licence_expiry,
             'days_left', a.licence_expiry - v_today,
             'last_contact', a.last_contact, 'next_contact', a.next_contact,
             'account_manager', (select s.full_name from public.sna_staff s where s.id = a.account_manager),
             'open_requests', (select count(*) from public.plan_requests q where q.restaurant_id = r.id and q.status in ('requested', 'approved')),
             'owner_name', o.full_name, 'owner_email', o.email,
             'last_bill', (select max(od.business_date) from public.orders od where od.restaurant_id = r.id)) as j
      from public.restaurants r
      left join public.sna_accounts a on a.restaurant_id = r.id
      left join lateral (
        select u.full_name, u.email from public.users u join public.roles ro on ro.id = u.role_id
         where u.restaurant_id = r.id and ro.name = 'Owner' and ro.is_system and u.deleted_at is null
         order by u.created_at limit 1) o on true
     where r.deleted_at is null
       and (v_q is null or r.trading_name ilike '%' || v_q || '%' or r.legal_name ilike '%' || v_q || '%' or r.client_code = v_q)
       and case coalesce(p_filter, 'all')
             when 'new'       then (r.created_at at time zone 'Asia/Kolkata')::date > v_today - 14
             when 'expiring'  then a.licence_expiry between v_today and v_today + 30
             when 'expired'   then a.licence_expiry < v_today
             when 'nolicence' then a.licence_expiry is null
             when 'followup'  then a.next_contact <= v_today
             else true end
     order by r.created_at desc
     limit 500) x;

  return jsonb_build_object('today', v_today, 'counts', v_counts, 'rows', v_rows);
end $$;

-- Everything SNA keeps about one client.
create function public.sna_client(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare
  r public.restaurants%rowtype; a public.sna_accounts%rowtype;
  v_today date := app.sna_today();
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_id and deleted_at is null;
  if not found then raise exception 'Restaurant not found.'; end if;
  select * into a from public.sna_accounts where restaurant_id = p_id;

  return jsonb_build_object(
    'id', r.id, 'today', v_today,
    'client_code', r.client_code, 'trading_name', r.trading_name, 'legal_name', r.legal_name,
    'country_code', r.country_code, 'currency', r.currency_code, 'edition', r.edition, 'status', r.subscription_status,
    'signed_up', (r.created_at at time zone 'Asia/Kolkata')::date,
    'monthly', app.monthly_charge(r.id),
    'licence_start', a.licence_start, 'licence_expiry', a.licence_expiry, 'days_left', a.licence_expiry - v_today,
    'account_manager', a.account_manager, 'sales_person', a.sales_person, 'support_person', a.support_person,
    'last_contact', a.last_contact, 'next_contact', a.next_contact,
    'owner', (select jsonb_build_object('full_name', u.full_name, 'email', u.email, 'phone', coalesce(u.phone, r.contact_phone))
                from public.users u join public.roles ro on ro.id = u.role_id
               where u.restaurant_id = r.id and ro.name = 'Owner' and ro.is_system and u.deleted_at is null
               order by u.created_at limit 1),
    'usage', jsonb_build_object(
      'outlets',   (select count(*) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null),
      'people',    (select count(*) from public.users u where u.restaurant_id = r.id and u.deleted_at is null and u.is_active),
      'last_bill', (select max(od.business_date) from public.orders od where od.restaurant_id = r.id),
      'bills_30d', (select count(*) from public.orders od where od.restaurant_id = r.id and od.business_date > v_today - 30)),
    'contacts', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'full_name', c.full_name, 'job_title', c.job_title,
                    'phone', c.phone, 'email', c.email) order by c.created_at), '[]'::jsonb)
                   from public.sna_contacts c where c.restaurant_id = r.id and c.removed_at is null),
    'notes', (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'body', n.body, 'created_at', n.created_at,
                    'by', (select s.full_name from public.sna_staff s where s.id = n.staff_id)) order by n.created_at desc), '[]'::jsonb)
                from (select * from public.sna_notes where restaurant_id = r.id order by created_at desc limit 200) n),
    'sales', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'sale_date', s.sale_date, 'kind', s.kind, 'description', s.description,
                    'amount', s.amount, 'currency', s.currency_code, 'period_from', s.period_from, 'period_to', s.period_to,
                    'invoice_no', s.invoice_no, 'paid_on', s.paid_on, 'note', s.note, 'cancelled', s.cancelled_at is not null,
                    'cancel_reason', s.cancel_reason,
                    'by', (select st.full_name from public.sna_staff st where st.id = s.staff_id)) order by s.sale_date desc, s.created_at desc), '[]'::jsonb)
                from public.sna_sales s where s.restaurant_id = r.id),
    'sales_total', (select coalesce(sum(amount), 0) from public.sna_sales where restaurant_id = r.id and cancelled_at is null),
    'sales_unpaid', (select coalesce(sum(amount), 0) from public.sna_sales where restaurant_id = r.id and cancelled_at is null and paid_on is null),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'full_name', s.full_name, 'role', s.role) order by s.full_name), '[]'::jsonb)
                from public.sna_staff s where s.is_active));
end $$;

------------------------------------------------------------------
-- 4. Writing
------------------------------------------------------------------

-- Licence dates, status and the SNA people who look after the client. Sales and admin only.
create function public.sna_save_account(
  p_restaurant uuid, p_status text, p_licence_start date, p_licence_expiry date,
  p_account_manager uuid default null, p_sales_person uuid default null, p_support_person uuid default null
) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid; v_old_status text; a public.sna_accounts%rowtype; v_id uuid;
begin
  v_me := app.sna_require(array['sales']);
  if p_status not in ('trial', 'active', 'past_due', 'suspended', 'cancelled') then raise exception 'Unknown status.'; end if;
  if p_licence_start is not null and p_licence_expiry is not null and p_licence_expiry < p_licence_start then
    raise exception 'The licence cannot end before it starts.';
  end if;
  foreach v_id in array array[p_account_manager, p_sales_person, p_support_person] loop
    if v_id is not null and not exists (select 1 from public.sna_staff where id = v_id and is_active) then
      raise exception 'Choose an active SNA staff member.';
    end if;
  end loop;

  perform app.sna_account_row(p_restaurant);
  select * into a from public.sna_accounts where restaurant_id = p_restaurant for update;
  select subscription_status into v_old_status from public.restaurants where id = p_restaurant for update;

  update public.sna_accounts
     set licence_start = p_licence_start, licence_expiry = p_licence_expiry,
         account_manager = p_account_manager, sales_person = p_sales_person, support_person = p_support_person,
         updated_at = now(), updated_by = v_me
   where restaurant_id = p_restaurant;
  if v_old_status is distinct from p_status then
    update public.restaurants set subscription_status = p_status where id = p_restaurant;
  end if;

  if v_old_status is distinct from p_status or a.licence_start is distinct from p_licence_start or a.licence_expiry is distinct from p_licence_expiry then
    perform app.log_plan(p_restaurant, 'account.changed', jsonb_strip_nulls(jsonb_build_object(
      'status_from', case when v_old_status is distinct from p_status then v_old_status end,
      'status_to',   case when v_old_status is distinct from p_status then p_status end,
      'licence_start', p_licence_start, 'licence_expiry', p_licence_expiry,
      'expiry_was', case when a.licence_expiry is distinct from p_licence_expiry then a.licence_expiry end)));
  end if;
end $$;

-- A note, or a logged call / visit / message / email. Any SNA staff.
create function public.sna_add_note(p_restaurant uuid, p_kind text, p_body text, p_next_contact date default null) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid; v_id uuid; v_body text := trim(coalesce(p_body, ''));
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  if coalesce(p_kind, '') not in ('note', 'call', 'visit', 'message', 'email') then raise exception 'Unknown kind of note.'; end if;
  if length(v_body) = 0 then raise exception 'Write the note first.'; end if;
  if length(v_body) > 2000 then raise exception 'The note is too long (2,000 characters at most).'; end if;
  if p_next_contact is not null and p_next_contact < app.sna_today() then raise exception 'The follow-up date cannot be in the past.'; end if;

  perform app.sna_account_row(p_restaurant);
  insert into public.sna_notes (restaurant_id, kind, body, staff_id) values (p_restaurant, p_kind, v_body, v_me) returning id into v_id;
  update public.sna_accounts
     set last_contact = case when p_kind <> 'note' then app.sna_today() else last_contact end,
         -- A contact clears the follow-up that was due, unless a new one is given.
         next_contact = case when p_next_contact is not null then p_next_contact
                             when p_kind <> 'note' and next_contact <= app.sna_today() then null
                             else next_contact end,
         updated_at = now(), updated_by = v_me
   where restaurant_id = p_restaurant;
  return v_id;
end $$;

-- Set or clear the next follow-up date without writing a note. Any SNA staff.
create function public.sna_set_follow_up(p_restaurant uuid, p_next_contact date) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid;
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  if p_next_contact is not null and p_next_contact < app.sna_today() then raise exception 'The follow-up date cannot be in the past.'; end if;
  perform app.sna_account_row(p_restaurant);
  update public.sna_accounts set next_contact = p_next_contact, updated_at = now(), updated_by = v_me where restaurant_id = p_restaurant;
end $$;

-- Add a contact (p_id null) or change one. Any SNA staff.
create function public.sna_save_contact(
  p_restaurant uuid, p_id uuid, p_kind text, p_full_name text,
  p_job_title text default null, p_phone text default null, p_email text default null
) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_me uuid; v_id uuid;
  v_name text := trim(coalesce(p_full_name, ''));
  v_title text := nullif(trim(coalesce(p_job_title, '')), '');
  v_phone text := nullif(trim(coalesce(p_phone, '')), '');
  v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  if coalesce(p_kind, '') not in ('owner', 'billing', 'accounts', 'manager', 'it', 'contact') then raise exception 'Unknown kind of contact.'; end if;
  if length(v_name) = 0 then raise exception 'Enter the person''s name.'; end if;
  if length(v_name) > 120 or length(coalesce(v_title, '')) > 120 then raise exception 'The name or position is too long.'; end if;
  if v_phone is not null and (v_phone !~ '^[0-9+() -]{6,25}$') then raise exception 'Enter a phone number with digits only (spaces, + and - are fine).'; end if;
  if v_email is not null and (length(v_email) > 200 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') then raise exception 'That email address does not look right.'; end if;
  if v_phone is null and v_email is null then raise exception 'Enter a phone number or an email address.'; end if;

  if p_id is null then
    perform app.sna_account_row(p_restaurant);
    if (select count(*) from public.sna_contacts where restaurant_id = p_restaurant and removed_at is null) >= 30 then
      raise exception 'This client already has 30 contacts. Remove one first.';
    end if;
    insert into public.sna_contacts (restaurant_id, kind, full_name, job_title, phone, email, created_by)
    values (p_restaurant, p_kind, v_name, v_title, v_phone, v_email, v_me) returning id into v_id;
  else
    update public.sna_contacts set kind = p_kind, full_name = v_name, job_title = v_title, phone = v_phone, email = v_email
     where id = p_id and restaurant_id = p_restaurant and removed_at is null returning id into v_id;
    if v_id is null then raise exception 'Contact not found.'; end if;
  end if;
  return v_id;
end $$;

create function public.sna_remove_contact(p_id uuid) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  update public.sna_contacts set removed_at = now() where id = p_id and removed_at is null;
  if not found then raise exception 'Contact not found.'; end if;
end $$;

-- Record something SNA sold to the client. Sales and admin only.
-- p_extend_licence: also move the licence end date to the end of the period sold.
create function public.sna_add_sale(
  p_restaurant uuid, p_kind text, p_description text, p_amount numeric, p_sale_date date,
  p_period_from date default null, p_period_to date default null, p_invoice_no text default null,
  p_paid_on date default null, p_note text default null, p_extend_licence boolean default false
) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_me uuid; v_id uuid; v_cur char(3); v_old date;
  v_desc text := trim(coalesce(p_description, ''));
  v_today date := app.sna_today();
begin
  v_me := app.sna_require(array['sales']);
  if coalesce(p_kind, '') not in ('new', 'renewal', 'upgrade', 'addon', 'outlet', 'hardware', 'service', 'other') then raise exception 'Unknown kind of sale.'; end if;
  if length(v_desc) = 0 then raise exception 'Say what was sold.'; end if;
  if length(v_desc) > 200 then raise exception 'The description is too long (200 characters at most).'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 99999999 then raise exception 'Enter the amount (0 or more).'; end if;
  if p_sale_date is null or p_sale_date > v_today then raise exception 'The sale date cannot be in the future.'; end if;
  if p_paid_on is not null and p_paid_on > v_today then raise exception 'The paid date cannot be in the future.'; end if;
  if p_period_from is not null and p_period_to is not null and p_period_to < p_period_from then raise exception 'The period cannot end before it starts.'; end if;
  if coalesce(p_extend_licence, false) and p_period_to is null then raise exception 'To move the licence date, enter the date the period ends.'; end if;

  perform app.sna_account_row(p_restaurant);
  select currency_code into v_cur from public.restaurants where id = p_restaurant;
  insert into public.sna_sales (restaurant_id, sale_date, kind, description, amount, currency_code, period_from, period_to, invoice_no, paid_on, note, staff_id)
  values (p_restaurant, p_sale_date, p_kind, v_desc, round(p_amount, 2), v_cur, p_period_from, p_period_to,
          nullif(trim(coalesce(p_invoice_no, '')), ''), p_paid_on, nullif(trim(coalesce(p_note, '')), ''), v_me)
  returning id into v_id;

  if coalesce(p_extend_licence, false) then
    select licence_expiry into v_old from public.sna_accounts where restaurant_id = p_restaurant for update;
    update public.sna_accounts
       set licence_expiry = p_period_to,
           licence_start = case when licence_start is null or licence_start > p_period_to then coalesce(p_period_from, p_sale_date) else licence_start end,
           updated_at = now(), updated_by = v_me
     where restaurant_id = p_restaurant;
  end if;
  perform app.log_plan(p_restaurant, 'sale.added', jsonb_strip_nulls(jsonb_build_object(
    'kind', p_kind, 'what', v_desc, 'amount', round(p_amount, 2), 'currency', v_cur,
    'licence_expiry', case when coalesce(p_extend_licence, false) then p_period_to end,
    'expiry_was', case when coalesce(p_extend_licence, false) then v_old end)));
  return v_id;
end $$;

-- Mark a sale paid (a date) or not paid (null). Sales and admin only.
create function public.sna_set_sale_paid(p_id uuid, p_paid_on date) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare s public.sna_sales%rowtype;
begin
  perform app.sna_require(array['sales']);
  select * into s from public.sna_sales where id = p_id for update;
  if not found then raise exception 'Sale not found.'; end if;
  if s.cancelled_at is not null then raise exception 'This sale was cancelled.'; end if;
  if p_paid_on is not null and p_paid_on > app.sna_today() then raise exception 'The paid date cannot be in the future.'; end if;
  if p_paid_on is not null and p_paid_on < s.sale_date - 366 then raise exception 'Check the paid date.'; end if;
  update public.sna_sales set paid_on = p_paid_on where id = p_id;
  perform app.log_plan(s.restaurant_id, case when p_paid_on is null then 'sale.unpaid' else 'sale.paid' end,
    jsonb_strip_nulls(jsonb_build_object('what', s.description, 'amount', s.amount, 'currency', s.currency_code, 'paid_on', p_paid_on)));
end $$;

-- Cancel a wrong sale entry. It stays in the list, struck out. Sales and admin only.
-- The licence date is not moved back by this: check it on the client page.
create function public.sna_cancel_sale(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid; s public.sna_sales%rowtype; v_reason text := trim(coalesce(p_reason, ''));
begin
  v_me := app.sna_require(array['sales']);
  if length(v_reason) < 3 then raise exception 'Write a short reason for cancelling this entry.'; end if;
  select * into s from public.sna_sales where id = p_id for update;
  if not found then raise exception 'Sale not found.'; end if;
  if s.cancelled_at is not null then raise exception 'This sale was already cancelled.'; end if;
  update public.sna_sales set cancelled_at = now(), cancelled_by = v_me, cancel_reason = left(v_reason, 300) where id = p_id;
  perform app.log_plan(s.restaurant_id, 'sale.cancelled',
    jsonb_build_object('what', s.description, 'amount', s.amount, 'currency', s.currency_code, 'reason', left(v_reason, 300)));
end $$;

------------------------------------------------------------------
-- 5. Who may call these
------------------------------------------------------------------
-- Signed-in people only; each function then checks the SNA staff list itself.
revoke all on function
  public.sna_clients(text, text), public.sna_client(uuid),
  public.sna_save_account(uuid, text, date, date, uuid, uuid, uuid),
  public.sna_add_note(uuid, text, text, date), public.sna_set_follow_up(uuid, date),
  public.sna_save_contact(uuid, uuid, text, text, text, text, text), public.sna_remove_contact(uuid),
  public.sna_add_sale(uuid, text, text, numeric, date, date, date, text, date, text, boolean),
  public.sna_set_sale_paid(uuid, date), public.sna_cancel_sale(uuid, text)
from public, anon;
grant execute on function
  public.sna_clients(text, text), public.sna_client(uuid),
  public.sna_save_account(uuid, text, date, date, uuid, uuid, uuid),
  public.sna_add_note(uuid, text, text, date), public.sna_set_follow_up(uuid, date),
  public.sna_save_contact(uuid, uuid, text, text, text, text, text), public.sna_remove_contact(uuid),
  public.sna_add_sale(uuid, text, text, numeric, date, date, date, text, date, text, boolean),
  public.sna_set_sale_paid(uuid, date), public.sna_cancel_sale(uuid, text)
to authenticated, service_role;

commit;
