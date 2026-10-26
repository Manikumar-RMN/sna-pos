-- 132: Move one or more items from a running bill to another table (before the bill is paid).
--
--  * public.move_order_items(p_order_id, p_items, p_to_table, p_client_ref): moves whole lines or part of a line.
--    The target is the table's open bill (same outlet, same kind: food or liquor); if the table has none, a new bill is opened on it.
--  * Money: nothing is re-priced. A moved line keeps its unit price and its tax snapshot (order_items.tax_comps); a part-line is a
--    copy of the line with the same snapshot. Both bills are recomputed with app.recalc_order. The function refuses (and so undoes
--    everything) if the two bills together do not add up to the same subtotal, tax and amount due (before each bill's own rounding) as before.
--  * Refused on a paid, part-paid, voided, merged, discounted or complimentary source bill, and on a discounted or complimentary target.
--    At least one item must stay on the source bill.
--  * Kitchen: a kitchen ticket whose items all moved is pointed at the target bill; a ticket that is shared gets a copy for the
--    target bill, so "food is ready" alerts show the new table and the old table's ticket does not lose its other items.
--  * Safe to send twice (request id kind 'move_items'). Audit: order.move_item. Right needed: order.create.
-- Additive: one new function. Nothing is dropped. One transaction.

create or replace function public.move_order_items(p_order_id uuid, p_items jsonb, p_to_table uuid, p_client_ref uuid default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid;
  v_rest uuid := app.current_restaurant_id();
  o public.orders%rowtype; tg public.orders%rowtype; it public.order_items%rowtype; r record; kt record;
  v_tbl public.dining_tables%rowtype; v_from_tbl text;
  v_tgt uuid; v_new boolean := false; v_shift uuid; v_device uuid; v_bill text; v_line uuid; v_kid uuid; v_n int;
  v_moved uuid[] := '{}'; v_names text[] := '{}'; v_count int := 0;
  v_s0 numeric; v_t0 numeric; v_g0 numeric; v_s1 numeric; v_t1 numeric; v_g1 numeric; v_u0 numeric; v_u1 numeric;
  v_c1 jsonb; v_c2 jsonb; v_seen record; v_out jsonb;
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen
      from public.request_refs rr where rr.restaurant_id = v_rest and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'move_items' or v_seen.order_id is distinct from p_order_id then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  v_user := app.require_permission('order.create');

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Choose the items to move.';
  end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = v_rest;
  if not found then raise exception 'Bill not found.'; end if;
  select * into v_tbl from public.dining_tables
   where id = p_to_table and restaurant_id = v_rest and is_active and not is_kiosk;
  if not found then raise exception 'That table does not exist.'; end if;
  if v_tbl.branch_id <> o.branch_id then raise exception 'Items can only move to a table of the same outlet.'; end if;
  if o.dining_table_id is not distinct from p_to_table then
    raise exception 'These items are already on table %.', v_tbl.table_number;
  end if;

  -- The table's open bill (same kind: food or liquor), if any. Lock both bills in a fixed order so two people moving at once cannot deadlock.
  select x.id into v_tgt from public.orders x
   where x.restaurant_id = v_rest and x.branch_id = o.branch_id and x.dining_table_id = p_to_table and x.id <> o.id
     and x.status <> 'voided' and x.merged_into is null and x.payment_status in ('unpaid', 'partial') and x.is_liquor = o.is_liquor
   order by x.created_at, x.id limit 1;
  for r in select id from public.orders where id in (o.id, coalesce(v_tgt, o.id)) order by id for update loop end loop;
  select * into o from public.orders where id = p_order_id and restaurant_id = v_rest;
  if v_tgt is not null then
    select * into tg from public.orders where id = v_tgt;
    if tg.status = 'voided' or tg.merged_into is not null or tg.payment_status not in ('unpaid', 'partial') then
      raise exception 'Table % just changed. Open the bill again and try once more.', v_tbl.table_number;
    end if;
  end if;

  if o.branch_id is distinct from app.current_branch_id() then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' or o.merged_into is not null then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment, so items cannot be moved off it.', o.bill_number;
  end if;
  if coalesce((o.calc_params->>'discount')::numeric, 0) > 0 or nullif(o.senior_details, 'null'::jsonb) is not null
     or exists (select 1 from public.order_discounts where order_id = o.id) or o.comp_kind is not null then
    raise exception 'Bill % has a discount or is complimentary, so items cannot be moved.', o.bill_number;
  end if;
  if v_tgt is not null and (
       coalesce((tg.calc_params->>'discount')::numeric, 0) > 0 or nullif(tg.senior_details, 'null'::jsonb) is not null
       or exists (select 1 from public.order_discounts where order_id = tg.id) or tg.comp_kind is not null) then
    raise exception 'Bill % on table % has a discount or is complimentary, so items cannot be moved onto it.', tg.bill_number, v_tbl.table_number;
  end if;
  if v_tgt is not null and (
       coalesce(tg.calc_params->>'sc_percent', '0') is distinct from coalesce(o.calc_params->>'sc_percent', '0')
       or coalesce(tg.calc_params->>'sc_taxable', 'false') is distinct from coalesce(o.calc_params->>'sc_taxable', 'false')
       or coalesce(tg.calc_params->>'rounding', 'none') is distinct from coalesce(o.calc_params->>'rounding', 'none')) then
    raise exception 'Bill % on table % uses different service charge or rounding settings, so items cannot be moved onto it.', tg.bill_number, v_tbl.table_number;
  end if;

  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

  select dt.table_number into v_from_tbl from public.dining_tables dt where dt.id = o.dining_table_id;
  -- before: subtotal, tax, grand total as billed (v_g0) and the same without the per-bill rounding (v_u0)
  v_s0 := o.subtotal; v_t0 := o.tax_total; v_g0 := o.grand_total; v_u0 := o.grand_total - o.rounding_adjustment;
  if v_tgt is not null then
    v_s0 := v_s0 + tg.subtotal; v_t0 := v_t0 + tg.tax_total; v_g0 := v_g0 + tg.grand_total; v_u0 := v_u0 + tg.grand_total - tg.rounding_adjustment;
  end if;

  if v_tgt is null then
    v_new := true; v_tgt := gen_random_uuid();
    if o.is_liquor then
      select n.device_id, n.bill_no into v_device, v_bill from app.next_liquor_number(o.branch_id) n;
    else
      select n.device_id, n.bill_no into v_device, v_bill from app.next_bill_number(o.branch_id) n;
    end if;
    insert into public.orders
      (id, restaurant_id, branch_id, device_id, bill_number, order_type, dining_table_id, customer_id,
       cashier_id, waiter_id, shift_id, currency_code, status, payment_status, client_created_at, calc_params)
    values
      (v_tgt, o.restaurant_id, o.branch_id, v_device, v_bill, 'dine_in', p_to_table, null,
       v_user, o.waiter_id, v_shift, o.currency_code, 'open', 'unpaid', now(), o.calc_params);
    select * into tg from public.orders where id = v_tgt;
  end if;

  for r in select (x->>'order_item_id') as oid, sum(coalesce((x->>'qty')::numeric, 0)) as q
             from jsonb_array_elements(p_items) x group by 1 loop
    if coalesce(r.oid, '') !~* '^[0-9a-f-]{36}$' then raise exception 'An item is not on this bill.'; end if;
    select * into it from public.order_items where id = r.oid::uuid and order_id = o.id and cancelled_at is null for update;
    if not found then raise exception 'An item is not on this bill.'; end if;
    if r.q <= 0 then continue; end if;
    if r.q > it.quantity then raise exception 'Only % of % are on the bill.', trim_scale(it.quantity), it.product_name; end if;
    v_count := v_count + 1; v_names := v_names || (trim_scale(r.q)::text || ' x ' || it.product_name);
    if r.q = it.quantity then
      update public.order_items set order_id = v_tgt where id = it.id;
      update public.order_item_taxes set order_id = v_tgt where order_item_id = it.id;
      v_moved := v_moved || it.id;
    else
      -- part of a line: a copy of the line (same price, same tax snapshot, same options) for the target bill
      v_line := gen_random_uuid();
      update public.order_items set quantity = quantity - r.q where id = it.id;
      -- the copy keeps open_price (it is part of the line), but it is not a new open-price event: tell the audit trigger to skip it
      perform set_config('app.line_clone', 'on', true);
      insert into public.order_items
      select * from jsonb_populate_record(null::public.order_items,
        to_jsonb(it) || jsonb_build_object('id', v_line, 'order_id', v_tgt, 'quantity', r.q, 'line_subtotal', 0, 'line_discount', 0,
          'line_tax', 0, 'line_total', 0, 'net_amount', 0, 'service_charge', 0, 'tax_included', 0));
      perform set_config('app.line_clone', '', true);
      insert into public.order_item_modifiers (restaurant_id, order_item_id, modifier_item_id, name, price_delta)
      select restaurant_id, v_line, modifier_item_id, name, price_delta from public.order_item_modifiers where order_item_id = it.id;
      -- the kitchen already has this line: give the moved part its own kitchen line (on the same ticket for now, repointed below)
      select k.id into v_kid from public.kitchen_ticket_items k
       where k.order_item_id = it.id and k.status <> 'cancelled' and k.quantity > r.q order by k.id limit 1;
      if v_kid is not null then
        insert into public.kitchen_ticket_items
        select * from jsonb_populate_record(null::public.kitchen_ticket_items,
          (select to_jsonb(k) from public.kitchen_ticket_items k where k.id = v_kid)
          || jsonb_build_object('id', gen_random_uuid(), 'order_item_id', v_line, 'quantity', r.q));
        update public.kitchen_ticket_items set quantity = quantity - r.q where id = v_kid;
      end if;
      v_moved := v_moved || v_line;
    end if;
  end loop;
  if v_count = 0 then raise exception 'Choose the items to move.'; end if;
  if not exists (select 1 from public.order_items where order_id = o.id and cancelled_at is null) then
    raise exception 'Leave at least one item on bill %. To move the whole bill use Move table or Merge.', o.bill_number;
  end if;

  -- Kitchen tickets: follow the food to the new table.
  for kt in select distinct k.kitchen_ticket_id as id from public.kitchen_ticket_items k where k.order_item_id = any(v_moved) loop
    if exists (select 1 from public.kitchen_ticket_items k where k.kitchen_ticket_id = kt.id and k.order_item_id <> all(v_moved)) then
      select count(*) + 1 into v_n from public.kitchen_tickets where order_id = v_tgt;
      v_kid := gen_random_uuid();
      insert into public.kitchen_tickets
      select * from jsonb_populate_record(null::public.kitchen_tickets,
        (select to_jsonb(k) from public.kitchen_tickets k where k.id = kt.id)
        || jsonb_build_object('id', v_kid, 'order_id', v_tgt, 'branch_id', tg.branch_id,
             'ticket_number', 'K-' || tg.bill_number || case when v_n > 1 then '-' || v_n else '' end));
      update public.kitchen_ticket_items set kitchen_ticket_id = v_kid
       where kitchen_ticket_id = kt.id and order_item_id = any(v_moved);
    else
      update public.kitchen_tickets set order_id = v_tgt where id = kt.id;
    end if;
  end loop;

  v_c1 := app.recalc_order(o.id);
  v_c2 := app.recalc_order(v_tgt);
  if v_new then
    update public.orders set status = 'completed',
           payment_status = case when (v_c2->>'grand_total')::numeric = 0 then 'paid' else 'unpaid' end
     where id = v_tgt;
  end if;

  -- Safety net: moving must not create or lose a single paisa of sales, tax or amount due before rounding. Anything else undoes the whole move.
  -- (Each bill is rounded on its own, e.g. to the nearest rupee, so the two rounded totals may differ from the old pair by the rounding; that is reported, not hidden.)
  v_s1 := (v_c1->>'subtotal')::numeric + (v_c2->>'subtotal')::numeric;
  v_t1 := (v_c1->>'tax_total')::numeric + (v_c2->>'tax_total')::numeric;
  v_g1 := (v_c1->>'grand_total')::numeric + (v_c2->>'grand_total')::numeric;
  v_u1 := v_g1 - (v_c1->>'rounding')::numeric - (v_c2->>'rounding')::numeric;
  if v_s1 <> v_s0 or v_t1 <> v_t0 or v_u1 <> v_u0 then
    raise exception 'The move would change the bill totals, so nothing was moved. Please tell support (bills % and %).', o.bill_number, tg.bill_number;
  end if;

  perform app.audit('order.move_item', 'orders', v_tgt,
    jsonb_build_object('from_bill', o.bill_number, 'from_table', v_from_tbl, 'to_bill', tg.bill_number, 'to_table', v_tbl.table_number,
                       'new_bill', v_new, 'items', to_jsonb(v_names),
                       'from_total', (v_c1->>'grand_total')::numeric, 'to_total', (v_c2->>'grand_total')::numeric),
    jsonb_build_object('from_total', o.grand_total, 'to_total', case when v_new then 0 else tg.grand_total end));
  v_out := jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'grand_total', (v_c1->>'grand_total')::numeric,
    'to_order_id', v_tgt, 'to_bill_number', tg.bill_number, 'to_grand_total', (v_c2->>'grand_total')::numeric,
    'to_table', v_tbl.table_number, 'new_bill', v_new, 'lines_moved', v_count,
    'total_before', v_g0, 'total_after', v_g1, 'unrounded_before', v_u0, 'unrounded_after', v_u1);
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result)
    values (v_rest, p_client_ref, 'move_items', p_order_id, v_out);
    delete from public.request_refs where restaurant_id = v_rest and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $function$;

revoke all on function public.move_order_items(uuid, jsonb, uuid, uuid) from public, anon;
grant execute on function public.move_order_items(uuid, jsonb, uuid, uuid) to authenticated, service_role;
