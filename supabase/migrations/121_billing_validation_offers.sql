-- 121: High / medium money and billing fixes from QA round 1.
--
--  * Happy hours: offers that run past midnight use the day they started for their dates; an end time of 23:59 includes the last minute;
--    the QR menu shows the offer price; the bill remembers the offer name and the normal price (receipt shows them).
--  * A bill refuses: a zero or negative quantity, a fraction on a dish sold by the piece, a sold-out size or combo choice, a dish that is sold only in sizes.
--  * A weight is rounded to 3 decimals before the quote is worked out, so the quote and the saved bill agree.
--  * An outlet's kinds of bill are enforced on the server.
--  * Card / UPI payments no longer record change. A payment request id cannot be reused on another bill.
--  * Inclusive price with a discount: taxable value + GST = invoice value to the paisa.
--  * A dish's sizes follow its GST rate.

alter table public.order_items add column if not exists list_price numeric(14,2), add column if not exists offer_name text;

-- The price a happy-hour rule gives right now, and which rule it is. Used for the bill and the receipt.
create or replace function app.rule_pick(p_restaurant uuid, p_branch uuid, p_product uuid, p_price numeric, p_at timestamptz)
returns table (price numeric, rule_name text)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  with p as (select pr.id, pr.parent_id, pr.category_id, pr.is_charge,
                    (select c.parent_id from public.categories c where c.id = pr.category_id) as main_category
               from public.products pr where pr.id = p_product),
       t as (select (p_at at time zone coalesce(nullif(b.timezone, ''), nullif(r.timezone, ''), 'Asia/Kolkata')) as lt
               from public.restaurants r left join public.branches b on b.id = p_branch where r.id = p_restaurant),
       -- a rule that runs past midnight (10 p.m. to 1 a.m.) belongs to the day it started: its dates and weekdays use that day
       c as (select x.name,
                    case when x.kind = 'percent_off' then round(p_price * (100 - x.value) / 100, 2) else x.value end as pr
               from public.price_rules x, p, t
              where x.restaurant_id = p_restaurant and x.is_active and not p.is_charge
                and (x.branch_id is null or x.branch_id = p_branch)
                and (x.valid_from is null or (case when x.end_time < x.start_time and t.lt::time < x.end_time then t.lt - interval '1 day' else t.lt end)::date >= x.valid_from)
                and (x.valid_to is null or (case when x.end_time < x.start_time and t.lt::time < x.end_time then t.lt - interval '1 day' else t.lt end)::date <= x.valid_to)
                and extract(isodow from case when x.end_time < x.start_time and t.lt::time < x.end_time then t.lt - interval '1 day' else t.lt end)::smallint = any (x.days)
                -- an end time of 23:59 means "until closing time", so the last minute of the day is included
                and case when x.start_time < x.end_time then t.lt::time >= x.start_time and (t.lt::time < x.end_time or x.end_time >= time '23:59')
                         else t.lt::time >= x.start_time or t.lt::time < x.end_time end
                and ((cardinality(x.product_ids) = 0 and cardinality(x.category_ids) = 0)
                     or p.id = any (x.product_ids) or p.parent_id = any (x.product_ids)
                     or p.category_id = any (x.category_ids) or p.main_category = any (x.category_ids))
              order by 2 limit 1)
  select least(p_price, coalesce((select pr from c), p_price)),
         (select name from c where pr < p_price)
$function$;
revoke all on function app.rule_pick(uuid, uuid, uuid, numeric, timestamptz) from public, anon, authenticated;

create or replace function app.rule_price(p_restaurant uuid, p_branch uuid, p_product uuid, p_price numeric, p_at timestamptz)
returns numeric
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select (app.rule_pick(p_restaurant, p_branch, p_product, p_price, p_at)).price
$function$;

