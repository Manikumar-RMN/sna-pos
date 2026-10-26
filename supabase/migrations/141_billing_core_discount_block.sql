-- 141: billing core - per-item discount block, prep time, and the slot for a loyalty-points discount.
--
-- (A) Discount block. products.discount_restricted ("Do not allow discounts on this item"): a restricted line never receives any
--     share of a bill-level discount (typed amount, percent typed as an amount, loyalty points). The discountable pool is the sum of
--     the line subtotals of the unrestricted lines; the typed discount is capped at the pool. Tax keeps its formula: restricted lines
--     have discount 0 (tax on the full price), unrestricted lines carry the whole discount (tax on the reduced value).
--       Worked example: A 100 (restricted) + B 100, 18% exclusive, discount 20 -> A tax 18.00, B base 80 tax 14.40, total 212.40 (100 + 80 + 32.40 tax).
--     The flag is a SNAPSHOT on the order line (order_items.discount_blocked) because app.recalc_order rebuilds the calculation from
--     order_items rows only. Statutory senior/PWD, happy-hour/offer prices, gift-card and points-as-payment tenders are not
--     discounts and ignore the flag; a complimentary / staff-meal bill takes the whole bill off (calc_params.comp_all).
--       * app.bill_input         copy of 131; reads the flag (the size row first, else the dish it belongs to) and adds 'no_disc': true to
--                                the line only when true (bills without restricted dishes are byte-identical)
--       * app.insert_order_lines copy of 131; writes order_items.discount_blocked
--       * app.calc_bill          copy of 121; 'no_disc' per line, pool, the loyalty points discount. The output gains 'discountable_subtotal'
--                                (only when a line is restricted) and 'loyalty_discount' (only when points are asked for); 'discount' is the
--                                typed (manual) part. With no restricted line and no points the result is byte-identical to 121
--                                (calc-bill.golden.json passes unchanged; a test compares 3000 random bills with the old function).
--       * app.recalc_order       copy of the live one; feeds 'no_disc' / 'loyalty_discount'; discount_total includes the points part; calls
--                                app.loyalty_trim when the points discount can no longer be applied in full
--       * public.adjust_order    live body + a pool-aware refusal ("The discount can be at most <pool> ...")
--       * public.create_order    live body; a discount above the DISCOUNTABLE part (but not above the whole bill) is cut, not refused
--       * public.split_order     live body; the cloned line keeps discount_blocked
--       * public.make_complimentary live body; sets calc_params.comp_all so the block is ignored
--     Rollback: the previous bodies are migrations 121 (calc_bill, bill_input), 131 (bill_input, insert_order_lines), 036/037/041 (adjust_order),
--     the 119-baseline recalc_order and 018-140 create_order / split_order / make_complimentary.
--
-- (B) Prep time. products.prep_minutes (1..240, null = not set); a size follows its dish (coalesce(size, dish) when read, and the
--     variant-follow trigger copies it to the sizes). Used by floor_status (142) and the kitchen screen; it never affects billing.
--
-- (C) Loyalty slot. order_discounts.discount_type also allows 'loyalty_points'; app.loyalty_trim is the helper recalc_order calls when
--     a points discount shrinks (the redeem functions themselves are in 145).
--
-- (D) Audit: menu.discount_flag and menu.prep_time rows (who/when) when a dish's flag or prep time changes.
-- Additive: columns with defaults, one constraint widened, CREATE OR REPLACE. Re-runnable. One transaction.

alter table public.products add column if not exists discount_restricted boolean not null default false;
alter table public.products add column if not exists prep_minutes smallint;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.products'::regclass and conname = 'products_prep_minutes_range') then
    alter table public.products add constraint products_prep_minutes_range check (prep_minutes is null or prep_minutes between 1 and 240);
  end if;
end $$;
alter table public.order_items add column if not exists discount_blocked boolean not null default false;

alter table public.order_discounts drop constraint if exists order_discounts_discount_type_check;
alter table public.order_discounts add constraint order_discounts_discount_type_check
  check (discount_type in ('percentage', 'fixed_amount', 'senior_pwd', 'loyalty_points'));

-- ---------------------------------------------------------------- audit of the two menu flags
-- Sizes (parent_id not null) follow their dish silently; only the dish row is audited.
create or replace function app.audit_discount_flag() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.audit('menu.discount_flag', 'products', new.id,
    jsonb_build_object('name', new.name, 'discount_restricted', new.discount_restricted), jsonb_build_object('discount_restricted', old.discount_restricted));
  return new;
