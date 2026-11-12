-- Outlet transfer: the bill gets a business day that exists in the other outlet (it used to fail on orders_business_day_fk).
create or replace function public.order_outlet_transfer(p_order_id uuid, p_branch_id uuid, p_table_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('order.void');
  o public.orders%rowtype; t public.dining_tables%rowtype; v_shift uuid; v_name text; v_day date;
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
  -- The bill needs a business day in the other outlet: its own date if that outlet has that day open, otherwise that
  -- outlet's latest open day. A closed day, or an outlet with no open day, refuses the move.
  select d.business_date into v_day from public.business_days d
   where d.branch_id = p_branch_id and d.business_date = coalesce(o.business_date, current_date) and d.status = 'open';
  if v_day is null then
    if exists (select 1 from public.business_days d where d.branch_id = p_branch_id and d.status = 'closed'
                and d.business_date = coalesce(o.business_date, current_date)) then
      raise exception 'The day is already closed in %.', v_name;
    end if;
    select max(d.business_date) into v_day from public.business_days d where d.branch_id = p_branch_id and d.status = 'open';
    if v_day is null then raise exception '% has no open business day, so the bill cannot be moved there.', v_name; end if;
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
  update public.orders set branch_id = p_branch_id, dining_table_id = p_table_id, shift_id = v_shift, business_date = v_day where id = o.id;
  update public.kitchen_tickets set branch_id = p_branch_id where order_id = o.id;

  perform app.audit('order.outlet_transfer', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'branch_id', p_branch_id, 'outlet', v_name,
                       'dining_table_id', p_table_id, 'business_date', v_day, 'reason', v_reason, 'by', v_user),
    jsonb_build_object('branch_id', o.branch_id, 'dining_table_id', o.dining_table_id, 'shift_id', o.shift_id, 'business_date', o.business_date));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'outlet', v_name);
end $function$;

revoke all on function public.order_outlet_transfer(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.order_outlet_transfer(uuid, uuid, uuid, text) to authenticated;
