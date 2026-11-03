-- 170: Front Office bill-to-company (SNA Hospitality, batch C part 2). Depends on 160-169. Additive except two replaced
-- functions (fo_issue_invoice, fo_invoice_for_stay gain a "party" argument; calls without it behave as before).
--
-- A company can pay for part of a stay.
--   * Companies are a master list (name, GSTIN, address, credit days, optional credit limit).
--   * A stay is linked to a company with a scope: "room" (room charges and their tax go to the company, everything else
--     to the guest) or "all" (every charge goes to the company). Which side a charge falls on is worked out from the stay's
--     link and the charge kind, never stored, so the rule cannot drift from the data.
--   * The GUEST balance, and so check-out, counts only the guest's side. The company side stays open on the company's
--     account until the company pays. Payments from a company are recorded against the company, not against a stay.
--   * Each side gets its own tax invoice (guest invoice and company invoice). Payments taken from the guest appear on the
--     guest invoice only.
--   * The link cannot be changed once an invoice exists for the stay.
--   * Company payments are applied oldest stay first (FIFO) to decide what is overdue. Credit notes are NOT built.

-- ---------------------------------------------------------------- 1. companies
create table if not exists public.fo_companies (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null check (btrim(name) <> ''),
  gstin text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  state_code text check (state_code is null or state_code ~ '^[0-9]{2}$'),
  address text,
  contact_name text,
  phone text,
  email text,
  credit_days int not null default 30 check (credit_days between 0 and 365),
  credit_limit numeric(14,2) check (credit_limit is null or credit_limit >= 0),
  active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (restaurant_id, id)
);
create unique index if not exists fo_companies_name_uq on public.fo_companies (restaurant_id, lower(btrim(name)));

create table if not exists public.fo_company_payments (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  company_id uuid not null,
  business_date date not null,
  amount numeric(14,2) not null check (amount > 0),
  payment_method_id uuid,
  method_name text not null,
  reference text,
  voided_at timestamptz,
  void_reason text,
  voided_by uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  client_ref uuid,
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, company_id) references public.fo_companies(restaurant_id, id),
  constraint fo_company_payments_void_check check (voided_at is null or coalesce(btrim(void_reason), '') <> '')
);
create unique index if not exists fo_company_payments_ref_uq on public.fo_company_payments (restaurant_id, client_ref) where client_ref is not null;
create index if not exists fo_company_payments_idx on public.fo_company_payments (company_id) where voided_at is null;

alter table public.fo_stays add column if not exists company_id uuid;
alter table public.fo_stays add column if not exists company_scope text not null default 'none';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'fo_stays_company_fk') then
    alter table public.fo_stays add constraint fo_stays_company_fk
      foreign key (restaurant_id, company_id) references public.fo_companies(restaurant_id, id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'fo_stays_company_scope_check') then
    alter table public.fo_stays add constraint fo_stays_company_scope_check
      check (company_scope in ('none', 'room', 'all') and ((company_id is null) = (company_scope = 'none')));
  end if;
end $$;
create index if not exists fo_stays_company_idx on public.fo_stays (company_id) where company_id is not null;

do $$
declare t text;
begin
  foreach t in array array['fo_companies', 'fo_company_payments'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from authenticated, anon', t);
    execute format('grant select on public.%I to authenticated', t);
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'tenant_read') then
      execute format($p$create policy tenant_read on public.%I for select to authenticated using (
        restaurant_id = (select app.current_restaurant_id())
        and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))))$p$, t);
    end if;
  end loop;
end $$;

-- Invoices: one per party (guest side, company side) per stay instead of one per stay.
alter table public.fo_invoices add column if not exists party text not null default 'guest';
alter table public.fo_invoices add column if not exists company_id uuid;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'fo_invoices_party_check') then
    alter table public.fo_invoices add constraint fo_invoices_party_check check (party in ('guest', 'company'));
  end if;
  if exists (select 1 from pg_constraint where conname = 'fo_invoices_stay_id_key') then
    alter table public.fo_invoices drop constraint fo_invoices_stay_id_key;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'fo_invoices_stay_party_key') then
    alter table public.fo_invoices add constraint fo_invoices_stay_party_key unique (stay_id, party);
  end if;
end $$;

-- ---------------------------------------------------------------- 2. which side a charge falls on, and the balances
create or replace function app.fo_to_company(p_company uuid, p_scope text, p_kind text) returns boolean
language sql immutable as $$
  select p_company is not null and (p_scope = 'all' or (p_scope = 'room' and p_kind = 'room'));
$$;
revoke all on function app.fo_to_company(uuid, text, text) from public, anon, authenticated;

