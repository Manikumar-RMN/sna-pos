-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260925082605, name 'sna_pos_19_running_bills_split_pay_options'. This is the SQL that actually ran.

-- Running bills (add items / cancel item / move / merge / split), split payments,
-- and item options (modifiers). Every amount is still computed by app.calc_bill.

alter table public.orders
  add column if not exists calc_params jsonb,
  add column if not exists merged_into uuid references public.orders(id);

alter table public.order_items
  add column if not exists tax_comps jsonb,
  add column if not exists options_text text,
  add column if not exists cancelled_qty numeric(10,3) not null default 0,
  add column if not exists cancel_reason text;

-- An unpaid or part-paid bill may be recalculated, but only by the database's own
-- functions (they switch app.recalc on for the moment of the update). Paid and
-- voided bills stay frozen.
create or replace function app.protect_completed_orders()
 returns trigger language plpgsql set search_path to 'public', 'pg_temp'
as $$
begin
  if old.status in ('completed', 'voided') then
    if new.bill_number is distinct from old.bill_number or new.branch_id is distinct from old.branch_id then
      raise exception 'Bill % cannot be renumbered or moved to another branch.', old.bill_number;
    end if;
    if new.subtotal is distinct from old.subtotal
    or new.discount_total is distinct from old.discount_total
    or new.tax_total is distinct from old.tax_total
    or new.tax_included is distinct from old.tax_included
    or new.tax_exempt_amount is distinct from old.tax_exempt_amount
    or new.service_charge is distinct from old.service_charge
    or new.grand_total is distinct from old.grand_total then
      if not (coalesce(current_setting('app.recalc', true), '') = 'on'
              and old.status = 'completed' and old.payment_status in ('unpaid', 'partial')) then
        raise exception 'Bill % is closed and its amounts cannot be changed. Void it or raise a refund instead.', old.bill_number;
      end if;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

-- Money already taken against a bill, not counting cash rounding.
create or replace function app.order_covered(p_order uuid)
 returns numeric language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select coalesce(sum(amount - coalesce(rounding_adjustment, 0)), 0)::numeric(14,2)
    from public.payments where order_id = p_order and status = 'captured';
$$;

create or replace function app.next_bill_number(p_branch uuid, out device_id uuid, out bill_no text)
 language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_prefix text; v_seq bigint;
begin
  select d.id, d.bill_prefix, d.next_bill_seq into device_id, v_prefix, v_seq
    from public.devices d where d.branch_id = p_branch and d.is_active order by d.created_at limit 1 for update;
  if device_id is null then raise exception 'No billing device is set up for this branch.'; end if;
  bill_no := (select b.code from public.branches b where b.id = p_branch)
             || '-' || coalesce(v_prefix, 'C1') || '-' || lpad(v_seq::text, 4, '0');
  update public.devices set next_bill_seq = next_bill_seq + 1 where id = device_id;
end $$;

