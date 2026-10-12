-- 094: Happy hours and time-based prices (2-4 p.m. prices, weekday offers, a festival week).
--
-- A price rule lowers prices on chosen days and times: a percentage off, or one fixed price, on chosen dishes or
-- categories (a main category includes its sub-categories; a dish includes its sizes), or on the whole menu,
-- for every outlet or one. The lowest price wins when rules overlap. The packing charge is never changed.
-- The bill, the billing screen (v_menu.price) and the QR order all use the same rule price; v_menu.list_price is the
-- normal price so the screen can show the saving. A bill made offline at a happy-hour price is not flagged.

create table public.price_rules (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid,
  name text not null check (length(btrim(name)) between 1 and 40),
  days smallint[] not null default '{1,2,3,4,5,6,7}' check (cardinality(days) between 1 and 7 and days <@ '{1,2,3,4,5,6,7}'::smallint[]),
  start_time time not null,
  end_time time not null check (end_time <> start_time),
  kind text not null check (kind in ('percent_off', 'price')),
  value numeric(14,2) not null check (value > 0 and (kind <> 'percent_off' or value < 100)),
  product_ids uuid[] not null default '{}',
  category_ids uuid[] not null default '{}',
  valid_from date,
  valid_to date check (valid_to is null or valid_from is null or valid_to >= valid_from),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references public.users(id) on delete set null,
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id) on delete cascade,
  check (kind <> 'price' or cardinality(product_ids) > 0)
);
create index idx_price_rules_rest on public.price_rules (restaurant_id) where is_active;
alter table public.price_rules enable row level security;
revoke all on public.price_rules from anon, authenticated;

-- The price of a dish at a moment: the lowest any active rule gives, never more than the normal price.
create or replace function app.rule_price(p_restaurant uuid, p_branch uuid, p_product uuid, p_price numeric, p_at timestamptz)
returns numeric
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  with p as (select pr.id, pr.parent_id, pr.category_id, pr.is_charge,
                    (select c.parent_id from public.categories c where c.id = pr.category_id) as main_category
               from public.products pr where pr.id = p_product),
       t as (select (p_at at time zone coalesce(nullif(b.timezone, ''), nullif(r.timezone, ''), 'Asia/Kolkata')) as lt
               from public.restaurants r left join public.branches b on b.id = p_branch where r.id = p_restaurant)
  select least(p_price, coalesce(min(case when x.kind = 'percent_off' then round(p_price * (100 - x.value) / 100, 2) else x.value end), p_price))
    from public.price_rules x, p, t
   where x.restaurant_id = p_restaurant and x.is_active and not p.is_charge
     and (x.branch_id is null or x.branch_id = p_branch)
     and (x.valid_from is null or t.lt::date >= x.valid_from)
     and (x.valid_to is null or t.lt::date <= x.valid_to)
     -- a rule that runs past midnight (10 p.m. to 1 a.m.) belongs to the day it started
     and extract(isodow from case when x.end_time < x.start_time and t.lt::time < x.end_time then t.lt - interval '1 day' else t.lt end)::smallint = any (x.days)
     and case when x.start_time < x.end_time then t.lt::time >= x.start_time and t.lt::time < x.end_time
              else t.lt::time >= x.start_time or t.lt::time < x.end_time end
     and ((cardinality(x.product_ids) = 0 and cardinality(x.category_ids) = 0)
          or p.id = any (x.product_ids) or p.parent_id = any (x.product_ids)
          or p.category_id = any (x.category_ids) or p.main_category = any (x.category_ids))
$function$;
revoke all on function app.rule_price(uuid, uuid, uuid, numeric, timestamptz) from public, anon, authenticated;

-- Settings → Happy hours: list, save and remove rules (needs "Manage menu").
create or replace function public.price_rules_list()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) - 'restaurant_id' - 'created_by' order by x.is_active desc, x.start_time, x.name)
                     from public.price_rules x where x.restaurant_id = v_rest), '[]'::jsonb);
end $function$;

