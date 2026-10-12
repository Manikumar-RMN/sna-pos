-- 098: Pre-orders with advance (a custom cake for Saturday, 50% paid now; a party order for tomorrow).
--
-- A pre-order is not a bill yet, so it never blocks closing a day. It keeps the guest, the due date and time, the
-- dishes and a note (e.g. the message on the cake). Advances are money received: cash goes into the drawer as a
-- cash-in for the shift (like a gift card sale). When the guest collects, "Bill now" makes the bill from the
-- pre-order and pays it first with the advance (a payment of the kind "advance"); the cashier takes the balance as usual.
-- Cancelling refunds the advance (cash goes out of the drawer).

alter table public.payment_methods drop constraint payment_methods_kind_check;
alter table public.payment_methods add constraint payment_methods_kind_check
  check (kind = any (array['cash', 'card', 'wallet', 'bank_transfer', 'upi', 'other', 'gift_card', 'loyalty', 'advance']));

create table public.pre_orders (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  number integer not null,
  guest_name text not null check (length(btrim(guest_name)) between 1 and 80),
  guest_phone text,
  due_at timestamptz not null,
  order_type text not null default 'takeaway' check (order_type in ('takeaway', 'delivery', 'dine_in')),
  address text check (address is null or length(address) <= 300),
  note text check (note is null or length(note) <= 500),
  items jsonb not null check (jsonb_typeof(items) = 'array' and jsonb_array_length(items) between 1 and 100),
  estimate numeric(14,2) not null default 0,
  status text not null default 'booked' check (status in ('booked', 'billed', 'cancelled')),
  order_id uuid references public.orders(id) on delete restrict,
  cancel_reason text,
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id) on delete restrict,
  unique (restaurant_id, number)
);
create index idx_pre_orders_due on public.pre_orders (branch_id, due_at) where status = 'booked';
alter table public.pre_orders enable row level security;
revoke all on public.pre_orders from anon, authenticated;