-- Validates the cart (items, options, service charge, senior) and builds the
-- engine input. Options: each item may carry "options": [modifier_item_id, ...].
create or replace function app.bill_input(p_restaurant uuid, p_branch uuid, p_items jsonb, p_discount numeric, p_service_charge boolean, p_senior jsonb)
 returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare
  bs record; v_country public.countries%rowtype; v_item jsonb; v_product public.products%rowtype;
  v_incl boolean; v_rate uuid; v_comps jsonb; v_lines jsonb := '[]'::jsonb; v_qty numeric; i int := 0;
  v_sc_on boolean; v_senior jsonb := null; v_cnt int; v_din int;
  v_req int; v_found int; v_opts jsonb; v_delta numeric; v_text text; g record;
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
    if not v_product.is_available then raise exception '% is marked sold out.', v_product.name; end if;
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
                                order by mg.created_at, mg.id, mi.display_order, mi.name), '[]'::jsonb),
             coalesce(sum(mi.price_delta), 0),
             string_agg(mi.name, ', ' order by mg.created_at, mg.id, mi.display_order, mi.name)
        into v_found, v_opts, v_delta, v_text
        from jsonb_array_elements_text(v_item->'options') x
        join public.modifier_items mi on mi.id = x::uuid and mi.restaurant_id = p_restaurant and mi.is_active
        join public.modifier_groups mg on mg.id = mi.modifier_group_id
        join public.product_modifier_groups pmg on pmg.modifier_group_id = mg.id and pmg.product_id = v_product.id;
      if v_found <> v_req then raise exception 'An option on % is no longer available.', v_product.name; end if;
    end if;
    for g in
      select mg.name, greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end) as mn,
             coalesce(mg.max_select, 99) as mx,
             (select count(*) from jsonb_array_elements(v_opts) o
               join public.modifier_items mi on mi.id = (o->>'id')::uuid where mi.modifier_group_id = mg.id) as picked
        from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id
       where pmg.product_id = v_product.id
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
      'qty', v_qty, 'note', nullif(left(coalesce(v_item->>'note', ''), 200), ''),
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
end $$;

-- Inserts validated lines (from bill_input) with zero amounts; recalc_order fills them.
create or replace function app.insert_order_lines(p_order uuid, p_restaurant uuid, p_lines jsonb)
 returns uuid[] language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare s jsonb; m jsonb; v_id uuid; v_ids uuid[] := '{}';
begin
  for s in select * from jsonb_array_elements(p_lines) loop
    v_id := gen_random_uuid();
    insert into public.order_items
      (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity, modifier_total,
       line_subtotal, line_discount, line_tax, line_total, is_price_inclusive, kitchen_note,
       net_amount, service_charge, tax_included, tax_comps, options_text, created_at)
    values
      (v_id, p_restaurant, p_order, (s->>'product_id')::uuid, s->>'name', (s->>'price')::numeric,
       (s->>'qty')::numeric, (s->>'price')::numeric - coalesce((s->>'base_price')::numeric, (s->>'price')::numeric),
       0, 0, 0, 0, coalesce((s->>'inclusive')::boolean, false), s->>'note',
       0, 0, 0, coalesce(s->'comps', '[]'::jsonb), nullif(s->>'options_text', ''), clock_timestamp());
    for m in select * from jsonb_array_elements(coalesce(s->'options', '[]'::jsonb)) loop
      insert into public.order_item_modifiers (restaurant_id, order_item_id, modifier_item_id, name, price_delta)
      values (p_restaurant, v_id, (m->>'id')::uuid, m->>'name', coalesce((m->>'price_delta')::numeric, 0));
    end loop;
    v_ids := v_ids || v_id;
  end loop;
  return v_ids;
end $$;

