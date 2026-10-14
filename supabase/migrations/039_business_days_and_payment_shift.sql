-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928091146, name '39_business_days_and_payment_shift'. This is the SQL that actually ran.

-- A business day per branch. Bills belong to the day that was open when they were made.
create table public.business_days (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  business_date date not null,
  status text not null default 'open' check (status in ('open', 'closed', 'parked')),
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by uuid,
  close_notes text,
  z_report jsonb,
  reopen_count int not null default 0,
  created_at timestamptz not null default now(),
  unique (branch_id, business_date),
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id)
);
create unique index business_days_one_open on public.business_days (branch_id) where status = 'open';
create unique index business_days_one_parked on public.business_days (branch_id) where status = 'parked';
alter table public.business_days enable row level security;
create policy tenant_read on public.business_days for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()));
grant select on public.business_days to authenticated;

alter table public.orders add column business_date date;
alter table public.payments add column shift_id uuid;
alter table public.refunds add column shift_id uuid, add column payment_method_id uuid, add column credit_note_id uuid;

-- The open day of a branch; opens one when needed. Date = the later of today (local) and the day after the last day.
create or replace function app.open_business_day(p_branch uuid) returns public.business_days
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare d public.business_days; v_rest uuid; v_tz text; v_date date;
begin
  select * into d from public.business_days where branch_id = p_branch and status = 'open';
  if found then return d; end if;
  select b.restaurant_id, coalesce(b.timezone, r.timezone) into v_rest, v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = p_branch;
  if v_rest is null then raise exception 'Branch not found.'; end if;
  perform pg_advisory_xact_lock(hashtext('business_day:' || p_branch::text));
  select * into d from public.business_days where branch_id = p_branch and status = 'open';
  if found then return d; end if;
  select greatest((now() at time zone coalesce(v_tz, 'UTC'))::date,
                  coalesce(max(business_date) + 1, (now() at time zone coalesce(v_tz, 'UTC'))::date))
    into v_date from public.business_days where branch_id = p_branch;
  insert into public.business_days (restaurant_id, branch_id, business_date) values (v_rest, p_branch, v_date)
  returning * into d;
  return d;
end $$;

-- Existing bills: their local calendar date becomes their business day (all closed except today).
do $$
declare r record;
begin
  update public.orders o set business_date = (o.created_at at time zone coalesce(b.timezone, re.timezone, 'UTC'))::date
    from public.branches b, public.restaurants re
   where b.id = o.branch_id and re.id = o.restaurant_id and o.business_date is null;
  for r in select distinct restaurant_id, branch_id, business_date from public.orders loop
    insert into public.business_days (restaurant_id, branch_id, business_date, status, closed_at)
    values (r.restaurant_id, r.branch_id, r.business_date, 'closed', now())
    on conflict (branch_id, business_date) do nothing;
  end loop;
end $$;
alter table public.orders add constraint orders_business_day_fk
  foreign key (branch_id, business_date) references public.business_days(branch_id, business_date);

create or replace function app.set_order_business_date() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  new.business_date := (app.open_business_day(new.branch_id)).business_date;
  return new;
end $$;
create trigger trg_order_business_date before insert on public.orders
  for each row execute function app.set_order_business_date();

-- A closed day is frozen: its bills cannot change (credit notes are made on today instead).
create or replace function app.guard_closed_day() returns trigger
language plpgsql set search_path to 'public','pg_temp' as $$
declare v_status text; v_order public.orders%rowtype;
begin
  if coalesce(current_setting('app.day_ok', true), '') = 'on' then return new; end if;
  if tg_table_name = 'orders' then
    select status into v_status from public.business_days where branch_id = old.branch_id and business_date = old.business_date;
    if v_status = 'closed' and (to_jsonb(new) - 'updated_at' - 'synced_at') is distinct from (to_jsonb(old) - 'updated_at' - 'synced_at') then
      raise exception 'The day % is closed, so bill % cannot be changed. Issue a credit note instead, or reopen the day.',
        to_char(old.business_date, 'DD Mon YYYY'), old.bill_number;
    end if;
  else
    select * into v_order from public.orders where id = new.order_id;
    select status into v_status from public.business_days where branch_id = v_order.branch_id and business_date = v_order.business_date;
    if v_status = 'closed' then
      raise exception 'The day % is closed, so bill % cannot be changed.', to_char(v_order.business_date, 'DD Mon YYYY'), v_order.bill_number;
    end if;
  end if;
  return new;
end $$;
create trigger trg_guard_closed_day before update on public.orders
  for each row execute function app.guard_closed_day();
create trigger trg_guard_closed_day_pay before insert on public.payments
  for each row execute function app.guard_closed_day();