create or replace function public.save_price_rule(p jsonb)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('menu.manage');
  v_rest uuid := app.current_restaurant_id();
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_prod uuid[] := coalesce((select array_agg(distinct x::uuid) from jsonb_array_elements_text(coalesce(p->'product_ids', '[]')) x), '{}');
  v_cat uuid[] := coalesce((select array_agg(distinct x::uuid) from jsonb_array_elements_text(coalesce(p->'category_ids', '[]')) x), '{}');
  v_days smallint[] := coalesce((select array_agg(distinct x::smallint order by x::smallint) from jsonb_array_elements_text(coalesce(p->'days', '[]')) x), '{}');
  v_branch uuid := nullif(p->>'branch_id', '')::uuid;
  r public.price_rules;
begin
  if cardinality(v_days) = 0 then raise exception 'Choose at least one day.'; end if;
  if exists (select 1 from unnest(v_prod) u where not exists (select 1 from public.products x where x.id = u and x.restaurant_id = v_rest and x.deleted_at is null)) then
    raise exception 'A dish in this offer is no longer on the menu.';
  end if;
  if exists (select 1 from unnest(v_cat) u where not exists (select 1 from public.categories x where x.id = u and x.restaurant_id = v_rest and x.deleted_at is null)) then
    raise exception 'A category in this offer no longer exists.';
  end if;
  if coalesce(p->>'kind', '') not in ('percent_off', 'price') then raise exception 'Choose percent off or a fixed price.'; end if;
  if p->>'kind' = 'price' and cardinality(v_prod) = 0 then raise exception 'A fixed offer price needs the dishes it is for.'; end if;
  if p->>'kind' = 'percent_off' and not coalesce((p->>'value')::numeric, 0) between 1 and 99 then raise exception 'Percent off is 1 to 99.'; end if;
  if coalesce((p->>'value')::numeric, 0) <= 0 then raise exception 'Enter the offer price.'; end if;
  if nullif(p->>'start_time', '') is null or nullif(p->>'end_time', '') is null or (p->>'start_time')::time = (p->>'end_time')::time then
    raise exception 'Enter a start and end time, for example 16:00 to 19:00.';
  end if;
  if v_id is null then
    insert into public.price_rules (restaurant_id, branch_id, name, days, start_time, end_time, kind, value, product_ids, category_ids, valid_from, valid_to, is_active, created_by)
    values (v_rest, v_branch, btrim(p->>'name'), v_days, (p->>'start_time')::time, (p->>'end_time')::time, p->>'kind', (p->>'value')::numeric,
            v_prod, v_cat, nullif(p->>'valid_from', '')::date, nullif(p->>'valid_to', '')::date, coalesce((p->>'is_active')::boolean, true), v_user)
    returning * into r;
  else
    update public.price_rules set branch_id = v_branch, name = btrim(p->>'name'), days = v_days,
           start_time = (p->>'start_time')::time, end_time = (p->>'end_time')::time, kind = p->>'kind', value = (p->>'value')::numeric,
           product_ids = v_prod, category_ids = v_cat, valid_from = nullif(p->>'valid_from', '')::date, valid_to = nullif(p->>'valid_to', '')::date,
           is_active = coalesce((p->>'is_active')::boolean, true)
     where id = v_id and restaurant_id = v_rest returning * into r;
    if not found then raise exception 'That offer was not found.'; end if;
  end if;
  return r.id;
end $function$;

