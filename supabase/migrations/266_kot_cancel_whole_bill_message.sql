-- Cancelling a KOT that holds every item on the bill used to fail item by item: the last line raised
-- "<item> is the only item on bill <no>", the whole transaction rolled back and nothing was cancelled,
-- so the cashier read a message about one dish that made no sense. Say it plainly, before anything is touched.
create or replace function public.kot_cancel(p_ticket_id uuid, p_reason text)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  kt public.kitchen_tickets%rowtype; r record; v_n int := 0; v_out jsonb := '{}'::jsonb; v_reason text := left(trim(coalesce(p_reason, '')), 200);
  v_bill text;
begin
  if length(v_reason) < 3 then raise exception 'Write a short reason for cancelling the KOT.'; end if;
  select * into kt from public.kitchen_tickets where id = p_ticket_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That KOT was not found.'; end if;
  if kt.status = 'cancelled' then raise exception 'KOT % is already cancelled.', kt.ticket_number; end if;
  if kt.status not in ('new', 'preparing', 'ready') then
    raise exception 'KOT % is already served. Ask a manager to cancel items on the bill.', kt.ticket_number;
  end if;

  -- Would the bill be left with nothing? Then the bill has to be voided, not the KOT cancelled.
  if not exists (
        select 1 from public.order_items oi
         where oi.order_id = kt.order_id and oi.cancelled_at is null
           and not exists (
                 select 1 from public.kitchen_ticket_items ki
                  where ki.kitchen_ticket_id = kt.id and ki.status <> 'cancelled'
                    and ki.order_item_id = oi.id and ki.quantity >= oi.quantity)
      ) then
    select bill_number into v_bill from public.orders where id = kt.order_id;
    raise exception 'KOT % holds every item on bill %. Void the bill instead.', kt.ticket_number, v_bill;
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
