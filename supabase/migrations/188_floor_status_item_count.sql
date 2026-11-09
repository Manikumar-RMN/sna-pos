-- 188: floor_status also returns how many items are on each table's open bills (shown on the table tile, like Petpooja).
-- One new last column, open_items (lines not cancelled on unpaid / part-paid bills). Every old column keeps its name, type and order.
-- Read only. Re-runnable (if open_items already exists nothing changes).
do $$
declare d text;
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'floor_status' and pg_get_function_result(p.oid) like '%open_items%') then
    return;
  end if;
  d := pg_get_functiondef('public.floor_status()'::regprocedure);
  d := replace(d, 'billed_bills integer, billed_at timestamp with time zone)', 'billed_bills integer, billed_at timestamp with time zone, open_items integer)');
  d := replace(d, 'coalesce(b.printed, 0)::integer, b.printed_at', 'coalesce(b.printed, 0)::integer, b.printed_at, coalesce(b.items, 0)::integer');
  d := replace(d, 'count(pr.at) as printed, min(pr.at) as printed_at', 'count(pr.at) as printed, min(pr.at) as printed_at,
             sum((select count(*) from public.order_items oi where oi.order_id = o.id and oi.cancelled_at is null)) as items');
  if position('open_items integer' in d) = 0 or position('as items' in d) = 0 or position('b.items' in d) = 0 then
    raise exception 'floor_status text did not match; nothing changed';
  end if;
  drop function public.floor_status();
  execute d;
  revoke all on function public.floor_status() from public, anon;
  grant execute on function public.floor_status() to authenticated, service_role;
end $$;
