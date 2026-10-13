-- 100: Customer accounts — eat now, pay later (canteen staff, corporate clients, regulars).
--
-- A customer can have a credit account with a limit. A bill can be "charged to account": it is then fully paid
-- (by a hidden payment of the kind "account"), so it never blocks closing the day, and the amount is added to what
-- the customer owes. Settlements (cash, UPI, bank) reduce what is owed; cash goes into the drawer as a cash-in.
-- Statements list every charge and settlement with a running balance.

alter table public.payment_methods drop constraint payment_methods_kind_check;
alter table public.payment_methods add constraint payment_methods_kind_check
  check (kind = any (array['cash', 'card', 'wallet', 'bank_transfer', 'upi', 'other', 'gift_card', 'loyalty', 'advance', 'account']));

alter table public.customers
  add column credit_limit numeric(14,2) check (credit_limit is null or credit_limit >= 0),
  add column account_company text check (account_company is null or length(account_company) <= 80);

create table public.customer_ledger (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  customer_id uuid not null,
  kind text not null check (kind in ('charge', 'settlement', 'adjustment')),
  amount numeric(14,2) not null check (amount <> 0),   -- + adds to what is owed, - takes off
  order_id uuid references public.orders(id) on delete restrict,
  payment_method_id uuid references public.payment_methods(id) on delete restrict,
  shift_id uuid references public.shifts(id) on delete set null,
  note text check (note is null or length(note) <= 200),
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (restaurant_id, customer_id) references public.customers(restaurant_id, id) on delete restrict
);
create index idx_customer_ledger on public.customer_ledger (customer_id, created_at);
alter table public.customer_ledger enable row level security;
revoke all on public.customer_ledger from anon, authenticated;
create trigger trg_no_change_customer_ledger before delete or update on public.customer_ledger
  for each row execute function app.block_delete();

create or replace function app.account_balance(p_customer uuid)
returns numeric
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(sum(amount), 0)::numeric(14,2) from public.customer_ledger where customer_id = p_customer
$function$;

create or replace function app.account_method(p_rest uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v uuid;
begin
  select id into v from public.payment_methods where restaurant_id = p_rest and kind = 'account' order by display_order limit 1;
  if v is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order)
    values (p_rest, 'Customer account', 'account', false, false, 98) returning id into v;
  end if;
  return v;
end $function$;

-- Account payments are written only by "Charge to account"; no payment changes to or from one.
CREATE OR REPLACE FUNCTION app.guard_redeem_payment()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k_new text; k_old text;
begin
  select kind into k_new from public.payment_methods where id = new.payment_method_id;
  if tg_op = 'INSERT' then
    if k_new in ('gift_card', 'loyalty') and coalesce(current_setting('app.redeem', true), '') <> 'on' then
      raise exception 'Use "Redeem gift card" or "Redeem points" on the bill for this payment.';
    end if;
    if k_new = 'advance' and coalesce(current_setting('app.advance', true), '') <> 'on' then
      raise exception 'A pre-order advance is applied with "Bill now" on the pre-order.';
    end if;
    if k_new = 'account' and coalesce(current_setting('app.account', true), '') <> 'on' then
      raise exception 'Use "Charge to account" on the bill for this payment.';
    end if;
  elsif new.payment_method_id is distinct from old.payment_method_id then
    select kind into k_old from public.payment_methods where id = old.payment_method_id;
    if k_new in ('gift_card', 'loyalty', 'advance', 'account') or k_old in ('gift_card', 'loyalty', 'advance', 'account') then
      raise exception 'A gift card, points, advance or account payment cannot be changed to another method, or the other way round.';
    end if;
  end if;
  return new;
end $function$;

-- Open or change a credit account (limit 0 or more; null closes it for new charges).
create or replace function public.account_save(p_customer uuid, p_name text, p_phone text, p_limit numeric, p_company text default null)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('customer.manage'); v_rest uuid := app.current_restaurant_id(); v uuid := p_customer;
  v_phone text := app.clean_phone(p_phone);
begin
  if p_limit is not null and (p_limit < 0 or p_limit > 100000000) then raise exception 'Enter a credit limit of 0 or more.'; end if;
  if v is null then
    if coalesce(btrim(p_name), '') = '' then raise exception 'Enter the customer''s name.'; end if;
    if v_phone is not null then
      select id into v from public.customers where restaurant_id = v_rest and phone = v_phone;
      if v is not null then update public.customers set deleted_at = null where id = v; end if;
    end if;
    if v is null then
      insert into public.customers (restaurant_id, name, phone) values (v_rest, left(btrim(p_name), 80), v_phone) returning id into v;
    end if;
  end if;
  update public.customers set credit_limit = round(p_limit, 2), account_company = nullif(left(btrim(coalesce(p_company, '')), 80), ''),
         name = case when coalesce(btrim(p_name), '') <> '' then left(btrim(p_name), 80) else name end
   where id = v and restaurant_id = v_rest and deleted_at is null;
  if not found then raise exception 'Customer not found.'; end if;
  perform app.audit('account.save', 'customers', v, jsonb_build_object('limit', p_limit), null);
  return v;
