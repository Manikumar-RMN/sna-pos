-- Purchase and inventory gaps from the full review (group 3):
--   1. HSN code on items and on each received line.
--   2. Input tax report by rate and HSN, split CGST / SGST / IGST by the state in the GSTINs.
--   3. Supplier statement (running balance) and supplier ageing.
--   4. Optional rule: do not issue stock to a department while expired stock is on hand.

-- 1. HSN code.
alter table public.ingredients add column if not exists hsn_code text;
alter table public.goods_receipt_lines add column if not exists hsn_code text;
alter table public.ingredients drop constraint if exists ingredients_hsn_code_check;
alter table public.ingredients add constraint ingredients_hsn_code_check check (hsn_code is null or hsn_code ~ '^[0-9]{4,8}$');
grant select (hsn_code) on public.ingredients to authenticated, sna_pos_agent;

create or replace function public.set_ingredient_hsn(p_id uuid, p_hsn text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id();
        v_h text := nullif(regexp_replace(coalesce(p_hsn, ''), '\s', '', 'g'), '');
begin
  perform app.require_feature('stock');
  if v_h is not null and v_h !~ '^[0-9]{4,8}$' then raise exception 'The HSN code is 4 to 8 digits.'; end if;
  update public.ingredients set hsn_code = v_h where id = p_id and restaurant_id = v_rest;
  if not found then raise exception 'Item not found.'; end if;
  perform app.audit('stock.hsn', 'ingredients', p_id, jsonb_build_object('hsn', v_h));
end $$;
revoke all on function public.set_ingredient_hsn(uuid, text) from public, anon;
grant execute on function public.set_ingredient_hsn(uuid, text) to authenticated;

-- A received line keeps the item's HSN as it was on the day.
do $$
declare d text; a text := 'tax_claimable, batch_no, expiry_date)'; b text := 'v_ok and v_ltax > 0, v_batch, v_exp);';
begin
  d := pg_get_functiondef('public.receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid,date,text,boolean)'::regprocedure);
  if position('hsn_code' in d) > 0 then return; end if;
  if position(a in d) = 0 or position(b in d) = 0 then raise exception 'receive_goods text did not match; nothing changed'; end if;
  d := replace(d, a, 'tax_claimable, batch_no, expiry_date, hsn_code)');
  d := replace(d, b, 'v_ok and v_ltax > 0, v_batch, v_exp, (select i.hsn_code from public.ingredients i where i.id = l.ingredient_id));');
  execute d;
end $$;

-- 2. Input tax report. Net of goods sent back. CGST + SGST when the supplier's GSTIN state is the restaurant's own state, IGST when it is
--    another state, "unknown" when either GSTIN is missing or not in the 15-character form.
create or replace function public.report_input_tax(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_own text;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  select left(upper(regexp_replace(coalesce(tax_registration_no, ''), '\s', '', 'g')), 2) into v_own from public.restaurants where id = v_rest;
  return (
    with d as (
      select l.tax_rate as rate, coalesce(nullif(l.hsn_code, ''), nullif(i.hsn_code, ''), '') as hsn, coalesce(l.tax_claimable, false) as claimable,
             case when v_own ~ '^[0-9]{2}$' and left(upper(regexp_replace(coalesce(s.tax_no, ''), '\s', '', 'g')), 2) ~ '^[0-9]{2}$'
                  then (case when v_own = left(upper(regexp_replace(s.tax_no, '\s', '', 'g')), 2) then 'intra' else 'inter' end) else 'unknown' end as kind,
             l.line_total * (l.qty - l.returned_qty) / l.qty as taxable,
             l.tax_amount * (l.qty - l.returned_qty) / l.qty as tax
        from public.goods_receipt_lines l
        join public.goods_receipts g on g.id = l.goods_receipt_id
        join public.suppliers s on s.id = g.supplier_id
        join public.ingredients i on i.id = l.ingredient_id
       where g.restaurant_id = v_rest and (v_rb is null or g.branch_id = v_rb) and g.received_on between p_from and p_to
         and g.status <> 'cancelled' and l.tax_rate > 0 and l.qty > 0),
    per as (select rate, hsn, claimable, kind, sum(taxable) as taxable, sum(tax) as tax from d group by rate, hsn, claimable, kind)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object('rate', rate, 'hsn', hsn, 'claimable', claimable, 'kind', kind,
                'taxable', round(taxable, 2), 'tax', round(tax, 2),
                'cgst', case when kind = 'intra' then round(tax / 2, 2) else 0 end, 'sgst', case when kind = 'intra' then round(tax / 2, 2) else 0 end,
                'igst', case when kind = 'inter' then round(tax, 2) else 0 end) order by rate, hsn, kind, claimable) from per), '[]'::jsonb),
      'totals', jsonb_build_object(
        'taxable', coalesce((select round(sum(taxable), 2) from per), 0), 'tax', coalesce((select round(sum(tax), 2) from per), 0),
        'claimable', coalesce((select round(sum(tax) filter (where claimable), 2) from per), 0),
        'cgst', coalesce((select round(sum(tax / 2) filter (where kind = 'intra'), 2) from per), 0),
        'sgst', coalesce((select round(sum(tax / 2) filter (where kind = 'intra'), 2) from per), 0),
        'igst', coalesce((select round(sum(tax) filter (where kind = 'inter'), 2) from per), 0),
        'unsplit', coalesce((select round(sum(tax) filter (where kind = 'unknown'), 2) from per), 0)),
      'typed_tax', (select coalesce(round(sum(g.tax_amount - coalesce((select sum(l.tax_amount) from public.goods_receipt_lines l where l.goods_receipt_id = g.id), 0)), 2), 0)
                      from public.goods_receipts g where g.restaurant_id = v_rest and (v_rb is null or g.branch_id = v_rb) and g.received_on between p_from and p_to and g.status <> 'cancelled'),
      'own_state', nullif(v_own, ''))
  );
