-- PO rate variance (order price vs price paid), consumption by department (cost centre), XYZ demand-variability analysis.

create or replace function public.report_po_variance(p_from date, p_to date) returns jsonb
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
      select g.number, g.received_on, po.number as po_number, coalesce(b.name, '') as outlet, s.name as supplier, i.name as item, i.unit, l.qty,
             pol.unit_cost as ordered_rate, round(l.line_total / nullif(l.qty, 0), 4) as paid_rate
        from public.goods_receipts g
        join public.purchase_orders po on po.id = g.purchase_order_id
        join public.goods_receipt_lines l on l.goods_receipt_id = g.id
        join public.purchase_order_lines pol on pol.purchase_order_id = po.id and pol.ingredient_id = l.ingredient_id
        join public.ingredients i on i.id = l.ingredient_id
        join public.suppliers s on s.id = g.supplier_id
        left join public.branches b on b.id = g.branch_id
       where g.restaurant_id = v_rest and (v_rb is null or g.branch_id = v_rb) and g.status <> 'cancelled' and g.received_on between p_from and p_to),
    v as (select d.*, round((d.paid_rate - d.ordered_rate) * d.qty, 2) as variance from d),
    capped as (select * from v order by received_on desc, number desc, item limit 3000)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(to_jsonb(c) order by c.received_on desc, c.number desc, c.item) from capped c), '[]'::jsonb),
      'truncated', (select count(*) from v) > 3000, 'row_limit', 3000,
      'totals', jsonb_build_object('lines', (select count(*) from v), 'variance', coalesce((select sum(variance) from v), 0),
        'over', coalesce((select sum(variance) from v where variance > 0), 0), 'under', coalesce((select sum(variance) from v where variance < 0), 0)))
  );
end $$;
revoke all on function public.report_po_variance(date, date) from public, anon;
grant execute on function public.report_po_variance(date, date) to authenticated;

create or replace function public.report_department_use(p_from date, p_to date) returns jsonb
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
      select m.department, coalesce(b.name, '') as outlet, i.name as item, i.unit, sum(l.qty) as qty, round(sum(l.qty * l.unit_cost), 2) as value,
             count(distinct m.id) as issues
        from public.material_issues m
        join public.material_issue_lines l on l.issue_id = m.id
        join public.ingredients i on i.id = l.ingredient_id
        left join public.branches b on b.id = m.branch_id
       where m.restaurant_id = v_rest and (v_rb is null or m.branch_id = v_rb) and m.issued_on between p_from and p_to
       group by m.department, b.name, i.name, i.unit),
    capped as (select * from d order by department, value desc, item limit 3000)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(to_jsonb(c) order by c.department, c.value desc, c.item) from capped c), '[]'::jsonb),
      'departments', coalesce((select jsonb_agg(jsonb_build_object('department', department, 'value', v) order by v desc) from (select department, sum(value) v from d group by department) x), '[]'::jsonb),
      'truncated', (select count(*) from d) > 3000, 'row_limit', 3000,
      'totals', jsonb_build_object('value', coalesce((select sum(value) from d), 0)))
  );
end $$;
revoke all on function public.report_department_use(date, date) from public, anon;
grant execute on function public.report_department_use(date, date) to authenticated;

-- XYZ: how steady the weekly use of each ingredient is. X steady (variation up to 0.5), Y moderate (up to 1), Z erratic (above 1).
create or replace function public.report_xyz(p_days int default 84) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_today date; v_weeks int;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_days is null or p_days < 28 or p_days > 364 then raise exception 'Choose between 28 and 364 days.'; end if;
  v_weeks := p_days / 7;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  v_today := (now() at time zone coalesce((select timezone from public.restaurants where id = v_rest), 'UTC'))::date;
  return (
    with use_w as (
      select m.ingredient_id, ((v_today - m.business_date) / 7) as wk, sum(-m.qty) as q
        from public.stock_movements m
       where m.restaurant_id = v_rest and (v_rb is null or m.branch_id = v_rb)
         and (m.kind in ('sale', 'wastage', 'transfer_out') or (m.kind = 'adjust' and m.reason = 'issued'))
         and m.business_date > v_today - v_weeks * 7 and m.business_date <= v_today
       group by 1, 2),
    ing as (select distinct ingredient_id from use_w),
    grid as (
      select a.ingredient_id, w.wk, coalesce(u.q, 0) as q from ing a cross join generate_series(0, v_weeks - 1) as w(wk)
        left join use_w u on u.ingredient_id = a.ingredient_id and u.wk = w.wk),
    stat as (
      select ingredient_id, sum(q) as total, avg(q) as mean, stddev_pop(q) as sd from grid group by ingredient_id),
    r as (
      select i.name, i.unit, round(s.total, 3) as total, round(s.mean, 3) as avg_week,
             case when s.mean > 0 then round(s.sd / s.mean, 2) else null end as cv,
             case when s.mean <= 0 then 'Z' when s.sd / s.mean <= 0.5 then 'X' when s.sd / s.mean <= 1 then 'Y' else 'Z' end as class
        from stat s join public.ingredients i on i.id = s.ingredient_id where i.is_active and s.total > 0)
    select jsonb_build_object(
      'weeks', v_weeks,
      'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.class, x.cv, x.name) from (select * from r order by class, cv, name limit 2000) x), '[]'::jsonb),
      'totals', jsonb_build_object('items', (select count(*) from r), 'x', (select count(*) from r where class = 'X'), 'y', (select count(*) from r where class = 'Y'), 'z', (select count(*) from r where class = 'Z')))
  );
end $$;
revoke all on function public.report_xyz(int) from public, anon;
grant execute on function public.report_xyz(int) to authenticated;
