-- GO-LIVE 151: two read-only report functions (public.report_leakage and public.report_table_turnaround).
--   Powers Reports > "Leakage summary" and "Table turnaround time". No table, column or data is touched.
--
-- Paste this WHOLE file into the Supabase SQL editor and press Run. It is all-or-nothing (a DO block is one transaction).
--   * It refuses to run unless migration 150 (150_customer_favourites) is already recorded.
--   * It refuses to run if 151 is already recorded (a second run changes nothing and says so).
--
do $go$
begin
  if not exists (select 1 from supabase_migrations.schema_migrations
                  where name like '150\_%' or name like '%customer\_favourites%') then
    raise exception 'GO-LIVE 151 STOPPED: change 150 (customer_favourites) is not recorded as applied. Nothing was changed.';
  end if;
  if exists (select 1 from supabase_migrations.schema_migrations
              where name like '151\_%' or name like '%report\_leakage%') then
    raise exception 'GO-LIVE 151 STOPPED: change 151 (report_leakage_turnaround) is already recorded as applied. Nothing was changed.';
  end if;

  execute $mig151$
-- 151: two report functions for the Reports screen. Read only: no table, column or data is changed.
--
-- 1. report_leakage(p_from, p_to)       "Leakage summary": where money can leak, in one place. Needs report.view_sales; the rupee values are filled only
--                                       for people who ALSO have report.view_financial (else null + "money": false). Counts are always shown.
--      summary:[{key, label, count, value}]  keys: void_bills, cancelled_items, cancelled_kots, credit_notes, discounts, complimentary, staff_meals,
--                                       reprints, moves, offline_flagged. value = rupees where the database holds one (void bills, credit notes,
--                                       discounts, complimentary, staff meals), else null.
--      by_staff:[{user_id, staff_name, voids, cancelled_items, cancelled_kots, credit_notes, complimentary, reprints, moves}]  (from the audit log)
-- 2. report_table_turnaround(p_from, p_to)  dine-in table time: minutes from the bill being opened to the last payment. Needs report.view_sales.
--      by_day:[{business_date, bills, avg_minutes}], by_table:[{table_number, bills, avg_minutes, longest_minutes}],
--      totals:{bills, avg_minutes, median_minutes, longest_minutes}. Bills with no payment, voided, merged, or taking over 24 hours are left out.
--
-- Same safety and style as 128 / 138 / 146: STABLE, SECURITY DEFINER, search_path = public, pg_temp, own restaurant only, outlet scope from
-- app.report_branch(), business day filters, 366-day limit. Audit rows are read by time in the restaurant's time zone (like report_reprints).
-- Re-runnable.

