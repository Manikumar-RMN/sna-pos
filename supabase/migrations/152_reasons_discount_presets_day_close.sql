-- 152: Reasons list, discount presets, a maximum discount, and "do not close the day before" (live migration
-- 20261102192626, name '152_reasons_discount_presets_day_close').
--
-- RECONSTRUCTED on 2026-11-04. The original SQL file was never committed. This file was rebuilt from the live database
-- catalog (tables, constraints, indexes, policies, grants, and the function bodies exactly as they run). It produces the
-- same objects; it is not byte-for-byte the text that was first applied. Run on a database that already has 152 it is safe
-- (every statement is repeatable).
--
--   1. reasons              A per-restaurant list of reasons (void a bill, cancel an item, discount, complimentary, refund, change
--                           payment mode, cash out). 24 are seeded for every restaurant, old and new. save_reason / list_reasons.
--   2. discount_presets     Named discounts (percent or amount) with dates, order types and outlets. save_discount_preset,
--                           list_discount_presets (for the billing screen), list_discount_presets_admin (for settings).
--   3. discount_settings    One row per restaurant: the largest discount allowed, as a percent of the bill (null = no limit).
--                           set_max_discount, get_discount_settings, trigger trg_discount_cap on order_discounts, and the
--                           permission discount.over_limit (owners) to go above it.
--   4. day_close_not_before branch_settings column + set_day_close_not_before, enforced in close_day for people without
--                           settings.manage.
--   5. report_reasons_summary   "Void, discount, complimentary and refund reasons" report by reason and staff.
--   6. erase_groups         Discount presets are part of what "erase POS master data" removes.

-- ---------------------------------------------------------------- 1. reasons
create table if not exists public.reasons (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null,
  purposes text[] not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint reasons_name_check check (length(name) >= 2 and length(name) <= 60 and name = btrim(name)),
  constraint reasons_purposes_check check (cardinality(purposes) >= 1 and purposes <@ array['void_bill', 'cancel_item', 'discount', 'complimentary', 'refund', 'change_payment', 'cash_out']::text[])
);
create unique index if not exists reasons_restaurant_name_uq on public.reasons (restaurant_id, lower(name));
alter table public.reasons enable row level security;
drop policy if exists tenant_read on public.reasons;
create policy tenant_read on public.reasons for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
revoke all on public.reasons from anon, authenticated;
grant select on public.reasons to authenticated;

-- ---------------------------------------------------------------- 2. discount presets
create table if not exists public.discount_presets (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null,
  kind text not null,
  value numeric(14,2) not null,
  valid_from date,
  valid_to date,
  order_types text[] not null default '{dine_in,takeaway,delivery}'::text[],
  outlet_ids uuid[],
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint discount_presets_name_check check (length(name) >= 2 and length(name) <= 60 and name = btrim(name)),
  constraint discount_presets_kind_check check (kind = any (array['percent', 'amount'])),
  constraint discount_presets_value_check check (value > 0),
  constraint discount_presets_percent_max check (kind <> 'percent' or value <= 100),
  constraint discount_presets_dates check (valid_from is null or valid_to is null or valid_from <= valid_to),
  constraint discount_presets_order_types_check check (cardinality(order_types) >= 1 and order_types <@ array['dine_in', 'takeaway', 'delivery']::text[])
);
create unique index if not exists discount_presets_restaurant_name_uq on public.discount_presets (restaurant_id, lower(name));
alter table public.discount_presets enable row level security;
drop policy if exists tenant_read on public.discount_presets;
create policy tenant_read on public.discount_presets for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
revoke all on public.discount_presets from anon, authenticated;
grant select on public.discount_presets to authenticated;

-- ---------------------------------------------------------------- 3. maximum discount
create table if not exists public.discount_settings (
  restaurant_id uuid primary key references public.restaurants(id) on delete cascade,
  max_discount_percent numeric(5,2),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.users(id) on delete set null,
  constraint discount_settings_max_discount_percent_check check (max_discount_percent is null or (max_discount_percent >= 1 and max_discount_percent <= 100))
);
alter table public.discount_settings enable row level security;
drop policy if exists tenant_read on public.discount_settings;
create policy tenant_read on public.discount_settings for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
revoke all on public.discount_settings from anon, authenticated;
grant select on public.discount_settings to authenticated;