CREATE OR REPLACE FUNCTION app.insert_order_lines(p_order uuid, p_restaurant uuid, p_lines jsonb)
 RETURNS uuid[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s jsonb; m jsonb; v_id uuid; v_ids uuid[] := '{}';
begin
  for s in select * from jsonb_array_elements(p_lines) loop
    v_id := gen_random_uuid();
    insert into public.order_items
      (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity, modifier_total,
       line_subtotal, line_discount, line_tax, line_total, is_price_inclusive, kitchen_note,
       net_amount, service_charge, tax_included, tax_comps, options_text, created_at, held, list_price, offer_name)
    values
      (v_id, p_restaurant, p_order, (s->>'product_id')::uuid, s->>'name', (s->>'price')::numeric,
       (s->>'qty')::numeric, (s->>'price')::numeric - coalesce((s->>'base_price')::numeric, (s->>'price')::numeric),
       0, 0, 0, 0, coalesce((s->>'inclusive')::boolean, false), s->>'note',
       0, 0, 0, coalesce(s->'comps', '[]'::jsonb), nullif(s->>'options_text', ''), clock_timestamp(), coalesce((s->>'held')::boolean, false),
       nullif(s->>'list_price', '')::numeric, nullif(s->>'offer_name', ''));
    for m in select * from jsonb_array_elements(coalesce(s->'options', '[]'::jsonb)) loop
      insert into public.order_item_modifiers (restaurant_id, order_item_id, modifier_item_id, name, price_delta)
      values (p_restaurant, v_id, (m->>'id')::uuid, m->>'name', coalesce((m->>'price_delta')::numeric, 0));
    end loop;
    v_ids := v_ids || v_id;
  end loop;
  return v_ids;
end $function$;

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
  v_list numeric; v_offer text; v_pr numeric; v_sold_by text; v_pname text;
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
    if exists (select 1 from public.products ch where ch.parent_id = v_product.id and ch.deleted_at is null) then
      raise exception 'Choose a size for %.', v_product.name;
    end if;
    -- Happy hours / time-based prices (Settings → Happy hours): the lowest price a rule gives right now.
    -- A size (Large) is sold out when its dish (Pizza) is sold out.
    if v_product.parent_id is not null then
      select pp.name into v_pname from public.products pp left join public.branch_prices pb on pb.branch_id = p_branch and pb.product_id = pp.id
       where pp.id = v_product.parent_id and not (pp.is_available and coalesce(pb.is_available, true));
      if found then raise exception '% is marked sold out.', v_pname; end if;
    end if;
    v_list := v_product.price;
    select rp.price, rp.rule_name into v_pr, v_offer from app.rule_pick(p_restaurant, p_branch, v_product.id, v_product.price, now()) rp;
    v_product.price := v_pr;
    if v_offer is null then v_list := null; end if;
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    if v_qty <= 0 then raise exception 'Quantity for % must be more than zero.', v_product.name; end if;
    if v_qty > 999 then raise exception 'Quantity for % is too large.', v_product.name; end if;
    -- The bill stores weights to 3 decimals; calculate on the same figure so the quote and the bill agree.
    v_qty := round(v_qty, 3);
    if v_qty <= 0 then raise exception 'Quantity for % is too small.', v_product.name; end if;
    select sold_by into v_sold_by from public.products where id = v_product.id;
    if coalesce(v_sold_by, 'unit') <> 'weight' and v_qty <> trunc(v_qty) then
      raise exception '% is sold by the piece: enter a whole number.', v_product.name;
    end if;

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
      -- A dish chosen inside a combo must not be sold out.
      select pp.name into v_pname
        from jsonb_array_elements(v_opts) o
        join public.modifier_items mi on mi.id = (o->>'id')::uuid
        join public.products pp on pp.id = mi.product_id
        left join public.branch_prices pb on pb.branch_id = p_branch and pb.product_id = pp.id
       where not (pp.is_available and coalesce(pb.is_available, true)) limit 1;
      if found then raise exception '% is marked sold out.', v_pname; end if;
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
      'base_price', v_product.price, 'price', v_product.price + v_delta, 'list_price', v_list, 'offer_name', v_offer,
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

CREATE OR REPLACE FUNCTION public.qr_menu(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.dining_tables%rowtype := app.qr_table(p_token); r record;
begin
  select res.trading_name, res.currency_code, res.second_language, b.name as branch_name
    into r from public.restaurants res join public.branches b on b.id = t.branch_id where res.id = t.restaurant_id;
  return jsonb_build_object(
    'restaurant', r.trading_name, 'outlet', r.branch_name, 'currency', r.currency_code,
    'second_language', r.second_language, 'table', t.table_number, 'kiosk', t.is_kiosk,
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items', c.items) order by c.display_order, c.name)
        from (
          -- A sub-category's dishes are shown under its main category, headed by the sub-category's name ('sub').
          select top.id, top.name, top.display_order,
                 jsonb_agg(jsonb_build_object(
                   'id', p.id, 'name', p.name, 'name_local', p.name_local, 'is_veg', p.is_veg,
                   'sub', case when c.parent_id is not null then c.name end,
                   'price', app.rule_price(t.restaurant_id, t.branch_id, p.id, coalesce(bp.price, p.price), now()),
                   'list_price', case when app.rule_price(t.restaurant_id, t.branch_id, p.id, coalesce(bp.price, p.price), now()) < coalesce(bp.price, p.price)
                                      then coalesce(bp.price, p.price) end,
                   'option_groups', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'id', mg.id, 'name', mg.name,
                              'min', greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end),
                              'max', coalesce(mg.max_select, 99),
                              'options', (select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price_delta', mi.price_delta)
                                                             order by mi.display_order, mi.name), '[]'::jsonb)
                                            from public.modifier_items mi where mi.modifier_group_id = mg.id and mi.is_active))
                            order by mg.is_required desc, mg.name)
                       from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id
                      where pmg.product_id = p.id and mg.is_active), '[]'::jsonb))
                   order by (c.parent_id is not null), c.display_order, c.name, p.display_order, p.name) as items
            from public.categories c
            join public.categories top on top.id = coalesce(c.parent_id, c.id) and top.deleted_at is null
            join public.products p on p.category_id = c.id and p.deleted_at is null
            left join public.branch_prices bp on bp.product_id = p.id and bp.branch_id = t.branch_id
           where c.restaurant_id = t.restaurant_id and c.deleted_at is null
             and p.is_available and coalesce(bp.is_available, true)
             and not p.is_charge
             -- a size is not offered while its dish is sold out
             and not exists (select 1 from public.products pp left join public.branch_prices pb on pb.product_id = pp.id and pb.branch_id = t.branch_id
                              where pp.id = p.parent_id and not (pp.is_available and coalesce(pb.is_available, true)))
             -- a dish with sizes is ordered by its sizes, which are listed as dishes of their own
             and not exists (select 1 from public.products ch where ch.parent_id = p.id and ch.deleted_at is null)
           group by top.id, top.name, top.display_order
        ) c), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.create_order(p_items jsonb, p_order_type text DEFAULT 'dine_in'::text, p_table_id uuid DEFAULT NULL::uuid, p_customer_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_tendered numeric DEFAULT NULL::numeric, p_discount_amount numeric DEFAULT 0, p_discount_reason text DEFAULT NULL::text, p_service_charge boolean DEFAULT NULL::boolean, p_senior jsonb DEFAULT NULL::jsonb, p_reference text DEFAULT NULL::text, p_client_ref uuid DEFAULT NULL::uuid, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_restaurant uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  v_in jsonb; v_c jsonb; v_currency char(3); v_auto_kot boolean; v_shift uuid; v_device uuid;
  v_bill_no text; v_order_id uuid := gen_random_uuid(); v_ids uuid[];
  v_method_kind text; v_grand numeric(14,2); v_amount numeric(14,2); v_cash_round numeric(14,2) := 0;
  v_change numeric(14,2) := 0; v_paid boolean := false; v_rmode text;
  v_gname text; v_gphone text; v_addr text; v_cust uuid := p_customer_id; v_gdel timestamptz;
  v_tok text; v_token int;
begin
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('order_ref:' || p_client_ref::text));
    select jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'grand_total', o.grand_total,
             'amount_paid', o.paid_total, 'cash_rounding', 0, 'change', 0, 'paid', o.payment_status = 'paid', 'repeat', true,
             'token_no', o.token_no)
      into v_in from public.orders o where o.restaurant_id = app.current_restaurant_id() and o.client_ref = p_client_ref;
    if v_in is not null then return v_in; end if;
  end if;
  if nullif(p_senior, 'null'::jsonb) is not null and not app.allowed('order.discount') then
    raise exception 'A manager must approve the senior citizen / PWD discount (order.discount).';
  end if;
  if coalesce(p_discount_amount, 0) < 0 then raise exception 'A discount cannot be negative.'; end if;
  if coalesce(p_discount_amount, 0) > 0 and not app.allowed('order.discount') then
    raise exception 'A manager must approve a discount (order.discount).';
  end if;
  if v_branch is null then raise exception 'No branch is set up for this restaurant.'; end if;
  if coalesce(p_order_type, '') not in ('dine_in', 'takeaway', 'delivery') then raise exception 'Unknown order type.'; end if;
  -- Only the kinds of bill this outlet has switched on.
  if exists (select 1 from public.branch_settings bs where bs.branch_id = v_branch and bs.order_types is not null
                and cardinality(bs.order_types) > 0 and not (p_order_type = any (bs.order_types))) then
    raise exception 'This outlet does not take % bills.', replace(p_order_type, '_', '-');
  end if;

  select s.id into v_shift from public.shifts s
   where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1; if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

  if p_payment_method_id is not null and not app.allowed('payment.take') then
    raise exception 'You do not have the right to take payment (payment.take). Save the bill and ask the cashier to settle it.';
  end if;
  if p_payment_method_id is not null then
    select pm.kind into v_method_kind from public.payment_methods pm
     where pm.id = p_payment_method_id and pm.restaurant_id = v_restaurant and pm.is_active;
    if not found then raise exception 'That payment method is not available.'; end if;
    -- Change is only for cash.
    if v_method_kind <> 'cash' then p_tendered := null; end if;
  end if;
  if p_table_id is not null and not exists (
      select 1 from public.dining_tables t where t.id = p_table_id and t.restaurant_id = v_restaurant and t.is_active) then
    raise exception 'That table does not exist.';
  end if;
  if p_customer_id is not null and not exists (
      select 1 from public.customers c where c.id = p_customer_id and c.restaurant_id = v_restaurant and c.deleted_at is null) then
    raise exception 'That customer does not exist.';
  end if;

  -- The guest's name, phone and delivery address, when the counter took them.
  -- A phone number also finds (or starts) that guest's customer record.
  if p_extra is not null and jsonb_typeof(p_extra) = 'object' then
    v_gname  := nullif(left(trim(coalesce(p_extra->>'guest_name', '')), 80), '');
    v_gphone := app.clean_phone(p_extra->>'guest_phone');
    v_addr   := nullif(left(trim(coalesce(p_extra->>'address', '')), 300), '');
    if v_gphone is not null and length(regexp_replace(p_extra->>'guest_phone', '[^0-9]', '', 'g')) < 7 then
      raise exception 'That phone number looks too short.';
    end if;
    if v_gphone is not null and v_cust is null then
      select c.id, c.deleted_at into v_cust, v_gdel from public.customers c
       where c.restaurant_id = v_restaurant and c.phone = v_gphone;
      if v_cust is null then
        insert into public.customers (restaurant_id, name, phone)
        values (v_restaurant, coalesce(v_gname, 'Guest'), v_gphone) returning id into v_cust;
      else
        update public.customers set deleted_at = null,
               name = case when v_gname is not null and (name is null or name = 'Guest' or v_gdel is not null) then v_gname else name end
         where id = v_cust and (v_gdel is not null or (v_gname is not null and (name is null or name = 'Guest')));
      end if;
    end if;
  end if;
  v_in := app.bill_input(v_restaurant, v_branch, p_items, p_discount_amount, p_service_charge, p_senior);
  v_rmode := v_in->>'cash_rounding';

  select r.currency_code into v_currency from public.restaurants r where r.id = v_restaurant;
  select coalesce(bs.auto_print_kot, true) into v_auto_kot from public.branch_settings bs where bs.branch_id = v_branch;
  v_auto_kot := coalesce(v_auto_kot, true);

  if app.items_are_liquor(v_restaurant, p_items) then
    select n.device_id, n.bill_no into v_device, v_bill_no from app.next_liquor_number(v_branch) n;
  else
    select n.device_id, n.bill_no into v_device, v_bill_no from app.next_bill_number(v_branch) n;
  end if;

  insert into public.orders
    (id, restaurant_id, branch_id, device_id, bill_number, order_type, dining_table_id, customer_id,
     cashier_id, shift_id, currency_code, status, payment_status, client_created_at, calc_params, senior_details,
     guest_name, guest_phone, delivery_address)
  values
    (v_order_id, v_restaurant, v_branch, v_device, v_bill_no, p_order_type, p_table_id, v_cust,
     v_user, v_shift, v_currency, 'open', 'unpaid', now(), (v_in->'calc') - 'lines', nullif(v_in->'senior', 'null'::jsonb),
     v_gname, v_gphone, case when p_order_type = 'delivery' then v_addr end);
  if p_client_ref is not null then update public.orders set client_ref = p_client_ref where id = v_order_id; end if;
  -- Captain app: number of guests at the table, and who took the order.
  if p_order_type = 'dine_in' and coalesce(p_extra->>'covers', '') ~ '^[0-9]{1,2}$' and (p_extra->>'covers')::int between 1 and 99 then
    update public.orders set covers = (p_extra->>'covers')::smallint, waiter_id = v_user where id = v_order_id;
  end if;
  -- Token number for the day (takeaway and delivery, or every bill), if the outlet uses tokens.
  select coalesce(bs.token_numbers, 'off') into v_tok from public.branch_settings bs where bs.branch_id = v_branch;
  if v_tok = 'all' or (v_tok = 'takeaway' and p_order_type <> 'dine_in') then
    update public.business_days d set last_token = d.last_token + 1
     where d.branch_id = v_branch
       and d.business_date = (select o.business_date from public.orders o where o.id = v_order_id)
    returning d.last_token into v_token;
    update public.orders set token_no = v_token where id = v_order_id;
  end if;
  v_ids := app.insert_order_lines(v_order_id, v_restaurant, v_in->'calc'->'lines');
  v_c := app.recalc_order(v_order_id);
  if (v_c->>'discount')::numeric < round(coalesce(p_discount_amount, 0), 2) then
    raise exception 'The discount (%) is more than the bill (%).', round(p_discount_amount, 2), (v_c->>'subtotal')::numeric;
  end if;
  v_grand := (v_c->>'grand_total')::numeric;

  if (v_c->>'discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (v_restaurant, v_order_id, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric,
            nullif(left(p_discount_reason, 200), ''), v_user);
  end if;
  if (v_c->>'senior_discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (v_restaurant, v_order_id, 'senior_pwd', 20, (v_c->>'senior_discount')::numeric,
            left(upper(v_in->'senior'->>'kind') || ': ' || (v_in->'senior'->>'name') || ', ID ' || (v_in->'senior'->>'id_no'), 200),
            v_user);
  end if;

  if p_payment_method_id is not null and v_grand > 0 then
    v_amount := v_grand;
    if v_method_kind = 'cash' and v_rmode <> 'none' then
      v_amount := app.round_cash(v_grand, v_rmode);
      if v_amount <= 0 then v_amount := v_grand; end if;
      v_cash_round := v_amount - v_grand;
    end if;
    if p_tendered is not null then
      if p_tendered < v_amount then
        raise exception 'Cash received (%) is less than the amount due (%).', p_tendered, v_amount;
      end if;
      v_change := p_tendered - v_amount;
    end if;
    insert into public.payments
      (id, restaurant_id, order_id, payment_method_id, amount, currency_code, tendered_amount,
       change_amount, status, received_by, client_created_at, rounding_adjustment, reference_no)
    values
      (gen_random_uuid(), v_restaurant, v_order_id, p_payment_method_id, v_amount, v_currency,
       p_tendered, v_change, 'captured', v_user, now(), v_cash_round, nullif(left(trim(p_reference), 60), ''));
    v_paid := true;
  end if;

  update public.orders set
      paid_total = case when v_paid then v_amount else 0 end,
      status = 'completed',
      payment_status = case when v_paid or v_grand = 0 then 'paid' else 'unpaid' end,
      synced_at = now()
  where id = v_order_id;

  if v_auto_kot then perform app.create_kitchen_ticket(v_order_id, v_ids); end if;

  perform app.audit('order.create', 'orders', v_order_id,
    jsonb_build_object('bill_number', v_bill_no, 'grand_total', v_grand,
                       'discount', (v_c->>'discount')::numeric, 'senior_discount', (v_c->>'senior_discount')::numeric));

  return jsonb_build_object('order_id', v_order_id, 'bill_number', v_bill_no,
    'grand_total', v_grand, 'amount_paid', case when v_paid then v_amount else 0 end,
    'cash_rounding', v_cash_round, 'change', v_change, 'paid', v_paid or v_grand = 0, 'token_no', v_token);