-- Recomputes a bill from its live lines with the one money engine and writes
-- every amount back (lines, line taxes, discounts, totals).
create or replace function app.recalc_order(p_order uuid)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  o public.orders%rowtype; p jsonb; r record; i int := 0; v_lines jsonb := '[]'::jsonb; v_map jsonb := '{}'::jsonb;
  v_c jsonb; l jsonb; t jsonb; v_id uuid; v_comps jsonb;
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Bill not found.'; end if;
  p := coalesce(o.calc_params, '{}'::jsonb);

  for r in select id, unit_price, quantity, is_price_inclusive, tax_comps
             from public.order_items where order_id = p_order and cancelled_at is null
            order by created_at, id loop
    i := i + 1;
    v_comps := coalesce(r.tax_comps,
      (select jsonb_agg(jsonb_build_object('name', component_name, 'rate', rate, 'compound', false) order by id)
         from public.order_item_taxes where order_item_id = r.id), '[]'::jsonb);
    v_lines := v_lines || jsonb_build_object('key', i, 'price', r.unit_price, 'qty', r.quantity,
                 'inclusive', coalesce(r.is_price_inclusive, false), 'comps', v_comps);
    v_map := v_map || jsonb_build_object(i::text, jsonb_build_object('id', r.id, 'comps', v_comps));
  end loop;
  if i = 0 then raise exception 'Bill % has no items left. Void it instead.', o.bill_number; end if;

  v_c := app.calc_bill(jsonb_build_object(
    'lines', v_lines, 'discount', coalesce((p->>'discount')::numeric, 0),
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

  update public.orders set
      subtotal = (v_c->>'subtotal')::numeric,
      discount_total = (v_c->>'discount')::numeric + (v_c->>'senior_discount')::numeric,
      tax_total = (v_c->>'tax_total')::numeric,
      tax_included = (v_c->>'tax_included')::numeric,
      tax_exempt_amount = (v_c->>'tax_exempt_amount')::numeric,
      exempt_sales = (v_c->>'exempt_sales')::numeric,
      service_charge = (v_c->>'service_charge')::numeric,
      rounding_adjustment = (v_c->>'rounding')::numeric,
      grand_total = (v_c->>'grand_total')::numeric
   where id = p_order;

  perform set_config('app.recalc', 'off', true);
  return v_c;
end $$;

create or replace function app.create_kitchen_ticket(p_order uuid, p_items uuid[])
 returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare o public.orders%rowtype; v_n int; v_id uuid := gen_random_uuid();
begin
  select * into o from public.orders where id = p_order;
  select count(*) + 1 into v_n from public.kitchen_tickets where order_id = p_order;
  insert into public.kitchen_tickets (id, restaurant_id, branch_id, order_id, ticket_number, status, client_created_at)
  values (v_id, o.restaurant_id, o.branch_id, o.id,
          'K-' || o.bill_number || case when v_n > 1 then '-' || v_n else '' end, 'new', now());
  insert into public.kitchen_ticket_items (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note)
  select o.restaurant_id, v_id, oi.id,
         oi.product_name || coalesce(' (' || oi.options_text || ')', ''), oi.quantity, oi.kitchen_note
    from public.order_items oi where oi.id = any(p_items) order by oi.created_at, oi.id;
  return v_id;
end $$;

revoke all on function app.order_covered(uuid), app.next_bill_number(uuid), app.insert_order_lines(uuid, uuid, jsonb),
  app.recalc_order(uuid), app.create_kitchen_ticket(uuid, uuid[]) from public, anon, authenticated;

-- ---------------------------------------------------------------- create_order
create or replace function public.create_order(p_items jsonb, p_order_type text default 'dine_in', p_table_id uuid default null,
  p_customer_id uuid default null, p_payment_method_id uuid default null, p_tendered numeric default null,
  p_discount_amount numeric default 0, p_discount_reason text default null, p_service_charge boolean default null,
  p_senior jsonb default null)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  v_restaurant uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  v_in jsonb; v_c jsonb; v_currency char(3); v_auto_kot boolean; v_shift uuid; v_device uuid;
  v_bill_no text; v_order_id uuid := gen_random_uuid(); v_ids uuid[];
  v_method_kind text; v_grand numeric(14,2); v_amount numeric(14,2); v_cash_round numeric(14,2) := 0;
  v_change numeric(14,2) := 0; v_paid boolean := false; v_rmode text;
begin
  if coalesce(p_discount_amount, 0) < 0 then raise exception 'A discount cannot be negative.'; end if;
  if coalesce(p_discount_amount, 0) > 0 and not app.has_permission('order.discount') then
    raise exception 'A manager must approve a discount.';
  end if;
  if v_branch is null then raise exception 'No branch is set up for this restaurant.'; end if;
  if coalesce(p_order_type, '') not in ('dine_in', 'takeaway', 'delivery') then raise exception 'Unknown order type.'; end if;

  select s.id into v_shift from public.shifts s
   where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1;
  if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

  if p_payment_method_id is not null then
    select pm.kind into v_method_kind from public.payment_methods pm
     where pm.id = p_payment_method_id and pm.restaurant_id = v_restaurant and pm.is_active;
    if not found then raise exception 'That payment method is not available.'; end if;
  end if;
  if p_table_id is not null and not exists (
      select 1 from public.dining_tables t where t.id = p_table_id and t.restaurant_id = v_restaurant and t.is_active) then
    raise exception 'That table does not exist.';
  end if;
  if p_customer_id is not null and not exists (
      select 1 from public.customers c where c.id = p_customer_id and c.restaurant_id = v_restaurant and c.deleted_at is null) then
    raise exception 'That customer does not exist.';
  end if;

  v_in := app.bill_input(v_restaurant, v_branch, p_items, p_discount_amount, p_service_charge, p_senior);
  v_rmode := v_in->>'cash_rounding';

  select r.currency_code into v_currency from public.restaurants r where r.id = v_restaurant;
  select coalesce(bs.auto_print_kot, true) into v_auto_kot from public.branch_settings bs where bs.branch_id = v_branch;
  v_auto_kot := coalesce(v_auto_kot, true);

  select n.device_id, n.bill_no into v_device, v_bill_no from app.next_bill_number(v_branch) n;

  insert into public.orders
    (id, restaurant_id, branch_id, device_id, bill_number, order_type, dining_table_id, customer_id,
     cashier_id, shift_id, currency_code, status, payment_status, client_created_at, calc_params, senior_details)
  values
    (v_order_id, v_restaurant, v_branch, v_device, v_bill_no, p_order_type, p_table_id, p_customer_id,
     v_user, v_shift, v_currency, 'open', 'unpaid', now(), (v_in->'calc') - 'lines', v_in->'senior');

  v_ids := app.insert_order_lines(v_order_id, v_restaurant, v_in->'calc'->'lines');
  v_c := app.recalc_order(v_order_id);
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
       change_amount, status, received_by, client_created_at, rounding_adjustment)
    values
      (gen_random_uuid(), v_restaurant, v_order_id, p_payment_method_id, v_amount, v_currency,
       p_tendered, v_change, 'captured', v_user, now(), v_cash_round);
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
    'cash_rounding', v_cash_round, 'change', v_change, 'paid', v_paid or v_grand = 0);
