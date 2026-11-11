-- Cancel settlement (Winsar "Cancel Settlement"): a paid or part-paid bill goes back to unpaid so it can be settled again.
-- Narrow on purpose: manager right (order.void), reason required, same open shift, no refund, day not closed,
-- only cash / UPI / card / other payments (no gift card, loyalty, account or advance), no loyalty / gift / account entries, not from a pre-order.
create or replace function public.reopen_order(p_order_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('order.void');
  o public.orders%rowtype; v_shift_open boolean; v_paid numeric(14,2); v_n int;
begin
  perform app.require_feature('pos');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for cancelling the settlement.'; end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status <> 'completed' then raise exception 'Bill % is not a completed bill.', o.bill_number; end if;
  if o.payment_status not in ('paid', 'partial') then raise exception 'Bill % has no settlement to cancel.', o.bill_number; end if;
  if exists (select 1 from public.refunds where order_id = o.id) then
    raise exception 'Bill % already has a refund, so its settlement cannot be cancelled.', o.bill_number;
  end if;
  select s.status = 'open' into v_shift_open from public.shifts s where s.id = o.shift_id;
  if not coalesce(v_shift_open, false) then
    raise exception 'The shift for bill % is already closed. Void the bill or issue a credit note instead.', o.bill_number;
  end if;
  if exists (select 1 from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
              where p.order_id = o.id and p.status = 'captured' and pm.kind not in ('cash', 'upi', 'card', 'other')) then
    raise exception 'Bill % was paid with a gift card, loyalty points, an account or an advance, so its settlement cannot be cancelled. Void the bill instead.', o.bill_number;
  end if;
  if exists (select 1 from public.loyalty_ledger where order_id = o.id)
     or exists (select 1 from public.gift_card_ledger where order_id = o.id)
     or exists (select 1 from public.customer_ledger where order_id = o.id)
     or exists (select 1 from public.pre_orders where order_id = o.id) then
    raise exception 'Bill % has loyalty, gift card, account or pre-order entries, so its settlement cannot be cancelled. Void the bill instead.', o.bill_number;
  end if;

  select coalesce(sum(amount), 0) into v_paid from public.payments where order_id = o.id and status = 'captured';
  update public.payments set status = 'refunded' where order_id = o.id and status = 'captured';
  get diagnostics v_n = row_count;
  update public.orders set paid_total = 0, payment_status = 'unpaid' where id = o.id;

  perform app.audit('order.reopen', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'payments_cancelled', v_n, 'amount', v_paid, 'reason', left(trim(p_reason), 200), 'by', v_user),
    jsonb_build_object('payment_status', o.payment_status, 'paid_total', o.paid_total));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'cancelled', v_n, 'amount', v_paid);
end $function$;

revoke all on function public.reopen_order(uuid, text) from public, anon;
grant execute on function public.reopen_order(uuid, text) to authenticated;
