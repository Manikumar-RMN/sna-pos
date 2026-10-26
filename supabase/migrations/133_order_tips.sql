-- 133: tips (memo only) on pay_order.
--
-- A tip is recorded, reported and audited, and that is all. It is NOT part of payments.amount, so it is never in the bill's
-- paid total, order_covered, the shift's expected cash, the day close / Z report or tax. A voided bill's tips are left out of
-- the tip report (the report joins orders.status); credit notes never refund a tip.
--   * new table order_tips (RLS: read by your own restaurant, no direct writes; written only by pay_order)
--   * public.pay_order gains p_tip numeric default 0 (last parameter). The old six-argument function is dropped and the
--     new one granted the same way; callers that pass six arguments keep working through the default.
--     With p_tip = 0 the return value and every row written are identical to before.
-- Additive, one transaction. Register order_tips in app.erase_groups() (migration 139, integrator).

create table if not exists public.order_tips (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  branch_id uuid references public.branches(id),
  order_id uuid not null references public.orders(id) on delete restrict,
  payment_id uuid references public.payments(id) on delete restrict,
  method_id uuid references public.payment_methods(id),
  amount numeric(14,2) not null check (amount > 0),
  waiter_id uuid references public.users(id),
  received_by uuid references public.users(id),
  shift_id uuid,
  business_date date,
  created_at timestamptz not null default now()
);
create index if not exists idx_order_tips_order on public.order_tips (order_id);
create index if not exists idx_order_tips_day on public.order_tips (restaurant_id, branch_id, business_date);
alter table public.order_tips enable row level security;
drop policy if exists tenant_read on public.order_tips;
create policy tenant_read on public.order_tips for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
revoke all on public.order_tips from anon, authenticated;
grant select on public.order_tips to authenticated;

drop function if exists public.pay_order(uuid, uuid, numeric, numeric, text, uuid);

CREATE OR REPLACE FUNCTION public.pay_order(p_order_id uuid, p_payment_method_id uuid, p_tendered numeric DEFAULT NULL::numeric, p_amount numeric DEFAULT NULL::numeric, p_reference text DEFAULT NULL::text, p_client_ref uuid DEFAULT NULL::uuid, p_tip numeric DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('payment.take');
  o public.orders%rowtype; v_kind text; v_shift uuid; v_rmode text; v_rcash boolean;
  v_balance numeric(14,2); v_amount numeric(14,2); v_round numeric(14,2) := 0; v_change numeric(14,2) := 0; v_full boolean;
  v_tip numeric(14,2) := 0; v_pay uuid := gen_random_uuid();
begin
  -- A tip is a memo: it is recorded (order_tips) but never counted in the payment, the bill balance, the shift cash, tax or day close.
  if p_tip is not null then
    if p_tip < 0 then raise exception 'A tip cannot be negative.'; end if;
    if p_tip > 99999999 then raise exception 'That tip is too large.'; end if;
    v_tip := round(p_tip, 2);
  end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('pay_ref:' || p_client_ref::text));
    select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id();
    if exists (select 1 from public.payments p where p.restaurant_id = app.current_restaurant_id() and p.client_ref = p_client_ref and p.order_id <> p_order_id) then
      raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
    end if;
    if exists (select 1 from public.payments p where p.restaurant_id = app.current_restaurant_id() and p.client_ref = p_client_ref) then
      return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'amount', 0, 'cash_rounding', 0, 'change', 0,
        'paid', o.payment_status = 'paid', 'balance', o.grand_total - app.order_covered(o.id), 'repeat', true);
    end if;
  end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', o.bill_number; end if;
  select pm.kind into v_kind from public.payment_methods pm
   where pm.id = p_payment_method_id and pm.restaurant_id = o.restaurant_id and pm.is_active;
  if not found then raise exception 'That payment method is not available.'; end if;
  if v_kind <> 'cash' then p_tendered := null; end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_shift is null then raise exception 'Open a shift before taking payments.'; end if;

  v_balance := o.grand_total - app.order_covered(o.id);
  if v_balance <= 0 then raise exception 'Bill % has nothing left to pay.', o.bill_number; end if;

  if p_amount is null or round(p_amount, 2) = v_balance then
    v_full := true;
    v_amount := v_balance;
    select coalesce(cash_rounding_mode, 'none'), coalesce(rounding_cash_only, false) into v_rmode, v_rcash
      from public.branch_settings where branch_id = o.branch_id;
    if v_kind = 'cash' and coalesce(v_rcash, false) and coalesce(v_rmode, 'none') <> 'none' then
      v_amount := app.round_cash(v_balance, v_rmode);
      if v_amount <= 0 then v_amount := v_balance; end if;
      v_round := v_amount - v_balance;
    end if;
  else
    if round(p_amount, 2) <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
    if round(p_amount, 2) > v_balance then
      raise exception 'Only % is left to pay on bill %. For cash, enter the cash received below to work out the change.', v_balance, o.bill_number;
    end if;
    v_full := false;
    v_amount := round(p_amount, 2);
  end if;

  if p_tendered is not null then
    if p_tendered < v_amount then
      raise exception 'Cash received (%) is less than the amount due (%).', p_tendered, v_amount;
    end if;
    v_change := p_tendered - v_amount;
  end if;

  insert into public.payments
    (id, restaurant_id, order_id, payment_method_id, amount, currency_code, tendered_amount,
     change_amount, status, received_by, client_created_at, rounding_adjustment, reference_no, client_ref)
  values
    (v_pay, o.restaurant_id, o.id, p_payment_method_id, v_amount, o.currency_code,
     p_tendered, v_change, 'captured', v_user, now(), v_round, nullif(left(trim(p_reference), 60), ''), p_client_ref);

  update public.orders set paid_total = paid_total + v_amount,
      payment_status = case when v_full then 'paid' else 'partial' end,
      shift_id = case when exists (select 1 from public.shifts s where s.id = o.shift_id and s.status = 'open')
                      then o.shift_id else v_shift end
   where id = o.id;

  perform app.audit('order.pay', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'amount', v_amount, 'method_kind', v_kind, 'full', v_full));
  if v_tip > 0 then
    insert into public.order_tips (restaurant_id, branch_id, order_id, payment_id, method_id, amount, waiter_id, received_by, shift_id, business_date)
    values (o.restaurant_id, o.branch_id, o.id, v_pay, p_payment_method_id, v_tip, coalesce(o.waiter_id, o.cashier_id), v_user,
            (select py.shift_id from public.payments py where py.id = v_pay), o.business_date);
    perform app.audit('order.tip', 'orders', o.id,
      jsonb_build_object('bill_number', o.bill_number, 'tip', v_tip, 'method_kind', v_kind, 'payment_id', v_pay));
  end if;
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'amount', v_amount,
                            'cash_rounding', v_round, 'change', v_change, 'paid', v_full,
                            'balance', case when v_full then 0 else v_balance - v_amount end)
         || case when v_tip > 0 then jsonb_build_object('tip', v_tip) else '{}'::jsonb end;
end $function$;

revoke all on function public.pay_order(uuid, uuid, numeric, numeric, text, uuid, numeric) from public, anon;
grant execute on function public.pay_order(uuid, uuid, numeric, numeric, text, uuid, numeric) to authenticated;