-- The GUEST balance: the guest's side of the charges, less what the guest paid (plus refunds).
create or replace function app.fo_balance(p_stay uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select sum(c.total_amount) from public.fo_charges c join public.fo_stays s on s.id = c.stay_id
                    where c.stay_id = p_stay and c.voided_at is null
                      and not app.fo_to_company(s.company_id, s.company_scope, c.kind)), 0)
       - coalesce((select sum(p.amount) from public.fo_payments p where p.stay_id = p_stay and p.voided_at is null and not p.is_refund), 0)
       + coalesce((select sum(p.amount) from public.fo_payments p where p.stay_id = p_stay and p.voided_at is null and p.is_refund), 0);
$$;

-- What a stay has charged to its company so far.
create or replace function app.fo_company_part(p_stay uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select sum(c.total_amount) from public.fo_charges c join public.fo_stays s on s.id = c.stay_id
                    where c.stay_id = p_stay and c.voided_at is null
                      and app.fo_to_company(s.company_id, s.company_scope, c.kind)), 0);
$$;

-- What a company owes: charges routed to it on stays that have started, less what it has paid.
create or replace function app.fo_company_balance(p_company uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select sum(c.total_amount) from public.fo_charges c join public.fo_stays s on s.id = c.stay_id
                    where s.company_id = p_company and s.status in ('inhouse', 'checked_out') and c.voided_at is null
                      and app.fo_to_company(s.company_id, s.company_scope, c.kind)), 0)
       - coalesce((select sum(p.amount) from public.fo_company_payments p where p.company_id = p_company and p.voided_at is null), 0);
$$;
revoke all on function app.fo_balance(uuid), app.fo_company_part(uuid), app.fo_company_balance(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3. company master
create or replace function public.fo_save_company(
  p_name text, p_gstin text default null, p_state_code text default null, p_address text default null,
  p_contact_name text default null, p_phone text default null, p_email text default null,
  p_credit_days int default 30, p_credit_limit numeric default null, p_active boolean default true,
  p_company_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_user uuid; v_id uuid;
        v_gstin text := upper(nullif(btrim(coalesce(p_gstin, '')), '')); v_state text;
begin
  v_user := app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_name, '')), '') = '' then raise exception 'Give the company a name.'; end if;
  if v_gstin is not null and v_gstin !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
    raise exception 'That GSTIN does not look right. It has 15 characters, like 33AAACA0000A1Z5.'; end if;
  v_state := coalesce(nullif(btrim(coalesce(p_state_code, '')), ''), case when v_gstin is not null then substr(v_gstin, 1, 2) end);
  if v_state is not null and v_state !~ '^[0-9]{2}$' then raise exception 'The state code is two digits.'; end if;
  if v_gstin is not null and v_state is not null and substr(v_gstin, 1, 2) <> v_state then
    raise exception 'The GSTIN starts with % but the state code is %.', substr(v_gstin, 1, 2), v_state; end if;
  if coalesce(p_credit_days, 30) < 0 or coalesce(p_credit_days, 30) > 365 then raise exception 'Credit days are 0 to 365.'; end if;
  if p_credit_limit is not null and p_credit_limit < 0 then raise exception 'The credit limit cannot be negative.'; end if;
  if exists (select 1 from public.fo_companies where restaurant_id = v_rest and lower(btrim(name)) = lower(btrim(p_name))
                and id is distinct from p_company_id) then
    raise exception 'A company called % already exists.', btrim(p_name); end if;

  if p_company_id is null then
    insert into public.fo_companies (restaurant_id, name, gstin, state_code, address, contact_name, phone, email,
                                     credit_days, credit_limit, active, created_by)
    values (v_rest, btrim(p_name), v_gstin, v_state, nullif(btrim(coalesce(p_address, '')), ''),
            nullif(btrim(coalesce(p_contact_name, '')), ''), nullif(btrim(coalesce(p_phone, '')), ''),
            nullif(btrim(coalesce(p_email, '')), ''), coalesce(p_credit_days, 30), p_credit_limit, coalesce(p_active, true), v_user)
    returning id into v_id;
  else
    update public.fo_companies set name = btrim(p_name), gstin = v_gstin, state_code = v_state,
           address = nullif(btrim(coalesce(p_address, '')), ''), contact_name = nullif(btrim(coalesce(p_contact_name, '')), ''),
           phone = nullif(btrim(coalesce(p_phone, '')), ''), email = nullif(btrim(coalesce(p_email, '')), ''),
           credit_days = coalesce(p_credit_days, 30), credit_limit = p_credit_limit, active = coalesce(p_active, true)
     where id = p_company_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'That company was not found.'; end if;
  end if;
  perform app.audit('fo_company_saved', 'fo_company', v_id, jsonb_build_object('name', btrim(p_name), 'gstin', v_gstin));
  return jsonb_build_object('company_id', v_id);