create or replace function public.report_leakage(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_money boolean; v_tz text; v_start timestamptz; v_end timestamptz;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest  := app.current_restaurant_id();
  v_rb    := app.report_branch();
  v_money := app.has_permission('report.view_financial');
  select coalesce(nullif(timezone, ''), 'UTC') into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;
  return (
    with o as (
      select * from public.orders x
       where x.restaurant_id = v_rest and (v_rb is null or x.branch_id = v_rb)
         and x.business_date between p_from and p_to and x.merged_into is null),
    a as (
      select al.action, al.user_id from public.audit_logs al
       where al.restaurant_id = v_rest and (v_rb is null or al.branch_id = v_rb)
         and al.created_at >= v_start and al.created_at < v_end
         and al.action in ('order.cancel_item', 'kot.cancel', 'bill.reprint', 'kot.reprint', 'order.move_table', 'order.move_item',
                           'order.offline_flagged', 'order.void', 'credit_note.issue', 'order.complimentary')),
    cn as (
      select c.amount from public.credit_notes c
       where c.restaurant_id = v_rest and (v_rb is null or c.branch_id = v_rb) and c.business_date between p_from and p_to),
    s as (
      select 'void_bills' as key, 'Voided bills' as label, count(*) filter (where status = 'voided') as n,
             coalesce(sum(grand_total) filter (where status = 'voided'), 0) as v from o
      union all select 'cancelled_items', 'Cancelled items', count(*) filter (where action = 'order.cancel_item'), null from a
      union all select 'cancelled_kots', 'Cancelled kitchen tickets', count(*) filter (where action = 'kot.cancel'), null from a
      union all select 'credit_notes', 'Credit notes (sales returns)', count(*), coalesce(sum(amount), 0) from cn
      union all select 'discounts', 'Bills with a discount', count(*) filter (where status <> 'voided' and comp_kind is null and discount_total > 0),
             coalesce(sum(discount_total) filter (where status <> 'voided' and comp_kind is null), 0) from o
      union all select 'complimentary', 'Complimentary bills', count(*) filter (where status <> 'voided' and comp_kind = 'complimentary'),
             coalesce(sum(subtotal) filter (where status <> 'voided' and comp_kind = 'complimentary'), 0) from o
      union all select 'staff_meals', 'Staff meals', count(*) filter (where status <> 'voided' and comp_kind = 'staff_meal'),
             coalesce(sum(subtotal) filter (where status <> 'voided' and comp_kind = 'staff_meal'), 0) from o
      union all select 'reprints', 'Bill and kitchen reprints', count(*) filter (where action in ('bill.reprint', 'kot.reprint')), null from a
      union all select 'moves', 'Table and item moves', count(*) filter (where action in ('order.move_table', 'order.move_item')), null from a
      union all select 'offline_flagged', 'Offline bills flagged for a check', count(*) filter (where action = 'order.offline_flagged'), null from a),
    st as (
      select a.user_id,
             count(*) filter (where action = 'order.void') as voids,
             count(*) filter (where action = 'order.cancel_item') as cancelled_items,
             count(*) filter (where action = 'kot.cancel') as cancelled_kots,
             count(*) filter (where action = 'credit_note.issue') as credit_notes,
             count(*) filter (where action = 'order.complimentary') as complimentary,
             count(*) filter (where action in ('bill.reprint', 'kot.reprint')) as reprints,
             count(*) filter (where action in ('order.move_table', 'order.move_item')) as moves
        from a where a.user_id is not null group by a.user_id)
    select jsonb_build_object(
      'money', v_money,
      'summary', coalesce((select jsonb_agg(jsonb_build_object('key', s.key, 'label', s.label, 'count', s.n,
                    'value', case when v_money then s.v end)) from s), '[]'::jsonb),
      'by_staff', coalesce((select jsonb_agg(jsonb_build_object('user_id', st.user_id, 'staff_name', coalesce(u.full_name, 'Unknown'),
                    'voids', st.voids, 'cancelled_items', st.cancelled_items, 'cancelled_kots', st.cancelled_kots,
                    'credit_notes', st.credit_notes, 'complimentary', st.complimentary, 'reprints', st.reprints, 'moves', st.moves)
                    order by (st.voids + st.cancelled_items + st.cancelled_kots + st.credit_notes + st.complimentary + st.reprints + st.moves) desc, u.full_name, st.user_id)
                    from st left join public.users u on u.id = st.user_id), '[]'::jsonb))
  );
end $$;

create or replace function public.report_table_turnaround(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return (
    with b as (
      select o.id, o.business_date, dt.table_number,
             extract(epoch from (max(p.created_at) - coalesce(o.client_created_at, o.created_at))) / 60 as mins
        from public.orders o
        join public.payments p on p.order_id = o.id and p.restaurant_id = v_rest and p.status = 'captured'
        left join public.dining_tables dt on dt.id = o.dining_table_id
       where o.restaurant_id = v_rest and (v_rb is null or o.branch_id = v_rb)
         and o.business_date between p_from and p_to
         and o.order_type = 'dine_in' and o.dining_table_id is not null
         and o.status <> 'voided' and o.merged_into is null
         and o.payment_status in ('paid', 'partially_refunded')
       group by o.id, o.business_date, dt.table_number, o.client_created_at, o.created_at),
    g as (select * from b where mins > 0 and mins <= 1440)
    select jsonb_build_object(
      'by_day', coalesce((select jsonb_agg(jsonb_build_object('business_date', d.business_date, 'bills', d.n, 'avg_minutes', d.a) order by d.business_date)
                  from (select business_date, count(*) as n, round(avg(mins)::numeric, 1) as a from g group by business_date) d), '[]'::jsonb),
      'by_table', coalesce((select jsonb_agg(jsonb_build_object('table_number', t.table_number, 'bills', t.n, 'avg_minutes', t.a, 'longest_minutes', t.l)
                  order by t.table_number)
                  from (select coalesce(table_number, '?') as table_number, count(*) as n, round(avg(mins)::numeric, 1) as a, round(max(mins)::numeric, 1) as l
                          from g group by coalesce(table_number, '?')) t), '[]'::jsonb),
      'totals', jsonb_build_object('bills', (select count(*) from g),
                  'avg_minutes', (select round(avg(mins)::numeric, 1) from g),
                  'median_minutes', (select round((percentile_cont(0.5) within group (order by mins))::numeric, 1) from g),
                  'longest_minutes', (select round(max(mins)::numeric, 1) from g)))
  );
end $$;

revoke all on function public.report_leakage(date, date), public.report_table_turnaround(date, date) from public, anon;
grant execute on function public.report_leakage(date, date), public.report_table_turnaround(date, date) to authenticated;

$mig151$;

  insert into supabase_migrations.schema_migrations (version, name)
  values (to_char(clock_timestamp() at time zone 'utc', 'YYYYMMDDHH24MISS'), '151_report_leakage_turnaround');

  raise notice 'GO-LIVE 151 done: report_leakage and report_table_turnaround are ready.';
end
$go$;
