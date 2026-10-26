-- 134: Floor status for the table strip and the Captain table grid.
--
--  * public.floor_status() returns one row per active table of the signed-in outlet: how many bills are open on it, their total,
--    since when the oldest has been open, how many kitchen tickets are still waiting and since when, and the next reservation
--    that is close (from 60 minutes before the booked time until 30 minutes after it).
--  * An "open" bill is payment_status in ('unpaid','partial'), not voided, not merged away. (Bills are saved with status
--    'completed' even when unpaid, so the status column must not be used for this.)
--  * Times use coalesce(client_created_at, created_at): a bill or KOT keyed on an offline device counts from when it was keyed.
--  * The database sends its own clock (db_now) so the screen does not depend on the device's clock; colours and thresholds
--    (90 minutes open, 15 minutes KOT waiting) are decided in the app (lib/table-status.ts).
--  * Read only. Needs the right to take orders (order.create), like the screens that show it.
-- Additive: one new function. Nothing is dropped.

create or replace function public.floor_status()
 returns table (
   table_id uuid, table_number text, seats integer,
   open_bills integer, open_total numeric, oldest_open_at timestamptz,
   kot_waiting integer, oldest_kot_at timestamptz,
   reservation_id uuid, reservation_at timestamptz, reservation_name text, reservation_party integer,
   db_now timestamptz)
 language plpgsql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if not app.has_permission('order.create') then raise exception 'Your role does not allow this action (order.create).'; end if;
  return query
  select t.id, t.table_number::text, t.seats::integer,
         coalesce(b.n, 0)::integer, coalesce(b.total, 0)::numeric, b.oldest,
         coalesce(k.n, 0)::integer, k.oldest,
         rs.id, rs.reserved_for, rs.guest_name::text, rs.party_size::integer,
         now()
    from public.dining_tables t
    left join lateral (
      select count(*) as n, sum(o.grand_total) as total, min(coalesce(o.client_created_at, o.created_at)) as oldest
        from public.orders o
       where o.dining_table_id = t.id and o.restaurant_id = v_rest
         and o.payment_status in ('unpaid', 'partial') and o.status <> 'voided' and o.merged_into is null) b on true
    left join lateral (
      select count(*) as n, min(coalesce(kt.client_created_at, kt.created_at)) as oldest
        from public.kitchen_tickets kt
        join public.orders o on o.id = kt.order_id
       where o.dining_table_id = t.id and o.restaurant_id = v_rest
         and o.payment_status in ('unpaid', 'partial') and o.status <> 'voided' and o.merged_into is null
         and kt.status in ('new', 'preparing')) k on true
    left join lateral (
      select r.id, r.reserved_for, r.guest_name, r.party_size
        from public.reservations r
       where r.dining_table_id = t.id and r.restaurant_id = v_rest and r.status = 'booked'
         and r.reserved_for is not null
         and r.reserved_for >= now() - interval '30 minutes' and r.reserved_for <= now() + interval '60 minutes'
       order by r.reserved_for limit 1) rs on true
   where t.restaurant_id = v_rest and t.branch_id = v_branch and t.is_active and not t.is_kiosk
   order by t.table_number;
end $function$;

revoke all on function public.floor_status() from public, anon;
grant execute on function public.floor_status() to authenticated, service_role;
