-- 125: Kitchen order tickets (KOT): a waiter can cancel or change what was sent to the kitchen,
--      the kitchen sees it at once (red CANCELLED / amber CHANGED until it taps "Seen"),
--      and the waiter who took the order is alerted when the kitchen marks the food Ready.
--
-- Cancelling a KOT or one of its items needs a reason, not a manager PIN (Founder's decision, 20 Oct 2026).
-- The reason, the person and the time are kept in the audit log. A bill that is already paid still needs a refund,
-- and the last thing on a bill cannot be cancelled here (void the bill instead): both rules are the same as for
-- "Cancel an item" on the bill screen, which stays manager-only and is not changed.

alter table public.kitchen_ticket_items
  add column if not exists change_text text,
  add column if not exists changed_at timestamptz,
  add column if not exists cancel_reason text;

alter table public.kitchen_tickets
  add column if not exists cancel_reason text,
  add column if not exists cancelled_at timestamptz,
  add column if not exists changed_at timestamptz,
  add column if not exists kitchen_seen_at timestamptz,
  add column if not exists waiter_seen_at timestamptz;

-- A ticket that goes back to Ready (after being moved back by mistake) alerts the waiter again.
create or replace function app.trg_ticket_ready_alert()
returns trigger language plpgsql set search_path to 'public', 'pg_temp'
as $$
begin
  if new.status = 'ready' and old.status is distinct from 'ready' then new.waiter_seen_at := null; end if;
  return new;
end $$;
revoke all on function app.trg_ticket_ready_alert() from public, anon, authenticated;
drop trigger if exists trg_ticket_ready_alert on public.kitchen_tickets;
create trigger trg_ticket_ready_alert before update of status on public.kitchen_tickets
  for each row execute function app.trg_ticket_ready_alert();

-- ------------------------------------------------------------------ shared cancel (no permission check: callers check)
create or replace function app.kot_cancel_line(p_order_item_id uuid, p_qty numeric, p_reason text, p_user uuid)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  it public.order_items%rowtype; o public.orders%rowtype; v_q numeric; v_c jsonb; v_before numeric(14,2);
  v_reason text := left(trim(coalesce(p_reason, '')), 200); v_old numeric;
begin
  if length(v_reason) < 3 then raise exception 'Write a short reason for the change.'; end if;
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
  v_before := o.grand_total; v_old := it.quantity;

  if v_q = it.quantity then
    if (select count(*) from public.order_items where order_id = o.id and cancelled_at is null) = 1 then
      raise exception '% is the only item on bill %. Void the bill instead.', it.product_name, o.bill_number;
    end if;
    update public.order_items set cancelled_at = now(), cancelled_by = p_user, cancelled_qty = cancelled_qty + v_q,
           cancel_reason = v_reason where id = it.id;
    update public.kitchen_ticket_items set status = 'cancelled', cancel_reason = v_reason, changed_at = now(),
           change_text = 'CANCELLED: ' || v_reason
     where order_item_id = it.id and status in ('new', 'preparing', 'ready');
  else
    update public.order_items set quantity = quantity - v_q, cancelled_qty = cancelled_qty + v_q, cancel_reason = v_reason where id = it.id;
    update public.kitchen_ticket_items set quantity = quantity - v_q, changed_at = now(),
           change_text = 'Quantity ' || trim_scale(v_old) || ' → ' || trim_scale(v_old - v_q) || ' (' || v_reason || ')'
     where order_item_id = it.id and status in ('new', 'preparing', 'ready') and quantity > v_q;
  end if;
  -- Tell the kitchen: every ticket of this bill that was touched is shown again until it taps "Seen".
  update public.kitchen_tickets kt set changed_at = now(), kitchen_seen_at = null
   where kt.order_id = o.id and kt.status in ('new', 'preparing', 'ready')
     and exists (select 1 from public.kitchen_ticket_items k where k.kitchen_ticket_id = kt.id and k.order_item_id = it.id);
  update public.kitchen_tickets kt set status = 'cancelled', cancelled_at = coalesce(kt.cancelled_at, now()),
         cancel_reason = coalesce(kt.cancel_reason, v_reason), kitchen_seen_at = null
   where kt.order_id = o.id and kt.status in ('new', 'preparing', 'ready')
     and not exists (select 1 from public.kitchen_ticket_items k where k.kitchen_ticket_id = kt.id and k.status <> 'cancelled');

  v_c := app.recalc_order(o.id);
  if (v_c->>'grand_total')::numeric < app.order_covered(o.id) then
    raise exception 'Bill % already has % paid, which is more than the new total. Refund after payment instead.',
      o.bill_number, app.order_covered(o.id);
  end if;
  if app.order_covered(o.id) > 0 and (v_c->>'grand_total')::numeric = app.order_covered(o.id) then
    update public.orders set payment_status = 'paid' where id = o.id;
  end if;

  perform app.audit('order.cancel_item', 'order_items', it.id,
    jsonb_build_object('bill_number', o.bill_number, 'item', it.product_name, 'qty', v_q, 'reason', v_reason,
                       'grand_total', (v_c->>'grand_total')::numeric, 'via', 'kot'),
    jsonb_build_object('grand_total', v_before, 'qty', v_old));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'grand_total', (v_c->>'grand_total')::numeric);