end $$;
revoke all on function app.audit_discount_flag() from public, anon, authenticated;
drop trigger if exists trg_audit_discount_flag on public.products;
create trigger trg_audit_discount_flag after update of discount_restricted on public.products
  for each row when (old.discount_restricted is distinct from new.discount_restricted and new.parent_id is null) execute function app.audit_discount_flag();

create or replace function app.audit_prep_time() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.audit('menu.prep_time', 'products', new.id,
    jsonb_build_object('name', new.name, 'prep_minutes', new.prep_minutes), jsonb_build_object('prep_minutes', old.prep_minutes));
  return new;
end $$;
revoke all on function app.audit_prep_time() from public, anon, authenticated;
drop trigger if exists trg_audit_prep_time on public.products;
create trigger trg_audit_prep_time after update of prep_minutes on public.products
  for each row when (old.prep_minutes is distinct from new.prep_minutes and new.parent_id is null) execute function app.audit_prep_time();

-- ---------------------------------------------------------------- sizes follow their dish (121 + the two new columns)
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
  if new.discount_restricted is distinct from old.discount_restricted then
    update public.products c set discount_restricted = new.discount_restricted where c.parent_id = new.id;
  end if;
  if new.prep_minutes is distinct from old.prep_minutes then
    update public.products c set prep_minutes = new.prep_minutes where c.parent_id = new.id;
  end if;
  return null;
end $function$;
drop trigger if exists trg_product_variant_follow on public.products;
create trigger trg_product_variant_follow after update of name, category_id, deleted_at, tax_group_id, discount_restricted, prep_minutes on public.products
  for each row execute function app.trg_product_variant_follow();

-- ---------------------------------------------------------------- loyalty slot helper
-- Called by app.recalc_order (which holds the order row lock) when calc_bill applied less points discount than calc_params asks for.
-- Lowers calc_params.loyalty_discount / loyalty_points to what was applied, returns the surplus points to the guest ('adjust' row,
-- "Bill changed") and fixes or removes the 'loyalty_points' order_discounts row. Internal (not callable from the app).
create or replace function app.loyalty_trim(p_order uuid, p_applied numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; s public.loyalty_settings%rowtype; v_pts numeric; v_keep numeric; v_applied numeric := greatest(coalesce(p_applied, 0), 0); v_cust uuid;
begin
  select * into o from public.orders where id = p_order;
  if not found then return; end if;
  v_pts := coalesce((o.calc_params->>'loyalty_points')::numeric, 0);
  if v_pts <= 0 then return; end if;
  select * into s from public.loyalty_settings where restaurant_id = o.restaurant_id;
  v_keep := case when v_applied <= 0 or s.point_value is null or s.point_value <= 0 then 0
                 else least(v_pts, ceil(v_applied / s.point_value)) end;
  -- QA fix: the points go back to the guest who SPENT them (the redeem row), even when the counter has since put another guest on the bill.
  select l.customer_id into v_cust from public.loyalty_ledger l where l.order_id = o.id and l.kind = 'redeem' order by l.created_at desc, l.id desc limit 1;
  v_cust := coalesce(v_cust, o.customer_id);
  if v_pts - v_keep > 0 and v_cust is not null then
    insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note, created_by)
    values (o.restaurant_id, v_cust, o.id, v_pts - v_keep, 'adjust', 'Bill changed', app.current_user_id());
  end if;
  if v_keep > 0 then
    update public.orders set calc_params = calc_params || jsonb_build_object('loyalty_discount', v_applied, 'loyalty_points', v_keep) where id = o.id;
    update public.order_discounts set value = v_keep, amount = v_applied where order_id = o.id and discount_type = 'loyalty_points';
  else
    update public.orders set calc_params = (calc_params - 'loyalty_discount') - 'loyalty_points' where id = o.id;
    delete from public.order_discounts where order_id = o.id and discount_type = 'loyalty_points';
  end if;