end $$;

-- ---------------------------------------------------------- add items to a bill
create or replace function public.add_order_items(p_order_id uuid, p_items jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; v_in jsonb; v_ids uuid[]; v_c jsonb; v_auto boolean; v_before numeric(14,2);
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then
    raise exception 'Bill % is already paid. Start a new bill for more items.', o.bill_number;
  end if;
  if not exists (select 1 from public.shifts where branch_id = o.branch_id and status = 'open') then
    raise exception 'Open a shift before taking bills.';
  end if;
  v_before := o.grand_total;
  v_in := app.bill_input(o.restaurant_id, o.branch_id, p_items, 0, null, null);
  v_ids := app.insert_order_lines(o.id, o.restaurant_id, v_in->'calc'->'lines');
  v_c := app.recalc_order(o.id);

  select coalesce(bs.auto_print_kot, true) into v_auto from public.branch_settings bs where bs.branch_id = o.branch_id;
  if coalesce(v_auto, true) then perform app.create_kitchen_ticket(o.id, v_ids); end if;

  perform app.audit('order.add_items', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'lines_added', coalesce(array_length(v_ids, 1), 0),
                       'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', v_before));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number,
    'grand_total', (v_c->>'grand_total')::numeric,
    'balance', (v_c->>'grand_total')::numeric - app.order_covered(o.id));
end $$;