end $$;

-- 3a. Supplier statement: bills, goods returned, payments (and undone payments), refunds received, with a running balance owed.
create or replace function public.report_supplier_statement(p_supplier uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; sup public.suppliers%rowtype; v_open numeric(14,2);
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  select * into sup from public.suppliers where id = p_supplier and restaurant_id = v_rest;
  if not found then raise exception 'Choose a supplier.'; end if;
  return (
    with e as (
      select g.received_on as day, g.created_at as at, 'Bill'::text as kind, g.number || coalesce(' · bill ' || nullif(g.supplier_bill_no, ''), '') as ref, (g.total + g.returned_total) as amt
        from public.goods_receipts g where g.restaurant_id = v_rest and (v_rb is null or g.branch_id = v_rb) and g.supplier_id = sup.id and g.status <> 'cancelled'
      union all
      select r.returned_on, r.created_at, 'Goods returned', r.number || ' · ' || g.number, -r.total
        from public.goods_returns r join public.goods_receipts g on g.id = r.goods_receipt_id
       where r.restaurant_id = v_rest and (v_rb is null or r.branch_id = v_rb) and r.supplier_id = sup.id and g.status <> 'cancelled'
      union all
      select p.paid_on, p.created_at, case when p.reverses_id is null then 'Payment' else 'Payment undone' end,
             g.number || ' · ' || p.method || coalesce(' · ' || nullif(p.reference, ''), ''), -p.amount
        from public.supplier_payments p join public.goods_receipts g on g.id = p.goods_receipt_id
       where p.restaurant_id = v_rest and (v_rb is null or p.branch_id = v_rb) and p.supplier_id = sup.id and g.status <> 'cancelled'
      union all
      select f.received_on, f.created_at, 'Refund received', g.number || ' · ' || f.method || coalesce(' · ' || nullif(f.reference, ''), ''), f.amount
        from public.supplier_refunds f join public.goods_receipts g on g.id = f.goods_receipt_id
       where f.restaurant_id = v_rest and (v_rb is null or f.branch_id = v_rb) and f.supplier_id = sup.id and g.status <> 'cancelled'),
    o as (select coalesce(sum(amt), 0) as v from e where day < p_from),
    r as (select day, at, kind, ref, amt, sum(amt) over (order by day, at, ref rows between unbounded preceding and current row) as run from e where day between p_from and p_to)
    select jsonb_build_object(
      'supplier', jsonb_build_object('name', sup.name, 'tax_no', sup.tax_no, 'phone', sup.phone, 'payment_days', sup.payment_days),
      'opening', (select round(v, 2) from o),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'kind', kind, 'ref', ref,
                'debit', case when amt > 0 then round(amt, 2) else 0 end, 'credit', case when amt < 0 then round(-amt, 2) else 0 end,
                'balance', round((select v from o) + run, 2)) order by day, at, ref) from r), '[]'::jsonb),
      'closing', (select round(v + coalesce((select sum(amt) from r), 0), 2) from o))
  );
end $$;

