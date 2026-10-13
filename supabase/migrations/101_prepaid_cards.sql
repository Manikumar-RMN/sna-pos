-- 101: Prepaid cards (food courts, canteens, clubs): a gift card that can be topped up again and again,
-- and its unused balance paid back when the guest returns the card.
-- Top-ups and pay-backs go through the drawer like any other money in or out.

alter table public.gift_card_ledger drop constraint gift_card_ledger_kind_check;
alter table public.gift_card_ledger add constraint gift_card_ledger_kind_check
  check (kind = any (array['issue', 'redeem', 'topup', 'payback']));

-- Adds money to a card. The guest pays by cash, UPI or card; the card's expiry date is moved on if it has one.
create or replace function public.top_up_gift_card(p_code text, p_amount numeric, p_method_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  g public.gift_cards%rowtype; v_kind text; v_drawer boolean; v_shift uuid; v_amt numeric := round(coalesce(p_amount, 0), 2);
begin
  perform app.require_feature('loyalty');
  if v_amt <= 0 or v_amt > 1000000 then raise exception 'Enter the amount to add.'; end if;
  select * into g from public.gift_cards where restaurant_id = v_rest and code = upper(trim(p_code)) for update;
  if not found then raise exception 'No card with that code.'; end if;
  select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_method_id and restaurant_id = v_rest and is_active;
  if not found or v_kind in ('gift_card', 'loyalty', 'advance', 'account') then raise exception 'Choose how the guest paid.'; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift first.'; end if;
  insert into public.gift_card_ledger (restaurant_id, gift_card_id, amount, kind, created_by) values (v_rest, g.id, v_amt, 'topup', v_user);
  if g.expires_on is not null and g.expires_on < current_date + 365 then
    update public.gift_cards set expires_on = current_date + 365 where id = g.id;
  end if;
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', v_amt, 'Card top-up ' || g.code, v_user);
  end if;
  perform app.audit('giftcard.topup', 'gift_cards', g.id, jsonb_build_object('code', g.code, 'amount', v_amt, 'method', v_kind), null);
  return jsonb_build_object('code', g.code, 'added', v_amt, 'balance', app.gift_balance(g.id));
end $function$;

-- Pays the whole unused balance back in cash and empties the card (the guest hands the card back).
create or replace function public.pay_back_gift_card(p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('order.refund'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  g public.gift_cards%rowtype; v_bal numeric; v_shift uuid;
begin
  perform app.require_feature('loyalty');
  select * into g from public.gift_cards where restaurant_id = v_rest and code = upper(trim(p_code)) for update;
  if not found then raise exception 'No card with that code.'; end if;
  v_bal := app.gift_balance(g.id);
  if v_bal <= 0 then raise exception 'Card % has no balance to pay back.', g.code; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift first.'; end if;
  insert into public.gift_card_ledger (restaurant_id, gift_card_id, amount, kind, created_by) values (v_rest, g.id, -v_bal, 'payback', v_user);
  insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
  values (v_rest, v_shift, 'out', v_bal, 'Card balance paid back ' || g.code, v_user);
  perform app.audit('giftcard.payback', 'gift_cards', g.id, jsonb_build_object('code', g.code, 'amount', v_bal), null);
  return jsonb_build_object('code', g.code, 'paid_back', v_bal, 'balance', 0);
end $function$;

-- A card's history: issue, top-ups, bills paid with it, pay-back.
create or replace function public.gift_card_history(p_code text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare g public.gift_cards%rowtype;
begin
  perform app.require_permission('order.create');
  select * into g from public.gift_cards where restaurant_id = app.current_restaurant_id() and code = upper(trim(p_code));
  if not found then raise exception 'No card with that code.'; end if;
  return jsonb_build_object('code', g.code, 'balance', app.gift_balance(g.id), 'expires_on', g.expires_on,
    'entries', coalesce((select jsonb_agg(jsonb_build_object('at', l.created_at, 'kind', l.kind, 'amount', l.amount, 'bill', o.bill_number) order by l.created_at desc)
                           from public.gift_card_ledger l left join public.orders o on o.id = l.order_id where l.gift_card_id = g.id), '[]'::jsonb));
end $function$;

revoke all on function public.top_up_gift_card(text, numeric, uuid), public.pay_back_gift_card(text), public.gift_card_history(text) from public, anon;
grant execute on function public.top_up_gift_card(text, numeric, uuid), public.pay_back_gift_card(text), public.gift_card_history(text) to authenticated, service_role;