create trigger trg_guard_closed_day_items before insert or update on public.order_items
  for each row execute function app.guard_closed_day();

-- Every payment remembers the shift that received it (cash counts in the drawer that took it).
create or replace function app.set_payment_shift() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if new.shift_id is null then
    select s.id into new.shift_id from public.shifts s join public.orders o on o.branch_id = s.branch_id
     where o.id = new.order_id and s.status = 'open' order by s.opened_at desc limit 1;
  end if;
  return new;
end $$;
create trigger trg_payment_shift before insert on public.payments
  for each row execute function app.set_payment_shift();
update public.payments p set shift_id = o.shift_id from public.orders o where o.id = p.order_id and p.shift_id is null;

-- Drawer figures: money counts in the shift that took (or paid out) it.
create or replace function app.shift_figures(p_shift uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare
  s public.shifts%rowtype;
  v_cash_sales numeric(14,2); v_cash_refunds numeric(14,2);
  v_in numeric(14,2); v_out numeric(14,2);
  v_bills int; v_sales numeric(14,2); v_voided int; v_unpaid int; v_methods jsonb;
begin
  select * into s from public.shifts where id = p_shift;
  if not found then return null; end if;

  select coalesce(sum(p.amount),0) into v_cash_sales
    from public.payments p
    join public.orders o on o.id = p.order_id
    join public.payment_methods pm on pm.id = p.payment_method_id
   where coalesce(p.shift_id, o.shift_id) = s.id and o.status <> 'voided'
     and pm.affects_cash_drawer and p.status = 'captured';

  select coalesce(sum(r.amount),0) into v_cash_refunds
    from public.refunds r
    left join public.payments p on p.id = r.payment_id
    join public.payment_methods pm on pm.id = coalesce(r.payment_method_id, p.payment_method_id)
   where pm.affects_cash_drawer
     and (r.shift_id = s.id
          or (r.shift_id is null and r.restaurant_id = s.restaurant_id
              and exists (select 1 from public.orders o2 where o2.id = r.order_id and o2.branch_id = s.branch_id)
              and r.created_at >= s.opened_at and (s.closed_at is null or r.created_at <= s.closed_at)));

  select coalesce(sum(amount) filter (where direction='in'),0),
         coalesce(sum(amount) filter (where direction='out'),0)
    into v_in, v_out from public.cash_movements where shift_id = s.id;

  select count(*) filter (where status <> 'voided'),
         coalesce(sum(grand_total) filter (where status <> 'voided'),0),
         count(*) filter (where status = 'voided'),
         count(*) filter (where status <> 'voided' and payment_status in ('unpaid', 'partial'))
    into v_bills, v_sales, v_voided, v_unpaid
    from public.orders where shift_id = s.id and merged_into is null;

  select coalesce(jsonb_agg(jsonb_build_object('method', m.name, 'bills', m.n, 'amount', m.amt)
                            order by m.amt desc), '[]'::jsonb)
    into v_methods
    from (select pm.name, count(*) n, sum(p.amount) amt
            from public.payments p
            join public.orders o on o.id = p.order_id
            join public.payment_methods pm on pm.id = p.payment_method_id
           where coalesce(p.shift_id, o.shift_id) = s.id and o.status <> 'voided' and p.status = 'captured'
           group by pm.name) m;

  return jsonb_build_object(
    'shift_id', s.id, 'status', s.status, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
    'opened_by', (select full_name from public.users where id = s.opened_by),
    'closed_by', (select full_name from public.users where id = s.closed_by),
    'opening_float', s.opening_float,
    'bills', v_bills, 'sales', v_sales, 'voided', v_voided, 'unpaid', v_unpaid,
    'cash_sales', v_cash_sales, 'cash_refunds', v_cash_refunds,
    'cash_in', v_in, 'cash_out', v_out,
    'expected_cash', case when s.status = 'closed' and s.expected_cash is not null
                          then s.expected_cash
                          else s.opening_float + v_cash_sales - v_cash_refunds + v_in - v_out end,
    'counted_cash', s.counted_cash, 'variance', s.cash_variance, 'notes', s.notes,
    'by_method', v_methods);
end $$;

-- Rights for day close / reopen.
insert into public.permissions (key, description, is_sensitive) values
  ('day.close', 'Close the business day (end-of-day report)', true),
  ('day.reopen', 'Reopen the last closed day', true)
on conflict (key) do nothing;
insert into public.role_permissions (role_id, permission_key)
select r.id, k from public.roles r cross join (values ('day.close'), ('day.reopen')) v(k)
 where r.is_system and (r.name = 'Owner' or (r.name = 'Manager' and k = 'day.close'))
on conflict do nothing;
