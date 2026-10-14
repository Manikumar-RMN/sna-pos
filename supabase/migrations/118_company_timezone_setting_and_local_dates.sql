-- 118: The time zone is the client's own setting (Settings -> Company) and every date follows it.
--
-- Until now nothing let a client change the time zone after setup, and several places counted days in the DATABASE's time zone
-- (UTC) instead of the restaurant's: tax rates ("valid from today"), product batches (made today / expired), the API's default day.
-- Around midnight (for India, 00:00-05:30) these were a day off.
--
-- 1. public.set_company_timezone(text): the one place a client's time zone is changed. Needs the settings right; the name must be a
--    real time zone; refused while a shift is open (a bill must not move to another day); sets the restaurant AND all its outlets
--    (outlets are copies of it), and is written to the audit log.
-- 2. app.local_day_start(restaurant): midnight of the restaurant's today, as a moment.
-- 3. Tax-rate dates, batches, the API day and the offline menu copy use app.local_today(restaurant) (added in 117), not current_date.
--    Not changed on purpose: the clean-up of old report-send records (a housekeeping date) and SNA's own sign-up dates (SNA's
--    day, not a client's).
-- Safe to run again.

create or replace function app.local_day_start(p_restaurant uuid)
 returns timestamptz
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select (app.local_today(p_restaurant)::timestamp) at time zone coalesce(nullif(r.timezone, ''), 'UTC') from public.restaurants r where r.id = p_restaurant
$function$;

revoke all on function app.local_day_start(uuid) from public;

