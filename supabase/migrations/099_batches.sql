-- 099: Batches and expiry for ready-made goods (bakery, sweets, desserts).
--
-- A dish can be "tracked in batches": the kitchen records each batch made (how many, made on, best before).
-- Each sale takes from the oldest batch that has not expired; a cancelled or voided sale puts it back.
-- Expired leftovers are written off as wastage. The billing screen can show how many are left today.
-- Selling more than the batches hold is allowed (the bill is never blocked); the shortfall shows on the Batches screen.

alter table public.products add column track_batches boolean not null default false;

create table public.product_batches (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  product_id uuid not null,
  made_on date not null default current_date,
  expires_on date not null,
  qty_made numeric(12,3) not null check (qty_made > 0),
  qty_left numeric(12,3) not null check (qty_left >= 0),
  wasted numeric(12,3) not null default 0 check (wasted >= 0),
  note text check (note is null or length(note) <= 200),
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id) on delete restrict,
  foreign key (restaurant_id, product_id) references public.products(restaurant_id, id) on delete restrict,
  check (expires_on >= made_on)
);
create index idx_batches_open on public.product_batches (branch_id, product_id, expires_on) where qty_left > 0;
alter table public.product_batches enable row level security;
revoke all on public.product_batches from anon, authenticated;

create table public.batch_movements (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  batch_id uuid not null references public.product_batches(id) on delete cascade,
  order_item_id uuid references public.order_items(id) on delete cascade,
  qty numeric(12,3) not null,          -- negative = taken by a sale, positive = put back
  created_at timestamptz not null default now()
);
create index idx_batch_moves_item on public.batch_movements (order_item_id);
alter table public.batch_movements enable row level security;
revoke all on public.batch_movements from anon, authenticated;

-- Take a sale from the oldest unexpired batches; put back cancelled quantities to the batches they came from.
create or replace function app.batch_on_item()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_branch uuid; v_need numeric; b record; v_take numeric; m record; v_back numeric;
begin
  if not exists (select 1 from public.products where id = new.product_id and track_batches) then return new; end if;
  select branch_id into v_branch from public.orders where id = new.order_id;
  if tg_op = 'INSERT' then
    v_need := new.quantity;
    for b in select id, qty_left from public.product_batches
              where branch_id = v_branch and product_id = new.product_id and qty_left > 0 and expires_on >= current_date
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
end $function$;
revoke all on function app.batch_on_item() from public, anon, authenticated;
create trigger trg_batch_on_item after insert or update of quantity, cancelled_qty, cancelled_at on public.order_items
  for each row execute function app.batch_on_item();

-- Record a batch made (needs stock or menu rights).
create or replace function public.batch_add(p_product uuid, p_qty numeric, p_expires_on date, p_made_on date default null, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('order.create'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v uuid;
  v_made date := coalesce(p_made_on, current_date);
begin
  if not exists (select 1 from public.products where id = p_product and restaurant_id = v_rest and deleted_at is null and track_batches) then
    raise exception 'That dish is not tracked in batches. Tick "Track in batches" on the dish first.';
  end if;
  if coalesce(p_qty, 0) <= 0 or p_qty > 100000 then raise exception 'Enter how many were made.'; end if;
  if p_expires_on is null or p_expires_on < v_made then raise exception 'Best before must be on or after the day it was made.'; end if;
  if v_made > current_date then raise exception 'The day made cannot be in the future.'; end if;
  insert into public.product_batches (restaurant_id, branch_id, product_id, made_on, expires_on, qty_made, qty_left, note, created_by)
  values (v_rest, v_branch, p_product, v_made, p_expires_on, round(p_qty, 3), round(p_qty, 3), nullif(left(btrim(coalesce(p_note, '')), 200), ''), v_user)
  returning id into v;
  return v;
end $function$;

-- Write off what is left of a batch (expired or spoilt).
create or replace function public.batch_write_off(p_batch uuid)
returns numeric
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('order.create'); b public.product_batches;
begin
  select * into b from public.product_batches where id = p_batch and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Batch not found.'; end if;
  if b.qty_left <= 0 then return 0; end if;
  update public.product_batches set wasted = wasted + qty_left, qty_left = 0 where id = b.id;
  perform app.audit('batch.write_off', 'product_batches', b.id, jsonb_build_object('qty', b.qty_left), null);
  return b.qty_left;
end $function$;

-- The Batches screen: open batches of this outlet (expired first), today's sales of tracked dishes, and shortfalls.
create or replace function public.batches_list()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  return jsonb_build_object(
    'batches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'product_id', b.product_id, 'product', p.name, 'made_on', b.made_on,
                 'expires_on', b.expires_on, 'qty_made', b.qty_made, 'qty_left', b.qty_left, 'wasted', b.wasted, 'note', b.note,
                 'expired', b.expires_on < current_date) order by b.expires_on, p.name)
        from public.product_batches b join public.products p on p.id = b.product_id
       where b.branch_id = v_branch and (b.qty_left > 0 or b.created_at > now() - interval '2 days')), '[]'::jsonb),
    'dishes', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name,
                 'left', coalesce((select sum(qty_left) from public.product_batches b where b.product_id = p.id and b.branch_id = v_branch and b.expires_on >= current_date), 0),
                 -- sold without a batch to take from (more sold than recorded as made)
                 'short', coalesce((select sum(oi.quantity - coalesce(oi.cancelled_qty, 0)) from public.order_items oi join public.orders o on o.id = oi.order_id
                                     where oi.product_id = p.id and o.branch_id = v_branch and oi.created_at > current_date and oi.cancelled_at is null), 0)
                          - coalesce((select -sum(bm.qty) from public.batch_movements bm join public.order_items oi on oi.id = bm.order_item_id join public.orders o on o.id = oi.order_id
                                     where oi.product_id = p.id and o.branch_id = v_branch and oi.created_at > current_date), 0))
             order by p.name)
        from public.products p where p.restaurant_id = v_rest and p.track_batches and p.deleted_at is null), '[]'::jsonb));
end $function$;

-- How many of each tracked dish are left today at this outlet (billing screen).
create or replace function public.batch_stock()
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_object_agg(p.id, coalesce((select sum(qty_left) from public.product_batches b
           where b.product_id = p.id and b.branch_id = app.current_branch_id() and b.expires_on >= current_date), 0)), '{}'::jsonb)
    from public.products p where p.restaurant_id = app.current_restaurant_id() and p.track_batches and p.deleted_at is null
$function$;

revoke all on function public.batch_add(uuid, numeric, date, date, text), public.batch_write_off(uuid), public.batches_list(), public.batch_stock() from public, anon;
grant execute on function public.batch_add(uuid, numeric, date, date, text), public.batch_write_off(uuid), public.batches_list(), public.batch_stock() to authenticated, service_role;

-- Erasing a test restaurant also removes its batches.
CREATE OR REPLACE FUNCTION app.erase_groups()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('batch_movements', 'pre_order_payments', 'pre_orders', 'order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('product_batches', 'price_rules', 'product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'branch_prices',
            'products', 'categories', 'dining_tables', 'floors', 'customers'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$;