end $$;
revoke all on function app.loyalty_trim(uuid, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------- the money core
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
  v_open boolean; v_oprice numeric; v_bdate date; v_btoday date; v_nodisc boolean;
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

  -- Tax rates are looked up by the open business day (a bill rung at 01:00 belongs to yesterday's trading day);
  -- with no open day, by the business date it would open on. A STALE open day (older than the branch's business today,
  -- e.g. a day left open past the cutoff) is not trusted: the restaurant's current business day is used instead.
  select bd.business_date into v_bdate from public.business_days bd where bd.branch_id = p_branch and bd.status = 'open';
  v_btoday := app.business_today(p_branch);
  if v_bdate is null or (v_btoday is not null and v_bdate < v_btoday) then
    v_bdate := coalesce(v_btoday, app.local_today(p_restaurant));
  end if;

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
    select coalesce(p.is_open_price, false) into v_open from public.products p where p.id = v_product.id;
    -- 141: a dish (or the dish this size belongs to) marked "Do not allow discounts" takes no share of a bill discount.
    select coalesce(p.discount_restricted, false) or coalesce((select pp.discount_restricted from public.products pp where pp.id = p.parent_id), false)
      into v_nodisc from public.products p where p.id = v_product.id;
    if v_open then
      -- Open-priced item: the price is typed at the till. Needs the role right (a PIN cannot be taken inside this STABLE function).
      if not app.has_permission('order.open_price') then
        raise exception 'Only a manager or owner can enter a price for %. Ask them to bill it, or to switch off Open price for this item.', v_product.name;
      end if;
      begin v_oprice := round((v_item->>'price')::numeric, 2);
      exception when others then raise exception 'Enter a price for %.', v_product.name; end;
      if v_oprice is null or v_oprice <= 0 then raise exception 'Enter a price above zero for %.', v_product.name; end if;
      if v_oprice > 99999999 then raise exception 'The price for % is too large.', v_product.name; end if;
      v_product.price := v_oprice; v_list := null; v_offer := null;
    else
      v_list := v_product.price;
      select rp.price, rp.rule_name into v_pr, v_offer from app.rule_pick(p_restaurant, p_branch, v_product.id, v_product.price, now()) rp;
      v_product.price := v_pr;
      if v_offer is null then v_list := null; end if;
    end if;
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
     where tr.tax_group_id = v_product.tax_group_id and tr.valid_from <= v_bdate
       and (tr.valid_to is null or tr.valid_to >= v_bdate)
     order by tr.valid_from desc limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'rate', rate, 'compound', is_compound)
                              order by display_order), '[]'::jsonb)
      into v_comps from public.tax_rate_components
     where tax_rate_id = v_rate and applies_when in ('always', 'intra_region');

    i := i + 1;
    v_lines := v_lines || (jsonb_build_object(
      'key', i, 'product_id', v_product.id, 'name', v_product.name,
      'base_price', v_product.price, 'price', v_product.price + v_delta, 'list_price', v_list, 'offer_name', v_offer,
      'options', v_opts, 'options_text', v_text,
      'qty', v_qty, 'note', nullif(left(coalesce(v_item->>'note', ''), 200), ''), 'held', coalesce((v_item->>'hold')::boolean, false) and app.feature_on(p_restaurant, 'courses'),
      'inclusive', coalesce(v_incl, false), 'comps', v_comps)
      || case when v_open then jsonb_build_object('open_price', true) else '{}'::jsonb end
      || case when v_nodisc then jsonb_build_object('no_disc', true) else '{}'::jsonb end);
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
       net_amount, service_charge, tax_included, tax_comps, options_text, created_at, held, list_price, offer_name, open_price, discount_blocked)
    values
      (v_id, p_restaurant, p_order, (s->>'product_id')::uuid, s->>'name', (s->>'price')::numeric,
       (s->>'qty')::numeric, (s->>'price')::numeric - coalesce((s->>'base_price')::numeric, (s->>'price')::numeric),
       0, 0, 0, 0, coalesce((s->>'inclusive')::boolean, false), s->>'note',
       0, 0, 0, coalesce(s->'comps', '[]'::jsonb), nullif(s->>'options_text', ''), clock_timestamp(), coalesce((s->>'held')::boolean, false),
       nullif(s->>'list_price', '')::numeric, nullif(s->>'offer_name', ''), coalesce((s->>'open_price')::boolean, false), coalesce((s->>'no_disc')::boolean, false));
    for m in select * from jsonb_array_elements(coalesce(s->'options', '[]'::jsonb)) loop
      insert into public.order_item_modifiers (restaurant_id, order_item_id, modifier_item_id, name, price_delta)
      values (p_restaurant, v_id, (m->>'id')::uuid, m->>'name', coalesce((m->>'price_delta')::numeric, 0));
    end loop;
    v_ids := v_ids || v_id;
  end loop;
  return v_ids;
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
  v_loy_in  numeric := round(coalesce((p->>'loyalty_discount')::numeric, 0), 2);
  v_sc_pct  numeric := coalesce((p->>'sc_percent')::numeric, 0);
  v_sc_tax  boolean := coalesce((p->>'sc_taxable')::boolean, false);
  v_share   numeric := coalesce((p->'senior'->>'share')::numeric, 0);
  v_s_pct   numeric := coalesce((p->'senior'->>'rate')::numeric, 20);
  v_round   text    := coalesce(p->>'rounding', 'none');

  subs numeric[] := '{}';
  discs numeric[] := '{}';
  v_subtotal numeric := 0;
  v_big int := 0;
  v_alloc numeric := 0;
  v_discount numeric;
  v_pool numeric := 0; v_manual numeric := 0; v_loy numeric := 0; v_nd boolean; v_any_nd boolean := false; elig boolean[] := '{}';

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
  if v_loy_in < 0 then raise exception 'A points discount cannot be negative.'; end if;
  if v_share < 0 or v_share > 1 then raise exception 'The senior citizen / PWD share must be between 0 and 100%%.'; end if;
  if v_share > 0 and v_disc_in > 0 then
    raise exception 'A senior citizen / PWD discount cannot be combined with another discount.';
  end if;
  if v_share > 0 and v_loy_in > 0 then
    raise exception 'A senior citizen / PWD discount cannot be combined with loyalty points.';
  end if;
  if v_sc_pct < 0 or v_sc_pct > 100 then raise exception 'The service charge must be between 0 and 100%%.'; end if;

  -- Pass 1: line subtotals at menu price.
  for i in 0 .. n - 1 loop
    ln := v_lines -> i;
    v_sub := round((ln->>'price')::numeric * (ln->>'qty')::numeric, 2);
    if v_sub < 0 then raise exception 'A line cannot be negative.'; end if;
    subs := subs || v_sub;
    v_subtotal := v_subtotal + v_sub;
    -- 141: a line with no_disc takes no share of the bill discount; the pool is what the discount can come out of.
    v_nd := coalesce((ln->>'no_disc')::boolean, false);
    elig := elig || (not v_nd);
    if v_nd then v_any_nd := true; end if;
    if not v_nd then
      v_pool := v_pool + v_sub;
      if v_big = 0 or v_sub > subs[v_big] then v_big := i + 1; end if;
    end if;
  end loop;

  -- Pass 2: spread the bill discount by value; the largest line takes the
  -- rounding remainder so the parts always add up exactly.
  -- 141: the typed discount first, then the loyalty points discount, both capped by the pool of discountable lines
  -- (the whole subtotal when no line is restricted). The largest ELIGIBLE line takes the rounding remainder.
  v_manual   := least(v_disc_in, v_pool);
  v_loy      := least(v_loy_in, v_pool - v_manual);
  v_discount := v_manual + v_loy;
  for i in 1 .. n loop
    if not elig[i] or i = v_big or v_pool = 0 then
      discs := discs || 0::numeric;
    else
      v_disc := round(v_discount * subs[i] / v_pool, 2);
      discs := discs || v_disc;
      v_alloc := v_alloc + v_disc;
    end if;
  end loop;
  if v_big > 0 then discs[v_big] := v_discount - v_alloc; end if;

  -- A small discount over many lines can leave the largest line with less than
  -- nothing (every small line rounds up to 0.01). When that happens, spread it
  -- again to the paisa by largest remainder: no line goes below zero or above
  -- its own value, and the parts still add up exactly.
  if v_big > 0 and v_pool > 0 and (discs[v_big] < 0 or discs[v_big] > subs[v_big]) then
    v_dc := v_discount * 100; v_tc := v_pool * 100; v_alloc := 0;
    for i in 1 .. n loop
      bases[i] := case when elig[i] then div(v_dc * (subs[i] * 100), v_tc) else 0 end;
      rems[i]  := case when elig[i] then mod(v_dc * (subs[i] * 100), v_tc) else 0 end;
      taken[i] := not elig[i];
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
    'subtotal', v_subtotal, 'discount', t_disc - v_loy, 'senior_discount', t_sdisc,
    'tax_exempt_amount', t_removed, 'exempt_sales', t_exempt,
    'service_charge', t_sc, 'tax_total', t_tax, 'tax_included', t_incl,
    'net_sales', t_net, 'before_round', v_before,
    'rounding', v_grand - v_before, 'grand_total', v_grand,
    'taxes', v_taxes)
    -- 141: the two new keys appear only when they matter, so every ordinary bill's result is byte-identical to before
    || case when v_any_nd then jsonb_build_object('discountable_subtotal', v_pool) else '{}'::jsonb end
    || case when v_loy_in > 0 then jsonb_build_object('loyalty_discount', v_loy) else '{}'::jsonb end;
