-- 144: Inventory reports (Batch 3, plan section 5.2). Four read-only reports on top of 143.
--
--   report_stock_on_hand(p_as_of date default null)  stock.view (or stock.manage)
--   report_stock_movement(p_from, p_to)              stock.view (or stock.manage)
--   report_food_cost(p_from, p_to)                   (stock.view or stock.manage) AND report.view_sales
--   report_wastage(p_from, p_to)                     stock.view (or stock.manage)
--
-- Same style as 138: STABLE, SECURITY DEFINER, search_path = public, pg_temp, own restaurant only, outlet scope from app.report_branch()
-- (null = All outlets, with a by_outlet breakdown that adds up to the totals), days = stock_movements.business_date (the sales reports' business day,
-- written by the stamp trigger of 143), 366-day cap and the same messages, revoked from public / anon, granted to authenticated.
-- Needs the Professional module 'stock' (app.require_feature). Costs: movement rows carry the cost snapshot (unit_cost) taken when they were
-- written; on-hand valuation uses the ingredient's cost today, and negative stock is valued at 0 (and counted as "negative").
--
-- Return shapes (jsonb, numbers):
--   report_stock_on_hand  {as_of, all_outlets,
--       rows:[{branch_id, outlet_name, ingredient_id, name, category, unit, on_hand, cost, value, reorder_level, status 'ok'|'low'|'out'|'negative'}],
--       by_outlet:[{branch_id, outlet_name, value, items, low, out, negative}],
--       totals:{value, items, low, out, negative}}
--     status: negative below 0, out exactly 0, low = at or under a reorder level above 0. One row per outlet in scope x ingredient (active ones, and
--     inactive ones that still hold stock). as_of = business_date <= as_of (null = now).
--   report_stock_movement {all_outlets,
--       rows:[{branch_id, outlet_name, ingredient_id, name, unit, opening, purchased, transfer_in, transfer_out, used, wasted, adjusted, counted, closing}],
--       details:[{id, business_date, at, kind, qty, unit_cost, value, reason, note, bill_number, user_name, branch_id, outlet_name, ingredient_id, name, unit}],
--       truncated, row_limit, total_rows,
--       by_outlet:[{branch_id, outlet_name, purchased_value, used_value, wasted_value, adjusted_value, counted_value}],
--       totals:{rows, movements, purchased_value, used_value, wasted_value, adjusted_value, counted_value}}
--     closing = opening + purchased + transfer_in - transfer_out - used - wasted + adjusted + counted. used = sale + returned (net, positive =
--     consumed), wasted and transfer_out are positive too; adjusted and counted keep their sign. details: newest first, first 2000.
--   report_food_cost {all_outlets,
--       by_day:[{business_date, net_sales_all, net_sales_covered, cost, cost_pct}],
--       by_dish:[{product_id, name, qty_sold, net_sales, cost, cost_pct, margin, has_recipe}],
--       by_outlet:[{branch_id, outlet_name, net_sales_all, net_sales_covered, cost, cost_pct}],
--       totals:{net_sales_all, net_sales_covered, coverage_pct, cost, cost_pct, wastage_cost}}
--     Net sales = order_items.net_amount of lines that are not cancelled, on bills that are not voided and not merged (business_date in range).
--     A line is "covered" when it used ingredients (it has a sale movement); cost = ingredients used by covered lines at their snapshot cost (sale and
--     returned rows joined by order_item_id). Dishes with no covered line have cost null and are left out of the percentages. cost_pct and margin are on
--     covered sales only. Theoretical and actual cost are the same number here (cost comes from the ingredient movements the sales caused).
--   report_wastage {all_outlets, by_reason:[{reason, lines, value}], by_ingredient:[{ingredient_id, name, unit, qty, value}],
--       by_day:[{business_date, lines, value}], by_user:[{user_id, user_name, lines, value}], by_outlet:[{branch_id, outlet_name, lines, value}],
--       rows:[{id, business_date, at, branch_id, outlet_name, ingredient_id, name, unit, qty, unit_cost, value, reason, note, user_name}],
--       truncated, row_limit, total_rows, totals:{lines, value}}
--     Kind 'wastage' only (other adjustments are in Stock movement). qty and value are positive. A wastage with no reason (old rows) is "other".
-- Safe to run again (create or replace).