end $$;
revoke all on function app.kot_cancel_line(uuid, numeric, text, uuid) from public, anon, authenticated;

-- ------------------------------------------------------------------ cancel one item (or part of it) of a KOT
create or replace function public.kot_cancel_item(p_ticket_item_id uuid, p_qty numeric, p_reason text)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  ti public.kitchen_ticket_items%rowtype; kt public.kitchen_tickets%rowtype; v_q numeric;
begin
  select * into ti from public.kitchen_ticket_items where id = p_ticket_item_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That kitchen item was not found.'; end if;
  select * into kt from public.kitchen_tickets where id = ti.kitchen_ticket_id;
  if ti.status = 'cancelled' then raise exception '% is already cancelled.', ti.product_name; end if;
  if kt.status not in ('new', 'preparing', 'ready') then
    raise exception 'This KOT is already served. Ask a manager to cancel the item on the bill.';
  end if;
  v_q := coalesce(p_qty, ti.quantity);
  if v_q <= 0 or v_q > ti.quantity then
    raise exception 'Enter a quantity between 1 and % for %.', trim_scale(ti.quantity), ti.product_name;
  end if;
  return app.kot_cancel_line(ti.order_item_id, v_q, p_reason, v_user);
end $$;

-- ------------------------------------------------------------------ cancel a whole KOT
create or replace function public.kot_cancel(p_ticket_id uuid, p_reason text)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  kt public.kitchen_tickets%rowtype; r record; v_n int := 0; v_out jsonb := '{}'::jsonb; v_reason text := left(trim(coalesce(p_reason, '')), 200);
begin
  if length(v_reason) < 3 then raise exception 'Write a short reason for cancelling the KOT.'; end if;
  select * into kt from public.kitchen_tickets where id = p_ticket_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That KOT was not found.'; end if;
  if kt.status = 'cancelled' then raise exception 'KOT % is already cancelled.', kt.ticket_number; end if;
  if kt.status not in ('new', 'preparing', 'ready') then
    raise exception 'KOT % is already served. Ask a manager to cancel items on the bill.', kt.ticket_number;
  end if;
  for r in select * from public.kitchen_ticket_items where kitchen_ticket_id = kt.id and status <> 'cancelled' order by id loop
    v_out := app.kot_cancel_line(r.order_item_id, r.quantity, v_reason, v_user);
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'KOT % has nothing left to cancel.', kt.ticket_number; end if;
  update public.kitchen_tickets set status = 'cancelled', cancelled_at = coalesce(cancelled_at, now()),
         cancel_reason = v_reason, changed_at = now(), kitchen_seen_at = null where id = kt.id;
  perform app.audit('kot.cancel', 'kitchen_tickets', kt.id,
    jsonb_build_object('ticket', kt.ticket_number, 'items', v_n, 'reason', v_reason), jsonb_build_object('status', kt.status));
  return v_out || jsonb_build_object('ticket', kt.ticket_number, 'items_cancelled', v_n);
end $$;

-- ------------------------------------------------------------------ change quantity and/or note of a KOT item
-- Fewer: the difference is cancelled (a reason is needed). More: the extra portion goes to the kitchen as a new KOT.
create or replace function public.kot_modify_item(p_ticket_item_id uuid, p_qty numeric, p_note text, p_reason text default null)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  ti public.kitchen_ticket_items%rowtype; kt public.kitchen_tickets%rowtype; oi public.order_items%rowtype;
  v_note text; v_changed boolean := false; v_more numeric := 0; v_out jsonb := '{}'::jsonb;