create or replace function public.set_company_timezone(p_timezone text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_tz text := btrim(coalesce(p_timezone, ''));
  v_old text;
begin
  if v_tz = '' or v_tz !~ '^([A-Za-z_]+/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?|UTC)$' or v_tz ~ '^(posix|right|SystemV)/'
     or not exists (select 1 from pg_timezone_names n where n.name = v_tz) then
    raise exception 'Choose a time zone from the list.';
  end if;
  select timezone into v_old from public.restaurants where id = v_rest for update;
  if v_old = v_tz and not exists (select 1 from public.branches b where b.restaurant_id = v_rest and b.timezone <> v_tz) then
    return jsonb_build_object('timezone', v_tz, 'changed', false);
  end if;
  if exists (select 1 from public.shifts s where s.restaurant_id = v_rest and s.status = 'open') then
    raise exception 'Close the open shift on every outlet before changing the time zone, so that no bill falls on the wrong day.';
  end if;
  update public.restaurants set timezone = v_tz where id = v_rest;
  update public.branches set timezone = v_tz where restaurant_id = v_rest and timezone <> v_tz;
  perform app.audit('company.timezone', 'restaurants', v_rest, jsonb_build_object('timezone', v_tz), jsonb_build_object('timezone', v_old));
  return jsonb_build_object('timezone', v_tz, 'changed', true, 'was', v_old);
end $function$;

revoke all on function public.set_company_timezone(text) from public, anon;
grant execute on function public.set_company_timezone(text) to authenticated, service_role;

CREATE OR REPLACE FUNCTION app.batch_on_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_branch uuid; v_need numeric; b record; v_take numeric; m record; v_back numeric;
begin
  if not exists (select 1 from public.products where id = new.product_id and track_batches) then return new; end if;
  select branch_id into v_branch from public.orders where id = new.order_id;
  if tg_op = 'INSERT' then
    v_need := new.quantity;
    for b in select id, qty_left from public.product_batches
              where branch_id = v_branch and product_id = new.product_id and qty_left > 0 and expires_on >= app.local_today(new.restaurant_id)
              order by expires_on, made_on, created_at for update loop
      exit when v_need <= 0;
      v_take := least(v_need, b.qty_left);
      update public.product_batches set qty_left = qty_left - v_take where id = b.id;
      insert into public.batch_movements (restaurant_id, batch_id, order_item_id, qty) values (new.restaurant_id, b.id, new.id, -v_take);
      v_need := v_need - v_take;
    end loop;
  else
    v_back := coalesce(new.cancelled_qty, 0) - coalesce(old.cancelled_qty, 0);
    if v_back = 0 and new.cancelled_at is not null and old.cancelled_at is null then v_back := old.quantity - coalesce(old.cancelled_qty, 0); end if;
    if new.quantity < old.quantity and new.cancelled_at is null then v_back := old.quantity - new.quantity; end if;
    if v_back > 0 then
      -- put back to the newest batches this line took from, up to what it took
      for m in select bm.batch_id, -sum(bm.qty) as taken from public.batch_movements bm
                where bm.order_item_id = new.id group by bm.batch_id having -sum(bm.qty) > 0
                order by max(bm.created_at) desc loop
        exit when v_back <= 0;
        v_take := least(v_back, m.taken);
        update public.product_batches set qty_left = qty_left + v_take where id = m.batch_id;
        insert into public.batch_movements (restaurant_id, batch_id, order_item_id, qty) values (new.restaurant_id, m.batch_id, new.id, v_take);
        v_back := v_back - v_take;
      end loop;
    end if;
  end if;
  return new;
end $function$
;

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
     where tr.tax_group_id = v_product.tax_group_id and tr.valid_from <= app.local_today(p_restaurant)
       and (tr.valid_to is null or tr.valid_to >= app.local_today(p_restaurant))
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
end $function$
;

CREATE OR REPLACE FUNCTION app.write_tax_group(p_restaurant uuid, p_group uuid, p_comps jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cur public.tax_rates%rowtype; v_has boolean; v_rate uuid; c jsonb; k int := 0;
begin
  select * into cur from public.tax_rates
   where tax_group_id = p_group and valid_from <= app.local_today(p_restaurant)
     and (valid_to is null or valid_to >= app.local_today(p_restaurant))
   order by valid_from desc limit 1 for update;
  v_has := found;
  if v_has and cur.valid_from = app.local_today(p_restaurant) then
    update public.tax_rates set total_rate = app.effective_rate(p_comps) where id = cur.id;
    v_rate := cur.id;
    delete from public.tax_rate_components where tax_rate_id = cur.id;
  else
    if v_has then update public.tax_rates set valid_to = app.local_today(p_restaurant) - 1 where id = cur.id; end if;
    insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
    values (p_restaurant, p_group, app.effective_rate(p_comps), app.local_today(p_restaurant)) returning id into v_rate;
  end if;
  for c in select * from jsonb_array_elements(coalesce(p_comps, '[]'::jsonb)) loop
    k := k + 1;
    insert into public.tax_rate_components
      (restaurant_id, tax_rate_id, name, rate, applies_when, display_order, is_compound)
    values (p_restaurant, v_rate, left(trim(c->>'name'), 40), (c->>'rate')::numeric,
            coalesce(c->>'applies_when', 'always'), k, coalesce((c->>'compound')::boolean, false));
  end loop;
end $function$
;

CREATE OR REPLACE FUNCTION public.api_v1(p_key text, p_action text, p_params jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare k public.api_keys%rowtype; v_rest uuid; v_from date; v_to date; v_calls int;
begin
  if coalesce(length(p_key), 0) < 20 or length(p_key) > 100 then raise exception 'Invalid API key.'; end if;
  select * into k from public.api_keys where key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex') and revoked_at is null;
  if not found then raise exception 'Invalid API key.'; end if;
  v_rest := k.restaurant_id;
  if not app.feature_on(v_rest, 'open_api') then raise exception 'The Open API is not switched on for this restaurant.'; end if;
  select count(*) into v_calls from public.api_calls where key_id = k.id and at > now() - interval '1 minute';
  if v_calls >= 60 then raise exception 'Too many requests: at most 60 per minute per key.'; end if;
  insert into public.api_calls (key_id, action) values (k.id, left(coalesce(p_action, ''), 20));
  update public.api_keys set last_used_at = now() where id = k.id;

  if p_action in ('orders', 'sales') then
    begin
      v_from := coalesce((p_params->>'from')::date, app.local_today(v_rest));
      v_to := coalesce((p_params->>'to')::date, v_from);
    exception when others then raise exception 'Dates must look like 2026-09-28.';
    end;
    if v_to < v_from or v_to - v_from > 31 then raise exception 'Choose at most 31 days (from ≤ to).'; end if;
  end if;

  if p_action = 'menu' then
    -- Main categories, each with its own dishes and its sub-categories (each with their dishes).
    return jsonb_build_object('categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items', app.api_menu_items(c.id),
               'sub_categories', coalesce((
                 select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'items', app.api_menu_items(s.id)) order by s.display_order, s.name)
                   from public.categories s where s.parent_id = c.id and s.deleted_at is null), '[]'::jsonb)) order by c.display_order, c.name)
        from public.categories c where c.restaurant_id = v_rest and c.deleted_at is null and c.parent_id is null), '[]'::jsonb));
  elsif p_action = 'orders' then
    return jsonb_build_object('from', v_from, 'to', v_to, 'orders', coalesce((
      select jsonb_agg(x order by x->>'created_at') from (
        select jsonb_build_object('id', o.id, 'bill_number', o.bill_number, 'business_date', o.business_date, 'created_at', o.created_at,
                 'outlet', b.name, 'order_type', o.order_type, 'status', o.status, 'payment_status', o.payment_status,
                 'currency', o.currency_code, 'subtotal', o.subtotal, 'discount', o.discount_total, 'service_charge', o.service_charge,
                 'tax', o.tax_total, 'tax_included', o.tax_included, 'rounding', o.rounding_adjustment, 'grand_total', o.grand_total,
                 'paid', o.paid_total, 'buyer_gstin', o.buyer_gstin,
                 'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.product_name, 'qty', i.quantity, 'unit_price', i.unit_price,
                                'amount', i.line_subtotal, 'options', i.options_text, 'cancelled', i.cancelled_at is not null)), '[]'::jsonb)
                             from public.order_items i where i.order_id = o.id),
                 'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', pm.name, 'kind', pm.kind, 'amount', pa.amount, 'at', pa.created_at)), '[]'::jsonb)
                                from public.payments pa join public.payment_methods pm on pm.id = pa.payment_method_id
                               where pa.order_id = o.id and pa.status in ('captured', 'refunded'))) as x
          from public.orders o join public.branches b on b.id = o.branch_id
         where o.restaurant_id = v_rest and o.business_date between v_from and v_to
         order by o.created_at limit 5000) q), '[]'::jsonb));
  elsif p_action = 'sales' then
    return jsonb_build_object('from', v_from, 'to', v_to, 'days', coalesce((
      select jsonb_agg(jsonb_build_object('date', d, 'outlet', outlet, 'bills', bills, 'gross', gross, 'discount', disc, 'tax', tax,
                                          'total', total, 'voided_bills', voided) order by d, outlet)
        from (select o.business_date d, b.name outlet,
                     count(*) filter (where o.status <> 'voided') bills,
                     sum(o.subtotal) filter (where o.status <> 'voided') gross,
                     sum(o.discount_total) filter (where o.status <> 'voided') disc,
                     sum(o.tax_total + o.tax_included) filter (where o.status <> 'voided') tax,
                     sum(o.grand_total) filter (where o.status <> 'voided') total,
                     count(*) filter (where o.status = 'voided') voided
                from public.orders o join public.branches b on b.id = o.branch_id
               where o.restaurant_id = v_rest and o.business_date between v_from and v_to
               group by 1, 2) s), '[]'::jsonb),
      'credit_notes', coalesce((select jsonb_agg(jsonb_build_object('number', cn.number, 'date', cn.business_date, 'amount', cn.amount, 'tax', cn.tax_amount))
                                  from public.credit_notes cn where cn.restaurant_id = v_rest and cn.business_date between v_from and v_to), '[]'::jsonb));
  elsif p_action = 'stock' then
    if not app.feature_on(v_rest, 'stock') then raise exception 'Stock is not switched on for this restaurant.'; end if;
    return jsonb_build_object('ingredients', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'reorder_level', i.reorder_level,
               'by_outlet', (select coalesce(jsonb_agg(jsonb_build_object('outlet', b.name, 'stock', x.q)), '[]'::jsonb)
                               from (select m.branch_id, sum(m.qty) q from public.stock_movements m where m.ingredient_id = i.id group by 1) x
                               join public.branches b on b.id = x.branch_id)) order by i.name)
        from public.ingredients i where i.restaurant_id = v_rest and i.is_active), '[]'::jsonb));
  end if;
  raise exception 'Unknown action. Use menu, orders, sales or stock.';