end $function$;

CREATE OR REPLACE FUNCTION app.recalc_order(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  o public.orders%rowtype; p jsonb; r record; i int := 0; v_lines jsonb := '[]'::jsonb; v_map jsonb := '{}'::jsonb;
  v_c jsonb; l jsonb; t jsonb; v_id uuid; v_comps jsonb; v_comp_all boolean;
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Bill not found.'; end if;
  p := coalesce(o.calc_params, '{}'::jsonb);
  -- 141: a complimentary / staff-meal bill ignores the discount block (the whole bill comes off)
  v_comp_all := coalesce((p->>'comp_all')::boolean, false);

  for r in select id, unit_price, quantity, is_price_inclusive, tax_comps, discount_blocked
             from public.order_items where order_id = p_order and cancelled_at is null
            order by created_at, id loop
    i := i + 1;
    v_comps := coalesce(r.tax_comps,
      (select jsonb_agg(jsonb_build_object('name', component_name, 'rate', rate, 'compound', false) order by id)
         from public.order_item_taxes where order_item_id = r.id), '[]'::jsonb);
    v_lines := v_lines || (jsonb_build_object('key', i, 'price', r.unit_price, 'qty', r.quantity,
                 'inclusive', coalesce(r.is_price_inclusive, false), 'comps', v_comps)
                 || case when coalesce(r.discount_blocked, false) and not v_comp_all then jsonb_build_object('no_disc', true) else '{}'::jsonb end);
    v_map := v_map || jsonb_build_object(i::text, jsonb_build_object('id', r.id, 'comps', v_comps));
  end loop;
  if i = 0 then raise exception 'Bill % has no items left. Void it instead.', o.bill_number; end if;

  v_c := app.calc_bill(jsonb_build_object(
    'lines', v_lines, 'discount', coalesce((p->>'discount')::numeric, 0), 'loyalty_discount', coalesce((p->>'loyalty_discount')::numeric, 0),
    'sc_percent', coalesce((p->>'sc_percent')::numeric, 0), 'sc_taxable', coalesce((p->>'sc_taxable')::boolean, false),
    'senior', case when p->'senior' is null or p->'senior' = 'null'::jsonb then null else p->'senior' end,
    'rounding', coalesce(p->>'rounding', 'none')));

  perform set_config('app.recalc', 'on', true);

  for l in select * from jsonb_array_elements(v_c->'lines') loop
    v_id := (v_map->(l->>'key')->>'id')::uuid;
    update public.order_items set
        line_subtotal = (l->>'subtotal')::numeric,
        line_discount = (l->>'discount')::numeric + (l->>'senior_discount')::numeric,
        line_tax = (l->>'tax')::numeric, line_total = (l->>'total')::numeric,
        net_amount = (l->>'net')::numeric, service_charge = (l->>'service_charge')::numeric,
        tax_included = (l->>'tax_included')::numeric, tax_comps = v_map->(l->>'key')->'comps'
     where id = v_id;
    delete from public.order_item_taxes where order_item_id = v_id;
    for t in select * from jsonb_array_elements(l->'taxes') loop
      insert into public.order_item_taxes (restaurant_id, order_id, order_item_id, component_name, rate, taxable_amount, tax_amount)
      values (o.restaurant_id, o.id, v_id, t->>'name', (t->>'rate')::numeric, (t->>'taxable')::numeric, (t->>'amount')::numeric);
    end loop;
  end loop;

  update public.order_items set line_subtotal = 0, line_discount = 0, line_tax = 0, line_total = 0,
         net_amount = 0, service_charge = 0, tax_included = 0
   where order_id = p_order and cancelled_at is not null and (line_total <> 0 or line_subtotal <> 0);
  delete from public.order_item_taxes
   where order_item_id in (select id from public.order_items where order_id = p_order and cancelled_at is not null);

  update public.order_discounts set amount = (v_c->>'discount')::numeric, value = (v_c->>'discount')::numeric
   where order_id = p_order and discount_type = 'fixed_amount';
  update public.order_discounts set amount = (v_c->>'senior_discount')::numeric
   where order_id = p_order and discount_type = 'senior_pwd';
  update public.order_discounts set amount = coalesce((v_c->>'loyalty_discount')::numeric, 0)
   where order_id = p_order and discount_type = 'loyalty_points';

  update public.orders set
      subtotal = (v_c->>'subtotal')::numeric,
      discount_total = (v_c->>'discount')::numeric + coalesce((v_c->>'loyalty_discount')::numeric, 0) + (v_c->>'senior_discount')::numeric,
      tax_total = (v_c->>'tax_total')::numeric,
      tax_included = (v_c->>'tax_included')::numeric,
      tax_exempt_amount = (v_c->>'tax_exempt_amount')::numeric,
      exempt_sales = (v_c->>'exempt_sales')::numeric,
      service_charge = (v_c->>'service_charge')::numeric,
      rounding_adjustment = (v_c->>'rounding')::numeric,
      grand_total = (v_c->>'grand_total')::numeric
   where id = p_order;

  -- 141: the bill can no longer take all the points discount asked for (an item was cancelled, the pool shrank):
  -- lower it to what was applied and give the surplus points back. Bills without points never enter here.
  if coalesce((p->>'loyalty_points')::numeric, 0) > 0
     and coalesce((v_c->>'loyalty_discount')::numeric, 0) < coalesce((p->>'loyalty_discount')::numeric, 0) then
    perform app.loyalty_trim(p_order, coalesce((v_c->>'loyalty_discount')::numeric, 0));
  end if;

  perform set_config('app.recalc', 'off', true);
  return v_c;
end $function$;

CREATE OR REPLACE FUNCTION public.adjust_order(p_order_id uuid, p_discount_amount numeric, p_discount_reason text DEFAULT NULL::text, p_service_charge boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; p jsonb; bs record;
  v_old_disc numeric(14,2); v_new_disc numeric(14,2) := round(coalesce(p_discount_amount, 0), 2);
  v_old_sc boolean; v_new_sc boolean; v_c jsonb; v_before numeric(14,2); v_loy numeric(14,2); v_pool numeric(14,2);
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment, so its discount or service charge cannot be changed.', o.bill_number;
  end if;
  if v_new_disc < 0 then raise exception 'A discount cannot be negative.'; end if;

  p := coalesce(o.calc_params, '{}'::jsonb);
  v_old_disc := coalesce((p->>'discount')::numeric, 0);
  v_old_sc := coalesce((p->>'sc_percent')::numeric, 0) > 0;

  select coalesce(s.service_charge_percent, 0) as pct, coalesce(s.service_charge_taxable, false) as taxable
    into bs from public.branch_settings s where s.branch_id = o.branch_id;
  v_new_sc := coalesce(p_service_charge, v_old_sc) and coalesce(bs.pct, 0) > 0;

  if v_new_disc > 0 and p->'senior' is not null and p->'senior' <> 'null'::jsonb then
    raise exception 'This bill has a senior citizen / PWD discount; another discount cannot be added.';
  end if;
  if v_new_disc > v_old_disc and not app.allowed('order.discount') then
    raise exception 'A manager must approve a discount (order.discount).';
  end if;
  if v_old_sc and not v_new_sc and not app.allowed('order.discount') then
    raise exception 'A manager must approve removing the service charge (order.discount).';
  end if;
  if v_new_disc = v_old_disc and v_new_sc = v_old_sc then
    return jsonb_build_object('order_id', o.id, 'grand_total', o.grand_total, 'changed', false);
  end if;

  v_before := o.grand_total;
  perform set_config('app.recalc', 'on', true);
  update public.orders set calc_params = p
      || jsonb_build_object('discount', v_new_disc,
                            'sc_percent', case when v_new_sc then bs.pct else 0 end,
                            'sc_taxable', coalesce(bs.taxable, false))
   where id = o.id;
  v_c := app.recalc_order(o.id);
  if (v_c->>'discount')::numeric < v_new_disc then
    -- 141: the typed discount can only come out of the lines that may be discounted (and not out of points already used).
    v_pool := coalesce((v_c->>'discountable_subtotal')::numeric, (v_c->>'subtotal')::numeric);
    v_loy  := coalesce((p->>'loyalty_discount')::numeric, 0);
    if v_pool < (v_c->>'subtotal')::numeric then
      raise exception 'The discount can be at most % (some items on this bill cannot be discounted).', greatest(v_pool - v_loy, 0);
    elsif v_loy > 0 then
      raise exception 'The discount can be at most % (loyalty points already pay % of this bill).', greatest(v_pool - v_loy, 0), v_loy;
    end if;
    raise exception 'The discount (%) is more than the bill (%).', v_new_disc, (v_c->>'subtotal')::numeric;
  end if;

  delete from public.order_discounts where order_id = o.id and discount_type = 'fixed_amount';
  if (v_c->>'discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (o.restaurant_id, o.id, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric,
            nullif(left(trim(coalesce(p_discount_reason, '')), 200), ''), v_user);
  end if;

  perform app.audit('order.adjust', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'discount', (v_c->>'discount')::numeric,
                       'service_charge_on', v_new_sc, 'grand_total', (v_c->>'grand_total')::numeric,
                       'reason', nullif(trim(coalesce(p_discount_reason, '')), '')),
    jsonb_build_object('discount', v_old_disc, 'service_charge_on', v_old_sc, 'grand_total', v_before));
  return jsonb_build_object('order_id', o.id, 'grand_total', (v_c->>'grand_total')::numeric, 'changed', true);
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

  if p_extra is not null and jsonb_typeof(p_extra) = 'object' and nullif(btrim(coalesce(p_extra->>'covers', '')), '') is not null
     and not (p_extra->>'covers' ~ '^[0-9]{1,2}$' and (p_extra->>'covers')::int between 1 and 99) then
    raise exception 'The number of guests must be a number from 1 to 99.';
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
  -- 141: a discount above the whole bill is still refused; one above the discountable part only (some items cannot be
  -- discounted) is cut to that part, the same as the quote and the offline sync do.
  if (v_c->>'discount')::numeric < round(coalesce(p_discount_amount, 0), 2)
     and round(coalesce(p_discount_amount, 0), 2) > (v_c->>'subtotal')::numeric then
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

CREATE OR REPLACE FUNCTION public.split_order(p_order_id uuid, p_items jsonb, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid;
  o public.orders%rowtype; it public.order_items%rowtype; r record; v_shift uuid; v_device uuid; v_bill text;
  v_new uuid := gen_random_uuid(); v_line uuid; v_c1 jsonb; v_c2 jsonb; v_moved int := 0;
  v_seen record; v_out jsonb;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen
      from public.request_refs rr where rr.restaurant_id = app.current_restaurant_id() and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'split' or v_seen.order_id is distinct from p_order_id then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  v_user := app.require_permission('order.create');
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment. Split the payment instead.', o.bill_number;
  end if;
  if coalesce((o.calc_params->>'discount')::numeric, 0) > 0 or nullif(o.senior_details, 'null'::jsonb) is not null
     or exists (select 1 from public.order_discounts where order_id = o.id) then
    raise exception 'Bill % has a discount, so it cannot be split. Split the payment instead.', o.bill_number;
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Choose the items to move to the new bill.';
  end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

  if o.is_liquor then
    select n.device_id, n.bill_no into v_device, v_bill from app.next_liquor_number(o.branch_id) n;
  else
    select n.device_id, n.bill_no into v_device, v_bill from app.next_bill_number(o.branch_id) n;
  end if;
  insert into public.orders
    (id, restaurant_id, branch_id, device_id, bill_number, order_type, dining_table_id, customer_id,
     cashier_id, shift_id, currency_code, status, payment_status, client_created_at, calc_params)
  values
    (v_new, o.restaurant_id, o.branch_id, v_device, v_bill, o.order_type, o.dining_table_id, o.customer_id,
     v_user, v_shift, o.currency_code, 'open', 'unpaid', now(), o.calc_params);

  for r in select (x->>'order_item_id') as oid, sum(coalesce((x->>'qty')::numeric, 0)) as q
             from jsonb_array_elements(p_items) x group by 1 loop
    if coalesce(r.oid, '') !~* '^[0-9a-f-]{36}$' then raise exception 'An item is not on this bill.'; end if;
    select * into it from public.order_items where id = r.oid::uuid and order_id = o.id and cancelled_at is null for update;
    if not found then raise exception 'An item is not on this bill.'; end if;
    if r.q <= 0 then continue; end if;
    if r.q > it.quantity then raise exception 'Only % of % are on the bill.', trim_scale(it.quantity), it.product_name; end if;
    v_moved := v_moved + 1;
    if r.q = it.quantity then
      update public.order_items set order_id = v_new where id = it.id;
      update public.order_item_taxes set order_id = v_new where order_item_id = it.id;
    else
      update public.order_items set quantity = quantity - r.q where id = it.id;
      v_line := gen_random_uuid();
      insert into public.order_items
        (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity, modifier_total,
         line_subtotal, line_discount, line_tax, line_total, is_price_inclusive, kitchen_note,
         net_amount, service_charge, tax_included, tax_comps, options_text, created_at, brand_id, list_price, offer_name, discount_blocked)
      values
        (v_line, it.restaurant_id, v_new, it.product_id, it.product_name, it.unit_price, r.q, it.modifier_total,
         0, 0, 0, 0, it.is_price_inclusive, it.kitchen_note, 0, 0, 0, it.tax_comps, it.options_text, clock_timestamp(), it.brand_id, it.list_price, it.offer_name, it.discount_blocked);
      insert into public.order_item_modifiers (restaurant_id, order_item_id, modifier_item_id, name, price_delta)
      select restaurant_id, v_line, modifier_item_id, name, price_delta from public.order_item_modifiers where order_item_id = it.id;
      -- The kitchen already has this line. Give the moved part its own kitchen
      -- line, so cancelling or voiding one bill never touches the other's food.
      insert into public.kitchen_ticket_items (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note, status, product_name_local)
      select k.restaurant_id, k.kitchen_ticket_id, v_line, k.product_name, r.q, k.note, k.status, k.product_name_local
        from public.kitchen_ticket_items k
       where k.order_item_id = it.id and k.status <> 'cancelled' and k.quantity > r.q
       order by k.id limit 1;
      update public.kitchen_ticket_items set quantity = quantity - r.q
       where id = (select k.id from public.kitchen_ticket_items k
                    where k.order_item_id = it.id and k.status <> 'cancelled' and k.quantity > r.q
                    order by k.id limit 1);
    end if;
  end loop;
  if v_moved = 0 then raise exception 'Choose the items to move to the new bill.'; end if;
  if not exists (select 1 from public.order_items where order_id = o.id and cancelled_at is null) then
    raise exception 'Leave at least one item on bill %.', o.bill_number;
  end if;

  v_c1 := app.recalc_order(o.id);
  v_c2 := app.recalc_order(v_new);
  update public.orders set status = 'completed',
         payment_status = case when (v_c2->>'grand_total')::numeric = 0 then 'paid' else 'unpaid' end
   where id = v_new;

  perform app.audit('order.split', 'orders', v_new,
    jsonb_build_object('bill_number', v_bill, 'split_from', o.bill_number, 'grand_total', (v_c2->>'grand_total')::numeric),
    jsonb_build_object('source_total_before', o.grand_total, 'source_total_after', (v_c1->>'grand_total')::numeric));
  v_out := jsonb_build_object('order_id', v_new, 'bill_number', v_bill, 'grand_total', (v_c2->>'grand_total')::numeric,
                            'source_bill_number', o.bill_number, 'source_grand_total', (v_c1->>'grand_total')::numeric);
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result)
    values (app.current_restaurant_id(), p_client_ref, 'split', p_order_id, v_out);
    -- Request ids only matter for a retry within minutes; old ones are cleared as new ones arrive.
    delete from public.request_refs
     where restaurant_id = app.current_restaurant_id() and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION public.make_complimentary(p_order_id uuid, p_kind text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; p jsonb; v_c jsonb; v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 200), '');
  v_label text;