end $$;

create or replace function public.fo_companies_list(p_include_inactive boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id();
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'company_id', c.id, 'name', c.name, 'gstin', c.gstin, 'state_code', c.state_code, 'address', c.address,
      'contact_name', c.contact_name, 'phone', c.phone, 'email', c.email, 'credit_days', c.credit_days,
      'credit_limit', c.credit_limit, 'active', c.active, 'outstanding', app.fo_company_balance(c.id)) order by c.name)
    from public.fo_companies c where c.restaurant_id = v_rest and (p_include_inactive or c.active)), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- 4. link a stay (or a whole group) to a company
create or replace function app.fo_link_company(p_stay uuid, p_company uuid, p_scope text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.fo_stays;
begin
  select * into s from public.fo_stays where id = p_stay for update;
  if s.status not in ('reserved', 'inhouse') then
    raise exception 'Stay #% is %, so its company can no longer be changed.', s.stay_no, s.status; end if;
  if exists (select 1 from public.fo_invoices where stay_id = s.id) then
    raise exception 'Stay #% already has a tax invoice, so its company cannot be changed.', s.stay_no; end if;
  update public.fo_stays set company_id = p_company, company_scope = case when p_company is null then 'none' else p_scope end where id = s.id;
  perform app.audit('fo_stay_company_set', 'fo_stay', s.id, jsonb_build_object('company_id', p_company, 'scope', p_scope),
                    jsonb_build_object('company_id', s.company_id, 'scope', s.company_scope));
end $$;
revoke all on function app.fo_link_company(uuid, uuid, text) from public, anon, authenticated;

create or replace function public.fo_set_stay_company(p_stay uuid, p_company uuid, p_scope text default 'room') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); s public.fo_stays;
begin
  perform app.require_fo(array['fo.manage']);
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch;
  if not found then raise exception 'That stay was not found.'; end if;
  if p_company is not null then
    if p_scope not in ('room', 'all') then raise exception 'Choose what the company pays: the room, or everything.'; end if;
    if not exists (select 1 from public.fo_companies where id = p_company and restaurant_id = v_rest and active) then
      raise exception 'That company was not found, or is switched off.'; end if;
  end if;
  perform app.fo_link_company(p_stay, p_company, p_scope);
  return jsonb_build_object('stay_id', p_stay, 'company_id', p_company, 'scope', case when p_company is null then 'none' else p_scope end,
                            'guest_balance', app.fo_balance(p_stay), 'company_part', app.fo_company_part(p_stay));
end $$;

create or replace function public.fo_set_group_company(p_group uuid, p_company uuid, p_scope text default 'room') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); s record; v_n int := 0;
begin
  perform app.require_fo(array['fo.manage']);
  if not exists (select 1 from public.fo_groups where id = p_group and restaurant_id = v_rest and branch_id = v_branch) then
    raise exception 'That group was not found.'; end if;
  if p_company is not null then
    if p_scope not in ('room', 'all') then raise exception 'Choose what the company pays: the room, or everything.'; end if;
    if not exists (select 1 from public.fo_companies where id = p_company and restaurant_id = v_rest and active) then
      raise exception 'That company was not found, or is switched off.'; end if;
  end if;
  for s in select id from public.fo_stays where group_id = p_group and status in ('reserved', 'inhouse') order by stay_no loop
    perform app.fo_link_company(s.id, p_company, p_scope);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('group_id', p_group, 'rooms', v_n);
end $$;

