-- 259: sales, tax and GST reports count an order only once it is billed (orders.billed_at, migration 258).
-- A running table (KOT saved, bill not made) is no longer a sale and never appears in a bill register.
-- Applied live on 14 Nov 2026. It patches the 29 report functions in place; day_status and day_review are left
-- alone on purpose (day close must still see running orders).
do $m$
declare r record; d text; n text;
begin
  for r in select p.oid, p.proname from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname in ('public','app') and p.prosrc ~ '(o|o2|ord)\.status (=|in \()\s*''completed'''
              and p.proname not in ('protect_completed_orders','day_status','day_review','sales_report')
  loop
    d := pg_get_functiondef(r.oid);
    if d like '%billed_at is not null%' then continue; end if;
    n := regexp_replace(d, '\m(o|o2|ord)\.status = ''completed''', '\1.status = ''completed'' and \1.billed_at is not null', 'g');
    n := regexp_replace(n, '\m(o|o2|ord)\.status in \(''completed'', ''voided''\)', '\1.status in (''completed'', ''voided'') and \1.billed_at is not null', 'g');
    if r.proname = 'z_report' then
      n := regexp_replace(n, '(?<![\w.])status = ''completed''', 'status = ''completed'' and billed_at is not null', 'g');
      n := regexp_replace(n, '(?<![\w.])status <> ''voided'' and', 'status <> ''voided'' and billed_at is not null and', 'g');
      n := replace(n, 'order by created_at, bill_number)', 'order by billed_at, bill_number)');
      n := replace(n, 'order by created_at desc, bill_number desc)', 'order by billed_at desc, bill_number desc)');
    end if;
    if n = d then raise exception 'no change in %', r.proname; end if;
    execute n;
  end loop;
  d := pg_get_functiondef('public.sales_report'::regproc);
  if d not like '%billed_at is not null%' then
    n := replace(d, 'and status in (''completed'', ''voided'') and merged_into is null;', 'and status in (''completed'', ''voided'') and billed_at is not null and merged_into is null;');
    if n = d then raise exception 'sales_report patch failed'; end if;
    execute n;
  end if;
end $m$;
