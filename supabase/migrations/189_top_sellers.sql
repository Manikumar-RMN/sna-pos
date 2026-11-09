-- 189: top_sellers(): the dishes this outlet sold most in the last N days, for the "Top sellers" strip on the billing screen.
-- Read only. Needs the right to take orders (order.create), not a report right. Sizes count toward their dish. Voided and cancelled lines
-- do not count. Packing / charge lines never appear. Returns at most p_limit product ids, best first.
create or replace function public.top_sellers(p_days integer default 30, p_limit integer default 8)
 returns table(product_id uuid, units numeric)
 language plpgsql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  perform app.require_permission('order.create');
  return query
  select coalesce(p.parent_id, p.id) as pid, sum(oi.quantity)::numeric as units
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.products p on p.id = oi.product_id
   where o.restaurant_id = v_rest and o.branch_id = v_branch
     and o.status <> 'voided' and oi.cancelled_at is null
     and o.created_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)))
     and not coalesce(p.is_charge, false) and p.deleted_at is null
   group by coalesce(p.parent_id, p.id)
   order by units desc, pid
   limit greatest(1, least(coalesce(p_limit, 8), 20));
end $function$;

revoke all on function public.top_sellers(integer, integer) from public, anon;
grant execute on function public.top_sellers(integer, integer) to authenticated, service_role;