create or replace function public.delete_price_rule(p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  perform app.require_permission('menu.manage');
  delete from public.price_rules where id = p_id and restaurant_id = app.current_restaurant_id();
end $function$;

revoke all on function public.price_rules_list(), public.save_price_rule(jsonb), public.delete_price_rule(uuid) from public, anon;
grant execute on function public.price_rules_list(), public.save_price_rule(jsonb), public.delete_price_rule(uuid) to authenticated, service_role;

-- Bills use the rule price.
CREATE OR REPLACE FUNCTION app.bill_input(p_restaurant uuid, p_branch uuid, p_items jsonb, p_discount numeric, p_service_charge boolean, p_senior jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  bs record; v_country public.countries%rowtype; v_item jsonb; v_product public.products%rowtype;
  v_incl boolean; v_rate uuid; v_comps jsonb; v_lines jsonb := '[]'::jsonb; v_qty numeric; i int := 0;
  v_sc_on boolean; v_senior jsonb := null; v_cnt int; v_din int;
  v_req int; v_found int; v_opts jsonb; v_delta numeric; v_text text; g record; v_bp public.branch_prices%rowtype;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'The order is empty.';
  end if;
  if jsonb_array_length(p_items) > 200 then raise exception 'Too many lines on one bill.'; end if;

  select coalesce(s.service_charge_percent, 0) as sc_pct, coalesce(s.service_charge_taxable, false) as sc_tax,
         coalesce(s.service_charge_default_on, false) as sc_default, coalesce(s.service_charge_label, 'Service charge') as sc_label,
         coalesce(s.cash_rounding_mode, 'none') as rmode, coalesce(s.rounding_cash_only, false) as rcash
    into bs from public.branch_settings s where s.branch_id = p_branch;
  select c.* into v_country from public.restaurants r join public.countries c on c.code = r.country_code
   where r.id = p_restaurant;

  for v_item in select * from jsonb_array_elements(p_items) loop
    if coalesce(v_item->>'product_id', '') !~* '^[0-9a-f-]{36}$' then raise exception 'A menu item on the order no longer exists.'; end if;
    select * into v_product from public.products
     where id = (v_item->>'product_id')::uuid and restaurant_id = p_restaurant and deleted_at is null;
    if not found then raise exception 'A menu item on the order no longer exists.'; end if;
    select * into v_bp from public.branch_prices where branch_id = p_branch and product_id = v_product.id;
    if found then
      v_product.price := coalesce(v_bp.price, v_product.price);
      v_product.is_available := v_product.is_available and coalesce(v_bp.is_available, true);
    end if;
    if not v_product.is_available then raise exception '% is marked sold out.', v_product.name; end if;
    -- Happy hours / time-based prices (Settings → Happy hours): the lowest price a rule gives right now.
    v_product.price := app.rule_price(p_restaurant, p_branch, v_product.id, v_product.price, now());
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    if v_qty <= 0 then continue; end if;
    if v_qty > 999 then raise exception 'Quantity for % is too large.', v_product.name; end if;

    -- Options: every chosen option must belong to a group linked to this item,
    -- and each group's minimum / maximum must be met.
    v_opts := '[]'::jsonb; v_delta := 0; v_text := null;
    if jsonb_typeof(v_item->'options') = 'array' and jsonb_array_length(v_item->'options') > 0 then
      if jsonb_array_length(v_item->'options') > 30 then raise exception 'Too many options on %.', v_product.name; end if;
      if exists (select 1 from jsonb_array_elements_text(v_item->'options') x where x !~* '^[0-9a-f-]{36}$') then
        raise exception 'An option on % is no longer available.', v_product.name;
      end if;
      select count(distinct x) into v_req from jsonb_array_elements_text(v_item->'options') x;
      if v_req <> jsonb_array_length(v_item->'options') then raise exception 'An option was chosen twice on %.', v_product.name; end if;
      select count(*),
             coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price_delta', mi.price_delta, 'group', mg.name)
                                order by mg.is_required desc, mg.min_select desc, mg.name, mi.display_order, mi.name), '[]'::jsonb),
             coalesce(sum(mi.price_delta), 0),
             string_agg(mi.name, ', ' order by mg.is_required desc, mg.min_select desc, mg.name, mi.display_order, mi.name)
        into v_found, v_opts, v_delta, v_text
        from jsonb_array_elements_text(v_item->'options') x
        join public.modifier_items mi on mi.id = x::uuid and mi.restaurant_id = p_restaurant and mi.is_active
        join public.modifier_groups mg on mg.id = mi.modifier_group_id and mg.is_active
        join public.product_modifier_groups pmg on pmg.modifier_group_id = mg.id and pmg.product_id = v_product.id;
      if v_found <> v_req then raise exception 'An option on % is no longer available.', v_product.name; end if;
    end if;
    for g in
      select mg.name, greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end) as mn,
             coalesce(mg.max_select, 99) as mx,
             (select count(*) from jsonb_array_elements(v_opts) o
               join public.modifier_items mi on mi.id = (o->>'id')::uuid where mi.modifier_group_id = mg.id) as picked
        from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id
       where pmg.product_id = v_product.id and mg.is_active
    loop
      if g.picked < g.mn then
        raise exception 'Choose % for %.', case when g.mn > 1 then g.mn || ' from ' || g.name else g.name end, v_product.name;
      end if;
      if g.picked > g.mx then
        raise exception 'Choose at most % from % for %.', g.mx, g.name, v_product.name;
      end if;
    end loop;
    if v_product.price + v_delta < 0 then raise exception 'The options make % cost less than zero.', v_product.name; end if;

    select g2.is_price_inclusive into v_incl from public.tax_groups g2 where g2.id = v_product.tax_group_id;
    select tr.id into v_rate from public.tax_rates tr
     where tr.tax_group_id = v_product.tax_group_id and tr.valid_from <= current_date
       and (tr.valid_to is null or tr.valid_to >= current_date)
     order by tr.valid_from desc limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'rate', rate, 'compound', is_compound)
                              order by display_order), '[]'::jsonb)
      into v_comps from public.tax_rate_components
     where tax_rate_id = v_rate and applies_when in ('always', 'intra_region');

    i := i + 1;
    v_lines := v_lines || jsonb_build_object(
      'key', i, 'product_id', v_product.id, 'name', v_product.name,
      'base_price', v_product.price, 'price', v_product.price + v_delta,
      'options', v_opts, 'options_text', v_text,
      'qty', v_qty, 'note', nullif(left(coalesce(v_item->>'note', ''), 200), ''), 'held', coalesce((v_item->>'hold')::boolean, false) and app.feature_on(p_restaurant, 'courses'),
      'inclusive', coalesce(v_incl, false), 'comps', v_comps);
  end loop;
  if i = 0 then raise exception 'The order is empty.'; end if;

  v_sc_on := coalesce(p_service_charge, bs.sc_default) and coalesce(bs.sc_pct, 0) > 0;

  if p_senior is not null and p_senior <> 'null'::jsonb then
    if not coalesce(v_country.has_senior_discount, false) then
      raise exception 'The senior citizen / PWD discount applies only in the Philippines.';
    end if;
    v_cnt := coalesce((p_senior->>'count')::int, 0);
    v_din := coalesce((p_senior->>'diners')::int, 0);
    if v_cnt < 1 or v_din < v_cnt then
      raise exception 'Enter how many senior citizens / PWDs and how many people in total.';
    end if;
    if coalesce(trim(p_senior->>'name'), '') = '' or coalesce(trim(p_senior->>'id_no'), '') = '' then
      raise exception 'Enter the senior citizen / PWD name and ID number.';
    end if;
    if coalesce(p_senior->>'kind', '') not in ('senior', 'pwd') then
      raise exception 'Choose senior citizen or PWD.';
    end if;
    v_senior := jsonb_build_object('share', round(v_cnt::numeric / v_din, 6), 'rate', 20,
      'kind', p_senior->>'kind', 'name', left(trim(p_senior->>'name'), 80),
      'id_no', left(trim(p_senior->>'id_no'), 40), 'count', v_cnt, 'diners', v_din);
  end if;

  return jsonb_build_object(
    'calc', jsonb_build_object(
      'lines', v_lines, 'discount', coalesce(p_discount, 0),
      'sc_percent', case when v_sc_on then bs.sc_pct else 0 end, 'sc_taxable', bs.sc_tax,
      'senior', v_senior,
      'rounding', case when bs.rcash then 'none' else bs.rmode end),
    'service_charge_available', coalesce(bs.sc_pct, 0) > 0, 'service_charge_on', v_sc_on,
    'service_charge_percent', bs.sc_pct, 'service_charge_label', bs.sc_label,
    'cash_rounding', case when bs.rcash then bs.rmode else 'none' end,
    'senior', v_senior);
