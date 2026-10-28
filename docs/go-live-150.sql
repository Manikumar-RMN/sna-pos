-- GO-LIVE 150: customer favourites (read-only function public.customer_favourites).
--   Gives the order screen a guest's 3 favourite dishes and last 5 bills. No table, column or data is touched.
--
-- Paste this WHOLE file into the Supabase SQL editor and press Run. It is all-or-nothing (a DO block is one transaction).
--   * It refuses to run unless migration 149 (149_floor_status_billed) is already recorded.
--   * It refuses to run if 150 is already recorded (a second run changes nothing and says so).
--
do $go$
begin
  if not exists (select 1 from supabase_migrations.schema_migrations
                  where name like '149\_%' or name like '%floor\_status\_billed%') then
    raise exception 'GO-LIVE 150 STOPPED: change 149 (floor_status_billed) is not recorded as applied. Nothing was changed.';
  end if;
  if exists (select 1 from supabase_migrations.schema_migrations
              where name like '150\_%' or name like '%customer\_favourites%') then
    raise exception 'GO-LIVE 150 STOPPED: change 150 (customer_favourites) is already recorded as applied. Nothing was changed.';
  end if;

  execute $mig150$
-- 150: a guest's favourite dishes and last bills, for the order screen ("Regular guest" hint).
--
-- Read only. Same right as find_customer (order.create). Counts only paid, not voided, not merged bills of that guest in this
-- restaurant, and leaves out cancelled lines. favourites = the 3 dishes ordered most (by quantity); recent = the last 5 bills.
-- Returns null when the guest is not found. Re-runnable.

create or replace function public.customer_favourites(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_fav jsonb; v_rec jsonb;
begin
  perform app.require_permission('order.create');
  if p_customer is null or not exists (select 1 from public.customers c where c.id = p_customer and c.restaurant_id = v_rest and c.deleted_at is null) then
    return null;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('product_id', x.product_id, 'name', x.name, 'qty', x.q) order by x.q desc, x.name), '[]'::jsonb)
    into v_fav
    from (select oi.product_id, max(oi.product_name) as name, sum(oi.quantity) as q
            from public.orders o
            join public.order_items oi on oi.order_id = o.id and oi.restaurant_id = v_rest
           where o.restaurant_id = v_rest and o.customer_id = p_customer
             and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null
             and oi.cancelled_at is null
           group by oi.product_id
           order by sum(oi.quantity) desc, max(oi.product_name)
           limit 3) x;

  select coalesce(jsonb_agg(jsonb_build_object('bill_number', y.bill_number, 'on', y.business_date, 'total', y.grand_total) order by y.business_date desc, y.created_at desc), '[]'::jsonb)
    into v_rec
    from (select o.bill_number, o.business_date, o.grand_total, o.created_at
            from public.orders o
           where o.restaurant_id = v_rest and o.customer_id = p_customer
             and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null
           order by o.business_date desc, o.created_at desc
           limit 5) y;

  return jsonb_build_object('favourites', v_fav, 'recent', v_rec);
end $$;

revoke all on function public.customer_favourites(uuid) from public, anon;
grant execute on function public.customer_favourites(uuid) to authenticated, service_role;

$mig150$;

  insert into supabase_migrations.schema_migrations (version, name)
  values (to_char(clock_timestamp() at time zone 'utc', 'YYYYMMDDHH24MISS'), '150_customer_favourites');

  raise notice 'GO-LIVE 150 done: customer_favourites(uuid) is ready.';
end
$go$;