end $function$;

CREATE OR REPLACE FUNCTION public.pay_order(p_order_id uuid, p_payment_method_id uuid, p_tendered numeric DEFAULT NULL::numeric, p_amount numeric DEFAULT NULL::numeric, p_reference text DEFAULT NULL::text, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('payment.take');
  o public.orders%rowtype; v_kind text; v_shift uuid; v_rmode text; v_rcash boolean;
  v_balance numeric(14,2); v_amount numeric(14,2); v_round numeric(14,2) := 0; v_change numeric(14,2) := 0; v_full boolean;
begin
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('pay_ref:' || p_client_ref::text));
    select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id();
    if exists (select 1 from public.payments p where p.restaurant_id = app.current_restaurant_id() and p.client_ref = p_client_ref and p.order_id <> p_order_id) then
      raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
    end if;
    if exists (select 1 from public.payments p where p.restaurant_id = app.current_restaurant_id() and p.client_ref = p_client_ref) then
      return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'amount', 0, 'cash_rounding', 0, 'change', 0,
        'paid', o.payment_status = 'paid', 'balance', o.grand_total - app.order_covered(o.id), 'repeat', true);
    end if;
  end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', o.bill_number; end if;
  select pm.kind into v_kind from public.payment_methods pm
   where pm.id = p_payment_method_id and pm.restaurant_id = o.restaurant_id and pm.is_active;
  if not found then raise exception 'That payment method is not available.'; end if;
  if v_kind <> 'cash' then p_tendered := null; end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_shift is null then raise exception 'Open a shift before taking payments.'; end if;

  v_balance := o.grand_total - app.order_covered(o.id);
  if v_balance <= 0 then raise exception 'Bill % has nothing left to pay.', o.bill_number; end if;

  if p_amount is null or round(p_amount, 2) = v_balance then
    v_full := true;
    v_amount := v_balance;
    select coalesce(cash_rounding_mode, 'none'), coalesce(rounding_cash_only, false) into v_rmode, v_rcash
      from public.branch_settings where branch_id = o.branch_id;
    if v_kind = 'cash' and coalesce(v_rcash, false) and coalesce(v_rmode, 'none') <> 'none' then
      v_amount := app.round_cash(v_balance, v_rmode);
      if v_amount <= 0 then v_amount := v_balance; end if;
      v_round := v_amount - v_balance;
    end if;
  else
    if round(p_amount, 2) <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
    if round(p_amount, 2) > v_balance then
      raise exception 'Only % is left to pay on bill %. For cash, enter the cash received below to work out the change.', v_balance, o.bill_number;
    end if;
    v_full := false;
    v_amount := round(p_amount, 2);
  end if;

  if p_tendered is not null then
    if p_tendered < v_amount then
      raise exception 'Cash received (%) is less than the amount due (%).', p_tendered, v_amount;
    end if;
    v_change := p_tendered - v_amount;
  end if;

  insert into public.payments
    (id, restaurant_id, order_id, payment_method_id, amount, currency_code, tendered_amount,
     change_amount, status, received_by, client_created_at, rounding_adjustment, reference_no, client_ref)
  values
    (gen_random_uuid(), o.restaurant_id, o.id, p_payment_method_id, v_amount, o.currency_code,
     p_tendered, v_change, 'captured', v_user, now(), v_round, nullif(left(trim(p_reference), 60), ''), p_client_ref);

  update public.orders set paid_total = paid_total + v_amount,
      payment_status = case when v_full then 'paid' else 'partial' end,
      shift_id = case when exists (select 1 from public.shifts s where s.id = o.shift_id and s.status = 'open')
                      then o.shift_id else v_shift end
   where id = o.id;

  perform app.audit('order.pay', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'amount', v_amount, 'method_kind', v_kind, 'full', v_full));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'amount', v_amount,
                            'cash_rounding', v_round, 'change', v_change, 'paid', v_full,
                            'balance', case when v_full then 0 else v_balance - v_amount end);