end $function$;

-- A bill made offline at a happy-hour price is not flagged as a price change.
CREATE OR REPLACE FUNCTION public.sync_offline_bill(p_bill jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_ref uuid; ser public.offline_series; v_seq int; v_no text; v_expected text; v_at timestamptz;
  v_shift uuid; v_existing uuid; it jsonb; v_prod public.products%rowtype; v_incl boolean; v_rate uuid; v_comps jsonb;
  v_lines jsonb := '[]'::jsonb; v_calc_lines jsonb := '[]'::jsonb; i int := 0; v_hist numeric; v_flags jsonb := '[]'::jsonb;
  v_opts jsonb; v_text text; v_delta numeric; v_price numeric; v_disc numeric; v_sc boolean; bs record; v_c jsonb;
  v_order uuid := gen_random_uuid(); v_ids uuid[]; v_method uuid; v_kind text; v_amount numeric(14,2); v_round numeric(14,2) := 0;
  v_tendered numeric; v_currency char(3); v_rmode text; v_device uuid;
begin
  v_ref := (p_bill->>'client_id')::uuid;
  if v_ref is null then raise exception 'Offline bill without an id.'; end if;
  perform pg_advisory_xact_lock(hashtext('order_ref:' || v_ref::text));
  select id into v_existing from public.orders where restaurant_id = v_rest and client_ref = v_ref;
  if found then return jsonb_build_object('ok', true, 'order_id', v_existing, 'repeat', true); end if;

  select * into ser from public.offline_series where branch_id = v_branch and device_key = p_bill->>'device_key' for update;
  if not found then raise exception 'This device has no offline bill series.'; end if;
  v_seq := (p_bill->>'seq')::int;
  if v_seq is null or v_seq < 1 or v_seq > 999999 then raise exception 'Bad offline bill number.'; end if;
  v_no := p_bill->>'number';
  -- New numbers: <one of this outlet's bill prefixes>-X<device>-<seq>. Older devices: <code>-X01-<fy>-<seq>.
  v_expected := '-X' || (substr(ser.prefix, 2)::int) || '-' || lpad(v_seq::text, greatest(4, length(v_seq::text)), '0');
  if not (right(coalesce(v_no, ''), length(v_expected)) = v_expected
          and exists (select 1 from public.bill_series bs2 where bs2.branch_id = v_branch
                       and bs2.prefix = left(v_no, length(v_no) - length(v_expected)))) then
    v_expected := (select code from public.branches where id = v_branch) || '-' || ser.prefix || '-' ||
                  case when p_bill->>'fy' is not null then (p_bill->>'fy') || '-' else '' end || lpad(v_seq::text, greatest(4, length(v_seq::text)), '0');
    if v_no is distinct from v_expected then raise exception 'Offline bill number % does not match this device.', v_no; end if;
  end if;
  if exists (select 1 from public.orders where branch_id = v_branch and bill_number = v_no) then
    raise exception 'Bill number % is already used.', v_no;
  end if;
  v_at := least(coalesce((p_bill->>'created_at')::timestamptz, now()), now());
  if v_at < now() - interval '7 days' then v_flags := v_flags || jsonb_build_object('flag', 'older_than_7_days'); end if;

  select s.id into v_shift from public.shifts s where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1; if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then return jsonb_build_object('ok', false, 'reason', 'Open a shift to send offline bills.'); end if;

  -- Lines at the prices shown offline; any price that was not the menu price at that time is flagged for the owner.
  for it in select * from jsonb_array_elements(coalesce(p_bill->'items', '[]'::jsonb)) loop
    select * into v_prod from public.products where id = (it->>'product_id')::uuid and restaurant_id = v_rest;
    if not found then raise exception 'An item on offline bill % no longer exists.', v_no; end if;
    v_opts := '[]'::jsonb; v_delta := 0; v_text := null;
    if jsonb_typeof(it->'options') = 'array' and jsonb_array_length(it->'options') > 0 then
      select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price_delta', mi.price_delta, 'group', mg.name) order by mg.name, mi.display_order), '[]'::jsonb),
             coalesce(sum(mi.price_delta), 0), string_agg(mi.name, ', ' order by mg.name, mi.display_order)
        into v_opts, v_delta, v_text
        from jsonb_array_elements_text(it->'options') x
        join public.modifier_items mi on mi.id = x::uuid and mi.restaurant_id = v_rest
        join public.modifier_groups mg on mg.id = mi.modifier_group_id;
    end if;
    v_price := round((it->>'price')::numeric, 2);
    select price into v_hist from public.product_price_history
     where product_id = v_prod.id and valid_from <= v_at and (valid_to is null or valid_to > v_at) order by valid_from desc limit 1;
    if v_hist is null then
      select price into v_hist from public.product_price_history where product_id = v_prod.id order by valid_from limit 1;
    end if;
    if v_hist is null or (v_price <> v_hist + v_delta and v_price <> v_prod.price + v_delta and v_price <> coalesce((select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = v_prod.id), -1) + v_delta
        -- a happy-hour price that applied when the bill was made offline is not a price change
        and v_price <> app.rule_price(v_rest, v_branch, v_prod.id, coalesce((select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = v_prod.id), v_prod.price), v_at) + v_delta) then
      v_flags := v_flags || jsonb_build_object('flag', 'price', 'item', v_prod.name, 'offline_price', v_price, 'menu_price', coalesce(v_hist, v_prod.price) + v_delta);
    end if;
    select g2.is_price_inclusive into v_incl from public.tax_groups g2 where g2.id = v_prod.tax_group_id;
    select tr.id into v_rate from public.tax_rates tr where tr.tax_group_id = v_prod.tax_group_id
       and tr.valid_from <= v_at::date and (tr.valid_to is null or tr.valid_to >= v_at::date) order by tr.valid_from desc limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'rate', rate, 'compound', is_compound) order by display_order), '[]'::jsonb)
      into v_comps from public.tax_rate_components where tax_rate_id = v_rate and applies_when in ('always', 'intra_region');
    if coalesce((it->>'qty')::numeric, 0) <= 0 or (it->>'qty')::numeric > 999 then raise exception 'Bad quantity on offline bill %.', v_no; end if;
    i := i + 1;
    v_lines := v_lines || jsonb_build_object('key', i, 'product_id', v_prod.id, 'name', v_prod.name, 'base_price', v_price - v_delta,
      'price', v_price, 'options', v_opts, 'options_text', v_text, 'qty', (it->>'qty')::numeric,
      'note', nullif(left(coalesce(it->>'note', ''), 200), ''), 'inclusive', coalesce(v_incl, false), 'comps', v_comps);
  end loop;
  if i = 0 then raise exception 'Offline bill % has no items.', v_no; end if;

  v_disc := round(coalesce((p_bill->>'discount')::numeric, 0), 2);
  if v_disc > 0 and not app.allowed('order.discount') then
    v_flags := v_flags || jsonb_build_object('flag', 'discount_without_right', 'amount', v_disc);
  end if;
  select coalesce(s.service_charge_percent, 0) pct, coalesce(s.service_charge_taxable, false) tx,
         coalesce(s.cash_rounding_mode, 'none') rmode, coalesce(s.rounding_cash_only, false) rcash
    into bs from public.branch_settings s where s.branch_id = v_branch;
  v_sc := coalesce((p_bill->>'service_charge')::boolean, false) and bs.pct > 0;
  v_rmode := case when bs.rcash then 'none' else bs.rmode end;

  select d.id into v_device from public.devices d where d.branch_id = v_branch and d.is_active and d.device_type <> 'counter' order by d.created_at limit 1;
  select currency_code into v_currency from public.restaurants where id = v_rest;

  insert into public.orders (id, restaurant_id, branch_id, device_id, bill_number, order_type, cashier_id, shift_id, currency_code,
                             status, payment_status, client_created_at, created_at, calc_params, client_ref, offline_flags)
  values (v_order, v_rest, v_branch, v_device, v_no, case when p_bill->>'order_type' in ('dine_in', 'takeaway', 'delivery') then p_bill->>'order_type' else 'takeaway' end,
          v_user, v_shift, v_currency, 'open', 'unpaid', v_at, v_at,
          jsonb_build_object('discount', v_disc, 'sc_percent', case when v_sc then bs.pct else 0 end, 'sc_taxable', bs.tx, 'senior', null, 'rounding', v_rmode),
          v_ref, nullif(v_flags, '[]'::jsonb));
  v_ids := app.insert_order_lines(v_order, v_rest, v_lines);
  v_c := app.recalc_order(v_order);
  if (v_c->>'discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (v_rest, v_order, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric, 'Offline bill', v_user);
  end if;
  if p_bill ? 'grand_total' and round((p_bill->>'grand_total')::numeric, 2) <> (v_c->>'grand_total')::numeric then
    v_flags := v_flags || jsonb_build_object('flag', 'total_differs', 'printed', (p_bill->>'grand_total')::numeric, 'recorded', (v_c->>'grand_total')::numeric);
    update public.orders set offline_flags = v_flags where id = v_order;
  end if;

  v_method := (p_bill->>'method_id')::uuid;
  select kind into v_kind from public.payment_methods where id = v_method and restaurant_id = v_rest;
  if not found then
    select id, kind into v_method, v_kind from public.payment_methods where restaurant_id = v_rest and kind = 'cash' limit 1;
  end if;
  v_amount := (v_c->>'grand_total')::numeric;
  if v_kind = 'cash' and bs.rcash and bs.rmode <> 'none' then
    v_amount := app.round_cash(v_amount, bs.rmode);
    v_round := v_amount - (v_c->>'grand_total')::numeric;
  end if;
  v_tendered := nullif((p_bill->>'tendered')::numeric, 0);
  if v_amount > 0 then
    insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, tendered_amount, change_amount,
                                 status, received_by, client_created_at, rounding_adjustment, reference_no, client_ref, shift_id)
    values (gen_random_uuid(), v_rest, v_order, v_method, v_amount, v_currency, case when v_tendered >= v_amount then v_tendered end,
            case when v_tendered >= v_amount then v_tendered - v_amount else 0 end, 'captured', v_user, v_at, v_round,
            nullif(left(trim(coalesce(p_bill->>'reference', '')), 60), ''), v_ref, v_shift);
  end if;
  update public.orders set status = 'completed', payment_status = 'paid', paid_total = v_amount, synced_at = now() where id = v_order;
  -- The kitchen already got a printed ticket offline; keep a served ticket for the record.
  perform app.create_kitchen_ticket(v_order, v_ids);
  update public.kitchen_tickets set status = 'served', printed_at = v_at where order_id = v_order;

  update public.offline_series set next_seq = greatest(next_seq, v_seq + 1), last_sync_at = now() where id = ser.id;
  perform app.audit('order.offline_sync', 'orders', v_order,
    jsonb_build_object('bill_number', v_no, 'grand_total', (v_c->>'grand_total')::numeric, 'made_at', v_at, 'flags', v_flags));
  return jsonb_build_object('ok', true, 'order_id', v_order, 'bill_number', v_no, 'grand_total', (v_c->>'grand_total')::numeric,
                            'flags', v_flags);
