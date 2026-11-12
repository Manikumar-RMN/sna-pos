-- KOT date transfer: say plainly when the chosen day was never opened (it used to fail on a foreign key).
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
  if not exists (select 1 from public.business_days d where d.branch_id = o.branch_id and d.business_date = p_business_date) then
    raise exception 'The day % has not been opened for this outlet, so the bill cannot be moved there.', p_business_date;
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