end $function$;

-- Charge what is left to pay on a bill to a customer's account.
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
    raise exception '% owes % already; this bill (%) would go over the credit limit of %.', c.name, v_bal, v_due, c.credit_limit;
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

-- The customer pays (part of) what they owe.
create or replace function public.account_settle(p_customer uuid, p_method uuid, p_amount numeric, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  c public.customers; v_kind text; v_drawer boolean; v_shift uuid; v_amt numeric(14,2) := round(coalesce(p_amount, 0), 2); v_bal numeric(14,2);
begin
  select * into c from public.customers where id = p_customer and restaurant_id = v_rest for update;
  if not found then raise exception 'Customer not found.'; end if;
  if v_amt <= 0 then raise exception 'Enter the amount received.'; end if;
  v_bal := app.account_balance(c.id);
  if v_amt > v_bal then raise exception '% owes only %.', c.name, v_bal; end if;
  select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_method and restaurant_id = v_rest and is_active;
  if not found or v_kind in ('gift_card', 'loyalty', 'advance', 'account') then raise exception 'Choose how the customer paid.'; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift before taking a payment.'; end if;
  insert into public.customer_ledger (restaurant_id, customer_id, kind, amount, payment_method_id, shift_id, note, created_by)
  values (v_rest, c.id, 'settlement', -v_amt, p_method, v_shift, nullif(left(btrim(coalesce(p_note, '')), 200), ''), v_user);
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', v_amt, left('Account payment: ' || c.name, 200), v_user);
  end if;
  perform app.audit('account.settle', 'customers', c.id, jsonb_build_object('amount', v_amt, 'method', v_kind), null);
  return jsonb_build_object('balance', v_bal - v_amt);
end $function$;

-- All accounts with what each owes.
create or replace function public.accounts_list()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'company', c.account_company,
            'limit', c.credit_limit, 'balance', app.account_balance(c.id),
            'last', (select max(created_at) from public.customer_ledger l where l.customer_id = c.id)) order by c.name)
     from public.customers c
    where c.restaurant_id = v_rest and c.deleted_at is null
      and (c.credit_limit is not null or exists (select 1 from public.customer_ledger l where l.customer_id = c.id))), '[]'::jsonb);
end $function$;

-- A customer's statement for a period: opening balance, every entry with a running balance, closing balance.
create or replace function public.account_statement(p_customer uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id(); c public.customers; v_open numeric(14,2); v_tz text;
begin
  select * into c from public.customers where id = p_customer and restaurant_id = v_rest;
  if not found then raise exception 'Customer not found.'; end if;
  select coalesce(nullif(timezone, ''), 'Asia/Kolkata') into v_tz from public.restaurants where id = v_rest;
  select coalesce(sum(amount), 0) into v_open from public.customer_ledger
   where customer_id = c.id and (created_at at time zone v_tz)::date < p_from;
  return jsonb_build_object('customer', jsonb_build_object('name', c.name, 'phone', c.phone, 'company', c.account_company, 'limit', c.credit_limit),
    'from', p_from, 'to', p_to, 'opening', v_open,
    'entries', coalesce((select jsonb_agg(jsonb_build_object('at', x.created_at, 'kind', x.kind, 'amount', x.amount, 'note', x.note,
               'bill', (select bill_number from public.orders where id = x.order_id), 'order_id', x.order_id,
               'method', (select name from public.payment_methods where id = x.payment_method_id),
               'balance', v_open + x.running)
               order by x.created_at, x.id)
          from (select l.*, sum(l.amount) over (order by l.created_at, l.id) as running
                  from public.customer_ledger l
                 where l.customer_id = c.id and (l.created_at at time zone v_tz)::date between p_from and p_to) x), '[]'::jsonb),
    'closing', v_open + coalesce((select sum(amount) from public.customer_ledger where customer_id = c.id
                                  and (created_at at time zone v_tz)::date between p_from and p_to), 0));
end $function$;

revoke all on function app.account_balance(uuid), app.account_method(uuid) from public, anon, authenticated;
revoke all on function public.account_save(uuid, text, text, numeric, text), public.account_charge(uuid, uuid, text),
  public.account_settle(uuid, uuid, numeric, text), public.accounts_list(), public.account_statement(uuid, date, date) from public, anon;
grant execute on function public.account_save(uuid, text, text, numeric, text), public.account_charge(uuid, uuid, text),
  public.account_settle(uuid, uuid, numeric, text), public.accounts_list(), public.account_statement(uuid, date, date) to authenticated, service_role;

-- Erasing a test restaurant also removes its account entries.
CREATE OR REPLACE FUNCTION app.erase_groups()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('customer_ledger', 'batch_movements', 'pre_order_payments', 'pre_orders', 'order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('product_batches', 'price_rules', 'product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'branch_prices',
            'products', 'categories', 'dining_tables', 'floors', 'customers'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$;
