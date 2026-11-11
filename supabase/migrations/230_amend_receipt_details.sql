-- Correct a wrong supplier bill number, bill date or due date on a receipt.
-- Stock, cost and money are not touched; the old values go to the audit trail.
create or replace function public.amend_receipt_details(p_receipt uuid, p_bill_no text, p_bill_date date, p_due_on date, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  g public.goods_receipts%rowtype; v_no text := nullif(btrim(coalesce(p_bill_no, '')), ''); v_dup text; v_today date;
begin
  perform app.require_feature('stock');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for the correction.'; end if;
  select * into g from public.goods_receipts
   where id = p_receipt and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Receipt not found.'; end if;
  if g.status = 'cancelled' then raise exception 'Receipt % is cancelled and cannot be changed.', g.number; end if;
  v_today := (now() at time zone coalesce((select timezone from public.restaurants where id = g.restaurant_id), 'UTC'))::date;
  if p_bill_date is not null and p_bill_date > v_today then raise exception 'The bill date cannot be in the future.'; end if;
  if p_due_on is not null and p_bill_date is not null and p_due_on < p_bill_date then raise exception 'The due date cannot be before the bill date.'; end if;
  if v_no is not null then
    select x.number into v_dup from public.goods_receipts x
     where x.restaurant_id = g.restaurant_id and x.supplier_id = g.supplier_id and x.id <> g.id and x.status <> 'cancelled'
       and lower(btrim(x.supplier_bill_no)) = lower(v_no) limit 1;
    if v_dup is not null then raise exception 'Bill % from this supplier was already received as %.', v_no, v_dup; end if;
  end if;
  update public.goods_receipts set supplier_bill_no = v_no, supplier_bill_date = p_bill_date, due_on = coalesce(p_due_on, due_on) where id = g.id;
  perform app.audit('purchase.receipt_amended', 'goods_receipts', g.id,
    jsonb_build_object('number', g.number, 'reason', trim(p_reason),
      'old', jsonb_build_object('bill_no', g.supplier_bill_no, 'bill_date', g.supplier_bill_date, 'due_on', g.due_on),
      'new', jsonb_build_object('bill_no', v_no, 'bill_date', p_bill_date, 'due_on', coalesce(p_due_on, g.due_on))));
  return jsonb_build_object('number', g.number);
end $$;
revoke all on function public.amend_receipt_details(uuid, text, date, date, text) from public, anon;
grant execute on function public.amend_receipt_details(uuid, text, date, date, text) to authenticated;
