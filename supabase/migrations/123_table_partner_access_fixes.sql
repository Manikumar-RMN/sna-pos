-- 123: Table orders, partner orders, small billing and access fixes from QA round 1.
--
--  * A table (QR) order that mixes drinks and food is split onto a liquor bill and a food bill; a liquor-only order finds the table's liquor bill.
--  * A partner order mixing liquor and food is refused when it arrives; a total that differs from the POS total is flagged on the bill;
--    a callback is signed only for the state the order is really in; text where a number is expected gives a clean message.
--  * Splitting a bill keeps the line's brand and offer. A delivered, paid bill cannot go back to waiting/returned.
--  * A kiosk's billing user must work at that outlet; adding a kiosk is written to the audit log.
--  * Batches: adding and writing off need the stock or menu right; the "short" figure is right.
--  * Captain: a wrong guest count is refused instead of ignored.
--  * Access: API key hashes are not readable; the audit log is for managers; paid-money tables cannot be edited or deleted.
--  * Dish names are limited to 200 characters; settings must be an object.


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
         net_amount, service_charge, tax_included, tax_comps, options_text, created_at, brand_id, list_price, offer_name)
      values
        (v_line, it.restaurant_id, v_new, it.product_id, it.product_name, it.unit_price, r.q, it.modifier_total,
         0, 0, 0, 0, it.is_price_inclusive, it.kitchen_note, 0, 0, 0, it.tax_comps, it.options_text, clock_timestamp(), it.brand_id, it.list_price, it.offer_name);
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

CREATE OR REPLACE FUNCTION public.delivery_update(p_order uuid, p_status text, p_rider uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); o public.orders;
begin
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found or o.order_type <> 'delivery' then raise exception 'That is not a delivery bill.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if p_status not in ('waiting', 'out', 'delivered', 'returned') then raise exception 'Unknown delivery status.'; end if;
  if o.delivery_status = 'delivered' and p_status in ('waiting', 'returned') and o.payment_status in ('paid', 'refunded', 'partially_refunded') then
    raise exception 'Bill % was delivered and paid, so it cannot go back to %.', o.bill_number, p_status;
  end if;
  if p_status = 'out' then
    if p_rider is null and o.rider_id is null then raise exception 'Choose the rider.'; end if;
    if p_rider is not null and not exists (select 1 from public.riders where id = p_rider and restaurant_id = o.restaurant_id and is_active) then
      raise exception 'That rider was not found.';
    end if;
    update public.orders set delivery_status = 'out', rider_id = coalesce(p_rider, rider_id), out_at = now(), delivered_at = null where id = o.id;
  elsif p_status = 'delivered' then
    if o.rider_id is null and p_rider is null then raise exception 'Choose the rider who delivered it.'; end if;
    update public.orders set delivery_status = 'delivered', rider_id = coalesce(p_rider, rider_id), out_at = coalesce(out_at, now()), delivered_at = now() where id = o.id;
  elsif p_status = 'returned' then
    update public.orders set delivery_status = 'returned', delivered_at = null where id = o.id;
  else
    update public.orders set delivery_status = 'waiting', rider_id = null, out_at = null, delivered_at = null where id = o.id;
  end if;
  perform app.audit('delivery.' || p_status, 'orders', o.id, jsonb_build_object('rider', coalesce(p_rider, o.rider_id)), null);
  return jsonb_build_object('order_id', o.id, 'status', p_status);
end $function$;