-- ---------------------------------------------------------------- 5. company payments and ledger
create or replace function public.fo_take_company_payment(
  p_company uuid, p_amount numeric, p_payment_method_id uuid default null,
  p_reference text default null, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid; v_id uuid; v_method text;
begin
  v_user := app.require_fo(array['fo.manage']);
  if p_client_ref is not null then
    select id into v_id from public.fo_company_payments where restaurant_id = v_rest and client_ref = p_client_ref;
    if v_id is not null then return jsonb_build_object('payment_id', v_id, 'repeat', true); end if;
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'The amount must be more than zero.'; end if;
  if not exists (select 1 from public.fo_companies where id = p_company and restaurant_id = v_rest) then
    raise exception 'That company was not found.'; end if;
  if p_payment_method_id is null then v_method := 'Bank transfer';
  else
    select name into v_method from public.payment_methods where id = p_payment_method_id and restaurant_id = v_rest;
    if v_method is null then raise exception 'That payment method was not found.'; end if;
  end if;
  insert into public.fo_company_payments (restaurant_id, branch_id, company_id, business_date, amount, payment_method_id,
                                          method_name, reference, created_by, client_ref)
  values (v_rest, v_branch, p_company, app.business_today(v_branch), p_amount, p_payment_method_id, v_method,
          nullif(btrim(coalesce(p_reference, '')), ''), v_user, p_client_ref)
  returning id into v_id;
  perform app.audit('fo_company_payment_taken', 'fo_company_payment', v_id,
    jsonb_build_object('company_id', p_company, 'amount', p_amount, 'method', v_method));
  return jsonb_build_object('payment_id', v_id, 'outstanding', app.fo_company_balance(p_company), 'repeat', false);
end $$;

create or replace function public.fo_void_company_payment(p_payment uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_user uuid; p public.fo_company_payments;
begin
  v_user := app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give a reason for the void.'; end if;
  select * into p from public.fo_company_payments where id = p_payment and restaurant_id = v_rest for update;
  if not found then raise exception 'That payment was not found.'; end if;
  if p.voided_at is not null then return jsonb_build_object('payment_id', p.id, 'repeat', true); end if;
  update public.fo_company_payments set voided_at = now(), void_reason = btrim(p_reason), voided_by = v_user where id = p.id;
  perform app.audit('fo_company_payment_voided', 'fo_company_payment', p.id,
    jsonb_build_object('amount', p.amount, 'reason', btrim(p_reason)));
  return jsonb_build_object('payment_id', p.id, 'outstanding', app.fo_company_balance(p.company_id), 'repeat', false);
end $$;

-- The company's account: what each stay charged it, what it has paid, and what is overdue.
-- Overdue works oldest first: payments settle the oldest stays first, so only the part of the older stays that
-- the payments do not cover is overdue.
create or replace function public.fo_company_ledger(p_company uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); co public.fo_companies;
        v_today date; v_paid numeric; v_charged numeric; v_due_before_today numeric; v_stays jsonb; v_pays jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into co from public.fo_companies where id = p_company and restaurant_id = v_rest;
  if not found then return null; end if;
  v_today := app.business_today(v_branch);

  select coalesce(jsonb_agg(x order by (x ->> 'due_date'), (x ->> 'stay_no')::int), '[]'::jsonb),
         coalesce(sum((x ->> 'charged')::numeric), 0),
         coalesce(sum((x ->> 'charged')::numeric) filter (where (x ->> 'due_date')::date < v_today and x ->> 'status' = 'checked_out'), 0)
    into v_stays, v_charged, v_due_before_today
    from (select jsonb_build_object(
                   'stay_id', s.id, 'stay_no', s.stay_no, 'status', s.status, 'guest_name', g.full_name,
                   'room_number', r.room_number, 'arrival', s.arrival, 'departure', s.departure,
                   'charged', app.fo_company_part(s.id), 'scope', s.company_scope,
                   'invoice_no', (select i.invoice_no from public.fo_invoices i where i.stay_id = s.id and i.party = 'company'),
                   'due_date', s.departure + co.credit_days) as x
            from public.fo_stays s
            join public.fo_guests g on g.restaurant_id = s.restaurant_id and g.id = s.guest_id
            left join public.fo_rooms r on r.id = s.room_id
           where s.company_id = co.id and s.status in ('inhouse', 'checked_out')
             and app.fo_company_part(s.id) > 0) q;

  select coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'on', p.business_date, 'amount', p.amount,
           'method', p.method_name, 'reference', p.reference, 'voided', p.voided_at is not null, 'void_reason', p.void_reason)
           order by p.business_date, p.created_at), '[]'::jsonb),
         coalesce(sum(p.amount) filter (where p.voided_at is null), 0)
    into v_pays, v_paid
    from public.fo_company_payments p where p.company_id = co.id;

  return jsonb_build_object(
    'company', jsonb_build_object('company_id', co.id, 'name', co.name, 'gstin', co.gstin, 'address', co.address,
               'contact_name', co.contact_name, 'phone', co.phone, 'email', co.email, 'credit_days', co.credit_days,
               'credit_limit', co.credit_limit, 'active', co.active),
    'stays', v_stays, 'payments', v_pays,
    'summary', jsonb_build_object('charged', v_charged, 'paid', v_paid, 'outstanding', v_charged - v_paid,
               'overdue', greatest(0, v_due_before_today - v_paid),
               'over_limit', co.credit_limit is not null and (v_charged - v_paid) > co.credit_limit));
end $$;