-- ---------------------------------------------------------------- 1. stock on hand
create or replace function public.report_stock_on_hand(p_as_of date default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return (
    with br as (
      select b.id, b.name from public.branches b
       where b.restaurant_id = v_rest and b.deleted_at is null and (v_rb is null or b.id = v_rb)),
    bal as (
      select m.branch_id, m.ingredient_id, sum(m.qty) as q
        from public.stock_movements m
       where m.restaurant_id = v_rest and (v_rb is null or m.branch_id = v_rb) and (p_as_of is null or m.business_date <= p_as_of)
       group by m.branch_id, m.ingredient_id),
    r as (
      select br.id as branch_id, br.name as outlet_name, i.id as ingredient_id, i.name, i.category, i.unit,
             round(coalesce(bal.q, 0), 4) as on_hand, i.cost_per_unit as cost, i.reorder_level,
             round(greatest(coalesce(bal.q, 0), 0) * i.cost_per_unit, 2) as value,
             case when coalesce(bal.q, 0) < 0 then 'negative'
                  when coalesce(bal.q, 0) = 0 then 'out'
                  when i.reorder_level > 0 and bal.q <= i.reorder_level then 'low'
                  else 'ok' end as status
        from br
        cross join public.ingredients i
        left join bal on bal.branch_id = br.id and bal.ingredient_id = i.id
       where i.restaurant_id = v_rest and (i.is_active or coalesce(bal.q, 0) <> 0))
    select jsonb_build_object(
      'as_of', p_as_of,
      'all_outlets', v_rb is null,
      'rows', coalesce((select jsonb_agg(jsonb_build_object('branch_id', r.branch_id, 'outlet_name', r.outlet_name, 'ingredient_id', r.ingredient_id,
                 'name', r.name, 'category', r.category, 'unit', r.unit, 'on_hand', r.on_hand, 'cost', r.cost, 'value', r.value,
                 'reorder_level', r.reorder_level, 'status', r.status) order by r.outlet_name, r.branch_id, r.name, r.ingredient_id) from r), '[]'::jsonb),
      'by_outlet', coalesce((select jsonb_agg(jsonb_build_object('branch_id', g.branch_id, 'outlet_name', g.outlet_name, 'value', g.value, 'items', g.items,
                 'low', g.low, 'out', g.out, 'negative', g.neg) order by g.outlet_name, g.branch_id)
                 from (select r.branch_id, r.outlet_name, coalesce(sum(r.value), 0) as value, count(*) as items,
                              count(*) filter (where r.status = 'low') as low, count(*) filter (where r.status = 'out') as out,
                              count(*) filter (where r.status = 'negative') as neg
                         from r group by r.branch_id, r.outlet_name) g), '[]'::jsonb),
      'totals', jsonb_build_object('value', coalesce((select sum(r.value) from r), 0), 'items', (select count(*) from r),
                 'low', (select count(*) from r where r.status = 'low'), 'out', (select count(*) from r where r.status = 'out'),
                 'negative', (select count(*) from r where r.status = 'negative')))
  );
end $$;

-- ---------------------------------------------------------------- 2. stock movement
create or replace function public.report_stock_movement(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return (
    with m as (
      select sm.id, sm.branch_id, sm.ingredient_id, sm.kind, sm.qty, sm.unit_cost, sm.business_date, sm.created_at, sm.reason, sm.note,
             sm.order_id, sm.created_by
        from public.stock_movements sm
       where sm.restaurant_id = v_rest and (v_rb is null or sm.branch_id = v_rb) and sm.business_date <= p_to),
    agg as (
      select m.branch_id, m.ingredient_id,
             coalesce(sum(m.qty) filter (where m.business_date < p_from), 0) as opening,
             coalesce(sum(m.qty) filter (where m.business_date >= p_from and m.kind = 'purchase'), 0) as purchased,
             coalesce(sum(m.qty) filter (where m.business_date >= p_from and m.kind = 'transfer_in'), 0) as transfer_in,
             -coalesce(sum(m.qty) filter (where m.business_date >= p_from and m.kind = 'transfer_out'), 0) as transfer_out,
             -coalesce(sum(m.qty) filter (where m.business_date >= p_from and m.kind in ('sale', 'returned')), 0) as used,
             -coalesce(sum(m.qty) filter (where m.business_date >= p_from and m.kind = 'wastage'), 0) as wasted,
             coalesce(sum(m.qty) filter (where m.business_date >= p_from and m.kind = 'adjust'), 0) as adjusted,
             coalesce(sum(m.qty) filter (where m.business_date >= p_from and m.kind = 'count'), 0) as counted,
             coalesce(sum(m.qty), 0) as closing,
             count(*) filter (where m.business_date >= p_from) as n_in
        from m group by m.branch_id, m.ingredient_id),
    rows_ as (
      select a.*, coalesce(b.name, 'Unknown outlet') as outlet_name, i.name, i.unit
        from agg a
        join public.ingredients i on i.id = a.ingredient_id
        left join public.branches b on b.id = a.branch_id
       where a.opening <> 0 or a.n_in > 0),
    d as (
      select m.* from m where m.business_date >= p_from),
    capped as (select d.* from d order by d.created_at desc, d.id desc limit 2000),
    det as (
      select c.*, coalesce(b.name, 'Unknown outlet') as outlet_name, i.name, i.unit, o.bill_number, u.full_name as user_name
        from capped c
        join public.ingredients i on i.id = c.ingredient_id
        left join public.branches b on b.id = c.branch_id
        left join public.orders o on o.id = c.order_id
        left join public.users u on u.id = c.created_by),
    val as (
      select d.branch_id,
             coalesce(sum(d.qty * d.unit_cost) filter (where d.kind = 'purchase'), 0) as purchased_value,
             -coalesce(sum(d.qty * d.unit_cost) filter (where d.kind in ('sale', 'returned')), 0) as used_value,
             -coalesce(sum(d.qty * d.unit_cost) filter (where d.kind = 'wastage'), 0) as wasted_value,
             coalesce(sum(d.qty * d.unit_cost) filter (where d.kind = 'adjust'), 0) as adjusted_value,
             coalesce(sum(d.qty * d.unit_cost) filter (where d.kind = 'count'), 0) as counted_value
        from d group by d.branch_id)
    select jsonb_build_object(
      'all_outlets', v_rb is null,
      'rows', coalesce((select jsonb_agg(jsonb_build_object('branch_id', r.branch_id, 'outlet_name', r.outlet_name, 'ingredient_id', r.ingredient_id,
                 'name', r.name, 'unit', r.unit, 'opening', r.opening, 'purchased', r.purchased, 'transfer_in', r.transfer_in,
                 'transfer_out', r.transfer_out, 'used', r.used, 'wasted', r.wasted, 'adjusted', r.adjusted, 'counted', r.counted,
                 'closing', r.closing) order by r.outlet_name, r.branch_id, r.name, r.ingredient_id) from rows_ r), '[]'::jsonb),
      'details', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'business_date', x.business_date, 'at', x.created_at, 'kind', x.kind,
                 'qty', x.qty, 'unit_cost', x.unit_cost, 'value', case when x.unit_cost is not null then round(x.qty * x.unit_cost, 2) end,
                 'reason', x.reason, 'note', x.note, 'bill_number', x.bill_number, 'user_name', x.user_name, 'branch_id', x.branch_id,
                 'outlet_name', x.outlet_name, 'ingredient_id', x.ingredient_id, 'name', x.name, 'unit', x.unit)
                 order by x.created_at desc, x.id desc) from det x), '[]'::jsonb),
      'truncated', (select count(*) from d) > 2000,
      'row_limit', 2000,
      'total_rows', (select count(*) from d),
      'by_outlet', coalesce((select jsonb_agg(jsonb_build_object('branch_id', v.branch_id, 'outlet_name', coalesce(b.name, 'Unknown outlet'),
                 'purchased_value', round(v.purchased_value, 2), 'used_value', round(v.used_value, 2), 'wasted_value', round(v.wasted_value, 2),
                 'adjusted_value', round(v.adjusted_value, 2), 'counted_value', round(v.counted_value, 2))
                 order by coalesce(b.name, 'Unknown outlet'), v.branch_id)
                 from val v left join public.branches b on b.id = v.branch_id), '[]'::jsonb),
      'totals', jsonb_build_object('rows', (select count(*) from rows_), 'movements', (select count(*) from d),
                 'purchased_value', round(coalesce((select sum(v.purchased_value) from val v), 0), 2),
                 'used_value', round(coalesce((select sum(v.used_value) from val v), 0), 2),
                 'wasted_value', round(coalesce((select sum(v.wasted_value) from val v), 0), 2),
                 'adjusted_value', round(coalesce((select sum(v.adjusted_value) from val v), 0), 2),
                 'counted_value', round(coalesce((select sum(v.counted_value) from val v), 0), 2)))
  );