CREATE OR REPLACE FUNCTION public.kiosk_set_auto(p_id uuid, p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id();
begin
  if not exists (select 1 from public.dining_tables where id = p_id and restaurant_id = v_rest and is_kiosk and is_active) then
    raise exception 'That kiosk was not found.';
  end if;
  if p_user is not null and not exists (
       select 1 from public.users u join public.role_permissions rp on rp.role_id = u.role_id
        where u.id = p_user and u.restaurant_id = v_rest and u.is_active and u.deleted_at is null and rp.permission_key = 'order.create'
          and u.auth_user_id is not null) then
    raise exception 'Choose an active staff login that signs in with email and is allowed to take orders.';
  end if;
  if p_user is not null and exists (select 1 from public.user_branches ub where ub.user_id = p_user)
     and not exists (select 1 from public.user_branches ub join public.dining_tables t on t.branch_id = ub.branch_id
                      where ub.user_id = p_user and t.id = p_id) then
    raise exception 'That login does not work at this kiosk''s outlet. Choose someone who does.';
  end if;
  update public.dining_tables set kiosk_user_id = p_user where id = p_id;
  perform app.audit('kiosk.auto_accept', 'dining_tables', p_id, jsonb_build_object('user', p_user), null);
end $function$;

CREATE OR REPLACE FUNCTION public.kiosk_add(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_name text := btrim(coalesce(p_name, '')); v_id uuid; v_token text := app.new_token();
begin
  perform app.require_feature('qr_ordering');
  if v_name = '' or length(v_name) > 20 then raise exception 'Give the kiosk a short name, for example Kiosk 1.'; end if;
  if exists (select 1 from public.dining_tables where branch_id = v_branch and lower(table_number) = lower(v_name) and is_active) then
    raise exception 'There is already a table or kiosk called %.', v_name;
  end if;
  insert into public.dining_tables (restaurant_id, branch_id, table_number, seats, is_kiosk, qr_token)
  values (v_rest, v_branch, v_name, 1, true, v_token)
  on conflict (branch_id, table_number) do update set is_active = true, is_kiosk = true, qr_token = coalesce(public.dining_tables.qr_token, excluded.qr_token)
  returning id, qr_token into v_id, v_token;
  perform app.audit('kiosk.add', 'dining_tables', v_id, jsonb_build_object('name', v_name), null);
  return jsonb_build_object('id', v_id, 'name', v_name, 'token', v_token);
end $function$;


create or replace function public.accept_qr_order(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare q public.qr_orders%rowtype; v_order uuid; v_res jsonb; v_first jsonb; v_bill text; v_kiosk boolean;
  v_food jsonb; v_liq jsonb; v_parts jsonb[] := '{}'; v_part jsonb; v_is_liq boolean; v_bills jsonb := '[]'::jsonb; v_food_real int;
begin
  perform app.require_permission('order.create');
  perform app.require_feature('qr_ordering');
  select * into q from public.qr_orders where id = p_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That table order does not exist.'; end if;
  if q.status <> 'pending' then raise exception 'This table order was already %.', q.status; end if;
  if q.branch_id <> app.current_branch_id() then raise exception 'This order is for another outlet. Switch outlet first.'; end if;
  if q.guest_note is not null then
    q.items := jsonb_set(q.items, '{0,note}', to_jsonb(left(concat_ws(' · ', nullif(q.items->0->>'note', ''), 'Guest: ' || q.guest_note), 200)));
  end if;
  v_kiosk := coalesce((select is_kiosk from public.dining_tables where id = q.dining_table_id), false);

  -- Drinks (a separate liquor bill) and food go on different bills.
  select coalesce(jsonb_agg(x) filter (where coalesce(tg.separate_bill, false) and not coalesce(p.is_charge, false)), '[]'::jsonb),
         coalesce(jsonb_agg(x) filter (where not (coalesce(tg.separate_bill, false) and not coalesce(p.is_charge, false))), '[]'::jsonb),
         count(*) filter (where not (coalesce(tg.separate_bill, false) and not coalesce(p.is_charge, false)) and not coalesce(p.is_charge, false))
    into v_liq, v_food, v_food_real
    from jsonb_array_elements(q.items) x
    left join public.products p on p.id::text = x->>'product_id' and p.restaurant_id = q.restaurant_id
    left join public.tax_groups tg on tg.id = p.tax_group_id;
  if v_food_real = 0 and jsonb_array_length(v_liq) > 0 then v_liq := v_liq || v_food; v_food := '[]'::jsonb; end if;
  if jsonb_array_length(v_food) > 0 then v_parts := v_parts || jsonb_build_object('liquor', false, 'items', v_food); end if;
  if jsonb_array_length(v_liq) > 0 then v_parts := v_parts || jsonb_build_object('liquor', true, 'items', v_liq); end if;

  foreach v_part in array v_parts loop
    v_is_liq := (v_part->>'liquor')::boolean;
    v_order := null;
    if not v_kiosk then
      select o.id into v_order from public.orders o
       where o.dining_table_id = q.dining_table_id and o.restaurant_id = q.restaurant_id and o.is_liquor = v_is_liq
         and o.payment_status in ('unpaid', 'partial') and o.status <> 'voided' and o.merged_into is null
       order by o.created_at desc limit 1;
    end if;
    if v_order is not null then
      perform public.add_order_items(v_order, v_part->'items');
      select bill_number into v_bill from public.orders where id = v_order;
      v_res := jsonb_build_object('order_id', v_order, 'bill_number', v_bill, 'added', true);
    else
      if v_kiosk then
        v_res := public.create_order(v_part->'items', 'takeaway', null, null, null, null, 0, null, null, null, null, null);
      else
        v_res := public.create_order(v_part->'items', 'dine_in', q.dining_table_id, null, null, null, 0, null, null, null, null, null);
      end if;
      v_order := (v_res->>'order_id')::uuid;
    end if;
    v_bills := v_bills || jsonb_build_array(v_res);
    if v_first is null then v_first := v_res; end if;
  end loop;
  if v_first is null then raise exception 'That table order has no items.'; end if;
  v_order := (v_first->>'order_id')::uuid;
  update public.qr_orders set status = 'accepted', order_id = v_order, decided_by = app.current_user_id(), decided_at = now() where id = p_id;
  perform app.audit('qr_order.accept', 'qr_orders', p_id, jsonb_build_object('order_id', v_order, 'bills', jsonb_array_length(v_bills)), null);
  return v_first || jsonb_build_object('bills', v_bills);
end $function$;

CREATE OR REPLACE FUNCTION public.online_order_receive(p_key text, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare k public.api_keys%rowtype; v_rest uuid; v_branch uuid; v_calls int; v_channel text; v_ref text; v_items jsonb := '[]'::jsonb;
  x jsonb; v_prod uuid; v_id uuid; v_existing public.online_orders;
begin
  if coalesce(length(p_key), 0) < 20 or length(p_key) > 100 then raise exception 'Invalid API key.'; end if;
  select * into k from public.api_keys where key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex') and revoked_at is null;
  if not found then raise exception 'Invalid API key.'; end if;
  v_rest := k.restaurant_id;
  if not app.feature_on(v_rest, 'open_api') then raise exception 'The Open API is not switched on for this restaurant.'; end if;
  select count(*) into v_calls from public.api_calls where key_id = k.id and at > now() - interval '1 minute';
  if v_calls >= 120 then raise exception 'Too many requests: at most 120 per minute per key.'; end if;
  insert into public.api_calls (key_id, action) values (k.id, 'online_order');
  update public.api_keys set last_used_at = now() where id = k.id;

  v_channel := lower(btrim(coalesce(p->>'channel', '')));
  v_ref := btrim(coalesce(p->>'order_id', ''));
  if v_channel !~ '^[a-z0-9_]{2,20}$' then raise exception 'channel must be a short name such as swiggy, zomato or website.'; end if;
  if v_ref = '' or length(v_ref) > 60 then raise exception 'order_id (the partner''s order number) is needed.'; end if;
  select * into v_existing from public.online_orders where restaurant_id = v_rest and channel = v_channel and external_ref = v_ref;
  if found then return jsonb_build_object('id', v_existing.id, 'status', v_existing.status, 'repeat', true); end if;

  if nullif(btrim(coalesce(p->>'outlet_code', '')), '') is not null then
    select id into v_branch from public.branches where restaurant_id = v_rest and deleted_at is null and upper(code) = upper(btrim(p->>'outlet_code'));
    if v_branch is null then raise exception 'No outlet with the code %.', p->>'outlet_code'; end if;
  else
    select id into v_branch from public.branches where restaurant_id = v_rest and deleted_at is null order by created_at limit 1;
  end if;

  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'The order has no items.'; end if;
  if jsonb_array_length(p->'items') > 50 then raise exception 'At most 50 lines per order.'; end if;
  for x in select * from jsonb_array_elements(p->'items') loop
    v_prod := null;
    if coalesce(x->>'product_id', '') ~* '^[0-9a-f-]{36}$' then
      select id into v_prod from public.products where id = (x->>'product_id')::uuid and restaurant_id = v_rest and deleted_at is null;
    elsif nullif(x->>'item_code', '') is not null then
      select id into v_prod from public.products where restaurant_id = v_rest and barcode = x->>'item_code' and deleted_at is null;
    end if;
    if v_prod is null then raise exception 'Item % is not on the menu. Send product_id or item_code from GET /api/v1/menu.', coalesce(x->>'product_id', x->>'item_code', '?'); end if;
    if coalesce(x->>'qty', '') !~ '^[0-9]{1,2}(\.[0-9]{1,3})?$' or (x->>'qty')::numeric <= 0 or (x->>'qty')::numeric > 99 then raise exception 'Each qty must be a number from 1 to 99.'; end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object('product_id', v_prod, 'qty', (x->>'qty')::numeric,
                 'note', left(coalesce(x->>'note', ''), 120),
                 'options', coalesce(case when jsonb_typeof(x->'options') = 'array' then x->'options' end, '[]'::jsonb)));
  end loop;
  -- The items and options must be valid now (sold-out dishes, required choices…).
  perform app.bill_input(v_rest, v_branch, v_items, 0, null, null);
  -- Liquor and food cannot be on one bill: ask the partner to send them as two orders.
  begin
    perform app.items_are_liquor(v_rest, v_items);
  exception when others then
    raise exception 'This order mixes liquor and food. Send the drinks and the food as two separate orders.';
  end;
  if p ? 'paid_online' and nullif(btrim(p->>'paid_online'), '') is not null and lower(p->>'paid_online') not in ('true', 'false') then
    raise exception 'paid_online must be true or false.';
  end if;

  insert into public.online_orders (restaurant_id, branch_id, channel, external_ref, items, customer_name, customer_phone, address, note, paid_online, partner_total)
  values (v_rest, v_branch, v_channel, v_ref, v_items,
          nullif(left(btrim(coalesce(p->'customer'->>'name', '')), 80), ''), nullif(left(btrim(coalesce(p->'customer'->>'phone', '')), 20), ''),
          nullif(left(btrim(coalesce(p->'customer'->>'address', '')), 300), ''), nullif(left(btrim(coalesce(p->>'note', '')), 200), ''),
          coalesce((p->>'paid_online')::boolean, false), case when coalesce(p->>'total', '') ~ '^[0-9]+(\.[0-9]{1,2})?$' then (p->>'total')::numeric end)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'status', 'pending', 'repeat', false);
end $function$;

CREATE OR REPLACE FUNCTION public.online_order_accept(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare q public.online_orders; v_res jsonb; v_order uuid; v_due numeric; v_grand numeric;
begin
  perform app.require_permission('order.create');
  select * into q from public.online_orders where id = p_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That online order was not found.'; end if;
  if q.status <> 'pending' then raise exception 'This online order was already %.', q.status; end if;
  if q.branch_id <> app.current_branch_id() then raise exception 'This order is for another outlet. Switch outlet first.'; end if;
  if q.note is not null then
    q.items := jsonb_set(q.items, '{0,note}', to_jsonb(left(concat_ws(' · ', nullif(q.items->0->>'note', ''), 'Customer: ' || q.note), 200)));
  end if;
  v_res := public.create_order(q.items, 'delivery', null, null, null, null, 0, null, null, null, null, null,
             jsonb_build_object('guest_name', q.customer_name, 'guest_phone', q.customer_phone, 'address', q.address));
  v_order := (v_res->>'order_id')::uuid;
  update public.orders set channel = q.channel where id = v_order;
  if q.paid_online then
    perform app.require_permission('payment.take');
    v_due := (select grand_total from public.orders where id = v_order) - app.order_covered(v_order);
    if v_due > 0 then perform public.pay_order(v_order, app.channel_method(q.restaurant_id, q.channel), v_due, v_due, q.channel || ' ' || q.external_ref, null); end if;
  end if;
  -- The bill is made at POS prices. When the partner's total is different, say so on the bill, for the owner to reconcile.
  v_grand := (select grand_total from public.orders where id = v_order);
  if q.partner_total is not null and round(q.partner_total, 2) <> v_grand then
    update public.orders set offline_flags = coalesce(offline_flags, '[]'::jsonb)
           || jsonb_build_array(jsonb_build_object('flag', 'partner_total_differs', 'partner_total', q.partner_total, 'pos_total', v_grand))
     where id = v_order;
  end if;
  update public.online_orders set status = 'accepted', order_id = v_order, decided_by = app.current_user_id(), decided_at = now() where id = q.id;
  perform app.audit('online_order.accept', 'online_orders', q.id, jsonb_build_object('order_id', v_order, 'channel', q.channel), null);
  return v_res || jsonb_build_object('channel', q.channel);
end $function$;

CREATE OR REPLACE FUNCTION public.online_order_callback(p_id uuid, p_event text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); q public.online_orders; c public.online_channels; v_body text;
begin
  if p_event not in ('accepted', 'rejected', 'ready') then raise exception 'Unknown event.'; end if;
  select * into q from public.online_orders where id = p_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That online order was not found.'; end if;
  if (p_event = 'accepted' and q.status <> 'accepted') or (p_event = 'ready' and q.status <> 'accepted') or (p_event = 'rejected' and q.status <> 'rejected') then
    raise exception 'This online order is %, so a "%" message cannot be sent for it.', q.status, p_event;
  end if;
  select * into c from public.online_channels where restaurant_id = q.restaurant_id and channel = q.channel;
  if not found or c.callback_url is null then return null; end if;
  v_body := jsonb_build_object('event', p_event, 'channel', q.channel, 'order_id', q.external_ref,
              'bill_number', (select bill_number from public.orders where id = q.order_id),
              'reason', case when p_event = 'rejected' then q.reject_reason end,
              'at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))::text;
  return jsonb_build_object('url', c.callback_url, 'body', v_body, 'signature', encode(extensions.hmac(v_body, c.secret, 'sha256'), 'hex'));
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

CREATE OR REPLACE FUNCTION public.batch_add(p_product uuid, p_qty numeric, p_expires_on date, p_made_on date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v uuid;
  v_made date := coalesce(p_made_on, app.local_today(v_rest));
begin
  if not (app.allowed('stock.manage') or app.allowed('menu.manage')) then
    raise exception 'Your role does not allow this action (stock.manage).';
  end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.batch_write_off(p_batch uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); b public.product_batches;
begin
  if not (app.allowed('stock.manage') or app.allowed('menu.manage')) then
    raise exception 'Your role does not allow this action (stock.manage).';
  end if;
  select * into b from public.product_batches where id = p_batch and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Batch not found.'; end if;
  if b.qty_left <= 0 then return 0; end if;
  update public.product_batches set wasted = wasted + qty_left, qty_left = 0 where id = b.id;
  perform app.audit('batch.write_off', 'product_batches', b.id, jsonb_build_object('qty', b.qty_left), null);
  return b.qty_left;
end $function$;

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
                 'short', greatest(0,
                            coalesce((select sum(oi.quantity) from public.order_items oi join public.orders o on o.id = oi.order_id
                                       where oi.product_id = p.id and o.branch_id = v_branch and oi.created_at >= app.local_day_start(v_rest)
                                         and oi.cancelled_at is null and o.status <> 'voided' and o.merged_into is null), 0)
                          - coalesce((select -sum(bm.qty) from public.batch_movements bm join public.order_items oi on oi.id = bm.order_item_id join public.orders o on o.id = oi.order_id
                                       where oi.product_id = p.id and o.branch_id = v_branch and oi.created_at >= app.local_day_start(v_rest)
                                         and o.status <> 'voided' and o.merged_into is null), 0)))
             order by p.name)
        from public.products p where p.restaurant_id = v_rest and p.track_batches and p.deleted_at is null), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.update_settings(p_settings jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  s jsonb := coalesce(p_settings, '{}'::jsonb);
  v_country char(2); v_taxno text; v_logo text;
begin
  if jsonb_typeof(coalesce(p_settings, '{}'::jsonb)) <> 'object' then raise exception 'Settings must be an object.'; end if;
  select country_code into v_country from public.restaurants where id = v_rest;

  if s ? 'trading_name' and coalesce(trim(s->>'trading_name'), '') = '' then
    raise exception 'The name customers see cannot be empty.';
  end if;
  if s ? 'legal_name' and coalesce(trim(s->>'legal_name'), '') = '' then
    raise exception 'The registered business name cannot be empty.';
  end if;
  if s ? 'tax_registration_no' then
    v_taxno := upper(nullif(trim(s->>'tax_registration_no'), ''));
    if v_taxno is not null and v_country = 'IN'
       and v_taxno !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
      raise exception 'That GSTIN does not look right. It should be 15 characters, like 33AAACA0000A1Z5.';
    end if;
    if v_taxno is not null and length(v_taxno) > 30 then raise exception 'That tax number is too long.'; end if;
  end if;
  if s ? 'cash_rounding_mode' and (s->>'cash_rounding_mode') not in ('none', 'nearest_1', 'nearest_0_05', 'nearest_0_10') then
    raise exception 'Unknown rounding option.';
  end if;
  if s ? 'service_charge_percent' and ((s->>'service_charge_percent')::numeric < 0 or (s->>'service_charge_percent')::numeric > 30) then
    raise exception 'The service charge must be between 0 and 30 percent.';
  end if;

  if s ? 'token_numbers' and (s->>'token_numbers') not in ('off', 'takeaway', 'all') then
    raise exception 'Unknown token number option.';
  end if;
  if s ? 'bill_format' and (jsonb_typeof(s->'bill_format') <> 'object' or length((s->'bill_format')::text) > 4000) then
    raise exception 'The bill layout could not be saved.';
  end if;
  if s ? 'logo' then
    v_logo := nullif(s->>'logo', '');
    if v_logo is not null and (length(v_logo) > 150000 or v_logo !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$') then
      raise exception 'The logo must be a PNG or JPEG picture of about 100 KB or less.';
    end if;
  end if;
  if s ? 'fssai_no' and nullif(trim(s->>'fssai_no'), '') is not null and trim(s->>'fssai_no') !~ '^[0-9]{14}$' then
    raise exception 'The FSSAI licence number has 14 digits.';
  end if;
  if s ? 'sac_code' and nullif(trim(s->>'sac_code'), '') is not null and trim(s->>'sac_code') !~ '^[0-9]{4,8}$' then
    raise exception 'The SAC / HSN code is 4 to 8 digits.';
  end if;

  update public.restaurants set
    logo_url = case when s ? 'logo' then v_logo else logo_url end,
    fssai_no = case when s ? 'fssai_no' then nullif(trim(s->>'fssai_no'), '') else fssai_no end,
    sac_code = case when s ? 'sac_code' then nullif(trim(s->>'sac_code'), '') else sac_code end,
    trading_name = case when s ? 'trading_name' then left(trim(s->>'trading_name'), 120) else trading_name end,
    legal_name   = case when s ? 'legal_name' then left(trim(s->>'legal_name'), 160) else legal_name end,
    tax_registration_no = case when s ? 'tax_registration_no' then v_taxno else tax_registration_no end,
    contact_phone = case when s ? 'contact_phone' then nullif(left(trim(s->>'contact_phone'), 30), '') else contact_phone end
  where id = v_rest;

  update public.branches set
    name = case when s ? 'branch_name' and coalesce(trim(s->>'branch_name'), '') <> '' then left(trim(s->>'branch_name'), 80) else name end,
    address_line1 = case when s ? 'address_line1' then nullif(left(trim(s->>'address_line1'), 160), '') else address_line1 end,
    address_line2 = case when s ? 'address_line2' then nullif(left(trim(s->>'address_line2'), 160), '') else address_line2 end,
    city = case when s ? 'city' then nullif(left(trim(s->>'city'), 80), '') else city end,
    state_or_region = case when s ? 'state_or_region' then nullif(left(trim(s->>'state_or_region'), 80), '') else state_or_region end,
    postal_code = case when s ? 'postal_code' then nullif(left(trim(s->>'postal_code'), 12), '') else postal_code end,
    phone = case when s ? 'phone' then nullif(left(trim(s->>'phone'), 30), '') else phone end
  where id = v_branch;

  update public.branch_settings set
    receipt_header = case when s ? 'receipt_header' then nullif(left(trim(s->>'receipt_header'), 120), '') else receipt_header end,
    receipt_footer = case when s ? 'receipt_footer' then nullif(left(trim(s->>'receipt_footer'), 300), '') else receipt_footer end,
    cash_rounding_mode = case when s ? 'cash_rounding_mode' then s->>'cash_rounding_mode' else cash_rounding_mode end,
    rounding_cash_only = case when s ? 'rounding_cash_only' then (s->>'rounding_cash_only')::boolean else rounding_cash_only end,
    auto_print_kot = case when s ? 'auto_print_kot' then (s->>'auto_print_kot')::boolean else auto_print_kot end,
    token_numbers = case when s ? 'token_numbers' then s->>'token_numbers' else token_numbers end,
    bill_format = case when s ? 'bill_format' then app.clean_bill_format(s->'bill_format') else bill_format end,
    service_charge_percent = case when s ? 'service_charge_percent' then round((s->>'service_charge_percent')::numeric, 2) else service_charge_percent end,
    service_charge_taxable = case when s ? 'service_charge_taxable' then (s->>'service_charge_taxable')::boolean else service_charge_taxable end,
    service_charge_default_on = case when s ? 'service_charge_default_on' then (s->>'service_charge_default_on')::boolean else service_charge_default_on end,
    service_charge_label = case when s ? 'service_charge_label' and coalesce(trim(s->>'service_charge_label'), '') <> ''
                                then left(trim(s->>'service_charge_label'), 40) else service_charge_label end
  where branch_id = v_branch;

  -- The audit log keeps what changed, not the picture itself.
  perform app.audit('settings.update', 'restaurants', v_rest,
    (s - 'logo') || case when s ? 'logo' then jsonb_build_object('logo', case when v_logo is null then 'removed' else 'changed' end) else '{}'::jsonb end);
end $function$;


-- API key hashes are never readable by a signed-in user.
revoke select on public.api_keys from authenticated;
grant select (id, restaurant_id, name, prefix, created_at, last_used_at, revoked_at) on public.api_keys to authenticated;

-- The audit log is for the people who manage the business, not every role.
drop policy if exists tenant_read on public.audit_logs;
create policy tenant_read on public.audit_logs for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id())
         and ((select app.has_permission('report.view_financial')) or (select app.has_permission('user.manage')) or (select app.has_permission('settings.manage'))));

-- Money records cannot be edited or deleted after the fact (a gift card's expiry date can be extended).
drop trigger if exists trg_no_update_cash_movements on public.cash_movements;
create trigger trg_no_update_cash_movements before update on public.cash_movements for each row execute function app.block_update();
drop trigger if exists trg_no_delete_cash_movements on public.cash_movements;
create trigger trg_no_delete_cash_movements before delete on public.cash_movements for each row execute function app.block_delete();
create or replace function app.guard_gift_card_update()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  if (to_jsonb(new) - 'expires_on') is distinct from (to_jsonb(old) - 'expires_on') then
    raise exception 'A gift card''s value and details cannot be changed.';
  end if;
  return new;
end $function$;
drop trigger if exists trg_guard_gift_card_update on public.gift_cards;
create trigger trg_guard_gift_card_update before update on public.gift_cards for each row execute function app.guard_gift_card_update();

-- Dish names are at most 200 characters (existing rows are left as they are).
alter table public.products drop constraint if exists products_name_length;
alter table public.products add constraint products_name_length check (length(name) <= 200) not valid;