-- 3b. Supplier ageing: what is owed, in how many days past the due date. A supplier we have overpaid shows as "advance".
create or replace function public.report_supplier_ageing(p_asof date default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_asof date;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  v_asof := coalesce(p_asof, (now() at time zone coalesce((select timezone from public.restaurants where id = v_rest), 'UTC'))::date);
  return (
    with b as (
      select s.id as sid, s.name as supplier, g.total - g.paid_total as owed, g.refund_due,
             v_asof - coalesce(g.due_on, g.received_on) as late
        from public.goods_receipts g join public.suppliers s on s.id = g.supplier_id
       where g.restaurant_id = v_rest and (v_rb is null or g.branch_id = v_rb) and g.status <> 'cancelled' and g.received_on <= v_asof
         and (g.total - g.paid_total > 0 or g.refund_due > 0)),
    per as (
      select sid, supplier,
             coalesce(sum(owed) filter (where owed > 0 and late <= 0), 0) as not_due,
             coalesce(sum(owed) filter (where owed > 0 and late between 1 and 30), 0) as d30,
             coalesce(sum(owed) filter (where owed > 0 and late between 31 and 60), 0) as d60,
             coalesce(sum(owed) filter (where owed > 0 and late between 61 and 90), 0) as d90,
             coalesce(sum(owed) filter (where owed > 0 and late > 90), 0) as d90p,
             coalesce(sum(owed) filter (where owed > 0), 0) as owed,
             coalesce(sum(refund_due), 0) as advance
        from b group by sid, supplier)
    select jsonb_build_object(
      'asof', v_asof,
      'rows', coalesce((select jsonb_agg(jsonb_build_object('supplier', supplier, 'not_due', round(not_due, 2), 'd30', round(d30, 2), 'd60', round(d60, 2), 'd90', round(d90, 2), 'd90p', round(d90p, 2),
                'owed', round(owed, 2), 'advance', round(advance, 2)) order by owed desc, supplier) from per), '[]'::jsonb),
      'totals', jsonb_build_object('not_due', coalesce((select round(sum(not_due), 2) from per), 0), 'd30', coalesce((select round(sum(d30), 2) from per), 0),
                'd60', coalesce((select round(sum(d60), 2) from per), 0), 'd90', coalesce((select round(sum(d90), 2) from per), 0), 'd90p', coalesce((select round(sum(d90p), 2) from per), 0),
                'owed', coalesce((select round(sum(owed), 2) from per), 0), 'advance', coalesce((select round(sum(advance), 2) from per), 0)))
  );
end $$;

do $$ declare f text; begin
  foreach f in array array['report_input_tax(date,date)', 'report_supplier_statement(uuid,date,date)', 'report_supplier_ageing(date)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

-- 4. Optional rule: no issuing stock to a department while expired stock of that item is on hand.
--    Off by default: the batch picture is worked out from the receipts (newest stock is assumed to be what is left), so the owner opts in.
alter table public.purchase_settings add column if not exists block_expired_issue boolean not null default false;

create or replace function app.expired_qty(p_branch uuid, p_ingredient uuid, p_asof date) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(b.remaining), 0) from (
    select l.expiry_date,
           least(l.qty - l.returned_qty,
                 greatest(0, coalesce(oh.on_hand, 0) - coalesce(sum(l.qty - l.returned_qty) over (
                   partition by l.ingredient_id order by g.received_on desc, g.created_at desc, l.id desc
                   rows between unbounded preceding and 1 preceding), 0))) as remaining
      from public.goods_receipt_lines l
      join public.goods_receipts g on g.id = l.goods_receipt_id
      left join lateral (select sum(m.qty) as on_hand from public.stock_movements m where m.branch_id = p_branch and m.ingredient_id = l.ingredient_id) oh on true
     where g.branch_id = p_branch and g.status = 'received' and l.ingredient_id = p_ingredient) b
  where b.expiry_date is not null and b.expiry_date < p_asof and b.remaining > 0.0005;
$$;
revoke all on function app.expired_qty(uuid, uuid, date) from public, anon, authenticated;

create or replace function public.set_block_expired_issue(p_on boolean) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id();
begin
  insert into public.purchase_settings (restaurant_id, block_expired_issue, updated_by) values (v_rest, coalesce(p_on, false), v_user)
  on conflict (restaurant_id) do update set block_expired_issue = excluded.block_expired_issue, updated_at = now(), updated_by = v_user;
  perform app.audit('purchase.rules', 'purchase_settings', v_rest, jsonb_build_object('block_expired_issue', coalesce(p_on, false)));
  return coalesce(p_on, false);
end $$;
revoke all on function public.set_block_expired_issue(boolean) from public, anon;
grant execute on function public.set_block_expired_issue(boolean) to authenticated;

do $$
declare d text; a text := E'if not found then raise exception ''An ingredient on the list no longer exists.''; end if;';
begin
  d := pg_get_functiondef('public.issue_material(uuid,text,jsonb,text,uuid,date)'::regprocedure);
  if position('expired_qty' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception 'issue_material text did not match; nothing changed'; end if;
  d := replace(d, a, a || E'\n    if coalesce((select ps.block_expired_issue from public.purchase_settings ps where ps.restaurant_id = v_rest), false) and app.expired_qty(v_branch, x.ingredient_id, v_today) > 0 then\n      raise exception ''% has expired stock on hand. Write the expired stock off first (Stock, Wastage), then issue.'', v_name;\n    end if;');
  execute d;
end $$;