-- ---------------------------------------------------------------- 6. folio: each charge says which side it is on
create or replace function public.fo_folio(p_stay uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        s public.fo_stays; v_charges jsonb; v_payments jsonb; v_charged numeric; v_company numeric; v_paid numeric; v_refunded numeric;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch;
  if not found then return null; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'charge_id', c.id, 'on', c.business_date, 'kind', c.kind, 'description', c.description,
           'quantity', c.quantity, 'unit_amount', c.unit_amount, 'net_amount', c.net_amount,
           'tax_pct', c.tax_pct, 'tax_amount', c.tax_amount, 'total', c.total_amount,
           'order_id', c.order_id, 'voided', c.voided_at is not null, 'void_reason', c.void_reason,
           'to_company', app.fo_to_company(s.company_id, s.company_scope, c.kind))
           order by c.business_date, c.created_at), '[]'::jsonb),
         coalesce(sum(c.total_amount) filter (where c.voided_at is null and not app.fo_to_company(s.company_id, s.company_scope, c.kind)), 0),
         coalesce(sum(c.total_amount) filter (where c.voided_at is null and app.fo_to_company(s.company_id, s.company_scope, c.kind)), 0)
    into v_charges, v_charged, v_company
    from public.fo_charges c where c.stay_id = s.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'payment_id', p.id, 'on', p.business_date, 'amount', p.amount, 'method', p.method_name,
           'is_refund', p.is_refund, 'reference', p.reference,
           'voided', p.voided_at is not null, 'void_reason', p.void_reason)
           order by p.business_date, p.created_at), '[]'::jsonb),
         coalesce(sum(p.amount) filter (where p.voided_at is null and not p.is_refund), 0),
         coalesce(sum(p.amount) filter (where p.voided_at is null and p.is_refund), 0)
    into v_payments, v_paid, v_refunded
    from public.fo_payments p where p.stay_id = s.id;

  return jsonb_build_object(
    'stay', jsonb_build_object(
      'stay_id', s.id, 'stay_no', s.stay_no, 'status', s.status, 'arrival', s.arrival, 'departure', s.departure,
      'nights', (s.departure - s.arrival), 'adults', s.adults, 'children', s.children,
      'nightly_rate', s.nightly_rate, 'source', s.source, 'notes', s.notes,
      'room_id', s.room_id,
      'room_number', (select r.room_number from public.fo_rooms r where r.id = s.room_id),
      'room_type', (select rt.name from public.fo_room_types rt where rt.restaurant_id = s.restaurant_id and rt.id = s.room_type_id),
      'rate_plan', (select pl.name from public.fo_rate_plans pl where pl.id = s.rate_plan_id),
      'rate_plan_code', (select pl.code from public.fo_rate_plans pl where pl.id = s.rate_plan_id),
      'meal_plan', (select pl.meal_plan from public.fo_rate_plans pl where pl.id = s.rate_plan_id),
      'rate_schedule', coalesce((select jsonb_agg(jsonb_build_object('night', r.night, 'rate', r.rate) order by r.night)
                                   from public.fo_stay_rates r where r.stay_id = s.id), '[]'::jsonb),
      'company', case when s.company_id is null then null else
                  (select jsonb_build_object('company_id', c.id, 'name', c.name, 'scope', s.company_scope) from public.fo_companies c where c.id = s.company_id) end,
      'guest', (select jsonb_build_object('guest_id', g.id, 'full_name', g.full_name, 'phone', g.phone, 'email', g.email)
                  from public.fo_guests g where g.restaurant_id = s.restaurant_id and g.id = s.guest_id)),
    'charges', v_charges, 'payments', v_payments,
    'totals', jsonb_build_object('charged', v_charged, 'company_charged', v_company, 'paid', v_paid, 'refunded', v_refunded,
                                 'balance', v_charged - v_paid + v_refunded));
end $$;

