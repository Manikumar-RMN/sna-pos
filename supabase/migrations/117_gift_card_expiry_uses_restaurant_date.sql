-- 117: Gift-card expiry uses the restaurant's own date, not the database's (UTC).
--
-- A card "valid for 30 days" sold at 11 p.m. in India was counted from the next day in UTC terms, and a card that expires
-- "today" was treated as expired / valid up to 5.5 hours off, around midnight. The four gift-card functions used current_date,
-- which is the date in the database's time zone (UTC). They now use the restaurant's own calendar date
-- (app.local_today). Product batches (batch_add / batches_list ...) have the same pattern and are NOT changed here.
-- Safe to run again.

create or replace function app.local_today(p_restaurant uuid)
 returns date
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select (now() at time zone coalesce(nullif(r.timezone, ''), 'UTC'))::date from public.restaurants r where r.id = p_restaurant
$function$;

revoke all on function app.local_today(uuid) from public;

CREATE OR REPLACE FUNCTION public.gift_card_lookup(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare g public.gift_cards%rowtype;
begin
  perform app.require_permission('order.create');
  select * into g from public.gift_cards where restaurant_id = app.current_restaurant_id() and code = upper(trim(p_code));
  if not found then raise exception 'No gift card with that code.'; end if;
  return jsonb_build_object('code', g.code, 'value', g.value, 'balance', app.gift_balance(g.id), 'expires_on', g.expires_on,
    'expired', g.expires_on is not null and g.expires_on < app.local_today(app.current_restaurant_id()));
end $function$
;

CREATE OR REPLACE FUNCTION public.issue_gift_card(p_value numeric, p_method_id uuid, p_phone text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_valid_days integer DEFAULT 365)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_kind text; v_drawer boolean; v_shift uuid; v_code text; v_id uuid; v_cust uuid; v_phone text := app.clean_phone(p_phone);
begin
  perform app.require_feature('loyalty');
  if coalesce(p_value, 0) <= 0 or p_value > 1000000 then raise exception 'Enter the gift card value.'; end if;
  select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_method_id and restaurant_id = v_rest and is_active;
  if not found or v_kind in ('gift_card', 'loyalty') then raise exception 'Choose how the guest paid for the card.'; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift before selling a gift card.'; end if;
  loop
    v_code := 'GC' || upper(substr(regexp_replace(app.new_token(12), '[^A-Za-z0-9]', '', 'g'), 1, 8));
    exit when length(v_code) = 10 and not exists (select 1 from public.gift_cards where restaurant_id = v_rest and code = v_code);
  end loop;
  if v_phone is not null then
    select id into v_cust from public.customers where restaurant_id = v_rest and phone = v_phone and deleted_at is null;
    if v_cust is null then
      insert into public.customers (restaurant_id, name, phone) values (v_rest, coalesce(nullif(left(trim(p_name), 80), ''), 'Guest'), v_phone) returning id into v_cust;
    end if;
  end if;
  insert into public.gift_cards (restaurant_id, code, value, expires_on, customer_id, sold_method_id, sold_branch_id, sold_shift_id, issued_by)
  values (v_rest, v_code, round(p_value, 2), case when coalesce(p_valid_days, 0) > 0 then app.local_today(v_rest) + p_valid_days end,
          v_cust, p_method_id, v_branch, v_shift, v_user)
  returning id into v_id;
  insert into public.gift_card_ledger (restaurant_id, gift_card_id, amount, kind, created_by) values (v_rest, v_id, round(p_value, 2), 'issue', v_user);
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', round(p_value, 2), 'Gift card sold ' || v_code, v_user);
  end if;
  perform app.audit('giftcard.issue', 'gift_cards', v_id, jsonb_build_object('code', v_code, 'value', p_value, 'method', v_kind), null);
  return jsonb_build_object('id', v_id, 'code', v_code, 'value', round(p_value, 2),
    'expires_on', case when coalesce(p_valid_days, 0) > 0 then app.local_today(v_rest) + p_valid_days end);
end $function$
;

CREATE OR REPLACE FUNCTION public.redeem_gift_card(p_order uuid, p_code text, p_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; g public.gift_cards%rowtype; v_bal numeric; v_due numeric; v_amt numeric; v_res jsonb;
begin
  perform app.require_permission('payment.take');
  perform app.require_feature('loyalty');
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  select * into g from public.gift_cards where restaurant_id = o.restaurant_id and code = upper(trim(p_code)) for update;
  if not found then raise exception 'No gift card with that code.'; end if;
  if g.expires_on is not null and g.expires_on < app.local_today(o.restaurant_id) then raise exception 'Gift card % expired on %.', g.code, g.expires_on; end if;
  v_bal := app.gift_balance(g.id);
  v_due := o.grand_total - app.order_covered(o.id);
  v_amt := round(least(coalesce(p_amount, v_due), v_bal, v_due), 2);
  if v_bal <= 0 then raise exception 'Gift card % has no balance left.', g.code; end if;
  if v_amt <= 0 then raise exception 'Nothing left to pay on this bill.'; end if;
  perform set_config('app.redeem', 'on', true);
  v_res := public.pay_order(o.id, app.system_method(o.restaurant_id, 'gift_card'), null, v_amt, g.code, null);
  perform set_config('app.redeem', '', true);
  insert into public.gift_card_ledger (restaurant_id, gift_card_id, order_id, amount, kind, created_by)
  values (o.restaurant_id, g.id, o.id, -v_amt, 'redeem', app.current_user_id());
  return v_res || jsonb_build_object('card', g.code, 'used', v_amt, 'card_balance', v_bal - v_amt);
end $function$
;

CREATE OR REPLACE FUNCTION public.top_up_gift_card(p_code text, p_amount numeric, p_method_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  if g.expires_on is not null and g.expires_on < app.local_today(v_rest) + 365 then
    update public.gift_cards set expires_on = app.local_today(v_rest) + 365 where id = g.id;
  end if;
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', v_amt, 'Card top-up ' || g.code, v_user);
  end if;
  perform app.audit('giftcard.topup', 'gift_cards', g.id, jsonb_build_object('code', g.code, 'amount', v_amt, 'method', v_kind), null);
  return jsonb_build_object('code', g.code, 'added', v_amt, 'balance', app.gift_balance(g.id));
end $function$
;