-- ------------------------------------------------ cancel an item (manager, reason)
create or replace function public.cancel_order_item(p_order_item_id uuid, p_qty numeric, p_reason text)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.void');
  it public.order_items%rowtype; o public.orders%rowtype; v_q numeric; v_c jsonb; v_before numeric(14,2);
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'A reason is required to cancel an item.'; end if;
  select * into it from public.order_items where id = p_order_item_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That item is not on the bill.'; end if;
  select * into o from public.orders where id = it.order_id for update;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then
    raise exception 'Bill % is already paid. Use a refund instead.', o.bill_number;
  end if;
  if it.cancelled_at is not null then raise exception '% is already cancelled.', it.product_name; end if;
  v_q := coalesce(p_qty, it.quantity);
  if v_q <= 0 or v_q > it.quantity then
    raise exception 'Enter a quantity between 1 and % for %.', trim_scale(it.quantity), it.product_name;
  end if;
  v_before := o.grand_total;

  if v_q = it.quantity then
    if (select count(*) from public.order_items where order_id = o.id and cancelled_at is null) = 1 then
      raise exception '% is the only item on bill %. Void the bill instead.', it.product_name, o.bill_number;
    end if;
    update public.order_items set cancelled_at = now(), cancelled_by = v_user, cancelled_qty = cancelled_qty + v_q,
           cancel_reason = left(trim(p_reason), 200) where id = it.id;
    update public.kitchen_ticket_items set status = 'cancelled' where order_item_id = it.id and status in ('new', 'preparing');
  else
    update public.order_items set quantity = quantity - v_q, cancelled_qty = cancelled_qty + v_q,
           cancel_reason = left(trim(p_reason), 200) where id = it.id;
    update public.kitchen_ticket_items set quantity = quantity - v_q
     where order_item_id = it.id and status in ('new', 'preparing') and quantity > v_q;
  end if;
  update public.kitchen_tickets kt set status = 'cancelled'
   where kt.order_id = o.id and kt.status in ('new', 'preparing')
     and not exists (select 1 from public.kitchen_ticket_items k where k.kitchen_ticket_id = kt.id and k.status <> 'cancelled');

  v_c := app.recalc_order(o.id);
  if (v_c->>'grand_total')::numeric < app.order_covered(o.id) then
    raise exception 'Bill % already has % paid, which is more than the new total. Refund after payment instead.',
      o.bill_number, app.order_covered(o.id);
  end if;

  perform app.audit('order.cancel_item', 'order_items', it.id,
    jsonb_build_object('bill_number', o.bill_number, 'item', it.product_name, 'qty', v_q,
                       'reason', left(trim(p_reason), 200), 'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', v_before, 'qty', it.quantity));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'grand_total', (v_c->>'grand_total')::numeric);
end $$;

-- ------------------------------------------------------------------ move table
create or replace function public.move_order_table(p_order_id uuid, p_table_id uuid)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; v_to text; v_from text; v_busy text;
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', o.bill_number; end if;
  select table_number into v_to from public.dining_tables
   where id = p_table_id and restaurant_id = o.restaurant_id and is_active;
  if not found then raise exception 'That table does not exist.'; end if;
  if o.dining_table_id = p_table_id then raise exception 'Bill % is already on table %.', o.bill_number, v_to; end if;
  select bill_number into v_busy from public.orders
   where dining_table_id = p_table_id and id <> o.id and status <> 'voided' and payment_status in ('unpaid', 'partial') limit 1;
  if v_busy is not null then
    raise exception 'Table % already has bill %. Use Merge to put the two bills together.', v_to, v_busy;
  end if;
  select table_number into v_from from public.dining_tables where id = o.dining_table_id;
  update public.orders set dining_table_id = p_table_id, order_type = 'dine_in' where id = o.id;
  perform app.audit('order.move_table', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'table', v_to), jsonb_build_object('table', v_from));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'table', v_to);
end $$;

