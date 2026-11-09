-- Winsar-style inventory reports: receipts list, issues list (with department totals), supplier-wise purchases,
-- request/requisition status, stock count variance, stock watch-list (non-moving / high value / ABC) and the per-ingredient ledger.
-- Same rules as 144: STABLE, SECURITY DEFINER, own restaurant only, outlet scope from app.report_branch(), stock module + stock.view/manage.

create or replace function public.report_receipts(p_from date, p_to date) returns jsonb
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
      select g.number, g.received_on, g.status, g.supplier_bill_no, g.supplier_bill_date, coalesce(b.name, '') as outlet, s.name as supplier,
             i.name as item, i.unit, l.qty, l.returned_qty, l.unit_cost, l.line_total
        from public.goods_receipts g
        join public.goods_receipt_lines l on l.goods_receipt_id = g.id
        join public.ingredients i on i.id = l.ingredient_id
        join public.suppliers s on s.id = g.supplier_id
        left join public.branches b on b.id = g.branch_id
       where g.restaurant_id = v_rest and (v_rb is null or g.branch_id = v_rb) and g.received_on between p_from and p_to),
    capped as (select * from d order by received_on desc, number desc, item limit 3000)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(to_jsonb(c) order by c.received_on desc, c.number desc, c.item) from capped c), '[]'::jsonb),
      'total_rows', (select count(*) from d), 'row_limit', 3000, 'truncated', (select count(*) from d) > 3000,
      'totals', jsonb_build_object(
        'receipts', (select count(distinct number) from d where status <> 'cancelled'),
        'value', coalesce((select sum(line_total) from d where status <> 'cancelled'), 0)))
  );
end $$;

create or replace function public.report_issues(p_from date, p_to date) returns jsonb
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
      select m.number, m.issued_on, m.department, coalesce(b.name, '') as outlet, i.name as item, i.unit, l.qty, l.unit_cost,
             round(l.qty * l.unit_cost, 2) as value
        from public.material_issues m
        join public.material_issue_lines l on l.issue_id = m.id
        join public.ingredients i on i.id = l.ingredient_id
        left join public.branches b on b.id = m.branch_id
       where m.restaurant_id = v_rest and (v_rb is null or m.branch_id = v_rb) and m.issued_on between p_from and p_to),
    capped as (select * from d order by issued_on desc, number desc, item limit 3000),
    dep as (select department, count(distinct number) as issues, sum(value) as value from d group by department),
    dep_item as (select department, item, unit, sum(qty) as qty, sum(value) as value from d group by department, item, unit)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(to_jsonb(c) order by c.issued_on desc, c.number desc, c.item) from capped c), '[]'::jsonb),
      'by_department', coalesce((select jsonb_agg(to_jsonb(x) order by x.value desc) from dep x), '[]'::jsonb),
      'by_department_item', coalesce((select jsonb_agg(to_jsonb(x) order by x.department, x.value desc) from dep_item x), '[]'::jsonb),
      'total_rows', (select count(*) from d), 'row_limit', 3000, 'truncated', (select count(*) from d) > 3000,
      'totals', jsonb_build_object('issues', (select count(distinct number) from d), 'value', coalesce((select sum(value) from d), 0)))
  );
end $$;

create or replace function public.report_supplier_purchases(p_from date, p_to date) returns jsonb
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
      select s.name as supplier, count(*) as receipts, sum(g.total + g.returned_total) as bought, sum(g.returned_total) as returned,
             sum(g.total) as net, sum(g.paid_total) as paid, sum(g.total - g.paid_total) as owed
        from public.goods_receipts g join public.suppliers s on s.id = g.supplier_id
       where g.restaurant_id = v_rest and (v_rb is null or g.branch_id = v_rb) and g.received_on between p_from and p_to and g.status <> 'cancelled'
       group by s.name)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.net desc) from d x), '[]'::jsonb),
      'totals', jsonb_build_object('bought', coalesce((select sum(bought) from d), 0), 'returned', coalesce((select sum(returned) from d), 0),
                'net', coalesce((select sum(net) from d), 0), 'paid', coalesce((select sum(paid) from d), 0), 'owed', coalesce((select sum(owed) from d), 0)))
  );
end $$;

create or replace function public.report_requests(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  return jsonb_build_object(
    'stock_requests', coalesce((
      select jsonb_agg(jsonb_build_object('number', m.number, 'day', m.created_at::date, 'department', m.department, 'status', m.status,
               'item', i.name, 'unit', i.unit, 'requested', l.qty, 'issued', l.issued_qty, 'balance', greatest(l.qty - l.issued_qty, 0))
               order by m.created_at desc, m.number desc, i.name)
        from public.material_requests m join public.material_request_lines l on l.request_id = m.id join public.ingredients i on i.id = l.ingredient_id
       where m.restaurant_id = v_rest and (v_rb is null or m.branch_id = v_rb) and m.created_at::date between p_from and p_to), '[]'::jsonb),
    'requisitions', coalesce((
      select jsonb_agg(jsonb_build_object('number', r.number, 'day', r.created_at::date, 'status', r.status, 'est_total', r.est_total, 'order_number', po.number,
               'reason', r.reject_reason) order by r.created_at desc, r.number desc)
        from public.purchase_requisitions r left join public.purchase_orders po on po.id = r.purchase_order_id
       where r.restaurant_id = v_rest and (v_rb is null or r.branch_id = v_rb) and r.created_at::date between p_from and p_to), '[]'::jsonb));
end $$;

create or replace function public.report_count_variance(p_from date, p_to date) returns jsonb
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
      select c.business_date as day, coalesce(c.note, '') as note, i.name as item, i.unit, l.expected, l.counted, l.diff, l.unit_cost, l.value_diff
        from public.stock_counts c join public.stock_count_lines l on l.count_id = c.id join public.ingredients i on i.id = l.ingredient_id
       where c.restaurant_id = v_rest and (v_rb is null or c.branch_id = v_rb) and c.business_date between p_from and p_to and l.diff <> 0)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.day desc, x.item) from (select * from d limit 3000) x), '[]'::jsonb),
      'totals', jsonb_build_object('lines', (select count(*) from d), 'gain', coalesce((select sum(value_diff) from d where value_diff > 0), 0),
                'loss', coalesce((select sum(value_diff) from d where value_diff < 0), 0), 'net', coalesce((select sum(value_diff) from d), 0)))
  );