insert into public.permissions (key, description, is_sensitive)
values ('discount.over_limit', 'Give a discount above the maximum discount percent', true)
on conflict (key) do nothing;
insert into public.role_permissions (role_id, permission_key)
select r.id, 'discount.over_limit' from public.roles r where r.name = 'Owner'
on conflict do nothing;

-- ---------------------------------------------------------------- 4. day close not before
alter table public.branch_settings add column if not exists day_close_not_before time;

-- ---------------------------------------------------------------- reasons: the starting list
create or replace function app.seed_reasons(p_restaurant uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  insert into public.reasons (restaurant_id, name, purposes, sort_order)
  select p_restaurant, s.name, s.purposes, s.ord
    from (values
      ( 10, 'Wrong order',          array['void_bill']),
      ( 20, 'Guest left',           array['void_bill']),
      ( 30, 'Duplicate bill',       array['void_bill']),
      ( 40, 'Price error',          array['void_bill']),
      ( 50, 'Guest changed mind',   array['cancel_item']),
      ( 60, 'Kitchen out of stock', array['cancel_item']),
      ( 70, 'Wrong item punched',   array['cancel_item']),
      ( 80, 'Too slow',             array['cancel_item']),
      ( 90, 'Member',               array['discount']),
      (100, 'Staff',                array['discount']),
      (110, 'Service recovery',     array['discount']),
      (120, 'Promotion',            array['discount']),
      (130, 'Owner approved',       array['discount']),
      (140, 'Guest recovery',       array['complimentary']),
      (150, 'Owner / GM office',    array['complimentary']),
      (160, 'Sales and marketing',  array['complimentary']),
      (170, 'Group buffet',         array['complimentary']),
      (180, 'Meal plan',            array['complimentary']),
      (190, 'Staff meal',           array['complimentary']),
      (200, 'Food quality',         array['refund']),
      (210, 'Wrong charge',         array['refund']),
      (220, 'Wrong mode picked',    array['change_payment']),
      (230, 'Supplier payment',     array['cash_out']),
      (240, 'Petty expense',        array['cash_out'])) s(ord, name, purposes)
  on conflict (restaurant_id, lower(name)) do nothing;
end $function$;
revoke all on function app.seed_reasons(uuid) from public, anon, authenticated;

create or replace function app.trg_seed_reasons()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  perform app.seed_reasons(new.id);
  return new;
end $function$;
revoke all on function app.trg_seed_reasons() from public, anon, authenticated;
drop trigger if exists trg_seed_reasons on public.restaurants;
create trigger trg_seed_reasons after insert on public.restaurants
  for each row execute function app.trg_seed_reasons();

-- every restaurant that already exists gets the starting list too
select app.seed_reasons(id) from public.restaurants;

create or replace function public.list_reasons(p_purpose text default null::text)
 returns table(id uuid, name text, purposes text[], is_active boolean, sort_order integer)
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id(); v_all boolean;
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_purpose is not null and p_purpose not in ('void_bill', 'cancel_item', 'discount', 'complimentary', 'refund', 'change_payment', 'cash_out') then
    raise exception 'Unknown reason type "%".', p_purpose;
  end if;
  -- everything (hidden ones too) only for a person who manages settings and asked for all purposes
  v_all := p_purpose is null and app.has_permission('settings.manage');
  return query
    select r.id, r.name, r.purposes, r.is_active, r.sort_order
      from public.reasons r
     where r.restaurant_id = v_rest
       and (v_all or r.is_active)
       and (p_purpose is null or p_purpose = any (r.purposes))
     order by r.sort_order, lower(r.name), r.id;
end $function$;

create or replace function public.save_reason(p_id uuid, p_name text, p_purposes text[], p_active boolean default true, p_sort integer default null::integer)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid; v_name text := btrim(coalesce(p_name, '')); v_pur text[]; v_sort int; v_id uuid; old public.reasons%rowtype;
begin
  perform app.require_permission('settings.manage');
  v_rest := app.current_restaurant_id();
  if length(v_name) < 2 or length(v_name) > 60 then raise exception 'A reason must be between 2 and 60 letters long.'; end if;
  select coalesce(array_agg(x order by x), '{}') into v_pur from (select distinct unnest(coalesce(p_purposes, '{}')) x) z;
  if cardinality(v_pur) = 0 then raise exception 'Choose at least one place where this reason is used.'; end if;
  if not (v_pur <@ array['void_bill', 'cancel_item', 'discount', 'complimentary', 'refund', 'change_payment', 'cash_out']::text[]) then
    raise exception 'One of the places chosen for this reason is not known.';
  end if;
  if exists (select 1 from public.reasons r where r.restaurant_id = v_rest and lower(r.name) = lower(v_name) and r.id is distinct from p_id) then
    raise exception 'There is already a reason called "%".', v_name;
  end if;
  if p_id is null then
    v_sort := coalesce(p_sort, (select coalesce(max(r.sort_order), 0) + 10 from public.reasons r where r.restaurant_id = v_rest));
    insert into public.reasons (restaurant_id, name, purposes, is_active, sort_order)
    values (v_rest, v_name, v_pur, coalesce(p_active, true), v_sort) returning id into v_id;
    perform app.audit('reason.create', 'reasons', v_id,
      jsonb_build_object('name', v_name, 'purposes', v_pur, 'is_active', coalesce(p_active, true), 'sort_order', v_sort), null);
  else
    select * into old from public.reasons r where r.id = p_id and r.restaurant_id = v_rest for update;
    if not found then raise exception 'That reason was not found.'; end if;
    v_sort := coalesce(p_sort, old.sort_order);
    update public.reasons set name = v_name, purposes = v_pur, is_active = coalesce(p_active, true), sort_order = v_sort where id = p_id;
    v_id := p_id;
    perform app.audit('reason.update', 'reasons', v_id,
      jsonb_build_object('name', v_name, 'purposes', v_pur, 'is_active', coalesce(p_active, true), 'sort_order', v_sort),
      jsonb_build_object('name', old.name, 'purposes', old.purposes, 'is_active', old.is_active, 'sort_order', old.sort_order));
  end if;
  return v_id;
end $function$;

-- ---------------------------------------------------------------- discount presets
create or replace function public.list_discount_presets(p_order_type text default null::text)
 returns table(id uuid, name text, kind text, value numeric, valid_from date, valid_to date, order_types text[], outlet_ids uuid[], sort_order integer)
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid; v_today date;
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  v_branch := app.current_branch_id();
  v_today := coalesce(app.business_today(v_branch), current_date);
  return query
    select p.id, p.name, p.kind, p.value, p.valid_from, p.valid_to, p.order_types, p.outlet_ids, p.sort_order
      from public.discount_presets p
     where p.restaurant_id = v_rest and p.is_active
       and (p.valid_from is null or p.valid_from <= v_today)
       and (p.valid_to is null or p.valid_to >= v_today)
       and (p.outlet_ids is null or v_branch = any (p.outlet_ids))
       and (p_order_type is null or p_order_type = any (p.order_types))
     order by p.sort_order, lower(p.name), p.id;
end $function$;

create or replace function public.list_discount_presets_admin()
 returns table(id uuid, name text, kind text, value numeric, valid_from date, valid_to date, order_types text[], outlet_ids uuid[], is_active boolean, sort_order integer, created_at timestamp with time zone)
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid;
begin
  perform app.require_permission('settings.manage');
  v_rest := app.current_restaurant_id();
  return query
    select p.id, p.name, p.kind, p.value, p.valid_from, p.valid_to, p.order_types, p.outlet_ids, p.is_active, p.sort_order, p.created_at
      from public.discount_presets p
     where p.restaurant_id = v_rest
     order by p.sort_order, lower(p.name), p.id;
end $function$;

create or replace function public.save_discount_preset(p_id uuid, p_name text, p_kind text, p_value numeric, p_valid_from date default null::date, p_valid_to date default null::date, p_order_types text[] default null::text[], p_outlet_ids uuid[] default null::uuid[], p_active boolean default true, p_sort integer default null::integer)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid; v_name text := btrim(coalesce(p_name, '')); v_val numeric(14,2); v_ot text[]; v_out uuid[]; v_sort int; v_id uuid; old public.discount_presets%rowtype;
begin
  perform app.require_permission('settings.manage');
  v_rest := app.current_restaurant_id();
  if length(v_name) < 2 or length(v_name) > 60 then raise exception 'A discount name must be between 2 and 60 letters long.'; end if;
  if p_kind is null or p_kind not in ('percent', 'amount') then raise exception 'Choose whether the discount is a percentage or an amount.'; end if;
  if p_value is null or round(p_value, 2) <= 0 then raise exception 'The discount must be more than zero.'; end if;
  v_val := round(p_value, 2);
  if p_kind = 'percent' and v_val > 100 then raise exception 'A percentage discount cannot be more than 100%%.'; end if;
  if p_valid_from is not null and p_valid_to is not null and p_valid_from > p_valid_to then
    raise exception 'The "valid to" date cannot be before the "valid from" date.';
  end if;
  if p_order_types is null or cardinality(p_order_types) = 0 then
    v_ot := array['dine_in', 'takeaway', 'delivery'];
  else
    select coalesce(array_agg(x order by x), '{}') into v_ot from (select distinct unnest(p_order_types) x) z;
    if not (v_ot <@ array['dine_in', 'takeaway', 'delivery']::text[]) then raise exception 'Choose from dine-in, takeaway and delivery.'; end if;
  end if;
  if p_outlet_ids is null or cardinality(p_outlet_ids) = 0 then
    v_out := null;                                   -- every outlet
  else
    select array_agg(distinct x) into v_out from unnest(p_outlet_ids) x;
    if exists (select 1 from unnest(v_out) x where not exists (select 1 from public.branches b where b.id = x and b.restaurant_id = v_rest and b.deleted_at is null)) then
      raise exception 'One of the outlets chosen does not exist.';
    end if;
  end if;
  if exists (select 1 from public.discount_presets d where d.restaurant_id = v_rest and lower(d.name) = lower(v_name) and d.id is distinct from p_id) then
    raise exception 'There is already a discount called "%".', v_name;
  end if;
  if p_id is null then
    v_sort := coalesce(p_sort, (select coalesce(max(d.sort_order), 0) + 10 from public.discount_presets d where d.restaurant_id = v_rest));
    insert into public.discount_presets (restaurant_id, name, kind, value, valid_from, valid_to, order_types, outlet_ids, is_active, sort_order)
    values (v_rest, v_name, p_kind, v_val, p_valid_from, p_valid_to, v_ot, v_out, coalesce(p_active, true), v_sort) returning id into v_id;
    perform app.audit('discount_preset.create', 'discount_presets', v_id,
      jsonb_build_object('name', v_name, 'kind', p_kind, 'value', v_val, 'valid_from', p_valid_from, 'valid_to', p_valid_to,
                         'order_types', v_ot, 'outlet_ids', v_out, 'is_active', coalesce(p_active, true)), null);
  else
    select * into old from public.discount_presets d where d.id = p_id and d.restaurant_id = v_rest for update;
    if not found then raise exception 'That discount was not found.'; end if;
    v_sort := coalesce(p_sort, old.sort_order);
    update public.discount_presets set name = v_name, kind = p_kind, value = v_val, valid_from = p_valid_from, valid_to = p_valid_to,
           order_types = v_ot, outlet_ids = v_out, is_active = coalesce(p_active, true), sort_order = v_sort
     where id = p_id;
    v_id := p_id;
    perform app.audit('discount_preset.update', 'discount_presets', v_id,
      jsonb_build_object('name', v_name, 'kind', p_kind, 'value', v_val, 'valid_from', p_valid_from, 'valid_to', p_valid_to,
                         'order_types', v_ot, 'outlet_ids', v_out, 'is_active', coalesce(p_active, true)),
      jsonb_build_object('name', old.name, 'kind', old.kind, 'value', old.value, 'valid_from', old.valid_from, 'valid_to', old.valid_to,
                         'order_types', old.order_types, 'outlet_ids', old.outlet_ids, 'is_active', old.is_active));
  end if;
  return v_id;
end $function$;

-- ---------------------------------------------------------------- maximum discount
create or replace function public.get_discount_settings()
 returns table(max_discount_percent numeric)
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  return query select (select s.max_discount_percent from public.discount_settings s where s.restaurant_id = v_rest)::numeric;
end $function$;

create or replace function public.set_max_discount(p_percent numeric)
 returns numeric
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid; v_rest uuid; v_new numeric(5,2); v_old numeric(5,2);
begin
  v_user := app.require_permission('settings.manage');
  v_rest := app.current_restaurant_id();
  if p_percent is not null then
    if p_percent < 1 or p_percent > 100 then raise exception 'The maximum discount must be between 1%% and 100%%.'; end if;
    v_new := round(p_percent, 2);
  end if;
  select s.max_discount_percent into v_old from public.discount_settings s where s.restaurant_id = v_rest;
  insert into public.discount_settings (restaurant_id, max_discount_percent, updated_at, updated_by)
  values (v_rest, v_new, now(), v_user)
  on conflict (restaurant_id) do update set max_discount_percent = excluded.max_discount_percent, updated_at = now(), updated_by = v_user;
  perform app.audit('settings.max_discount', 'discount_settings', null,
    jsonb_build_object('max_discount_percent', v_new), jsonb_build_object('max_discount_percent', v_old));
  return v_new;
end $function$;

create or replace function app.trg_discount_cap()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_cap numeric; o public.orders%rowtype; v_base numeric; v_max numeric;
begin
  if new.discount_type is distinct from 'fixed_amount' then return new; end if;              -- loyalty points and senior / PWD are not capped
  if coalesce(new.amount, 0) <= 0 then return new; end if;
  if tg_op = 'UPDATE' and new.amount <= old.amount then return new; end if;                 -- recalculation that does not raise the discount
  select s.max_discount_percent into v_cap from public.discount_settings s where s.restaurant_id = new.restaurant_id;
  if v_cap is null then return new; end if;                                                 -- no limit set
  select * into o from public.orders x where x.id = new.order_id;
  if not found then return new; end if;
  if o.comp_kind is not null or coalesce(o.calc_params->>'comp_all', 'false') = 'true' then return new; end if;   -- complimentary / staff meal
  if app.current_user_id() is null then return new; end if;                                 -- internal call, nobody signed in
  if tg_op = 'INSERT' then
    v_base := o.subtotal;                                                                   -- recalc_order has already set it
  else
    select sum(i.line_subtotal) into v_base from public.order_items i where i.order_id = o.id and i.cancelled_at is null;
    if coalesce(v_base, 0) <= 0 then v_base := o.subtotal; end if;
  end if;
  if v_base is null or v_base <= 0 then return new; end if;
  v_max := v_base * v_cap / 100;
  if new.amount <= v_max + 0.005 then return new; end if;
  -- an OFFLINE bill (written by sync_offline_bill) is already printed and paid: it is never refused. It is recorded and the owner is told through the audit log.
  if coalesce(current_setting('app.offline_sync', true), '') = 'on' then
    if not app.has_permission('discount.over_limit') then
      perform app.audit('discount.over_cap_offline', 'orders', o.id,
        jsonb_build_object('bill_number', o.bill_number, 'amount', new.amount, 'cap_percent', v_cap, 'max_allowed', round(v_max, 2), 'bill_subtotal', v_base), null);
    end if;
    return new;
  end if;
  -- owner right, or an owner PIN approval for this one action (app.allowed), as for order.discount
  if app.allowed('discount.over_limit') then return new; end if;
  raise exception '%', format('The most discount allowed is %s%% of the bill (%s). Ask the owner to approve a bigger discount (discount.over_limit).',
    trim_scale(v_cap), trim_scale(round(v_max, 2)));
end $function$;
revoke all on function app.trg_discount_cap() from public, anon, authenticated;
drop trigger if exists trg_discount_cap on public.order_discounts;
create trigger trg_discount_cap before insert or update on public.order_discounts
  for each row execute function app.trg_discount_cap();

-- ---------------------------------------------------------------- day close: not before a set time
create or replace function public.set_day_close_not_before(p_time time without time zone, p_branch uuid default null::uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid; v_b uuid; v_old time;
begin
  perform app.require_permission('settings.manage');
  v_rest := app.current_restaurant_id();
  v_b := coalesce(p_branch, app.current_branch_id());
  if not exists (select 1 from public.branches b where b.id = v_b and b.restaurant_id = v_rest and b.deleted_at is null) then
    raise exception 'That outlet was not found.';
  end if;
  select bs.day_close_not_before into v_old from public.branch_settings bs where bs.branch_id = v_b;
  update public.branch_settings set day_close_not_before = p_time, updated_at = now() where branch_id = v_b and restaurant_id = v_rest;
  if not found then raise exception 'The settings of that outlet were not found.'; end if;
  perform app.audit('settings.day_close_not_before', 'branch_settings', null,
    jsonb_build_object('branch', v_b, 'day_close_not_before', p_time), jsonb_build_object('day_close_not_before', v_old));
end $function$;

create or replace function public.close_day(p_notes text default null::text, p_counted_cash numeric default null::numeric)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('day.close');
  v_branch uuid := app.current_branch_id(); d public.business_days; v_list text; v_z jsonb;
  v_nb time; v_cut time; v_tz text; v_local time; v_review jsonb;
begin
  select * into d from public.business_days where branch_id = v_branch and status = 'open' for update;
  if not found then raise exception 'There is no open day to close.'; end if;
  if p_counted_cash is not null and p_counted_cash < 0 then raise exception 'The counted cash cannot be negative.'; end if;
  -- 152: not before the time the owner set, on the same business day (the after-midnight tail and a day left open from before are not held back)
  select bs.day_close_not_before, coalesce(bs.day_cutoff, '04:00'::time), coalesce(b.timezone, r.timezone, 'UTC')
    into v_nb, v_cut, v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id
    left join public.branch_settings bs on bs.branch_id = b.id where b.id = v_branch;
  if v_nb is not null and d.business_date >= app.business_today(v_branch) and not app.has_permission('settings.manage') then
    v_local := (now() at time zone v_tz)::time;
    if v_local < v_nb and v_local >= v_cut then
      raise exception 'The day cannot be closed before %. Please wait until then, or ask the owner.', to_char(v_nb, 'HH24:MI');
    end if;
  end if;
  select string_agg(bill_number, ', ' order by created_at) into v_list from (
    select bill_number, created_at from public.orders
     where branch_id = v_branch and business_date = d.business_date and status = 'completed'
       and payment_status in ('unpaid', 'partial') and merged_into is null limit 20) x;
  if v_list is not null then
    raise exception 'These bills are not paid yet: %. Take payment, put them on a pay-later account, or void them before closing the day.', v_list;
  end if;
  perform app.close_auto_shifts(v_branch, p_counted_cash);
  if exists (select 1 from public.shifts where branch_id = v_branch and status = 'open') then
    raise exception 'Close the open shift first (count the cash on the Shift screen), then close the day.';
  end if;
  update public.business_days set status = 'closed', closed_at = now(), closed_by = v_user,
         close_notes = nullif(left(trim(coalesce(p_notes, '')), 300), '')
   where id = d.id;
  v_review := app.day_review(v_branch, d.business_date);
  v_z := app.z_report(d.id) || jsonb_build_object('review', v_review);
  update public.business_days set z_report = v_z where id = d.id;
  update public.business_days set status = 'open' where branch_id = v_branch and status = 'parked';
  perform app.audit('day.close', 'business_days', d.id,
    jsonb_build_object('business_date', d.business_date, 'total_billed', v_z->'total_billed', 'bills', v_z->'bills'));
  return v_z;
end $function$;

-- ---------------------------------------------------------------- reasons report
create or replace function public.report_reasons_summary(p_from date, p_to date)
 returns table(source text, reason text, staff text, n integer, amount numeric)
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
#variable_conflict use_column
declare v_rest uuid; v_rb uuid; v_money boolean; v_tz text; v_start timestamptz; v_end timestamptz;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest  := app.current_restaurant_id();
  v_rb    := app.report_branch();
  v_money := app.has_permission('report.view_financial');
  select coalesce(nullif(timezone, ''), 'UTC') into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;
  return query
    with o as (
      select x.id, x.status, x.comp_kind, x.void_reason, x.voided_by, x.comp_reason, x.comp_by, x.grand_total, x.subtotal
        from public.orders x
       where x.restaurant_id = v_rest and (v_rb is null or x.branch_id = v_rb)
         and x.business_date between p_from and p_to and x.merged_into is null),
    ev as (
      select 1 as ord, 'Void bill'::text as src, o.void_reason as txt, o.voided_by as uid, o.grand_total as amt
        from o where o.status = 'voided'
      union all
      select 2, 'Cancelled item', i.cancel_reason, coalesce(i.cancelled_by,
               (select al.user_id from public.audit_logs al where al.restaurant_id = v_rest and al.entity_type = 'order_items' and al.entity_id = i.id and al.action = 'order.cancel_item'
                 order by al.created_at desc limit 1)), i.cancelled_qty * i.unit_price
        from public.order_items i join o on o.id = i.order_id
       where i.restaurant_id = v_rest and i.cancelled_qty > 0 and i.cancel_reason is not null
      union all
      select 3, 'Discount', d.reason, d.approved_by, d.amount
        from public.order_discounts d join o on o.id = d.order_id
       where d.restaurant_id = v_rest and d.discount_type = 'fixed_amount' and d.amount > 0 and o.status <> 'voided' and o.comp_kind is null
      union all
      select case o.comp_kind when 'complimentary' then 4 else 5 end, case o.comp_kind when 'complimentary' then 'Complimentary' else 'Staff meal' end,
             o.comp_reason, o.comp_by, o.subtotal
        from o where o.status <> 'voided' and o.comp_kind is not null
      union all
      select 6, 'Refund', f.reason, f.approved_by, f.amount
        from public.refunds f join public.orders ro on ro.id = f.order_id
       where f.restaurant_id = v_rest and (v_rb is null or ro.branch_id = v_rb)
         and f.created_at >= v_start and f.created_at < v_end),
    lab as (
      select ev.ord, ev.src, ev.uid, ev.amt, btrim(split_part(coalesce(ev.txt, ''), ' - ', 1)) as lbl from ev),
    named as (
      select l.ord, l.src, coalesce(r.name, 'Other (typed)') as rsn, l.uid, l.amt
        from lab l left join public.reasons r on r.restaurant_id = v_rest and lower(r.name) = lower(l.lbl))
    select n.src, n.rsn, coalesce(u.full_name, 'Unknown'), count(*)::int, case when v_money then coalesce(sum(n.amt), 0) end
      from named n left join public.users u on u.id = n.uid
     group by n.ord, n.src, n.rsn, u.id, u.full_name
     order by n.ord, count(*) desc, coalesce(sum(n.amt), 0) desc, n.rsn, u.full_name;
end $function$;

-- ---------------------------------------------------------------- erase: discount presets are POS master data
create or replace function app.erase_groups()
 returns jsonb
 language sql
 immutable
 set search_path to 'public', 'pg_temp'
as $function$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('online_orders', 'customer_ledger', 'batch_movements', 'pre_order_payments', 'pre_orders', 'order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'order_tips', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('online_channels', 'product_batches', 'price_rules', 'product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'price_change_lines', 'price_change_batches', 'branch_prices',
            'discount_presets', 'products', 'categories', 'brands', 'dining_tables', 'floors', 'customers', 'riders'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_count_lines', 'stock_counts', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$;
revoke all on function app.erase_groups() from public, anon, authenticated;

-- ---------------------------------------------------------------- who may call what
revoke all on function public.list_reasons(text), public.save_reason(uuid, text, text[], boolean, integer),
  public.list_discount_presets(text), public.list_discount_presets_admin(),
  public.save_discount_preset(uuid, text, text, numeric, date, date, text[], uuid[], boolean, integer),
  public.get_discount_settings(), public.set_max_discount(numeric),
  public.set_day_close_not_before(time, uuid), public.report_reasons_summary(date, date),
  public.close_day(text, numeric) from public, anon;
grant execute on function public.list_reasons(text), public.save_reason(uuid, text, text[], boolean, integer),
  public.list_discount_presets(text), public.list_discount_presets_admin(),
  public.save_discount_preset(uuid, text, text, numeric, date, date, text[], uuid[], boolean, integer),
  public.get_discount_settings(), public.set_max_discount(numeric),
  public.set_day_close_not_before(time, uuid), public.report_reasons_summary(date, date),
  public.close_day(text, numeric) to authenticated;