end $function$
;

CREATE OR REPLACE FUNCTION public.batch_add(p_product uuid, p_qty numeric, p_expires_on date, p_made_on date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v uuid;
  v_made date := coalesce(p_made_on, app.local_today(v_rest));
begin
  if not exists (select 1 from public.products where id = p_product and restaurant_id = v_rest and deleted_at is null and track_batches) then
    raise exception 'That dish is not tracked in batches. Tick "Track in batches" on the dish first.';
  end if;
  if coalesce(p_qty, 0) <= 0 or p_qty > 100000 then raise exception 'Enter how many were made.'; end if;
  if p_expires_on is null or p_expires_on < v_made then raise exception 'Best before must be on or after the day it was made.'; end if;
  if v_made > app.local_today(v_rest) then raise exception 'The day made cannot be in the future.'; end if;
  insert into public.product_batches (restaurant_id, branch_id, product_id, made_on, expires_on, qty_made, qty_left, note, created_by)
  values (v_rest, v_branch, p_product, v_made, p_expires_on, round(p_qty, 3), round(p_qty, 3), nullif(left(btrim(coalesce(p_note, '')), 200), ''), v_user)
  returning id into v;
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION public.batch_stock()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(jsonb_object_agg(p.id, coalesce((select sum(qty_left) from public.product_batches b
           where b.product_id = p.id and b.branch_id = app.current_branch_id() and b.expires_on >= app.local_today(app.current_restaurant_id())), 0)), '{}'::jsonb)
    from public.products p where p.restaurant_id = app.current_restaurant_id() and p.track_batches and p.deleted_at is null
$function$
;

CREATE OR REPLACE FUNCTION public.batches_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  return jsonb_build_object(
    'batches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'product_id', b.product_id, 'product', p.name, 'made_on', b.made_on,
                 'expires_on', b.expires_on, 'qty_made', b.qty_made, 'qty_left', b.qty_left, 'wasted', b.wasted, 'note', b.note,
                 'expired', b.expires_on < app.local_today(v_rest)) order by b.expires_on, p.name)
        from public.product_batches b join public.products p on p.id = b.product_id
       where b.branch_id = v_branch and (b.qty_left > 0 or b.created_at > now() - interval '2 days')), '[]'::jsonb),
    'dishes', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name,
                 'left', coalesce((select sum(qty_left) from public.product_batches b where b.product_id = p.id and b.branch_id = v_branch and b.expires_on >= app.local_today(v_rest)), 0),
                 -- sold without a batch to take from (more sold than recorded as made)
                 'short', coalesce((select sum(oi.quantity - coalesce(oi.cancelled_qty, 0)) from public.order_items oi join public.orders o on o.id = oi.order_id
                                     where oi.product_id = p.id and o.branch_id = v_branch and oi.created_at >= app.local_day_start(v_rest) and oi.cancelled_at is null), 0)
                          - coalesce((select -sum(bm.qty) from public.batch_movements bm join public.order_items oi on oi.id = bm.order_item_id join public.orders o on o.id = oi.order_id
                                     where oi.product_id = p.id and o.branch_id = v_branch and oi.created_at >= app.local_day_start(v_rest)), 0))
             order by p.name)
        from public.products p where p.restaurant_id = v_rest and p.track_batches and p.deleted_at is null), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.create_tax_group(p_name text, p_total_rate numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('tax.manage');
  v_rest uuid := app.current_restaurant_id();
  v_group uuid;
  v_rate uuid;
  v_r numeric := round(p_total_rate, 3);
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a name for the tax group.'; end if;
  if v_r is null or v_r < 0 or v_r > 40 then
    raise exception 'Enter a tax rate between 0 and 40 percent.';
  end if;
  if exists (select 1 from public.tax_groups where restaurant_id = v_rest and lower(name) = lower(trim(p_name))) then
    raise exception 'A tax group with that name already exists.';
  end if;
  insert into public.tax_groups (restaurant_id, name, is_price_inclusive)
  values (v_rest, left(trim(p_name), 60), false) returning id into v_group;
  insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
  values (v_rest, v_group, v_r, app.local_today(v_rest)) returning id into v_rate;
  perform app.write_tax_components(v_rest, v_rate, v_r);
  perform app.audit('tax.group_create', 'tax_groups', v_group,
    jsonb_build_object('name', trim(p_name), 'rate', v_r));
  return v_group;
end $function$
;

CREATE OR REPLACE FUNCTION public.offline_snapshot(p_device_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_country text; v_tz text; ser public.offline_series; v_n int; v_menu jsonb; v_methods jsonb; v_bs record; v_r record; v_fy text;
begin
  if coalesce(p_device_key, '') !~ '^[0-9a-f-]{36}$' then raise exception 'Bad device key.'; end if;
  select r.*, coalesce(b.timezone, r.timezone) as tz into v_r from public.restaurants r join public.branches b on b.id = v_branch where r.id = v_rest;
  v_country := v_r.country_code; v_tz := v_r.tz;
  select * into ser from public.offline_series where branch_id = v_branch and device_key = p_device_key;
  if not found then
    perform pg_advisory_xact_lock(hashtext('offline_series:' || v_branch::text));
    select count(*) + 1 into v_n from public.offline_series where branch_id = v_branch;
    if v_n > 99 then raise exception 'Too many offline devices for this branch.'; end if;
    insert into public.offline_series (restaurant_id, branch_id, device_key, prefix)
    values (v_rest, v_branch, p_device_key, 'X' || lpad(v_n::text, 2, '0')) returning * into ser;
  end if;
  -- Offline bills follow the outlet's bill prefix: BILL26-X1-0001. A new prefix starts them again from 1.
  v_fy := (app.current_bill_series(v_branch)).prefix;
  if v_fy is distinct from ser.series_key then
    update public.offline_series set series_key = v_fy, fy = null, next_seq = 1 where id = ser.id returning * into ser;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'short_name', p.short_name, 'price', coalesce((select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = p.id), p.price), 'category_id', p.category_id,
      'category_name', c.name, 'is_veg', p.is_veg, 'station', coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen'),
      'inclusive', coalesce(g.is_price_inclusive, false),
      'comps', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'rate', t.rate, 'compound', t.is_compound) order by t.display_order)
                           from public.tax_rate_components t
                          where t.tax_rate_id = (select tr.id from public.tax_rates tr where tr.tax_group_id = p.tax_group_id
                                                   and tr.valid_from <= app.local_today(v_rest) and (tr.valid_to is null or tr.valid_to >= app.local_today(v_rest))
                                                 order by tr.valid_from desc limit 1)
                            and t.applies_when in ('always', 'intra_region')), '[]'::jsonb),
      'groups', coalesce((select jsonb_agg(jsonb_build_object('id', mg.id, 'name', mg.name,
                    'min', greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end), 'max', coalesce(mg.max_select, 99),
                    'options', (select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price', mi.price_delta) order by mi.display_order, mi.name), '[]'::jsonb)
                                  from public.modifier_items mi where mi.modifier_group_id = mg.id and mi.is_active)) order by mg.name)
                    from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id and mg.is_active
                   where pmg.product_id = p.id), '[]'::jsonb))
      order by c.display_order, c.name, p.display_order, p.name), '[]'::jsonb)
    into v_menu
    from public.products p join public.categories c on c.id = p.category_id
    left join public.tax_groups g on g.id = p.tax_group_id
   where p.restaurant_id = v_rest and p.deleted_at is null and p.is_available and c.deleted_at is null and coalesce((select bp.is_available from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = p.id), true);

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind, 'ask_reference', ask_reference, 'upi_id', upi_id) order by display_order), '[]'::jsonb)
    into v_methods from public.payment_methods where restaurant_id = v_rest and is_active and kind not in ('gift_card', 'loyalty');
  select coalesce(s.service_charge_percent, 0) pct, coalesce(s.service_charge_taxable, false) tx, coalesce(s.service_charge_default_on, false) def_on,
         coalesce(s.service_charge_label, 'Service charge') lbl, coalesce(s.cash_rounding_mode, 'none') rmode, coalesce(s.rounding_cash_only, false) rcash,
         s.receipt_header, s.receipt_footer, s.bill_format, s.packing_product_id, s.packing_per, s.packing_takeaway, s.packing_delivery
    into v_bs from public.branch_settings s where s.branch_id = v_branch;

  return jsonb_build_object(
    'taken_at', now(), 'device_key', p_device_key, 'user_id', v_user,
    'series', jsonb_build_object('prefix', 'X' || (substr(ser.prefix, 2)::int), 'fy', null, 'next_seq', ser.next_seq,
                                 'branch_code', ser.series_key, 'key', ser.series_key,
                                 'liquor_code', app.offline_liquor_code(v_branch), 'liquor_next_seq', ser.liquor_next_seq),
    'rights', jsonb_build_object('discount', app.has_permission('order.discount'), 'pay', app.has_permission('payment.take')),
    'menu', v_menu, 'methods', v_methods,
    'settings', jsonb_build_object('sc_percent', v_bs.pct, 'sc_taxable', v_bs.tx, 'sc_default_on', v_bs.def_on, 'sc_label', v_bs.lbl,
                                   'rounding', case when v_bs.rcash then 'none' else v_bs.rmode end,
                                   'cash_rounding', case when v_bs.rcash then v_bs.rmode else 'none' end,
                                   'packing', case when v_bs.packing_product_id is not null then jsonb_build_object(
                                     'product_id', v_bs.packing_product_id, 'per', v_bs.packing_per,
                                     'takeaway', v_bs.packing_takeaway, 'delivery', v_bs.packing_delivery) end),
    'receipt', jsonb_build_object('header', coalesce(v_bs.receipt_header, v_r.trading_name), 'legal_name', v_r.legal_name,
                                  'tax_id', v_r.tax_registration_no, 'tax_id_label', (select tax_id_label from public.countries where code = v_country),
                                  'fssai_no', case when v_country = 'IN' then v_r.fssai_no end, 'footer', v_bs.receipt_footer,
                                  'currency', v_r.currency_code, 'timezone', v_tz, 'country', v_country,
                                  'invoice_title', (select invoice_title from public.countries where code = v_country),
                                  'format', coalesce(v_bs.bill_format, '{}'::jsonb), 'logo', v_r.logo_url));
