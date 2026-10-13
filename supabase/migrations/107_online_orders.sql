-- 107: Online orders (Swiggy, Zomato, your own website) — the SNA POS side.
-- An ordering partner (for example an aggregator integration service) posts each new order to SNA POS with the
-- restaurant's API key. The order waits on the "Online orders" screen; accepting it makes a delivery bill (kitchen
-- ticket as usual) marked with its channel. An order already paid online is paid on the bill with that channel's
-- payment method, which is not cash and does not touch the drawer. The same order sent twice is taken once.

alter table public.orders add column channel text check (channel is null or channel ~ '^[a-z0-9_]{2,20}$');

create table public.online_orders (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  channel text not null check (channel ~ '^[a-z0-9_]{2,20}$'),
  external_ref text not null check (length(external_ref) between 1 and 60),
  items jsonb not null,
  customer_name text check (customer_name is null or length(customer_name) <= 80),
  customer_phone text check (customer_phone is null or length(customer_phone) <= 20),
  address text check (address is null or length(address) <= 300),
  note text check (note is null or length(note) <= 200),
  paid_online boolean not null default false,
  partner_total numeric(14,2),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  order_id uuid references public.orders(id) on delete restrict,
  decided_by uuid references public.users(id) on delete set null,
  decided_at timestamptz,
  reject_reason text check (reject_reason is null or length(reject_reason) <= 200),
  created_at timestamptz not null default now(),
  unique (restaurant_id, channel, external_ref)
);
create index idx_online_orders_pending on public.online_orders (branch_id, status, created_at);
alter table public.online_orders enable row level security;
create policy tenant_read on public.online_orders for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
revoke all on public.online_orders from anon;
grant select on public.online_orders to authenticated;

-- Receives one order from a partner. p: {channel, order_id, outlet_code?, customer:{name, phone, address}, note,
-- paid_online, total, items:[{product_id | item_code, qty, options?:[option ids], note?}]}
create or replace function public.online_order_receive(p_key text, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
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
    if coalesce((x->>'qty')::numeric, 0) <= 0 or (x->>'qty')::numeric > 99 then raise exception 'Each qty must be 1 to 99.'; end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object('product_id', v_prod, 'qty', (x->>'qty')::numeric,
                 'note', left(coalesce(x->>'note', ''), 120),
                 'options', coalesce(case when jsonb_typeof(x->'options') = 'array' then x->'options' end, '[]'::jsonb)));
  end loop;
  -- The items and options must be valid now (sold-out dishes, required choices…).
  perform app.bill_input(v_rest, v_branch, v_items, 0, null, null);

  insert into public.online_orders (restaurant_id, branch_id, channel, external_ref, items, customer_name, customer_phone, address, note, paid_online, partner_total)
  values (v_rest, v_branch, v_channel, v_ref, v_items,
          nullif(left(btrim(coalesce(p->'customer'->>'name', '')), 80), ''), nullif(left(btrim(coalesce(p->'customer'->>'phone', '')), 20), ''),
          nullif(left(btrim(coalesce(p->'customer'->>'address', '')), 300), ''), nullif(left(btrim(coalesce(p->>'note', '')), 200), ''),
          coalesce((p->>'paid_online')::boolean, false), case when coalesce(p->>'total', '') ~ '^[0-9]+(\.[0-9]{1,2})?$' then (p->>'total')::numeric end)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'status', 'pending', 'repeat', false);
end $function$;

-- Waiting online orders of this outlet, and those decided in the last 24 hours.
create or replace function public.online_orders_list()
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'channel', q.channel, 'external_ref', q.external_ref, 'status', q.status,
           'customer_name', q.customer_name, 'customer_phone', q.customer_phone, 'address', q.address, 'note', q.note,
           'paid_online', q.paid_online, 'partner_total', q.partner_total, 'created_at', q.created_at, 'reject_reason', q.reject_reason,
           'bill_number', o.bill_number, 'order_id', q.order_id,
           'items', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'qty', (i->>'qty')::numeric, 'note', nullif(i->>'note', ''))), '[]'::jsonb)
                       from jsonb_array_elements(q.items) i join public.products p on p.id = (i->>'product_id')::uuid))
         order by q.status <> 'pending', q.created_at desc), '[]'::jsonb)
    from public.online_orders q left join public.orders o on o.id = q.order_id
   where q.restaurant_id = app.current_restaurant_id() and q.branch_id = app.current_branch_id() and app.allowed('order.create')
     and (q.status = 'pending' or q.created_at > now() - interval '24 hours')
$function$;

-- The payment method for orders already paid on a channel (made on first use; not cash, not in the drawer).
create or replace function app.channel_method(p_restaurant uuid, p_channel text)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_id uuid; v_name text := initcap(replace(p_channel, '_', ' ')) || ' (paid online)';
begin
  select id into v_id from public.payment_methods where restaurant_id = p_restaurant and kind = 'other' and name = v_name;
  if v_id is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order)
    values (p_restaurant, v_name, 'other', false, true, 90) returning id into v_id;
  end if;
  return v_id;
end $function$;

-- Accept: makes the delivery bill (kitchen ticket as usual) and pays it if it was paid online.
create or replace function public.online_order_accept(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare q public.online_orders; v_res jsonb; v_order uuid; v_due numeric;
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
  update public.online_orders set status = 'accepted', order_id = v_order, decided_by = app.current_user_id(), decided_at = now() where id = q.id;
  perform app.audit('online_order.accept', 'online_orders', q.id, jsonb_build_object('order_id', v_order, 'channel', q.channel), null);
  return v_res || jsonb_build_object('channel', q.channel);
end $function$;

create or replace function public.online_order_reject(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('order.create');
begin
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Give a reason, for example Item not available.'; end if;
  update public.online_orders set status = 'rejected', reject_reason = left(btrim(p_reason), 200), decided_by = v_user, decided_at = now()
   where id = p_id and restaurant_id = app.current_restaurant_id() and status = 'pending';
  if not found then raise exception 'That online order is not waiting.'; end if;
end $function$;

revoke all on function public.online_order_receive(text, jsonb) from public;
grant execute on function public.online_order_receive(text, jsonb) to anon, authenticated, service_role;
revoke all on function public.online_orders_list(), public.online_order_accept(uuid), public.online_order_reject(uuid, text) from public, anon;
grant execute on function public.online_orders_list(), public.online_order_accept(uuid), public.online_order_reject(uuid, text) to authenticated, service_role;
revoke all on function app.channel_method(uuid, text) from public, anon, authenticated;

-- Erasing a test restaurant also removes its online orders.
CREATE OR REPLACE FUNCTION app.erase_groups()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('online_orders', 'customer_ledger', 'batch_movements', 'pre_order_payments', 'pre_orders', 'order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('product_batches', 'price_rules', 'product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'branch_prices',
            'products', 'categories', 'brands', 'dining_tables', 'floors', 'customers', 'riders'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$;