create table public.pre_order_payments (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  pre_order_id uuid not null references public.pre_orders(id) on delete restrict,
  kind text not null check (kind in ('advance', 'refund')),
  payment_method_id uuid not null references public.payment_methods(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  reference text,
  shift_id uuid references public.shifts(id) on delete set null,
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index idx_pre_order_payments on public.pre_order_payments (pre_order_id);
alter table public.pre_order_payments enable row level security;
revoke all on public.pre_order_payments from anon, authenticated;

-- An advance or refund, once recorded, is never changed or removed.
create trigger trg_no_delete_pre_order_payments before delete or update on public.pre_order_payments
  for each row execute function app.block_delete();

-- Advance still held for a pre-order.
create or replace function app.pre_order_held(p_id uuid)
returns numeric
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(sum(case when kind = 'advance' then amount else -amount end), 0)::numeric(14,2)
    from public.pre_order_payments where pre_order_id = p_id
$function$;

-- The restaurant's hidden "Pre-order advance" payment method (made the first time it is needed; never offered at the counter).
create or replace function app.advance_method(p_rest uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v uuid;
begin
  select id into v from public.payment_methods where restaurant_id = p_rest and kind = 'advance' order by display_order limit 1;
  if v is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order)
    values (p_rest, 'Pre-order advance', 'advance', false, false, 99) returning id into v;
  end if;
  return v;
end $function$;

-- An advance payment may be written only by "Bill now" on a pre-order; no payment can be changed to or from an advance.
CREATE OR REPLACE FUNCTION app.guard_redeem_payment()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k_new text; k_old text;
begin
  select kind into k_new from public.payment_methods where id = new.payment_method_id;
  if tg_op = 'INSERT' then
    if k_new in ('gift_card', 'loyalty') and coalesce(current_setting('app.redeem', true), '') <> 'on' then
      raise exception 'Use "Redeem gift card" or "Redeem points" on the bill for this payment.';
    end if;
    if k_new = 'advance' and coalesce(current_setting('app.advance', true), '') <> 'on' then
      raise exception 'A pre-order advance is applied with "Bill now" on the pre-order.';
    end if;
  elsif new.payment_method_id is distinct from old.payment_method_id then
    select kind into k_old from public.payment_methods where id = old.payment_method_id;
    if k_new in ('gift_card', 'loyalty', 'advance') or k_old in ('gift_card', 'loyalty', 'advance') then
      raise exception 'A gift card, points or pre-order advance payment cannot be changed to another method, or the other way round.';
    end if;
  end if;
  return new;
end $function$;

-- Create or change a pre-order (while it is booked). The dishes are checked like a bill; estimate = today's total.
create or replace function public.pre_order_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_id uuid := nullif(p->>'id', '')::uuid; v_due timestamptz; v_in jsonb; v_c jsonb; v_est numeric; r public.pre_orders; v_no int;
  v_type text := coalesce(nullif(p->>'order_type', ''), 'takeaway');
begin
  if v_branch is null then raise exception 'No outlet chosen.'; end if;
  if coalesce(btrim(p->>'guest_name'), '') = '' then raise exception 'Enter the guest''s name.'; end if;
  begin v_due := (p->>'due_at')::timestamptz; exception when others then raise exception 'Enter when the order is due.'; end;
  if v_due is null then raise exception 'Enter when the order is due.'; end if;
  if v_id is null and v_due < now() then raise exception 'The due time is in the past.'; end if;
  if v_due > now() + interval '180 days' then raise exception 'A pre-order can be at most 180 days ahead.'; end if;
  if v_type = 'delivery' and coalesce(btrim(p->>'address'), '') = '' then raise exception 'Enter the delivery address.'; end if;
  -- the same checks as a bill: dishes on the menu, options, sizes
  v_in := app.bill_input(v_rest, v_branch, p->'items', 0, null, null);
  v_c := app.calc_bill(v_in->'calc');
  v_est := coalesce((v_c->>'grand_total')::numeric, 0);
  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('pre_order_no:' || v_rest::text));
    select coalesce(max(number), 0) + 1 into v_no from public.pre_orders where restaurant_id = v_rest;
    insert into public.pre_orders (restaurant_id, branch_id, number, guest_name, guest_phone, due_at, order_type, address, note, items, estimate, created_by)
    values (v_rest, v_branch, v_no, btrim(p->>'guest_name'), app.clean_phone(p->>'guest_phone'), v_due, v_type,
            nullif(btrim(coalesce(p->>'address', '')), ''), nullif(btrim(coalesce(p->>'note', '')), ''), p->'items', v_est, v_user)
    returning * into r;
  else
    update public.pre_orders set guest_name = btrim(p->>'guest_name'), guest_phone = app.clean_phone(p->>'guest_phone'), due_at = v_due,
           order_type = v_type, address = nullif(btrim(coalesce(p->>'address', '')), ''), note = nullif(btrim(coalesce(p->>'note', '')), ''),
           items = p->'items', estimate = v_est, updated_at = now()
     where id = v_id and restaurant_id = v_rest and status = 'booked' returning * into r;
    if not found then raise exception 'That pre-order is not open for changes.'; end if;
  end if;
  return jsonb_build_object('id', r.id, 'number', r.number, 'estimate', r.estimate);
end $function$;

-- Take an advance (or part of it).
create or replace function public.pre_order_advance(p_id uuid, p_method uuid, p_amount numeric, p_reference text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('payment.take');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  r public.pre_orders; v_kind text; v_drawer boolean; v_shift uuid; v_amt numeric(14,2) := round(coalesce(p_amount, 0), 2);
begin
  select * into r from public.pre_orders where id = p_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Pre-order not found.'; end if;
  if r.status <> 'booked' then raise exception 'Pre-order % is already %.', r.number, r.status; end if;
  if v_amt <= 0 then raise exception 'Enter the advance amount.'; end if;
  select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_method and restaurant_id = v_rest and is_active;
  if not found or v_kind in ('gift_card', 'loyalty', 'advance') then raise exception 'Choose how the guest paid the advance.'; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift before taking an advance.'; end if;
  insert into public.pre_order_payments (restaurant_id, pre_order_id, kind, payment_method_id, amount, reference, shift_id, created_by)
  values (v_rest, r.id, 'advance', p_method, v_amt, nullif(left(btrim(coalesce(p_reference, '')), 60), ''), v_shift, v_user);
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', v_amt, 'Pre-order PO-' || r.number || ' advance', v_user);
  end if;
  perform app.audit('preorder.advance', 'pre_orders', r.id, jsonb_build_object('number', r.number, 'amount', v_amt, 'method', v_kind), null);
  return jsonb_build_object('held', app.pre_order_held(r.id));
end $function$;

-- Cancel a booked pre-order and refund what was paid (by the method chosen).
create or replace function public.pre_order_cancel(p_id uuid, p_reason text, p_refund_method uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  r public.pre_orders; v_held numeric(14,2); v_kind text; v_drawer boolean; v_shift uuid;
begin
  select * into r from public.pre_orders where id = p_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Pre-order not found.'; end if;
  if r.status <> 'booked' then raise exception 'Pre-order % is already %.', r.number, r.status; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Enter why the pre-order is cancelled.'; end if;
  v_held := app.pre_order_held(r.id);
  if v_held > 0 then
    perform app.require_permission('payment.take');
    select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_refund_method and restaurant_id = v_rest and is_active;
    if not found or v_kind in ('gift_card', 'loyalty', 'advance') then raise exception 'Choose how the advance of % is given back.', v_held; end if;
    select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
    if v_shift is null then raise exception 'Open a shift before refunding an advance.'; end if;
    insert into public.pre_order_payments (restaurant_id, pre_order_id, kind, payment_method_id, amount, shift_id, created_by)
    values (v_rest, r.id, 'refund', p_refund_method, v_held, v_shift, v_user);
    if v_kind = 'cash' or coalesce(v_drawer, false) then
      insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
      values (v_rest, v_shift, 'out', v_held, 'Pre-order PO-' || r.number || ' advance refunded', v_user);
    end if;
  end if;
  update public.pre_orders set status = 'cancelled', cancel_reason = left(btrim(p_reason), 200), updated_at = now() where id = r.id;
  perform app.audit('preorder.cancel', 'pre_orders', r.id, jsonb_build_object('number', r.number, 'refund', v_held, 'reason', p_reason), null);
  return jsonb_build_object('refunded', v_held);
end $function$;

-- The guest collects: make the bill from the pre-order and pay it first with the advance held.
create or replace function public.pre_order_bill(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id();
  r public.pre_orders; v_res jsonb; o public.orders; v_held numeric(14,2); v_apply numeric(14,2); v_shift uuid; v_method uuid;
begin
  select * into r from public.pre_orders where id = p_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Pre-order not found.'; end if;
  if r.status <> 'booked' then raise exception 'Pre-order % is already %.', r.number, r.status; end if;
  v_res := public.create_order(r.items, r.order_type, null::uuid,
            p_extra := jsonb_strip_nulls(jsonb_build_object('guest_name', r.guest_name, 'guest_phone', r.guest_phone, 'address', r.address)));
  select * into o from public.orders where id = (v_res->>'order_id')::uuid;
  v_held := app.pre_order_held(r.id);
  v_apply := least(v_held, o.grand_total);
  if v_apply > 0 then
    v_method := app.advance_method(v_rest);
    select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
    perform set_config('app.advance', 'on', true);
    insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, status, received_by, client_created_at, reference_no)
    values (gen_random_uuid(), o.restaurant_id, o.id, v_method, v_apply, o.currency_code, 'captured', v_user, now(), 'PO-' || r.number);
    perform set_config('app.advance', 'off', true);
    update public.orders set paid_total = paid_total + v_apply,
           payment_status = case when v_apply >= o.grand_total then 'paid' else 'partial' end,
           shift_id = coalesce(o.shift_id, v_shift)
     where id = o.id;
  end if;
  update public.pre_orders set status = 'billed', order_id = o.id, updated_at = now() where id = r.id;
  perform app.audit('preorder.bill', 'pre_orders', r.id, jsonb_build_object('number', r.number, 'bill', o.bill_number, 'advance_applied', v_apply), null);
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'total', o.grand_total, 'advance_applied', v_apply,
                            'balance', o.grand_total - v_apply, 'advance_left_over', v_held - v_apply);
end $function$;

-- The Pre-orders screen.
create or replace function public.pre_orders_list(p_status text default 'booked')
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'number', r.number, 'guest_name', r.guest_name, 'guest_phone', r.guest_phone, 'due_at', r.due_at,
             'order_type', r.order_type, 'address', r.address, 'note', r.note, 'items', r.items, 'estimate', r.estimate,
             'status', r.status, 'order_id', r.order_id, 'bill_number', (select bill_number from public.orders where id = r.order_id),
             'advance', app.pre_order_held(r.id), 'created_at', r.created_at,
             'lines', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'qty', (x->>'qty')::numeric, 'note', x->>'note',
                         'options', (select string_agg(mi.name, ', ') from jsonb_array_elements_text(coalesce(x->'options', '[]')) oid
                                       join public.modifier_items mi on mi.id = oid::uuid))), '[]'::jsonb)
                         from jsonb_array_elements(r.items) x join public.products p on p.id = (x->>'product_id')::uuid))
             order by r.due_at)
      from public.pre_orders r
     where r.restaurant_id = v_rest and r.branch_id = app.current_branch_id()
       and (p_status = 'all' or r.status = p_status)
       and (p_status = 'booked' or r.created_at > now() - interval '60 days')), '[]'::jsonb);
end $function$;

revoke all on function app.pre_order_held(uuid), app.advance_method(uuid) from public, anon, authenticated;
revoke all on function public.pre_order_save(jsonb), public.pre_order_advance(uuid, uuid, numeric, text), public.pre_order_cancel(uuid, text, uuid),
  public.pre_order_bill(uuid), public.pre_orders_list(text) from public, anon;
grant execute on function public.pre_order_save(jsonb), public.pre_order_advance(uuid, uuid, numeric, text), public.pre_order_cancel(uuid, text, uuid),
  public.pre_order_bill(uuid), public.pre_orders_list(text) to authenticated, service_role;

-- Erasing a test restaurant (SNA Console) also removes its pre-orders and its happy-hour offers.
CREATE OR REPLACE FUNCTION app.erase_groups()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('pre_order_payments', 'pre_orders', 'order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('price_rules', 'product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'branch_prices',
            'products', 'categories', 'dining_tables', 'floors', 'customers'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$;
