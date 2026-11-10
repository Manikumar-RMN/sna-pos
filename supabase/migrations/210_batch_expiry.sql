-- Batch number and expiry date per received line, and an expiry report.
-- Stock that is still on hand is assumed to be the newest deliveries (first in, first out),
-- so the report needs no change to how stock leaves the shelf.
alter table public.goods_receipt_lines add column if not exists batch_no text, add column if not exists expiry_date date;
create index if not exists goods_receipt_lines_expiry on public.goods_receipt_lines (restaurant_id, expiry_date) where expiry_date is not null;

do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid,date,text,boolean)'::regprocedure); o := d;
  d := replace(d, 'v_all numeric := 0;' || E'\nbegin', 'v_all numeric := 0; v_batch text; v_exp date;' || E'\nbegin');
  d := replace(d, E'    v_rate := coalesce(v_rate, 0);\n',
    E'    v_rate := coalesce(v_rate, 0);\n    select nullif(left(trim(coalesce(e->>''batch_no'', '''')), 40), ''''), nullif(trim(coalesce(e->>''expiry_date'', '''')), '''')::date into v_batch, v_exp from jsonb_array_elements(p_lines) e where (e->>''ingredient_id'')::uuid = l.ingredient_id limit 1;\n    if v_exp is not null and v_exp < v_today then raise exception ''The expiry date of % is before the delivery date.'', (select name from public.ingredients where id = l.ingredient_id); end if;\n');
  d := replace(d, 'prev_cost, new_cost, tax_rate, tax_amount, tax_claimable)', 'prev_cost, new_cost, tax_rate, tax_amount, tax_claimable, batch_no, expiry_date)');
  d := replace(d, 'v_prev_cost, v_new_cost, v_rate, v_ltax, v_ok and v_ltax > 0);', 'v_prev_cost, v_new_cost, v_rate, v_ltax, v_ok and v_ltax > 0, v_batch, v_exp);');
  if d = o or position('v_batch, v_exp);' in d) = 0 or position('v_batch text; v_exp date;' in d) = 0 or position('batch_no, expiry_date)' in d) = 0 or position('before the delivery date' in d) = 0 then raise exception 'receive_goods patch anchors changed'; end if;
  execute d;
end $$;
revoke all on function public.receive_goods(uuid, jsonb, uuid, text, date, numeric, numeric, date, text, jsonb, uuid, date, text, boolean) from public, anon;
grant execute on function public.receive_goods(uuid, jsonb, uuid, text, date, numeric, numeric, date, text, jsonb, uuid, date, text, boolean) to authenticated;

create or replace function public.expiry_report(p_days int default 30) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_branch uuid; v_today date; v_items jsonb; v_days int := greatest(0, least(coalesce(p_days, 30), 365));
begin
  perform app.require_feature('stock');
  perform app.require_permission('stock.manage');
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;
  select coalesce(jsonb_agg(x order by (x->>'expiry_date'), (x->>'ingredient')), '[]'::jsonb) into v_items from (
    select jsonb_build_object('ingredient', b.name, 'unit', b.unit, 'batch_no', b.batch_no, 'expiry_date', b.expiry_date,
             'received_on', b.received_on, 'receipt', b.number, 'remaining', b.remaining,
             'value', round(b.remaining * b.unit_cost, 2), 'days_left', b.expiry_date - v_today,
             'status', case when b.expiry_date < v_today then 'expired' when b.expiry_date - v_today <= v_days then 'soon' else 'ok' end) x
    from (
      select i.name, i.unit, l.batch_no, l.expiry_date, g.received_on, g.number, l.unit_cost,
             least(l.qty - l.returned_qty,
                   greatest(0, coalesce(oh.on_hand, 0) - coalesce(sum(l.qty - l.returned_qty) over (
                     partition by l.ingredient_id order by g.received_on desc, g.created_at desc, l.id desc
                     rows between unbounded preceding and 1 preceding), 0))) remaining
        from public.goods_receipt_lines l
        join public.goods_receipts g on g.id = l.goods_receipt_id
        join public.ingredients i on i.id = l.ingredient_id
        left join lateral (select sum(m.qty) on_hand from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = l.ingredient_id) oh on true
       where g.restaurant_id = v_rest and g.branch_id = v_branch and g.status = 'received') b
    where b.expiry_date is not null and b.remaining > 0.0005) z;
  return jsonb_build_object('today', v_today, 'days', v_days, 'items', v_items);
end $$;
revoke all on function public.expiry_report(int) from public, anon;
grant execute on function public.expiry_report(int) to authenticated;