-- The group view counts only the guest side as "charged", to match its balance, and shows the company side beside it.
create or replace function public.fo_group_view(p_group uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); g public.fo_groups; v_stays jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into g from public.fo_groups where id = p_group and restaurant_id = v_rest and branch_id = v_branch;
  if not found then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'stay_id', s.id, 'stay_no', s.stay_no, 'status', s.status, 'guest_id', s.guest_id, 'guest_name', gu.full_name,
           'room_type', rt.name, 'room_number', r.room_number, 'rate', s.nightly_rate, 'adults', s.adults, 'children', s.children,
           'company', (select co.name from public.fo_companies co where co.id = s.company_id), 'company_scope', s.company_scope,
           'company_part', app.fo_company_part(s.id),
           'charged', coalesce((select sum(c.total_amount) from public.fo_charges c
                                 where c.stay_id = s.id and c.voided_at is null
                                   and not app.fo_to_company(s.company_id, s.company_scope, c.kind)), 0),
           'paid', coalesce((select sum(case when p.is_refund then -p.amount else p.amount end) from public.fo_payments p where p.stay_id = s.id and p.voided_at is null), 0),
           'balance', app.fo_balance(s.id)) order by s.stay_no), '[]'::jsonb)
    into v_stays
    from public.fo_stays s
    join public.fo_guests gu on gu.restaurant_id = s.restaurant_id and gu.id = s.guest_id
    join public.fo_room_types rt on rt.restaurant_id = s.restaurant_id and rt.id = s.room_type_id
    left join public.fo_rooms r on r.id = s.room_id
   where s.group_id = g.id;
  return jsonb_build_object(
    'group', jsonb_build_object('group_id', g.id, 'group_no', g.group_no, 'name', g.name, 'status', g.status,
             'arrival', g.arrival, 'departure', g.departure, 'nights', g.departure - g.arrival, 'notes', g.notes,
             'contact_guest_id', g.contact_guest_id, 'contact_name', (select full_name from public.fo_guests where id = g.contact_guest_id),
             'cancel_reason', g.cancel_reason),
    'stays', v_stays,
    'totals', jsonb_build_object(
      'rooms', (select count(*) from jsonb_array_elements(v_stays) x where x ->> 'status' <> 'cancelled'),
      'charged', (select coalesce(sum((x ->> 'charged')::numeric), 0) from jsonb_array_elements(v_stays) x),
      'company_part', (select coalesce(sum((x ->> 'company_part')::numeric), 0) from jsonb_array_elements(v_stays) x),
      'paid', (select coalesce(sum((x ->> 'paid')::numeric), 0) from jsonb_array_elements(v_stays) x),
      'balance', (select coalesce(sum((x ->> 'balance')::numeric), 0) from jsonb_array_elements(v_stays) x where x ->> 'status' <> 'cancelled')));
end $$;

-- ---------------------------------------------------------------- 7. tax invoices, one per party
drop function if exists public.fo_issue_invoice(uuid, text, text, text, text);
drop function if exists public.fo_invoice_for_stay(uuid);

create or replace function public.fo_issue_invoice(
  p_stay uuid, p_bill_to_name text default null, p_bill_to_gstin text default null,
  p_bill_to_address text default null, p_bill_to_state_code text default null, p_party text default 'guest') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; cfg public.fo_branch_settings; g public.fo_guests; inv public.fo_invoices; co public.fo_companies;
        v_today date; v_fy text; v_no int; v_number text; v_company boolean := (p_party = 'company');
        v_gstin text := upper(nullif(btrim(coalesce(p_bill_to_gstin, '')), ''));
        v_name text; v_addr text; v_state text;
        v_lines jsonb; v_summary jsonb; v_pay jsonb := '[]'::jsonb; v_taxable numeric; v_tax numeric; v_total numeric;
