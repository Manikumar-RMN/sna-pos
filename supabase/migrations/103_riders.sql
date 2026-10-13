-- 103: Own delivery riders.
-- Delivery bills get a rider and a delivery status: waiting → out → delivered (or returned).
-- Cash on delivery stays unpaid on the bill until the rider hands the cash over; "settle rider" then takes payment
-- for all of that rider's delivered, unpaid bills at once, into the drawer.

create table public.riders (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid references public.branches(id) on delete set null,
  name text not null check (length(btrim(name)) between 1 and 60),
  phone text check (phone is null or length(phone) <= 20),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (restaurant_id, id)
);
alter table public.riders enable row level security;
create policy tenant_read on public.riders for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
revoke all on public.riders from anon;
grant select on public.riders to authenticated;

alter table public.orders
  add column rider_id uuid,
  add column delivery_status text check (delivery_status in ('waiting', 'out', 'delivered', 'returned')),
  add column out_at timestamptz,
  add column delivered_at timestamptz,
  add constraint orders_rider_same_rest foreign key (restaurant_id, rider_id) references public.riders (restaurant_id, id) on delete restrict;
create index idx_orders_delivery on public.orders (branch_id, delivery_status) where order_type = 'delivery';

-- Every new delivery bill starts as waiting for a rider.
create or replace function app.trg_delivery_status()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.order_type = 'delivery' and new.delivery_status is null then new.delivery_status := 'waiting'; end if;
  if new.order_type <> 'delivery' then new.delivery_status := null; new.rider_id := null; end if;
  return new;
end $function$;
create trigger trg_delivery_status before insert or update of order_type on public.orders
  for each row execute function app.trg_delivery_status();

create or replace function public.rider_save(p_id uuid, p_name text, p_phone text default null, p_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('order.create'); v_rest uuid := app.current_restaurant_id(); v_id uuid; v_name text := btrim(coalesce(p_name, ''));
begin
  if v_name = '' or length(v_name) > 60 then raise exception 'Enter the rider''s name.'; end if;
  if p_id is null then
    insert into public.riders (restaurant_id, branch_id, name, phone) values (v_rest, app.current_branch_id(), v_name, nullif(btrim(coalesce(p_phone, '')), ''))
    returning id into v_id;
  else
    update public.riders set name = v_name, phone = nullif(btrim(coalesce(p_phone, '')), ''), is_active = coalesce(p_active, true)
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'That rider was not found.'; end if;
  end if;
  return v_id;
end $function$;

-- Moves a delivery along: 'out' with a rider, 'delivered', 'returned' (food came back), or back to 'waiting'.
create or replace function public.delivery_update(p_order uuid, p_status text, p_rider uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('order.create'); o public.orders;
begin
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found or o.order_type <> 'delivery' then raise exception 'That is not a delivery bill.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if p_status not in ('waiting', 'out', 'delivered', 'returned') then raise exception 'Unknown delivery status.'; end if;
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

-- Delivery bills of this outlet that are not finished, plus those delivered or returned in the last 24 hours.
create or replace function public.deliveries_list()
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id, 'bill_number', o.bill_number, 'token_no', o.token_no, 'status', o.delivery_status,
           'rider_id', o.rider_id, 'rider', r.name, 'guest_name', o.guest_name, 'guest_phone', o.guest_phone,
           'address', o.delivery_address, 'total', o.grand_total,
           'due', case when o.payment_status in ('unpaid', 'partial') then o.grand_total - app.order_covered(o.id) else 0 end,
           'created_at', o.created_at, 'out_at', o.out_at, 'delivered_at', o.delivered_at) order by o.created_at), '[]'::jsonb)
    from public.orders o left join public.riders r on r.id = o.rider_id
   where o.restaurant_id = app.current_restaurant_id() and o.branch_id = app.current_branch_id()
     and app.allowed('order.create') and o.order_type = 'delivery' and o.status <> 'voided' and o.merged_into is null
     and (o.delivery_status in ('waiting', 'out') or o.created_at > now() - interval '24 hours')
$function$;

-- The rider hands over the cash: takes payment for every delivered, unpaid bill of that rider.
create or replace function public.rider_settle(p_rider uuid, p_method uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id();
  v_method uuid; o record; v_due numeric; v_total numeric := 0; v_n int := 0;
begin
  if not exists (select 1 from public.riders where id = p_rider and restaurant_id = v_rest) then raise exception 'That rider was not found.'; end if;
  v_method := coalesce(p_method, (select id from public.payment_methods where restaurant_id = v_rest and kind = 'cash' and is_active order by display_order limit 1));
  if v_method is null then raise exception 'Add a cash payment method first.'; end if;
  for o in select id from public.orders
            where restaurant_id = v_rest and branch_id = app.current_branch_id() and rider_id = p_rider and delivery_status = 'delivered'
              and status <> 'voided' and payment_status in ('unpaid', 'partial') order by created_at for update loop
    v_due := (select grand_total from public.orders where id = o.id) - app.order_covered(o.id);
    if v_due > 0 then
      perform public.pay_order(o.id, v_method, v_due, v_due, 'Rider ' || (select name from public.riders where id = p_rider), null);
      v_total := v_total + v_due; v_n := v_n + 1;
    end if;
  end loop;
  if v_n = 0 then raise exception 'This rider has no delivered bills waiting for payment.'; end if;
  return jsonb_build_object('bills', v_n, 'amount', v_total);
end $function$;

revoke all on function public.rider_save(uuid, text, text, boolean), public.delivery_update(uuid, text, uuid), public.deliveries_list(), public.rider_settle(uuid, uuid) from public, anon;
grant execute on function public.rider_save(uuid, text, text, boolean), public.delivery_update(uuid, text, uuid), public.deliveries_list(), public.rider_settle(uuid, uuid) to authenticated, service_role;

-- Delivery bills from before this change: paid ones count as delivered, the rest wait for a rider.
select set_config('app.day_ok', 'on', true);
update public.orders set delivery_status = case when status = 'completed' then 'delivered' else 'waiting' end
 where order_type = 'delivery' and delivery_status is null;
select set_config('app.day_ok', '', true);

-- Erasing a test restaurant also removes its riders.
CREATE OR REPLACE FUNCTION app.erase_groups()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('customer_ledger', 'batch_movements', 'pre_order_payments', 'pre_orders', 'order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('product_batches', 'price_rules', 'product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'branch_prices',
            'products', 'categories', 'brands', 'dining_tables', 'floors', 'customers', 'riders'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$;
