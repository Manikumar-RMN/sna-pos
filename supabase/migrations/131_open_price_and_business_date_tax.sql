-- 131: open-priced items + tax rate looked up by business date.
--
-- (a) products.is_open_price: the price is typed at the till. Needs the new role right order.open_price (Owner, Manager by
--     default); no manager PIN (bill_input is STABLE and cannot consume an approval, so the message must not name the right in
--     brackets: that would make the app offer a PIN prompt that cannot work). Price must be above zero. Tax is worked
--     out on the typed price like any other line. Every such line is written to the audit log by a trigger on order_items, so
--     create_order / add_order_items / insert_order_lines callers need no change.
-- (b) app.bill_input picks the tax rate by the open business day's date (fallback: the date the business day would open on,
--     then the calendar date), so a scheduled rate (130) starts with the business day and not at midnight.
-- Normal items: byte-identical result (no new keys in their lines). Additive: one column per table (default false), a key, a
-- trigger, CREATE OR REPLACE of app.bill_input (copy of 121 with a minimal diff) and app.insert_order_lines (+ open_price). One transaction.

alter table public.products add column if not exists is_open_price boolean not null default false;
alter table public.order_items add column if not exists open_price boolean not null default false;

insert into public.permissions (key, description, is_sensitive)
values ('order.open_price', 'Enter the price of an open-priced item at the till', true)
on conflict (key) do nothing;
insert into public.role_permissions (role_id, permission_key)
select r.id, 'order.open_price' from public.roles r
 where r.is_system and r.name in ('Owner', 'Manager')
on conflict do nothing;

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
       net_amount, service_charge, tax_included, tax_comps, options_text, created_at, held, list_price, offer_name, open_price)
    values
      (v_id, p_restaurant, p_order, (s->>'product_id')::uuid, s->>'name', (s->>'price')::numeric,
       (s->>'qty')::numeric, (s->>'price')::numeric - coalesce((s->>'base_price')::numeric, (s->>'price')::numeric),
       0, 0, 0, 0, coalesce((s->>'inclusive')::boolean, false), s->>'note',
       0, 0, 0, coalesce(s->'comps', '[]'::jsonb), nullif(s->>'options_text', ''), clock_timestamp(), coalesce((s->>'held')::boolean, false),
       nullif(s->>'list_price', '')::numeric, nullif(s->>'offer_name', ''), coalesce((s->>'open_price')::boolean, false));
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
  v_open boolean; v_oprice numeric; v_bdate date; v_btoday date;
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
      || case when v_open then jsonb_build_object('open_price', true) else '{}'::jsonb end);
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

-- Audit every open-priced line when it is rung up (the copy made by move_order_items keeps open_price but sets app.line_clone for its insert, so it is not logged twice).
create or replace function app.audit_open_price() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_setting('app.line_clone', true) = 'on' then return new; end if;
  insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, actor_type, new_value)
  values (new.restaurant_id, (select o.branch_id from public.orders o where o.id = new.order_id), app.current_user_id(),
          'order.open_price', 'order_items', new.id, 'user',
          jsonb_build_object('order_id', new.order_id, 'product_id', new.product_id, 'product', new.product_name,
                             'price', new.unit_price, 'qty', new.quantity, 'bill_number', (select o.bill_number from public.orders o where o.id = new.order_id)));
  return new;
end $$;
revoke all on function app.audit_open_price() from public, anon, authenticated;
drop trigger if exists trg_audit_open_price on public.order_items;
create trigger trg_audit_open_price after insert on public.order_items
  for each row when (new.open_price) execute function app.audit_open_price();

-- Turning the open-price switch on or off for a dish is recorded (it changes who may set that dish's price).
create or replace function app.audit_open_price_flag() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.audit('menu.open_price_flag', 'products', new.id,
    jsonb_build_object('name', new.name, 'is_open_price', new.is_open_price), jsonb_build_object('is_open_price', old.is_open_price));
  return new;
end $$;
revoke all on function app.audit_open_price_flag() from public, anon, authenticated;
drop trigger if exists trg_audit_open_price_flag on public.products;
create trigger trg_audit_open_price_flag after update of is_open_price on public.products
  for each row when (old.is_open_price is distinct from new.is_open_price) execute function app.audit_open_price_flag();
