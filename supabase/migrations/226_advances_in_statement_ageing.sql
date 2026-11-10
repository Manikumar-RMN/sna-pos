-- Supplier statement and ageing now take advance money into account.
-- Statement: "Advance paid" lowers what is owed; "Advance used" cancels out the payment row
-- written when the advance is put on a bill, so the same money is never counted twice.
-- Ageing: the advance column is money the supplier is holding for us -- overpayment after
-- returns (refund_due) plus advances not yet used.
-- A payment made out of advance money cannot be undone from the payment list; it is taken
-- back off the bill from the Advances list, so no cash wrongly returns to the till.

create or replace function public.report_supplier_statement(p_supplier uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; sup public.suppliers%rowtype;
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
       where f.restaurant_id = v_rest and (v_rb is null or f.branch_id = v_rb) and f.supplier_id = sup.id and g.status <> 'cancelled'
      union all
      -- Money given in advance. It leaves the business now, so it lowers what is owed.
      select ad.paid_on, ad.created_at, 'Advance paid', ad.number || ' · ' || ad.method || coalesce(' · ' || nullif(ad.reference, ''), ''), -ad.amount
        from public.supplier_advances ad
       where ad.restaurant_id = v_rest and (v_rb is null or ad.branch_id = v_rb) and ad.supplier_id = sup.id
      union all
      select (ad.cancelled_at at time zone coalesce((select timezone from public.restaurants where id = v_rest), 'UTC'))::date, ad.cancelled_at,
             'Advance cancelled', ad.number, ad.amount
        from public.supplier_advances ad
       where ad.restaurant_id = v_rest and (v_rb is null or ad.branch_id = v_rb) and ad.supplier_id = sup.id
         and ad.status = 'cancelled' and ad.cancelled_at is not null
      union all
      -- Using an advance on a bill moves no money: this cancels out the payment row above it.
      select p.paid_on, p.created_at, case when p.reverses_id is null then 'Advance used' else 'Advance put back' end,
             ad.number || ' · ' || g.number, p.amount
        from public.supplier_payments p
        join public.supplier_advances ad on ad.id = p.supplier_advance_id
        join public.goods_receipts g on g.id = p.goods_receipt_id
       where p.restaurant_id = v_rest and (v_rb is null or p.branch_id = v_rb) and p.supplier_id = sup.id and g.status <> 'cancelled'),
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
    bills as (
      select sid, supplier,
             coalesce(sum(owed) filter (where owed > 0 and late <= 0), 0) as not_due,
             coalesce(sum(owed) filter (where owed > 0 and late between 1 and 30), 0) as d30,
             coalesce(sum(owed) filter (where owed > 0 and late between 31 and 60), 0) as d60,
             coalesce(sum(owed) filter (where owed > 0 and late between 61 and 90), 0) as d90,
             coalesce(sum(owed) filter (where owed > 0 and late > 90), 0) as d90p,
             coalesce(sum(owed) filter (where owed > 0), 0) as owed,
             coalesce(sum(refund_due), 0) as refund_due
        from b group by sid, supplier),
    -- Advances still unused on that day are money the supplier is holding for us.
    adv as (
      select s.id as sid, s.name as supplier, coalesce(sum(ad.amount - ad.applied_total), 0) as adv_left
        from public.supplier_advances ad join public.suppliers s on s.id = ad.supplier_id
       where ad.restaurant_id = v_rest and (v_rb is null or ad.branch_id = v_rb) and ad.status = 'open' and ad.paid_on <= v_asof
       group by s.id, s.name),
    per as (
      select coalesce(bills.sid, adv.sid) as sid, coalesce(bills.supplier, adv.supplier) as supplier,
             coalesce(bills.not_due, 0) as not_due, coalesce(bills.d30, 0) as d30, coalesce(bills.d60, 0) as d60,
             coalesce(bills.d90, 0) as d90, coalesce(bills.d90p, 0) as d90p, coalesce(bills.owed, 0) as owed,
             coalesce(bills.refund_due, 0) + coalesce(adv.adv_left, 0) as advance
        from bills full outer join adv on adv.sid = bills.sid
       where coalesce(bills.owed, 0) > 0 or coalesce(bills.refund_due, 0) > 0 or coalesce(adv.adv_left, 0) > 0)
    select jsonb_build_object(
      'asof', v_asof,
      'rows', coalesce((select jsonb_agg(jsonb_build_object('supplier', supplier, 'not_due', round(not_due, 2), 'd30', round(d30, 2), 'd60', round(d60, 2), 'd90', round(d90, 2), 'd90p', round(d90p, 2),
                'owed', round(owed, 2), 'advance', round(advance, 2)) order by owed desc, supplier) from per), '[]'::jsonb),
      'totals', jsonb_build_object('not_due', coalesce((select round(sum(not_due), 2) from per), 0), 'd30', coalesce((select round(sum(d30), 2) from per), 0),
                'd60', coalesce((select round(sum(d60), 2) from per), 0), 'd90', coalesce((select round(sum(d90), 2) from per), 0), 'd90p', coalesce((select round(sum(d90p), 2) from per), 0),
                'owed', coalesce((select round(sum(owed), 2) from per), 0), 'advance', coalesce((select round(sum(advance), 2) from per), 0)))
  );
end $$;

-- A payment made from advance money is taken back off the bill, not undone like a cash payment.
do $$
declare d text; n text;
  o text := '  if sp.reverses_id is not null then raise exception ''That entry is itself an undo; it cannot be undone.''; end if;';
  r text := '  if sp.supplier_advance_id is not null then raise exception ''That payment came from advance money. Take it back off the bill from the Advances list instead.''; end if;
  if sp.reverses_id is not null then raise exception ''That entry is itself an undo; it cannot be undone.''; end if;';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.proname='undo_supplier_payment';
  if position('supplier_advance_id' in d) > 0 then raise notice 'already patched'; return; end if;
  if position(o in d) = 0 then raise exception 'undo_supplier_payment: anchor did not match'; end if;
  n := replace(d, o, r);
  execute n;
end $$;
