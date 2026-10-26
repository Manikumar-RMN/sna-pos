-- 149: floor_status also says which tables have a PRINTED bill waiting for payment (the blue colour).
--
-- Table colours (team feedback, Founder decision 26 Oct 2026): white = free, blue = the bill has been printed and payment is
-- pending, and after payment the table goes straight back to white (no "needs cleaning" state). A table is "billed" when it has
-- open bills (unpaid or partly paid, not voided, not merged) and EVERY one of them has been printed: a `bill.print` or
-- `bill.reprint` row exists in audit_logs for that order (written by log_print, migration 135, for the first print or a reprint).
-- Two new last columns: billed_bills (how many open bills have been printed) and billed_at (when the oldest of those prints was
-- logged). Every old column keeps its name, type, order and filter. Drop + create because the column list changes.
-- Read only. Re-runnable.

drop function if exists public.floor_status();
create function public.floor_status()
 returns table (
   table_id uuid, table_number text, seats integer,
   open_bills integer, open_total numeric, oldest_open_at timestamptz,
   kot_waiting integer, oldest_kot_at timestamptz,
   reservation_id uuid, reservation_at timestamptz, reservation_name text, reservation_party integer,
   db_now timestamptz,
   kot_due_at timestamptz, kot_prep_min integer, kot_ticket_at timestamptz,
   billed_bills integer, billed_at timestamptz)
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
         now(),
         k.due, k.prep, k.tat,
         coalesce(b.printed, 0)::integer, b.printed_at
    from public.dining_tables t
    left join lateral (
      select count(*) as n, sum(o.grand_total) as total, min(coalesce(o.client_created_at, o.created_at)) as oldest,
             count(pr.at) as printed, min(pr.at) as printed_at
        from public.orders o
        left join lateral (select min(a.created_at) as at from public.audit_logs a
                            where a.entity_type = 'orders' and a.entity_id = o.id and a.restaurant_id = v_rest
                              and a.action in ('bill.print', 'bill.reprint')) pr on true
       where o.dining_table_id = t.id and o.restaurant_id = v_rest
         and o.payment_status in ('unpaid', 'partial') and o.status <> 'voided' and o.merged_into is null) b on true
    left join lateral (
      select count(*) as n, min(y.at) as oldest,
             (array_agg(y.due  order by y.due, y.at))[1] as due,
             (array_agg(y.prep order by y.due, y.at))[1] as prep,
             (array_agg(y.at   order by y.due, y.at))[1] as tat
        from (select x.at, x.prep,
                     x.at + make_interval(mins => case when x.prep is null then app.kot_default_min() else x.prep + app.kot_grace_min() end) as due
                from (select coalesce(kt.client_created_at, kt.created_at) as at,
                             (select max(coalesce(p.prep_minutes, pp.prep_minutes))::integer
                                from public.kitchen_ticket_items kti
                                join public.order_items oi on oi.id = kti.order_item_id
                                join public.products p on p.id = oi.product_id
                                left join public.products pp on pp.id = p.parent_id
                               where kti.kitchen_ticket_id = kt.id and kti.status <> 'cancelled') as prep
                        from public.kitchen_tickets kt
                        join public.orders o on o.id = kt.order_id
                       where o.dining_table_id = t.id and o.restaurant_id = v_rest
                         and o.payment_status in ('unpaid', 'partial') and o.status <> 'voided' and o.merged_into is null
                         and kt.status in ('new', 'preparing')) x) y) k on true
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