begin
  v_user := app.require_fo(array['fo.manage']);
  if p_party not in ('guest', 'company') then raise exception 'The invoice is for the guest or for the company.'; end if;
  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;

  select * into inv from public.fo_invoices where stay_id = s.id and party = p_party;
  if found then
    return jsonb_build_object('invoice_id', inv.id, 'invoice_no', inv.invoice_no, 'repeat', true);
  end if;
  if s.status <> 'checked_out' then
    raise exception 'The tax invoice is issued after check-out, when the folio is final. This stay is %.', s.status; end if;
  if v_company and s.company_id is null then raise exception 'This stay has no company to invoice.'; end if;

  select * into cfg from public.fo_branch_settings where branch_id = v_branch;
  if not found or coalesce(btrim(coalesce(cfg.legal_name, '')), '') = '' or coalesce(btrim(coalesce(cfg.address, '')), '') = '' then
    raise exception 'Fill in the hotel''s legal name and address first (Rooms and rates, Business details).'; end if;

  select * into g from public.fo_guests where id = s.guest_id and restaurant_id = v_rest;

  select coalesce(jsonb_agg(jsonb_build_object(
           'on', c.business_date, 'kind', c.kind, 'description', c.description, 'sac', app.fo_sac(c.kind),
           'quantity', c.quantity, 'unit_amount', c.unit_amount, 'taxable', c.net_amount,
           'tax_pct', c.tax_pct, 'tax', c.tax_amount, 'total', c.total_amount)
           order by c.business_date, c.created_at), '[]'::jsonb),
         coalesce(sum(c.net_amount), 0), coalesce(sum(c.tax_amount), 0), coalesce(sum(c.total_amount), 0)
    into v_lines, v_taxable, v_tax, v_total
    from public.fo_charges c
   where c.stay_id = s.id and c.voided_at is null
     and app.fo_to_company(s.company_id, s.company_scope, c.kind) = v_company;
  if jsonb_array_length(v_lines) = 0 then
    raise exception 'There is nothing on the %''s side of this folio to invoice.', case when v_company then 'company' else 'guest' end; end if;

  if v_tax > 0 and cfg.gstin is null then
    raise exception 'This folio carries GST, so the hotel''s GSTIN is needed on the invoice (Rooms and rates, Business details).'; end if;

  if v_company then
    select * into co from public.fo_companies where id = s.company_id;
    v_gstin := co.gstin; v_name := co.name; v_addr := co.address; v_state := co.state_code;
  else
    if v_gstin is not null then
      if v_gstin !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
        raise exception 'That GSTIN does not look right. It has 15 characters, like 33AAACA0000A1Z5.'; end if;
      if coalesce(btrim(coalesce(p_bill_to_name, '')), '') = '' then
        raise exception 'Give the business name that goes with the GSTIN.'; end if;
    end if;
    v_name := coalesce(nullif(btrim(coalesce(p_bill_to_name, '')), ''), g.full_name);
    v_addr := coalesce(nullif(btrim(coalesce(p_bill_to_address, '')), ''), nullif(btrim(coalesce(g.address, '')), ''));
    v_state := coalesce(nullif(btrim(coalesce(p_bill_to_state_code, '')), ''), case when v_gstin is not null then substr(v_gstin, 1, 2) end);
    if v_state is not null and v_state !~ '^[0-9]{2}$' then raise exception 'The state code is two digits.'; end if;
    if v_gstin is not null and v_state is not null and substr(v_gstin, 1, 2) <> v_state then
      raise exception 'The GSTIN starts with % but the state code is %.', substr(v_gstin, 1, 2), v_state; end if;
  end if;
  if v_gstin is null and v_total >= 50000 and (v_addr is null or v_state is null) then
    raise exception 'A bill of 50,000 or more to a party without a GSTIN needs an address and state code on the invoice.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sac', x.sac, 'tax_pct', x.tax_pct, 'taxable', x.taxable, 'tax', x.tax,
           'cgst', round(x.tax / 2, 2), 'sgst', x.tax - round(x.tax / 2, 2)) order by x.sac, x.tax_pct), '[]'::jsonb)
    into v_summary
    from (select app.fo_sac(c.kind) as sac, c.tax_pct, sum(c.net_amount) as taxable, sum(c.tax_amount) as tax
            from public.fo_charges c
           where c.stay_id = s.id and c.voided_at is null and app.fo_to_company(s.company_id, s.company_scope, c.kind) = v_company
           group by 1, 2) x;

  if not v_company then
    select coalesce(jsonb_agg(jsonb_build_object('on', p.business_date, 'method', p.method_name, 'amount', p.amount,
             'is_refund', p.is_refund, 'reference', p.reference) order by p.business_date, p.created_at), '[]'::jsonb)
      into v_pay from public.fo_payments p where p.stay_id = s.id and p.voided_at is null;
  end if;

  v_today := app.business_today(v_branch);
  v_fy := app.fy_label('IN', v_today);
  v_fy := substr(v_fy, 3, 2) || substr(v_fy, 6, 2);
  insert into public.fo_invoice_counters (branch_id, fy, last_no) values (v_branch, v_fy, 0) on conflict do nothing;
  update public.fo_invoice_counters set last_no = last_no + 1 where branch_id = v_branch and fy = v_fy returning last_no into v_no;
  v_number := cfg.invoice_prefix || '/' || v_fy || '/' || lpad(v_no::text, 6, '0');

  insert into public.fo_invoices (restaurant_id, branch_id, stay_id, invoice_no, fy, seq, invoice_date,
         bill_to_name, bill_to_gstin, bill_to_address, bill_to_state_code, taxable, tax, total, snapshot, issued_by, party, company_id)
  values (v_rest, v_branch, s.id, v_number, v_fy, v_no, v_today, v_name, v_gstin, v_addr, v_state,
          v_taxable, v_tax, v_total,
          jsonb_build_object(
            'party', p_party,
            'property', jsonb_build_object('legal_name', cfg.legal_name, 'gstin', cfg.gstin, 'state_code', cfg.state_code,
                          'address', cfg.address, 'phone', cfg.phone, 'email', cfg.email, 'footer', cfg.invoice_footer),
            'bill_to', jsonb_build_object('name', v_name, 'gstin', v_gstin, 'address', v_addr, 'state_code', v_state),
            'guest', jsonb_build_object('name', g.full_name, 'phone', g.phone),
            'stay', jsonb_build_object('stay_no', s.stay_no, 'arrival', s.arrival, 'departure', s.departure,
                          'nights', s.departure - s.arrival, 'adults', s.adults, 'children', s.children,
                          'room_number', (select r.room_number from public.fo_rooms r where r.id = s.room_id),
                          'room_type', (select rt.name from public.fo_room_types rt where rt.restaurant_id = s.restaurant_id and rt.id = s.room_type_id),
                          'rate_plan', (select pl.name from public.fo_rate_plans pl where pl.id = s.rate_plan_id),
                          'checked_out_at', s.checked_out_at),
            'lines', v_lines, 'tax_summary', v_summary, 'payments', v_pay,
            'totals', jsonb_build_object('taxable', v_taxable, 'tax', v_tax, 'total', v_total),
            'supply', jsonb_build_object('type', 'intra', 'place_of_supply_state_code', cfg.state_code, 'reverse_charge', false)),
          v_user, p_party, case when v_company then s.company_id end)
  returning * into inv;

  if not v_company and v_gstin is not null then
    update public.fo_guests set bill_company = v_name, bill_gstin = v_gstin, bill_state_code = v_state
     where id = g.id and restaurant_id = v_rest;
  end if;

  perform app.audit('fo_invoice_issued', 'fo_invoice', inv.id,
    jsonb_build_object('invoice_no', v_number, 'stay_id', s.id, 'party', p_party, 'total', v_total, 'gstin', v_gstin));
  return jsonb_build_object('invoice_id', inv.id, 'invoice_no', v_number, 'total', v_total, 'repeat', false);
