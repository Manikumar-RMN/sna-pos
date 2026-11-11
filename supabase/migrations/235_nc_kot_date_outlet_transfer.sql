-- Winsar parity, Options menu: "NoCharge KOT to KOT" (undo_complimentary), "KOT Date Transfer" (kot_date_transfer)
-- and "KOT Table Transfer other outlet" (order_outlet_transfer). All three are manager-only, need a reason, work only on a
-- bill with no payment, and write an audit row. Rollback: 235_nc_kot_date_outlet_transfer_rollback.sql drops all three.

-- 1. NoCharge KOT back to a normal KOT: takes the complimentary / staff-meal mark off an unpaid bill and charges it again.
create or replace function public.undo_complimentary(p_order_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; p jsonb; v_c jsonb; v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 200), '');
begin
  perform app.require_feature('pos');
  if v_reason is null or length(v_reason) < 3 then raise exception 'Write a short reason for charging this bill again.'; end if;
  if not app.allowed('order.discount') then
    raise exception 'A manager must approve taking the no-charge mark off a bill (order.discount).';
  end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.comp_kind is null then raise exception 'Bill % is not a no-charge bill.', o.bill_number; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if coalesce(o.paid_total, 0) <> 0 or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment on it.', o.bill_number;
  end if;
  if exists (select 1 from public.business_days d
              where d.branch_id = o.branch_id and d.business_date = o.business_date and d.status = 'closed') then
    raise exception 'The day of bill % is closed. Use a credit note instead.', o.bill_number;
  end if;

  p := coalesce(o.calc_params, '{}'::jsonb);
  perform set_config('app.recalc', 'on', true);
  -- The whole-bill discount that made it free goes; the service charge goes back to the outlet's own setting.
  update public.orders set calc_params = (p - 'discount') - 'sc_percent' where id = o.id;
  v_c := app.recalc_order(o.id);
  delete from public.order_discounts where order_id = o.id and discount_type = 'fixed_amount';
  update public.orders set payment_status = 'unpaid', paid_total = 0, comp_kind = null, comp_reason = null, comp_by = null
   where id = o.id;

  perform app.audit('order.uncomplimentary', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'reason', v_reason, 'grand_total', (v_c->>'grand_total')::numeric, 'by', v_user),
    jsonb_build_object('kind', o.comp_kind, 'comp_reason', o.comp_reason, 'grand_total', o.grand_total));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'grand_total', (v_c->>'grand_total')::numeric);
end $function$;

revoke all on function public.undo_complimentary(uuid, text) from public, anon;
grant execute on function public.undo_complimentary(uuid, text) to authenticated;

-- 2. KOT Date Transfer: the bill counts towards another business day. Only an unpaid bill, only a day that is not closed,
-- and only within seven days either way, so a bill cannot be pushed into a finished month.
create or replace function public.kot_date_transfer(p_order_id uuid, p_business_date date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('order.void');
  o public.orders%rowtype; v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 200), '');
begin
  perform app.require_feature('pos');
  if v_reason is null or length(v_reason) < 3 then raise exception 'Write a short reason for the date change.'; end if;
  if p_business_date is null then raise exception 'Choose the date.'; end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or coalesce(o.paid_total, 0) <> 0 then
    raise exception 'Bill % already has a payment, so its date cannot be moved.', o.bill_number;
  end if;
  if o.business_date is null then raise exception 'Bill % has no business day yet.', o.bill_number; end if;
  if p_business_date = o.business_date then raise exception 'Bill % is already on %.', o.bill_number, p_business_date; end if;
  if abs(p_business_date - o.business_date) > 7 then
    raise exception 'The new date must be within seven days of %.', o.business_date;
  end if;
  if exists (select 1 from public.business_days d
              where d.branch_id = o.branch_id and d.business_date in (o.business_date, p_business_date) and d.status = 'closed') then
    raise exception 'One of those days is already closed, so the bill cannot be moved.';
  end if;

  perform set_config('app.recalc', 'on', true);
  update public.orders set business_date = p_business_date where id = o.id;

  perform app.audit('order.date_transfer', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'business_date', p_business_date, 'reason', v_reason, 'by', v_user),
    jsonb_build_object('business_date', o.business_date));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'business_date', p_business_date);
end $function$;

revoke all on function public.kot_date_transfer(uuid, date, text) from public, anon;
grant execute on function public.kot_date_transfer(uuid, date, text) to authenticated;

-- 3. KOT Table Transfer to another outlet: an unpaid bill moves to another outlet of the same restaurant, onto a free table
-- there (or to its counter). The bill number does not change, so the bill keeps the series of the outlet that opened it.
create or replace function public.order_outlet_transfer(p_order_id uuid, p_branch_id uuid, p_table_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('order.void');
  o public.orders%rowtype; t public.dining_tables%rowtype; v_shift uuid; v_name text;
  v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 200), '');
begin
  perform app.require_feature('pos');
  if v_reason is null or length(v_reason) < 3 then raise exception 'Write a short reason for the outlet change.'; end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or coalesce(o.paid_total, 0) <> 0 then
    raise exception 'Bill % already has a payment, so it cannot be moved to another outlet.', o.bill_number;
  end if;
  if p_branch_id = o.branch_id then raise exception 'Bill % is already in that outlet.', o.bill_number; end if;
  select name into v_name from public.branches where id = p_branch_id and restaurant_id = o.restaurant_id;
  if v_name is null then raise exception 'That outlet was not found.'; end if;
  if exists (select 1 from public.business_days d where d.branch_id = p_branch_id and d.status = 'closed'
              and d.business_date = coalesce(o.business_date, current_date)) then
    raise exception 'The day is already closed in %.', v_name;
  end if;
  if p_table_id is not null then
    select * into t from public.dining_tables where id = p_table_id and restaurant_id = o.restaurant_id;
    if not found then raise exception 'That table was not found.'; end if;
    if t.branch_id <> p_branch_id then raise exception 'Table % is not in %.', t.table_number, v_name; end if;
    if exists (select 1 from public.orders x where x.dining_table_id = p_table_id and x.id <> o.id
                and x.payment_status in ('unpaid', 'partial') and x.status <> 'voided' and x.merged_into is null) then
      raise exception 'Table % in % already has an open bill.', t.table_number, v_name;
    end if;
  end if;
  select s.id into v_shift from public.shifts s where s.branch_id = p_branch_id and s.status = 'open' limit 1;

  perform set_config('app.recalc', 'on', true);
  update public.orders set branch_id = p_branch_id, dining_table_id = p_table_id, shift_id = v_shift where id = o.id;
  update public.kitchen_tickets set branch_id = p_branch_id where order_id = o.id;

  perform app.audit('order.outlet_transfer', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'branch_id', p_branch_id, 'outlet', v_name,
                       'dining_table_id', p_table_id, 'reason', v_reason, 'by', v_user),
    jsonb_build_object('branch_id', o.branch_id, 'dining_table_id', o.dining_table_id, 'shift_id', o.shift_id));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'outlet', v_name);
end $function$;

revoke all on function public.order_outlet_transfer(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.order_outlet_transfer(uuid, uuid, uuid, text) to authenticated;