end $function$;

CREATE OR REPLACE FUNCTION app.calc_bill(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_lines   jsonb   := coalesce(p->'lines', '[]'::jsonb);
  n         int     := jsonb_array_length(coalesce(p->'lines', '[]'::jsonb));
  v_disc_in numeric := round(coalesce((p->>'discount')::numeric, 0), 2);
  v_sc_pct  numeric := coalesce((p->>'sc_percent')::numeric, 0);
  v_sc_tax  boolean := coalesce((p->>'sc_taxable')::boolean, false);
  v_share   numeric := coalesce((p->'senior'->>'share')::numeric, 0);
  v_s_pct   numeric := coalesce((p->'senior'->>'rate')::numeric, 20);
  v_round   text    := coalesce(p->>'rounding', 'none');

  subs numeric[] := '{}';
  discs numeric[] := '{}';
  v_subtotal numeric := 0;
  v_big int := 1;
  v_alloc numeric := 0;
  v_discount numeric;

  i int; k int; ln jsonb; comps jsonb; c jsonb;
  v_sub numeric; v_disc numeric; v_incl boolean; v_f numeric; v_rate numeric; v_cmp boolean;
  v_s_gross numeric; v_s_net numeric; v_s_disc numeric; v_s_removed numeric;
  v_r_amt numeric; v_net numeric; v_sc numeric;
  v_pi numeric; v_ps numeric; v_bi numeric; v_bs numeric; v_ai numeric; v_as numeric;
  ai numeric[]; bi numeric[];
  v_line_taxes jsonb; v_line_total numeric; v_line_tax numeric; v_line_incl numeric;
  o_lines jsonb := '[]'::jsonb;
  t_disc numeric := 0; t_sdisc numeric := 0; t_removed numeric := 0; t_sc numeric := 0;
  t_tax numeric := 0; t_incl numeric := 0; t_exempt numeric := 0; t_net numeric := 0;
  t_lines numeric := 0;
  v_before numeric; v_grand numeric;
  v_taxmap jsonb := '{}'::jsonb; v_key text; v_taxes jsonb;
  v_dc numeric; v_tc numeric; v_left int; v_best int; v_net_old numeric; v_net_adj numeric := 0;
  bases numeric[] := '{}'; rems numeric[] := '{}'; taken boolean[] := '{}';
begin
  if v_disc_in < 0 then raise exception 'A discount cannot be negative.'; end if;
  if v_share < 0 or v_share > 1 then raise exception 'The senior citizen / PWD share must be between 0 and 100%%.'; end if;
  if v_share > 0 and v_disc_in > 0 then
    raise exception 'A senior citizen / PWD discount cannot be combined with another discount.';
  end if;
  if v_sc_pct < 0 or v_sc_pct > 100 then raise exception 'The service charge must be between 0 and 100%%.'; end if;

  -- Pass 1: line subtotals at menu price.
  for i in 0 .. n - 1 loop
    ln := v_lines -> i;
    v_sub := round((ln->>'price')::numeric * (ln->>'qty')::numeric, 2);
    if v_sub < 0 then raise exception 'A line cannot be negative.'; end if;
    subs := subs || v_sub;
    v_subtotal := v_subtotal + v_sub;
    if v_sub > subs[v_big] then v_big := i + 1; end if;
  end loop;

  -- Pass 2: spread the bill discount by value; the largest line takes the
  -- rounding remainder so the parts always add up exactly.
  v_discount := least(v_disc_in, v_subtotal);
  for i in 1 .. n loop
    if i = v_big or v_subtotal = 0 then
      discs := discs || 0::numeric;
    else
      v_disc := round(v_discount * subs[i] / v_subtotal, 2);
      discs := discs || v_disc;
      v_alloc := v_alloc + v_disc;
    end if;
  end loop;
  if n > 0 then discs[v_big] := v_discount - v_alloc; end if;

  -- A small discount over many lines can leave the largest line with less than
  -- nothing (every small line rounds up to 0.01). When that happens, spread it
  -- again to the paisa by largest remainder: no line goes below zero or above
  -- its own value, and the parts still add up exactly.
  if n > 0 and v_subtotal > 0 and (discs[v_big] < 0 or discs[v_big] > subs[v_big]) then
    v_dc := v_discount * 100; v_tc := v_subtotal * 100; v_alloc := 0;
    for i in 1 .. n loop
      bases[i] := div(v_dc * (subs[i] * 100), v_tc);
      rems[i]  := mod(v_dc * (subs[i] * 100), v_tc);
      taken[i] := false;
      v_alloc  := v_alloc + bases[i];
    end loop;
    v_left := (v_dc - v_alloc)::int;
    while v_left > 0 loop
      v_best := 0;
      for i in 1 .. n loop
        if not taken[i] and (v_best = 0 or rems[i] > rems[v_best]) then v_best := i; end if;
      end loop;
      exit when v_best = 0;
      bases[v_best] := bases[v_best] + 1; taken[v_best] := true; v_left := v_left - 1;
    end loop;
    for i in 1 .. n loop discs[i] := round(bases[i] / 100, 2); end loop;
  end if;

  -- Pass 3: each line.
  for i in 0 .. n - 1 loop
    ln    := v_lines -> i;
    comps := coalesce(ln->'comps', '[]'::jsonb);
    v_incl := coalesce((ln->>'inclusive')::boolean, false);
    v_sub  := subs[i + 1];
    v_disc := discs[i + 1];

    -- Effective tax factor per 1.00 of net price (compound components apply on
    -- net + earlier components).
    v_f := 0;
    for k in 0 .. jsonb_array_length(comps) - 1 loop
      c := comps -> k;
      v_rate := coalesce((c->>'rate')::numeric, 0);
      v_cmp  := coalesce((c->>'compound')::boolean, false);
      v_f := v_f + v_rate / 100 * (1 + case when v_cmp then v_f else 0 end);
    end loop;

    -- Senior citizen / PWD share: VAT removed, then the percentage off.
    v_s_gross   := round(v_sub * v_share, 2);
    v_s_net     := case when v_incl then round(v_s_gross / (1 + v_f), 2) else v_s_gross end;
    v_s_removed := v_s_gross - v_s_net;
    v_s_disc    := round(v_s_net * v_s_pct / 100, 2);

    -- Regular (taxable) part of the line.
    v_r_amt := v_sub - v_s_gross - v_disc;
    v_net   := case when v_incl then round(v_r_amt / (1 + v_f), 2) else v_r_amt end;

    -- Item taxes.
    ai := '{}'; bi := '{}'; v_pi := 0;
    for k in 0 .. jsonb_array_length(comps) - 1 loop
      c := comps -> k;
      v_rate := coalesce((c->>'rate')::numeric, 0);
      v_cmp  := coalesce((c->>'compound')::boolean, false);
      v_bi := v_net + case when v_cmp then v_pi else 0 end;
      v_ai := round(v_bi * v_rate / 100, 2);
      ai := ai || v_ai; bi := bi || v_bi;
      v_pi := v_pi + v_ai;
    end loop;
    -- Inclusive price: whatever is not tax is the net, so the line is exact.
    v_net_adj := 0;
    if v_incl then v_net_old := v_net; v_net := v_r_amt - v_pi; v_net_adj := v_net - v_net_old; end if;

    -- Service charge on the pre-discount-for-seniors net value.
    v_sc := round((v_net + v_s_net) * v_sc_pct / 100, 2);

    -- Tax on the service charge (added on top, never included).
    v_ps := 0; v_line_taxes := '[]'::jsonb;
    for k in 0 .. jsonb_array_length(comps) - 1 loop
      c := comps -> k;
      v_rate := coalesce((c->>'rate')::numeric, 0);
      v_cmp  := coalesce((c->>'compound')::boolean, false);
      if v_sc_tax then
        v_bs := v_sc + case when v_cmp then v_ps else 0 end;
        v_as := round(v_bs * v_rate / 100, 2);
      else
        v_bs := 0; v_as := 0;
      end if;
      v_ps := v_ps + v_as;
      v_line_taxes := v_line_taxes || jsonb_build_object(
        'name', c->>'name', 'rate', v_rate, 'compound', v_cmp,
        'taxable', bi[k + 1] + v_net_adj + v_bs, 'amount', ai[k + 1] + v_as);
      v_key := (c->>'name') || '|' || v_rate::text;
      v_taxmap := jsonb_set(v_taxmap, array[v_key], jsonb_build_object(
        'name', c->>'name', 'rate', v_rate,
        'taxable', coalesce((v_taxmap->v_key->>'taxable')::numeric, 0) + bi[k + 1] + v_net_adj + v_bs,
        'amount',  coalesce((v_taxmap->v_key->>'amount')::numeric, 0) + ai[k + 1] + v_as));
    end loop;

    v_line_tax   := v_pi + v_ps;
    v_line_incl  := case when v_incl then v_pi else 0 end;
    v_line_total := (case when v_incl then v_r_amt else v_net + v_pi end)
                    + (v_s_net - v_s_disc) + v_sc + v_ps;

    o_lines := o_lines || jsonb_build_object(
      'key', ln->'key', 'subtotal', v_sub, 'discount', v_disc,
      'senior_discount', v_s_disc, 'exempt_sales', v_s_net, 'tax_exempt_amount', v_s_removed,
      'net', v_net + v_s_net - v_s_disc, 'taxable_net', v_net,
      'service_charge', v_sc, 'tax', v_line_tax, 'tax_included', v_line_incl,
      'total', v_line_total, 'inclusive', v_incl, 'taxes', v_line_taxes);

    t_disc := t_disc + v_disc;          t_sdisc := t_sdisc + v_s_disc;
    t_removed := t_removed + v_s_removed; t_exempt := t_exempt + v_s_net;
    t_sc := t_sc + v_sc;                t_tax := t_tax + v_line_tax;
    t_incl := t_incl + v_line_incl;     t_net := t_net + v_net + v_s_net - v_s_disc;
    t_lines := t_lines + v_line_total;
  end loop;

  v_before := v_subtotal - t_disc - t_sdisc - t_removed + t_sc + t_tax - t_incl;

  -- Invariant: the bill must equal the sum of its lines. If it ever does not,
  -- refuse rather than print a wrong bill.
  if v_before <> t_lines then
    raise exception 'Internal check failed: bill total % does not equal line total %.', v_before, t_lines;
  end if;

  v_grand := app.round_cash(v_before, v_round);

  select coalesce(jsonb_agg(value order by (value->>'rate')::numeric, value->>'name'), '[]'::jsonb)
    into v_taxes from jsonb_each(v_taxmap);

  return jsonb_build_object(
    'lines', o_lines,
    'subtotal', v_subtotal, 'discount', t_disc, 'senior_discount', t_sdisc,
    'tax_exempt_amount', t_removed, 'exempt_sales', t_exempt,
    'service_charge', t_sc, 'tax_total', t_tax, 'tax_included', t_incl,
    'net_sales', t_net, 'before_round', v_before,
    'rounding', v_grand - v_before, 'grand_total', v_grand,
    'taxes', v_taxes);
end $function$;

CREATE OR REPLACE FUNCTION app.trg_product_variant_follow()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.parent_id is not null then return null; end if;
  if new.name is distinct from old.name or new.category_id is distinct from old.category_id then
    update public.products c set name = left(new.name || ' (' || c.variant_name || ')', 200), category_id = new.category_id
     where c.parent_id = new.id;
  end if;
  if new.tax_group_id is distinct from old.tax_group_id then
    update public.products c set tax_group_id = new.tax_group_id where c.parent_id = new.id;
  end if;
  if new.deleted_at is not null and old.deleted_at is null then
    update public.products c set deleted_at = new.deleted_at where c.parent_id = new.id and c.deleted_at is null;
  end if;
  return null;
end $function$;
drop trigger if exists trg_product_variant_follow on public.products;
create trigger trg_product_variant_follow after update of name, category_id, deleted_at, tax_group_id on public.products
  for each row execute function app.trg_product_variant_follow();
