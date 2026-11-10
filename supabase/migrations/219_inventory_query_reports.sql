-- Winsar-style inventory queries and audit (read only):
--   report_consumption_monthly(p_from, p_to)  how much of each ingredient went out, month by month
--   report_item_stock(p_ingredient)           one ingredient at a glance: stock, value, last bought, use, cover
--   report_mr_audit(p_from, p_to)             every stock request: who asked, who decided, how long it took, what was issued

-- "Went out" = sold in dishes, wasted, sent to another outlet, issued to a department, or used in a production batch.
create or replace function public.report_consumption_monthly(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  return (
    with d as (
      select to_char(m.business_date, 'YYYY-MM') as mon, i.id as ing, i.name as item, i.unit, -m.qty as qty,
             -m.qty * coalesce(m.unit_cost, i.cost_per_unit) as value
        from public.stock_movements m join public.ingredients i on i.id = m.ingredient_id
       where m.restaurant_id = v_rest and (v_rb is null or m.branch_id = v_rb) and m.business_date between p_from and p_to
         and m.qty < 0 and (m.kind in ('sale', 'wastage', 'transfer_out') or (m.kind = 'adjust' and m.reason in ('issued', 'production')))),
    per as (select ing, item, unit, mon, sum(qty) as qty, sum(value) as value from d group by ing, item, unit, mon),
    tot as (select ing, item, unit, sum(qty) as qty, sum(value) as value from per group by ing, item, unit)
    select jsonb_build_object(
      'months', coalesce((select jsonb_agg(mon order by mon) from (select distinct mon from per) x), '[]'::jsonb),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('item', t.item, 'unit', t.unit, 'qty', round(t.qty, 3), 'value', round(t.value, 2),
                 'by_month', (select coalesce(jsonb_object_agg(p.mon, round(p.qty, 3)), '{}'::jsonb) from per p where p.ing = t.ing))
                 order by t.value desc, t.item) from tot t), '[]'::jsonb),
      'month_values', coalesce((select jsonb_agg(jsonb_build_object('month', mon, 'value', round(v, 2)) order by mon) from (select mon, sum(value) as v from per group by mon) y), '[]'::jsonb),
      'totals', jsonb_build_object('items', (select count(*) from tot), 'value', coalesce((select round(sum(value), 2) from tot), 0)))
  );
end $$;

create or replace function public.report_item_stock(p_ingredient uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_ing public.ingredients%rowtype; v_today date; v_on numeric; v_used30 numeric; v_last_used date; v_daily numeric;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  select * into v_ing from public.ingredients where id = p_ingredient and restaurant_id = v_rest;
  if not found then raise exception 'Choose an ingredient.'; end if;
  v_today := (now() at time zone coalesce((select timezone from public.restaurants where id = v_rest), 'UTC'))::date;
  select coalesce(sum(qty), 0) into v_on from public.stock_movements where restaurant_id = v_rest and ingredient_id = p_ingredient and (v_rb is null or branch_id = v_rb);
  select coalesce(-sum(qty), 0) into v_used30 from public.stock_movements
   where restaurant_id = v_rest and ingredient_id = p_ingredient and (v_rb is null or branch_id = v_rb) and qty < 0 and business_date > v_today - 30
     and (kind in ('sale', 'wastage', 'transfer_out') or (kind = 'adjust' and reason in ('issued', 'production')));
  select max(business_date) into v_last_used from public.stock_movements
   where restaurant_id = v_rest and ingredient_id = p_ingredient and (v_rb is null or branch_id = v_rb) and qty < 0
     and (kind in ('sale', 'wastage', 'transfer_out') or (kind = 'adjust' and reason in ('issued', 'production')));
  v_daily := v_used30 / 30.0;
  return jsonb_build_object(
    'item', v_ing.name, 'unit', v_ing.unit, 'category', v_ing.category, 'active', v_ing.is_active,
    'on_hand', round(v_on, 3), 'cost', v_ing.cost_per_unit, 'value', round(v_on * v_ing.cost_per_unit, 2), 'reorder_level', v_ing.reorder_level,
    'status', case when v_on < 0 then 'negative' when v_on = 0 then 'out' when v_ing.reorder_level > 0 and v_on <= v_ing.reorder_level then 'low' else 'ok' end,
    'used_30', round(v_used30, 3), 'daily_use', round(v_daily, 3),
    'days_cover', case when v_daily > 0 and v_on > 0 then round(v_on / v_daily, 1) else null end,
    'last_used', v_last_used,
    'receipts', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.received_on desc, x.number desc) from (
        select g.number, g.received_on, s.name as supplier, l.qty, l.unit_cost, l.line_total
          from public.goods_receipt_lines l join public.goods_receipts g on g.id = l.goods_receipt_id join public.suppliers s on s.id = g.supplier_id
         where l.restaurant_id = v_rest and l.ingredient_id = p_ingredient and g.status <> 'cancelled' and (v_rb is null or g.branch_id = v_rb)
         order by g.received_on desc, g.number desc limit 5) x), '[]'::jsonb),
    'movements', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
        select m.business_date as day, m.created_at, m.kind, m.reason, m.qty, coalesce(m.unit_cost, v_ing.cost_per_unit) as rate
          from public.stock_movements m
         where m.restaurant_id = v_rest and m.ingredient_id = p_ingredient and (v_rb is null or m.branch_id = v_rb)
         order by m.created_at desc limit 10) x), '[]'::jsonb));
end $$;

create or replace function public.report_mr_audit(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  return (
    with d as (
      select m.number, m.created_at, m.department, m.status, m.reject_reason, coalesce(b.name, '') as outlet,
             ru.full_name as asked_by, du.full_name as decided_by, m.decided_at,
             (select count(*) from public.material_request_lines l where l.request_id = m.id) as items,
             (select count(*) from public.material_request_lines l where l.request_id = m.id and l.issued_qty >= l.qty) as items_done,
             coalesce((select string_agg(mi.number, ', ' order by mi.number) from public.material_issues mi where mi.request_id = m.id), '') as issues
        from public.material_requests m
        join public.users ru on ru.id = m.requested_by
        left join public.users du on du.id = m.decided_by
        left join public.branches b on b.id = m.branch_id
       where m.restaurant_id = v_rest and (v_rb is null or m.branch_id = v_rb) and m.created_at::date between p_from and p_to),
    capped as (select * from d order by created_at desc, number desc limit 2000)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object('number', c.number, 'day', c.created_at::date, 'outlet', c.outlet, 'department', c.department,
                 'status', c.status, 'asked_by', c.asked_by, 'decided_by', c.decided_by, 'decided_day', c.decided_at::date,
                 'hours', case when c.decided_at is null then null else round((extract(epoch from (c.decided_at - c.created_at)) / 3600.0)::numeric, 1) end,
                 'items', c.items, 'items_done', c.items_done, 'issues', c.issues, 'reason', c.reject_reason)
                 order by c.created_at desc, c.number desc) from capped c), '[]'::jsonb),
      'totals', jsonb_build_object('requests', (select count(*) from d),
                'waiting', (select count(*) from d where status in ('requested', 'part_issued')),
                'issued', (select count(*) from d where status = 'issued'),
                'rejected', (select count(*) from d where status = 'rejected'),
                'cancelled', (select count(*) from d where status = 'cancelled'),
                'avg_hours', (select round((avg(extract(epoch from (decided_at - created_at)) / 3600.0))::numeric, 1) from d where decided_at is not null)))
  );
end $$;

do $$ declare f text; begin
  foreach f in array array['report_consumption_monthly(date,date)', 'report_item_stock(uuid)', 'report_mr_audit(date,date)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;