end $$;

-- ---------------------------------------------------------------- 3. food cost
create or replace function public.report_food_cost(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_permission('report.view_sales');
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return (
    with its as (
      select oi.id, oi.product_id, oi.product_name, oi.quantity, coalesce(oi.net_amount, 0) as net, o.business_date, o.branch_id
        from public.order_items oi
        join public.orders o on o.id = oi.order_id
       where o.restaurant_id = v_rest and (v_rb is null or o.branch_id = v_rb)
         and o.business_date between p_from and p_to
         and o.status <> 'voided' and o.merged_into is null
         and oi.cancelled_at is null),
    mv as (
      select sm.order_item_id, -sum(sm.qty * coalesce(sm.unit_cost, 0)) as cost, bool_or(sm.kind = 'sale') as has_sale
        from public.stock_movements sm
       where sm.restaurant_id = v_rest and sm.kind in ('sale', 'returned')
         and sm.order_item_id in (select its.id from its)
       group by sm.order_item_id),
    x as (
      select its.*, coalesce(mv.has_sale, false) as covered, case when coalesce(mv.has_sale, false) then mv.cost end as cost
        from its left join mv on mv.order_item_id = its.id),
    dsh as (
      select x.product_id, coalesce(max(p.name), max(x.product_name)) as name, sum(x.quantity) as qty_sold, sum(x.net) as net_sales,
             coalesce(sum(x.net) filter (where x.covered), 0) as covered_sales, sum(x.cost) as cost, bool_or(x.covered) as has_recipe
        from x left join public.products p on p.id = x.product_id
       group by x.product_id),
    dy as (
      select x.business_date, sum(x.net) as net_all, coalesce(sum(x.net) filter (where x.covered), 0) as net_cov, sum(x.cost) as cost
        from x group by x.business_date),
    ou as (
      select x.branch_id, coalesce(b.name, 'Unknown outlet') as outlet_name, sum(x.net) as net_all,
             coalesce(sum(x.net) filter (where x.covered), 0) as net_cov, sum(x.cost) as cost
        from x left join public.branches b on b.id = x.branch_id group by x.branch_id, b.name),
    w as (
      select coalesce(sum(-sm.qty * coalesce(sm.unit_cost, 0)), 0) as v
        from public.stock_movements sm
       where sm.restaurant_id = v_rest and (v_rb is null or sm.branch_id = v_rb) and sm.kind = 'wastage'
         and sm.business_date between p_from and p_to)
    select jsonb_build_object(
      'all_outlets', v_rb is null,
      'by_day', coalesce((select jsonb_agg(jsonb_build_object('business_date', d.business_date, 'net_sales_all', round(d.net_all, 2),
                 'net_sales_covered', round(d.net_cov, 2), 'cost', round(d.cost, 2),
                 'cost_pct', case when d.net_cov > 0 and d.cost is not null then round(100 * d.cost / d.net_cov, 1) end) order by d.business_date) from dy d), '[]'::jsonb),
      'by_dish', coalesce((select jsonb_agg(jsonb_build_object('product_id', s.product_id, 'name', s.name, 'qty_sold', s.qty_sold,
                 'net_sales', round(s.net_sales, 2), 'cost', case when s.has_recipe then round(s.cost, 2) end,
                 'cost_pct', case when s.has_recipe and s.covered_sales > 0 then round(100 * s.cost / s.covered_sales, 1) end,
                 'margin', case when s.has_recipe then round(s.covered_sales - s.cost, 2) end, 'has_recipe', s.has_recipe)
                 order by s.net_sales desc, s.name, s.product_id) from dsh s), '[]'::jsonb),
      'by_outlet', coalesce((select jsonb_agg(jsonb_build_object('branch_id', o.branch_id, 'outlet_name', o.outlet_name, 'net_sales_all', round(o.net_all, 2),
                 'net_sales_covered', round(o.net_cov, 2), 'cost', round(o.cost, 2),
                 'cost_pct', case when o.net_cov > 0 and o.cost is not null then round(100 * o.cost / o.net_cov, 1) end)
                 order by o.outlet_name, o.branch_id) from ou o), '[]'::jsonb),
      'totals', jsonb_build_object(
         'net_sales_all', round(coalesce((select sum(x.net) from x), 0), 2),
         'net_sales_covered', round(coalesce((select sum(x.net) from x where x.covered), 0), 2),
         'coverage_pct', case when coalesce((select sum(x.net) from x), 0) > 0
                              then round(100 * coalesce((select sum(x.net) from x where x.covered), 0) / (select sum(x.net) from x), 1) end,
         'cost', round(coalesce((select sum(x.cost) from x), 0), 2),
         'cost_pct', case when coalesce((select sum(x.net) from x where x.covered), 0) > 0
                          then round(100 * coalesce((select sum(x.cost) from x), 0) / (select sum(x.net) from x where x.covered), 1) end,
         'wastage_cost', round((select w.v from w), 2)))
  );
end $$;

-- ---------------------------------------------------------------- 4. wastage
create or replace function public.report_wastage(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return (
    with w as (
      select sm.id, sm.branch_id, sm.ingredient_id, -sm.qty as qty, sm.unit_cost, round(-sm.qty * coalesce(sm.unit_cost, 0), 2) as value,
             coalesce(sm.reason, 'other') as reason, sm.note, sm.business_date, sm.created_at, sm.created_by
        from public.stock_movements sm
       where sm.restaurant_id = v_rest and (v_rb is null or sm.branch_id = v_rb) and sm.kind = 'wastage'
         and sm.business_date between p_from and p_to),
    capped as (select w.* from w order by w.created_at desc, w.id desc limit 2000),
    r as (
      select c.*, coalesce(b.name, 'Unknown outlet') as outlet_name, i.name, i.unit, u.full_name as user_name
        from capped c
        join public.ingredients i on i.id = c.ingredient_id
        left join public.branches b on b.id = c.branch_id
        left join public.users u on u.id = c.created_by)
    select jsonb_build_object(
      'all_outlets', v_rb is null,
      'by_reason', coalesce((select jsonb_agg(jsonb_build_object('reason', g.reason, 'lines', g.n, 'value', g.v) order by g.v desc, g.reason)
                 from (select w.reason, count(*) as n, sum(w.value) as v from w group by w.reason) g), '[]'::jsonb),
      'by_ingredient', coalesce((select jsonb_agg(jsonb_build_object('ingredient_id', g.ingredient_id, 'name', g.name, 'unit', g.unit, 'qty', g.q, 'value', g.v)
                 order by g.v desc, g.name, g.ingredient_id)
                 from (select w.ingredient_id, i.name, i.unit, sum(w.qty) as q, sum(w.value) as v
                         from w join public.ingredients i on i.id = w.ingredient_id group by w.ingredient_id, i.name, i.unit) g), '[]'::jsonb),
      'by_day', coalesce((select jsonb_agg(jsonb_build_object('business_date', g.business_date, 'lines', g.n, 'value', g.v) order by g.business_date)
                 from (select w.business_date, count(*) as n, sum(w.value) as v from w group by w.business_date) g), '[]'::jsonb),
      'by_user', coalesce((select jsonb_agg(jsonb_build_object('user_id', g.created_by, 'user_name', coalesce(g.user_name, 'Unknown'), 'lines', g.n, 'value', g.v)
                 order by g.v desc, g.user_name, g.created_by)
                 from (select w.created_by, u.full_name as user_name, count(*) as n, sum(w.value) as v
                         from w left join public.users u on u.id = w.created_by group by w.created_by, u.full_name) g), '[]'::jsonb),
      'by_outlet', coalesce((select jsonb_agg(jsonb_build_object('branch_id', g.branch_id, 'outlet_name', g.outlet_name, 'lines', g.n, 'value', g.v)
                 order by g.outlet_name, g.branch_id)
                 from (select w.branch_id, coalesce(b.name, 'Unknown outlet') as outlet_name, count(*) as n, sum(w.value) as v
                         from w left join public.branches b on b.id = w.branch_id group by w.branch_id, b.name) g), '[]'::jsonb),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'business_date', r.business_date, 'at', r.created_at, 'branch_id', r.branch_id,
                 'outlet_name', r.outlet_name, 'ingredient_id', r.ingredient_id, 'name', r.name, 'unit', r.unit, 'qty', r.qty,
                 'unit_cost', r.unit_cost, 'value', r.value, 'reason', r.reason, 'note', r.note, 'user_name', r.user_name)
                 order by r.created_at desc, r.id desc) from r), '[]'::jsonb),
      'truncated', (select count(*) from w) > 2000,
      'row_limit', 2000,
      'total_rows', (select count(*) from w),
      'totals', jsonb_build_object('lines', (select count(*) from w), 'value', coalesce((select sum(w.value) from w), 0)))
  );
end $$;

revoke all on function public.report_stock_on_hand(date), public.report_stock_movement(date,date), public.report_food_cost(date,date),
  public.report_wastage(date,date) from public, anon;
grant execute on function public.report_stock_on_hand(date), public.report_stock_movement(date,date), public.report_food_cost(date,date),
  public.report_wastage(date,date) to authenticated;