end $function$;

-- The billing screen shows the rule price; list_price is the normal price.
create or replace view public.v_menu with (security_invoker = true) as
SELECT p.id,
    p.restaurant_id,
    p.category_id,
    p.tax_group_id,
    p.name,
    p.short_name,
    (app.rule_price(p.restaurant_id, ( SELECT app.current_branch_id() AS current_branch_id), p.id, COALESCE(bp.price, p.price), now()))::numeric(14,2) AS price,
    p.is_veg,
    (p.is_available AND COALESCE(bp.is_available, true)) AS is_available,
    p.display_order,
    c.name AS category_name,
    c.display_order AS category_order,
    tg.name AS tax_group_name,
    tg.is_price_inclusive,
    ( SELECT tr.total_rate
           FROM tax_rates tr
          WHERE ((tr.tax_group_id = p.tax_group_id) AND (tr.valid_from <= CURRENT_DATE) AND ((tr.valid_to IS NULL) OR (tr.valid_to >= CURRENT_DATE)))
          ORDER BY tr.valid_from DESC
         LIMIT 1) AS tax_rate,
    p.price AS menu_price,
    p.name_local,
    p.parent_id,
    p.variant_name,
    p.is_combo,
    (COALESCE(bp.price, p.price))::numeric(14,2) AS list_price
   FROM (((products p
     JOIN categories c ON ((c.id = p.category_id)))
     JOIN tax_groups tg ON ((tg.id = p.tax_group_id)))
     LEFT JOIN branch_prices bp ON (((bp.product_id = p.id) AND (bp.branch_id = ( SELECT app.current_branch_id() AS current_branch_id)))))
  WHERE ((p.deleted_at IS NULL) AND (c.deleted_at IS NULL));