-- --------------------------------------------------------------- merge bills
create or replace function public.merge_orders(p_target_id uuid, p_source_id uuid)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  t public.orders%rowtype; s public.orders%rowtype; v_c jsonb; r record;
begin
  if p_target_id = p_source_id then raise exception 'Choose two different bills to merge.'; end if;
  -- Lock in a fixed order so two people merging at once cannot deadlock.
  for r in select id from public.orders where id in (p_target_id, p_source_id)
            and restaurant_id = app.current_restaurant_id() order by id for update loop
  end loop;
  select * into t from public.orders where id = p_target_id and restaurant_id = app.current_restaurant_id();
  select * into s from public.orders where id = p_source_id and restaurant_id = app.current_restaurant_id();
  if t.id is null or s.id is null then raise exception 'Bill not found.'; end if;
  if t.branch_id <> s.branch_id then raise exception 'Only bills from the same branch can be merged.'; end if;
  if t.status = 'voided' or s.status = 'voided' then raise exception 'A voided bill cannot be merged.'; end if;
  if t.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', t.bill_number; end if;
  if s.payment_status <> 'unpaid' or app.order_covered(s.id) > 0 then
    raise exception 'Bill % already has a payment, so it cannot be merged into another bill.', s.bill_number;
  end if;
  if coalesce((s.calc_params->>'discount')::numeric, 0) > 0 or s.senior_details is not null
     or exists (select 1 from public.order_discounts where order_id = s.id) then
    raise exception 'Bill % has a discount, so it cannot be merged.', s.bill_number;
  end if;

  update public.order_items set order_id = t.id where order_id = s.id;
  update public.order_item_taxes set order_id = t.id where order_id = s.id;
  update public.kitchen_tickets set order_id = t.id where order_id = s.id;

  perform set_config('app.recalc', 'on', true);
  update public.orders set status = 'voided', voided_by = v_user, voided_at = now(),
         void_reason = 'Merged into bill ' || t.bill_number, merged_into = t.id,
         subtotal = 0, discount_total = 0, tax_total = 0, tax_included = 0, tax_exempt_amount = 0,
         exempt_sales = 0, service_charge = 0, rounding_adjustment = 0, grand_total = 0
   where id = s.id;
  v_c := app.recalc_order(t.id);

  perform app.audit('order.merge', 'orders', t.id,
    jsonb_build_object('bill_number', t.bill_number, 'merged_from', s.bill_number, 'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', t.grand_total, 'source_total', s.grand_total));
  return jsonb_build_object('order_id', t.id, 'bill_number', t.bill_number, 'merged_from', s.bill_number,
                            'grand_total', (v_c->>'grand_total')::numeric);
end $$;

-- --------------------------------------------------------------- split a bill
-- p_items: [{order_item_id, qty}] moves those quantities to a new bill.
create or replace function public.split_order(p_order_id uuid, p_items jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; it public.order_items%rowtype; r record; v_shift uuid; v_device uuid; v_bill text;
  v_new uuid := gen_random_uuid(); v_line uuid; v_c1 jsonb; v_c2 jsonb; v_moved int := 0;
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment. Split the payment instead.', o.bill_number;
  end if;
  if coalesce((o.calc_params->>'discount')::numeric, 0) > 0 or o.senior_details is not null
     or exists (select 1 from public.order_discounts where order_id = o.id) then
    raise exception 'Bill % has a discount, so it cannot be split. Split the payment instead.', o.bill_number;
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Choose the items to move to the new bill.';
  end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
  if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

  select n.device_id, n.bill_no into v_device, v_bill from app.next_bill_number(o.branch_id) n;
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
         net_amount, service_charge, tax_included, tax_comps, options_text, created_at)
      values
        (v_line, it.restaurant_id, v_new, it.product_id, it.product_name, it.unit_price, r.q, it.modifier_total,
         0, 0, 0, 0, it.is_price_inclusive, it.kitchen_note, 0, 0, 0, it.tax_comps, it.options_text, clock_timestamp());
      insert into public.order_item_modifiers (restaurant_id, order_item_id, modifier_item_id, name, price_delta)
      select restaurant_id, v_line, modifier_item_id, name, price_delta from public.order_item_modifiers where order_item_id = it.id;
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
  return jsonb_build_object('order_id', v_new, 'bill_number', v_bill, 'grand_total', (v_c2->>'grand_total')::numeric,
                            'source_bill_number', o.bill_number, 'source_grand_total', (v_c1->>'grand_total')::numeric);
