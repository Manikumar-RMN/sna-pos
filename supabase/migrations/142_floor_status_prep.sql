-- 142: floor_status learns each dish's preparation time (products.prep_minutes, added by 141).
--
-- The kitchen-waiting colour used a fixed 15 minutes. Now each waiting kitchen ticket is due at
--     ticket start + (the LONGEST prep_minutes among its items + 5 minutes grace)       when any item has a prep time
--     ticket start + 15 minutes (no grace)                                                when no item has one (as before)
-- where ticket start = coalesce(client_created_at, created_at) (an offline KOT counts from when it was keyed) and an item's prep time is
-- coalesce(its size's prep_minutes, its dish's prep_minutes). Cancelled kitchen lines do not count. For every table the ticket that is
-- due FIRST is reported: kot_due_at (its due time), kot_prep_min (its longest prep time, null when none) and kot_ticket_at (its own start).
-- The app (lib/table-status.ts) turns the table "kot_delayed" when now > kot_due_at; with the old columns only it keeps the fixed 15 minutes.
--
-- The grace and the default are constants: app.kot_grace_min() = 5 and app.kot_default_min() = 15. lib/table-status.ts has PREP_GRACE_MIN = 5
-- and KOT_DELAYED_MIN = 15; a test there and in docs/tests/t141-148.sql keeps the two sides equal.
--
-- Changing the columns of a RETURNS TABLE function needs DROP, so this is drop + create. Every old column keeps its name, type, order and
-- filter (payment_status in unpaid/partial, status <> voided, not merged); the 3 new ones are last. Grants as in 134 (authenticated, service_role).
-- Read only. Re-runnable.

create or replace function app.kot_grace_min() returns integer language sql immutable as $$ select 5 $$;
create or replace function app.kot_default_min() returns integer language sql immutable as $$ select 15 $$;
revoke all on function app.kot_grace_min(), app.kot_default_min() from public, anon, authenticated;

drop function if exists public.floor_status();
create function public.floor_status()
 returns table (
   table_id uuid, table_number text, seats integer,
   open_bills integer, open_total numeric, oldest_open_at timestamptz,
   kot_waiting integer, oldest_kot_at timestamptz,
   reservation_id uuid, reservation_at timestamptz, reservation_name text, reservation_party integer,
   db_now timestamptz,
   kot_due_at timestamptz, kot_prep_min integer, kot_ticket_at timestamptz)
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
         k.due, k.prep, k.tat
    from public.dining_tables t
    left join lateral (
      select count(*) as n, sum(o.grand_total) as total, min(coalesce(o.client_created_at, o.created_at)) as oldest
        from public.orders o
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