end $$;

-- p_kind: 'non_moving' (stock with no use for p_days), 'high_value' (stock worth at least p_cutoff), 'abc' (consumption over p_days ranked A 70% / B 20% / C 10%)
create or replace function public.report_stock_watch(p_kind text, p_days int default 30, p_cutoff numeric default 0) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_today date;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_kind not in ('non_moving', 'high_value', 'abc') then raise exception 'Choose non-moving, high value or ABC.'; end if;
  if p_days is null or p_days < 1 or p_days > 730 then raise exception 'Days must be between 1 and 730.'; end if;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  v_today := (now() at time zone coalesce((select timezone from public.restaurants where id = v_rest), 'UTC'))::date;
  return (
    with st as (
      select m.ingredient_id, sum(m.qty) as qty,
             max(m.business_date) filter (where m.kind in ('sale', 'wastage', 'transfer_out') or (m.kind = 'adjust' and m.reason = 'issued')) as last_used,
             -coalesce(sum(m.qty * coalesce(m.unit_cost, 0)) filter (where m.business_date > v_today - p_days
                and (m.kind in ('sale', 'wastage', 'transfer_out') or (m.kind = 'adjust' and m.reason = 'issued'))), 0) as used_value
        from public.stock_movements m
       where m.restaurant_id = v_rest and (v_rb is null or m.branch_id = v_rb) group by m.ingredient_id),
    base as (
      select i.name, i.unit, st.qty, i.cost_per_unit as rate, round(st.qty * i.cost_per_unit, 2) as value, st.last_used,
             case when st.last_used is null then null else v_today - st.last_used end as days_idle, round(st.used_value, 2) as used_value
        from st join public.ingredients i on i.id = st.ingredient_id where i.is_active),
    pick as (
      select * from base where p_kind = 'non_moving' and qty > 0 and (last_used is null or v_today - last_used >= p_days)
      union all select * from base where p_kind = 'high_value' and value >= coalesce(p_cutoff, 0) and qty > 0
      union all select * from base where p_kind = 'abc' and used_value > 0),
    ranked as (
      select p.*, case when p_kind = 'abc' then p.used_value else p.value end as basis from pick p),
    ranked2 as (
      select r.*, sum(r.basis) over (order by r.basis desc, r.name) as cum, sum(r.basis) over () as tot from ranked r)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'unit', unit, 'qty', qty, 'rate', rate, 'value', value, 'last_used', last_used,
                 'days_idle', days_idle, 'used_value', used_value,
                 'class', case when tot = 0 then 'C' when cum - basis < 0.7 * tot then 'A' when cum - basis < 0.9 * tot then 'B' else 'C' end)
                 order by basis desc, name) from (select * from ranked2 order by basis desc, name limit 2000) r), '[]'::jsonb),
      'totals', jsonb_build_object('items', (select count(*) from pick), 'value', coalesce((select sum(value) from pick), 0), 'used_value', coalesce((select sum(used_value) from pick), 0)))
  );
end $$;

create or replace function public.report_stock_ledger(p_ingredient uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_ing public.ingredients%rowtype; v_open numeric; v_open_val numeric;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  select * into v_ing from public.ingredients where id = p_ingredient and restaurant_id = v_rest;
  if not found then raise exception 'Choose an ingredient.'; end if;
  select coalesce(sum(m.qty), 0), coalesce(sum(m.qty * coalesce(m.unit_cost, v_ing.cost_per_unit)), 0) into v_open, v_open_val
    from public.stock_movements m where m.restaurant_id = v_rest and m.ingredient_id = p_ingredient and (v_rb is null or m.branch_id = v_rb) and m.business_date < p_from;
  return (
    with d as (
      select m.business_date as day, m.created_at, m.kind, m.reason, coalesce(m.note, '') as note, m.qty, coalesce(m.unit_cost, v_ing.cost_per_unit) as rate,
             round(m.qty * coalesce(m.unit_cost, v_ing.cost_per_unit), 2) as value,
             v_open + sum(m.qty) over (order by m.created_at, m.id) as balance
        from public.stock_movements m
       where m.restaurant_id = v_rest and m.ingredient_id = p_ingredient and (v_rb is null or m.branch_id = v_rb) and m.business_date between p_from and p_to)
    select jsonb_build_object(
      'item', v_ing.name, 'unit', v_ing.unit, 'opening', v_open, 'opening_value', round(v_open_val, 2),
      'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from (select * from d order by created_at limit 3000) x), '[]'::jsonb),
      'closing', v_open + coalesce((select sum(qty) from d), 0),
      'receipts', coalesce((select sum(qty) from d where qty > 0), 0), 'issues', -coalesce((select sum(qty) from d where qty < 0), 0))
  );
end $$;

do $$ declare f text; begin
  foreach f in array array['report_receipts(date,date)', 'report_issues(date,date)', 'report_supplier_purchases(date,date)', 'report_requests(date,date)',
    'report_count_variance(date,date)', 'report_stock_watch(text,integer,numeric)', 'report_stock_ledger(uuid,date,date)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;
