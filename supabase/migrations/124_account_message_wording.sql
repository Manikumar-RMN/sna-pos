-- 124: Wording: the credit-limit message shows the currency symbol.
create or replace function app.money_text(p_amount numeric, p_currency text)
returns text language sql immutable set search_path to 'public', 'pg_temp'
as $$ select case upper(coalesce(p_currency, 'INR')) when 'INR' then '₹' when 'AED' then 'AED ' when 'USD' then '$' when 'PHP' then '₱' else upper(coalesce(p_currency, '')) || ' ' end
              || to_char(coalesce(p_amount, 0), 'FM999,999,999,990.00') $$;
revoke all on function app.money_text(numeric, text) from public, anon, authenticated;

create or replace function public.account_charge(p_order uuid, p_customer uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id();
  o public.orders; c public.customers; v_due numeric(14,2); v_bal numeric(14,2); v_shift uuid;
begin
  select * into o from public.orders where id = p_order and restaurant_id = v_rest for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', o.bill_number; end if;
  select * into c from public.customers where id = p_customer and restaurant_id = v_rest and deleted_at is null;
  if not found then raise exception 'Customer not found.'; end if;
  if c.credit_limit is null then raise exception '% has no credit account.', c.name; end if;
  v_due := o.grand_total - app.order_covered(o.id);
  if v_due <= 0 then raise exception 'Bill % has nothing left to pay.', o.bill_number; end if;
  v_bal := app.account_balance(c.id);
  if v_bal + v_due > c.credit_limit then
    raise exception '% owes % already; this bill (%) would go over the credit limit of %.', c.name,
      app.money_text(v_bal, o.currency_code), app.money_text(v_due, o.currency_code), app.money_text(c.credit_limit, o.currency_code);
  end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  perform set_config('app.account', 'on', true);
  insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, status, received_by, client_created_at, reference_no)
  values (gen_random_uuid(), o.restaurant_id, o.id, app.account_method(v_rest), v_due, o.currency_code, 'captured', v_user, now(), left('Account: ' || c.name, 60));
  perform set_config('app.account', 'off', true);
  update public.orders set paid_total = paid_total + v_due, payment_status = 'paid',
         customer_id = coalesce(customer_id, c.id), shift_id = coalesce(shift_id, v_shift)
   where id = o.id;
  insert into public.customer_ledger (restaurant_id, customer_id, kind, amount, order_id, shift_id, note, created_by)
  values (v_rest, c.id, 'charge', v_due, o.id, v_shift, nullif(left(btrim(coalesce(p_note, '')), 200), ''), v_user);
  perform app.audit('account.charge', 'orders', o.id, jsonb_build_object('bill_number', o.bill_number, 'customer', c.name, 'amount', v_due), null);
  return jsonb_build_object('charged', v_due, 'balance', v_bal + v_due);
end $function$;