begin
  select * into ti from public.kitchen_ticket_items where id = p_ticket_item_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That kitchen item was not found.'; end if;
  select * into kt from public.kitchen_tickets where id = ti.kitchen_ticket_id;
  select * into oi from public.order_items where id = ti.order_item_id;
  if ti.status = 'cancelled' or oi.cancelled_at is not null then raise exception '% is cancelled.', ti.product_name; end if;
  if kt.status not in ('new', 'preparing') then
    raise exception 'KOT % is already % in the kitchen, so it cannot be changed. Send a new item instead.', kt.ticket_number,
      case kt.status when 'ready' then 'ready' else 'served' end;
  end if;

  if p_qty is not null and p_qty <> ti.quantity then
    if p_qty <= 0 then raise exception 'To remove the item, use Cancel.'; end if;
    if p_qty < ti.quantity then
      v_out := app.kot_cancel_line(ti.order_item_id, ti.quantity - p_qty, p_reason, v_user);
    else
      if oi.options_text is not null then
        raise exception '% has options. Add the extra portion as a new item.', ti.product_name;
      end if;
      v_more := p_qty - ti.quantity;
      v_out := public.add_order_items(oi.order_id, jsonb_build_array(jsonb_build_object(
        'product_id', oi.product_id, 'qty', v_more, 'note', coalesce(oi.kitchen_note, ''), 'options', '[]'::jsonb, 'hold', false)));
    end if;
    v_changed := true;
  end if;

  if p_note is not null and nullif(trim(p_note), '') is distinct from nullif(trim(coalesce(oi.kitchen_note, '')), '') then
    v_note := nullif(left(trim(p_note), 200), '');
    update public.order_items set kitchen_note = v_note where id = oi.id;
    update public.kitchen_ticket_items set note = v_note, changed_at = now(),
           change_text = case when change_text is null or v_more > 0 then 'Note changed' else change_text || ' · Note changed' end
     where id = ti.id;
    v_changed := true;
  end if;

  if not v_changed then raise exception 'Nothing was changed.'; end if;
  update public.kitchen_tickets set changed_at = now(), kitchen_seen_at = null where id = kt.id and status in ('new', 'preparing');
  perform app.audit('kot.modify', 'kitchen_tickets', kt.id,
    jsonb_build_object('ticket', kt.ticket_number, 'item', ti.product_name, 'qty_from', ti.quantity,
                       'qty_to', coalesce(p_qty, ti.quantity), 'note', v_note, 'reason', nullif(trim(coalesce(p_reason, '')), '')),
    jsonb_build_object('qty', ti.quantity, 'note', ti.note));
  return v_out || jsonb_build_object('ticket', kt.ticket_number, 'item', ti.product_name);
end $$;

-- ------------------------------------------------------------------ the kitchen taps "Seen" on a cancelled / changed ticket
create or replace function public.kot_kitchen_seen(p_ticket_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  update public.kitchen_tickets set kitchen_seen_at = now()
   where id = p_ticket_id and restaurant_id = app.current_restaurant_id() and kitchen_seen_at is null;
end $$;

-- ------------------------------------------------------------------ waiter alerts: food ready for my tables
create or replace function public.waiter_ready_alerts()
 returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid := app.current_user_id(); v_out jsonb;
begin
  if app.current_restaurant_id() is null or v_me is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x.j order by x.ready_at), '[]'::jsonb) into v_out from (
    select kt.ready_at, jsonb_build_object(
             'ticket_id', kt.id, 'ticket', kt.ticket_number, 'station', kt.station, 'ready_at', kt.ready_at,
             'order_id', o.id, 'bill', o.bill_number, 'table', dt.table_number,
             'items', coalesce((select jsonb_agg(jsonb_build_object('name', ti.product_name, 'qty', ti.quantity) order by ti.id)
                                  from public.kitchen_ticket_items ti where ti.kitchen_ticket_id = kt.id and ti.status <> 'cancelled'), '[]'::jsonb)) as j
      from public.kitchen_tickets kt
      join public.orders o on o.id = kt.order_id
      left join public.dining_tables dt on dt.id = o.dining_table_id
     where kt.restaurant_id = app.current_restaurant_id()
       and kt.status = 'ready' and kt.waiter_seen_at is null
       and kt.ready_at > now() - interval '60 minutes'
       and o.status <> 'voided' and o.dining_table_id is not null
       and coalesce(o.waiter_id, o.cashier_id) = v_me
     order by kt.ready_at limit 20) x;
  return v_out;
end $$;

create or replace function public.waiter_ready_seen(p_ticket_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid := app.current_user_id();
begin
  if app.current_restaurant_id() is null or v_me is null then raise exception 'You are not signed in to a restaurant.'; end if;
  update public.kitchen_tickets kt set waiter_seen_at = now()
   where kt.id = p_ticket_id and kt.restaurant_id = app.current_restaurant_id() and kt.waiter_seen_at is null
     and exists (select 1 from public.orders o where o.id = kt.order_id and coalesce(o.waiter_id, o.cashier_id) = v_me);
end $$;

revoke all on function public.kot_cancel_item(uuid, numeric, text), public.kot_cancel(uuid, text),
  public.kot_modify_item(uuid, numeric, text, text), public.kot_kitchen_seen(uuid),
  public.waiter_ready_alerts(), public.waiter_ready_seen(uuid) from public, anon;
grant execute on function public.kot_cancel_item(uuid, numeric, text), public.kot_cancel(uuid, text),
  public.kot_modify_item(uuid, numeric, text, text), public.kot_kitchen_seen(uuid),
  public.waiter_ready_alerts(), public.waiter_ready_seen(uuid) to authenticated;