end $function$
;

CREATE OR REPLACE FUNCTION public.set_tax_rate(p_tax_group_id uuid, p_total_rate numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('tax.manage');
  v_rest uuid := app.current_restaurant_id();
  g public.tax_groups%rowtype;
  cur public.tax_rates%rowtype;
  v_has boolean;
  v_rate uuid;
  v_r numeric := round(p_total_rate, 3);
begin
  if v_r is null or v_r < 0 or v_r > 40 then
    raise exception 'Enter a tax rate between 0 and 40 percent.';
  end if;
  select * into g from public.tax_groups where id = p_tax_group_id and restaurant_id = v_rest;
  if not found then raise exception 'Tax group not found.'; end if;

  select * into cur from public.tax_rates
   where tax_group_id = g.id and valid_from <= app.local_today(v_rest)
     and (valid_to is null or valid_to >= app.local_today(v_rest))
   order by valid_from desc limit 1 for update;
  v_has := found;
  if v_has and cur.total_rate = v_r then return; end if;

  if v_has and cur.valid_from = app.local_today(v_rest) then
    update public.tax_rates set total_rate = v_r where id = cur.id;
    v_rate := cur.id;
  else
    if v_has then
      update public.tax_rates set valid_to = app.local_today(v_rest) - 1 where id = cur.id;
    end if;
    insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
    values (v_rest, g.id, v_r, app.local_today(v_rest)) returning id into v_rate;
  end if;
  perform app.write_tax_components(v_rest, v_rate, v_r);

  perform app.audit('tax.rate_change', 'tax_groups', g.id,
    jsonb_build_object('group', g.name, 'rate', v_r),
    case when v_has then jsonb_build_object('rate', cur.total_rate) else null end);
end $function$
;