end $$;

-- --------------------------------------------- payments: full or part payment
drop function if exists public.pay_order(uuid, uuid, numeric);
create function public.pay_order(p_order_id uuid, p_payment_method_id uuid, p_tendered numeric default null, p_amount numeric default null)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; v_kind text; v_shift uuid; v_rmode text; v_rcash boolean;
  v_balance numeric(14,2); v_amount numeric(14,2); v_round numeric(14,2) := 0; v_change numeric(14,2) := 0; v_full boolean;
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', o.bill_number; end if;
  select pm.kind into v_kind from public.payment_methods pm
   where pm.id = p_payment_method_id and pm.restaurant_id = o.restaurant_id and pm.is_active;
  if not found then raise exception 'That payment method is not available.'; end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
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
     change_amount, status, received_by, client_created_at, rounding_adjustment)
  values
    (gen_random_uuid(), o.restaurant_id, o.id, p_payment_method_id, v_amount, o.currency_code,
     p_tendered, v_change, 'captured', v_user, now(), v_round);

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
end $$;

-- A refund is only for a fully paid bill.
create or replace function public.refund_order(p_order_id uuid, p_amount numeric, p_reason text)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.refund');
  o public.orders%rowtype; v_done numeric(14,2); v_left numeric(14,2); v_payment uuid;
  v_id uuid := gen_random_uuid(); v_amount numeric(14,2) := round(coalesce(p_amount,0), 2);
begin
  if coalesce(trim(p_reason),'') = '' then raise exception 'A reason is required for a refund.'; end if;
  if v_amount <= 0 then raise exception 'Enter a refund amount greater than zero.'; end if;
  select * into o from public.orders
   where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status <> 'completed' then raise exception 'Only a completed bill can be refunded.'; end if;
  if o.payment_status in ('unpaid', 'partial') then
    raise exception 'Bill % is not fully paid yet. Take the rest of the payment, or cancel items / void the bill instead.', o.bill_number;
  end if;
  select coalesce(sum(amount),0) into v_done from public.refunds where order_id = o.id;
  v_left := o.paid_total - v_done;
  if v_left <= 0 then raise exception 'Bill % has already been fully refunded.', o.bill_number; end if;
  if v_amount > v_left then
    raise exception 'The most that can be refunded on bill % is %.', o.bill_number, v_left;
  end if;
  select id into v_payment from public.payments where order_id = o.id order by created_at limit 1;

  insert into public.refunds (id, restaurant_id, order_id, payment_id, amount, reason, approved_by, client_created_at)
  values (v_id, o.restaurant_id, o.id, v_payment, v_amount, left(trim(p_reason),300), v_user, now());

  update public.orders set payment_status =
         case when v_done + v_amount >= o.paid_total then 'refunded' else 'partially_refunded' end
   where id = o.id;

  perform app.audit('order.refund', 'refunds', v_id,
    jsonb_build_object('bill_number', o.bill_number, 'amount', v_amount, 'reason', left(trim(p_reason),300)));
  return jsonb_build_object('refund_id', v_id, 'bill_number', o.bill_number,
                            'amount', v_amount, 'remaining', v_left - v_amount);
end $$;

grant execute on function public.add_order_items(uuid, jsonb), public.cancel_order_item(uuid, numeric, text),
  public.move_order_table(uuid, uuid), public.merge_orders(uuid, uuid), public.split_order(uuid, jsonb),
  public.pay_order(uuid, uuid, numeric, numeric) to authenticated;
revoke execute on function public.add_order_items(uuid, jsonb), public.cancel_order_item(uuid, numeric, text),
  public.move_order_table(uuid, uuid), public.merge_orders(uuid, uuid), public.split_order(uuid, jsonb),
  public.pay_order(uuid, uuid, numeric, numeric) from anon;