end $$;

create or replace function public.fo_invoice_for_stay(p_stay uuid, p_party text default 'guest') returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        s public.fo_stays; inv public.fo_invoices; g public.fo_guests; cfg public.fo_branch_settings; co public.fo_companies;
        v_company boolean := (p_party = 'company'); v_lines int;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch;
  if not found then return null; end if;
  select * into inv from public.fo_invoices where stay_id = s.id and party = p_party;
  if found then
    return jsonb_build_object('issued', true, 'party', p_party, 'invoice_id', inv.id, 'invoice_no', inv.invoice_no,
      'invoice_date', inv.invoice_date, 'total', inv.total, 'snapshot', inv.snapshot);
  end if;
  select count(*) into v_lines from public.fo_charges c
   where c.stay_id = s.id and c.voided_at is null and app.fo_to_company(s.company_id, s.company_scope, c.kind) = v_company;
  select * into g from public.fo_guests where id = s.guest_id and restaurant_id = v_rest;
  select * into cfg from public.fo_branch_settings where branch_id = v_branch;
  select * into co from public.fo_companies where id = s.company_id;
  return jsonb_build_object('issued', false, 'party', p_party,
    'has_lines', v_lines > 0 and (not v_company or s.company_id is not null),
    'ready', s.status = 'checked_out' and coalesce(cfg.legal_name, '') <> '' and coalesce(cfg.address, '') <> '',
    'status', s.status,
    'has_business_details', coalesce(cfg.legal_name, '') <> '' and coalesce(cfg.address, '') <> '',
    'has_gstin', cfg.gstin is not null,
    'prefill', case when v_company
      then jsonb_build_object('name', co.name, 'gstin', co.gstin, 'address', co.address, 'state_code', co.state_code)
      else jsonb_build_object('name', coalesce(g.bill_company, g.full_name), 'gstin', g.bill_gstin,
                'address', g.address, 'state_code', g.bill_state_code) end);
end $$;

revoke all on function
  public.fo_save_company(text, text, text, text, text, text, text, int, numeric, boolean, uuid), public.fo_companies_list(boolean),
  public.fo_set_stay_company(uuid, uuid, text), public.fo_set_group_company(uuid, uuid, text),
  public.fo_take_company_payment(uuid, numeric, uuid, text, uuid), public.fo_void_company_payment(uuid, text),
  public.fo_company_ledger(uuid), public.fo_folio(uuid), public.fo_group_view(uuid),
  public.fo_issue_invoice(uuid, text, text, text, text, text), public.fo_invoice_for_stay(uuid, text) from public, anon;
grant execute on function
  public.fo_save_company(text, text, text, text, text, text, text, int, numeric, boolean, uuid), public.fo_companies_list(boolean),
  public.fo_set_stay_company(uuid, uuid, text), public.fo_set_group_company(uuid, uuid, text),
  public.fo_take_company_payment(uuid, numeric, uuid, text, uuid), public.fo_void_company_payment(uuid, text),
  public.fo_company_ledger(uuid), public.fo_folio(uuid), public.fo_group_view(uuid),
  public.fo_issue_invoice(uuid, text, text, text, text, text), public.fo_invoice_for_stay(uuid, text) to authenticated, service_role;