begin
  if p_kind is null or p_kind not in ('complimentary', 'staff_meal') then
    raise exception 'Choose complimentary or staff meal.';
  end if;
  v_label := case p_kind when 'complimentary' then 'complimentary' else 'a staff meal' end;
  if v_reason is null or length(v_reason) < 3 then
    raise exception 'Write a short reason (for example the guest''s name or the staff member''s name).';
  end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.comp_kind is not null then raise exception 'Bill % is already marked %.', o.bill_number, replace(o.comp_kind, '_', ' '); end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment, so it cannot be made %.', o.bill_number, v_label;
  end if;
  p := coalesce(o.calc_params, '{}'::jsonb);
  if p->'senior' is not null and p->'senior' <> 'null'::jsonb then
    raise exception 'Bill % has a senior citizen / PWD discount. Remove it first.', o.bill_number;
  end if;
  if not exists (select 1 from public.order_items where order_id = o.id and cancelled_at is null) or coalesce(o.subtotal, 0) <= 0 then
    raise exception 'Bill % has no items.', o.bill_number;
  end if;
  if not app.allowed('order.discount') then
    raise exception 'A manager must approve a complimentary bill or staff meal (order.discount).';
  end if;

  -- 141: comp_all makes recalc_order ignore the discount block (and any points discount is given back by its trim).
  -- The whole bill comes off as one discount, the service charge is removed, and the total is worked out again.
  perform set_config('app.recalc', 'on', true);
  update public.orders set calc_params = p || jsonb_build_object('discount', o.subtotal, 'sc_percent', 0, 'comp_all', true) where id = o.id;
  v_c := app.recalc_order(o.id);
  if (v_c->>'grand_total')::numeric <> 0 then
    raise exception 'Bill % could not be brought to zero (total %). Nothing was changed.', o.bill_number, (v_c->>'grand_total')::numeric;
  end if;

  delete from public.order_discounts where order_id = o.id and discount_type = 'fixed_amount';
  insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
  values (o.restaurant_id, o.id, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric,
          left(case p_kind when 'complimentary' then 'Complimentary: ' else 'Staff meal: ' end || v_reason, 200), v_user);

  update public.orders set payment_status = 'paid', comp_kind = p_kind, comp_reason = v_reason, comp_by = v_user
   where id = o.id;

  perform app.audit('order.complimentary', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'kind', p_kind, 'reason', v_reason,
                       'value', o.subtotal, 'grand_total', 0),
    jsonb_build_object('grand_total', o.grand_total, 'discount', coalesce((p->>'discount')::numeric, 0)));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'kind', p_kind, 'value', o.subtotal, 'grand_total', 0);
end $function$;
