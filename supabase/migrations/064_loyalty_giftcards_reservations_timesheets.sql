-- 064: loyalty points, gift cards, reservations & waitlist, staff timesheets.

-- ---------- Payment kinds used only through redemption ----------
alter table public.payment_methods drop constraint if exists payment_methods_kind_check;
alter table public.payment_methods add constraint payment_methods_kind_check
  check (kind in ('cash', 'card', 'wallet', 'bank_transfer', 'upi', 'other', 'gift_card', 'loyalty'));

-- The restaurant's own "Gift card" / "Loyalty points" method, made on first use (never shown in the normal pay list).
create or replace function app.system_method(p_restaurant uuid, p_kind text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid;
begin
  select id into v from public.payment_methods where restaurant_id = p_restaurant and kind = p_kind limit 1;
  if v is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order)
    values (p_restaurant, case p_kind when 'gift_card' then 'Gift card' else 'Loyalty points' end, p_kind, false, true, 90)
    returning id into v;
  end if;
  return v;
end $$;

-- A gift card or points payment can only be made through its redeem function (which checks the balance),
-- and an existing payment can never be switched to or from one.
create or replace function app.guard_redeem_payment() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare k_new text; k_old text;
begin
  select kind into k_new from public.payment_methods where id = new.payment_method_id;
  if tg_op = 'INSERT' then
    if k_new in ('gift_card', 'loyalty') and coalesce(current_setting('app.redeem', true), '') <> 'on' then
      raise exception 'Use "Redeem gift card" or "Redeem points" on the bill for this payment.';
    end if;
  elsif new.payment_method_id is distinct from old.payment_method_id then
    select kind into k_old from public.payment_methods where id = old.payment_method_id;
    if k_new in ('gift_card', 'loyalty') or k_old in ('gift_card', 'loyalty') then
      raise exception 'A gift card or points payment cannot be changed to another method, or the other way round.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_redeem_payment on public.payments;
create trigger trg_guard_redeem_payment before insert or update on public.payments
  for each row execute function app.guard_redeem_payment();

-- ---------- Customers on a bill ----------
create unique index if not exists customers_phone_uq on public.customers (restaurant_id, phone) where deleted_at is null and phone is not null;

create or replace function app.clean_phone(p text) returns text language sql immutable as $$
  select nullif(regexp_replace(coalesce(p, ''), '[^0-9+]', '', 'g'), '');
$$;

-- ---------- Loyalty ----------
create table if not exists public.loyalty_settings (
  restaurant_id uuid primary key references public.restaurants(id),
  spend_per_point numeric(14,2) not null default 100 check (spend_per_point > 0),
  point_value numeric(14,4) not null default 1 check (point_value >= 0),
  min_redeem integer not null default 0 check (min_redeem >= 0),
  updated_at timestamptz not null default now()
);
create table if not exists public.loyalty_ledger (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  customer_id uuid not null references public.customers(id),
  order_id uuid references public.orders(id),
  points numeric(14,2) not null,
  kind text not null check (kind in ('earn', 'redeem', 'reverse', 'adjust')),
  note text,
  created_by uuid references public.users(id),
  created_at timestamptz not null default now()
);
create unique index if not exists loyalty_one_earn_per_order on public.loyalty_ledger (order_id) where kind = 'earn';
create index if not exists loyalty_customer_idx on public.loyalty_ledger (customer_id);
drop trigger if exists trg_no_update on public.loyalty_ledger;
create trigger trg_no_update before update on public.loyalty_ledger for each row execute function app.block_update();
drop trigger if exists trg_no_delete on public.loyalty_ledger;
create trigger trg_no_delete before delete on public.loyalty_ledger for each row execute function app.block_delete();

create or replace function app.points_balance(p_customer uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(points), 0) from public.loyalty_ledger where customer_id = p_customer;
$$;

-- Points are earned once per bill, when it is fully paid and has a customer (not on the part paid with points).
create or replace function app.loyalty_earn() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.loyalty_settings%rowtype; v_base numeric; v_pts numeric;
begin
  if new.payment_status <> 'paid' or new.customer_id is null or new.status = 'voided' then return new; end if;
  if not app.feature_on(new.restaurant_id, 'loyalty') then return new; end if;
  select * into s from public.loyalty_settings where restaurant_id = new.restaurant_id;
  if not found then return new; end if;
  if exists (select 1 from public.loyalty_ledger where order_id = new.id and kind = 'earn') then return new; end if;
  select new.grand_total - coalesce(sum(p.amount), 0) into v_base
    from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
   where p.order_id = new.id and p.status = 'captured' and pm.kind in ('loyalty', 'gift_card');
  v_pts := floor(greatest(v_base, 0) / s.spend_per_point);
  if v_pts > 0 then
    insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note)
    values (new.restaurant_id, new.customer_id, new.id, v_pts, 'earn', 'Bill ' || new.bill_number);
  end if;
  return new;
end $$;
drop trigger if exists trg_loyalty_earn on public.orders;
create trigger trg_loyalty_earn after update of payment_status, customer_id on public.orders
  for each row execute function app.loyalty_earn();

-- A credit note takes back the points earned on the refunded part.
create or replace function app.loyalty_reverse() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.loyalty_ledger%rowtype; s public.loyalty_settings%rowtype; v_back numeric; v_done numeric;
begin
  select * into e from public.loyalty_ledger where order_id = new.order_id and kind = 'earn';
  if not found then return new; end if;
  select * into s from public.loyalty_settings where restaurant_id = new.restaurant_id;
  select coalesce(-sum(points), 0) into v_done from public.loyalty_ledger where order_id = new.order_id and kind = 'reverse';
  v_back := least(e.points - v_done, ceil(new.amount / coalesce(s.spend_per_point, 100)));
  if v_back > 0 then
    insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note)
    values (new.restaurant_id, e.customer_id, new.order_id, -v_back, 'reverse', 'Credit note ' || new.number);
  end if;
  return new;
end $$;
drop trigger if exists trg_loyalty_reverse on public.credit_notes;
create trigger trg_loyalty_reverse after insert on public.credit_notes for each row execute function app.loyalty_reverse();

create or replace function public.save_loyalty_settings(p_spend_per_point numeric, p_point_value numeric, p_min_redeem int)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('settings.manage');
  perform app.require_feature('loyalty');
  insert into public.loyalty_settings (restaurant_id, spend_per_point, point_value, min_redeem)
  values (app.current_restaurant_id(), p_spend_per_point, p_point_value, coalesce(p_min_redeem, 0))
  on conflict (restaurant_id) do update set spend_per_point = excluded.spend_per_point, point_value = excluded.point_value,
    min_redeem = excluded.min_redeem, updated_at = now();
  perform app.audit('loyalty.settings', 'loyalty_settings', null,
    jsonb_build_object('spend_per_point', p_spend_per_point, 'point_value', p_point_value, 'min_redeem', p_min_redeem), null);
end $$;

-- Find (or add) the guest by phone and put them on the bill. Returns their points.
create or replace function public.attach_customer(p_order uuid, p_phone text, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_phone text := app.clean_phone(p_phone); v_cust uuid; v_name text; o public.orders%rowtype;
begin
  perform app.require_permission('order.create');
  if v_phone is null or length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 7 then raise exception 'Enter the guest''s phone number.'; end if;
  select * into o from public.orders where id = p_order and restaurant_id = v_rest for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  select id, name into v_cust, v_name from public.customers where restaurant_id = v_rest and phone = v_phone and deleted_at is null;
  if v_cust is null then
    insert into public.customers (restaurant_id, name, phone) values (v_rest, coalesce(nullif(left(trim(p_name), 80), ''), 'Guest'), v_phone)
    returning id, name into v_cust, v_name;
  elsif nullif(trim(p_name), '') is not null and v_name = 'Guest' then
    update public.customers set name = left(trim(p_name), 80) where id = v_cust returning name into v_name;
  end if;
  update public.orders set customer_id = v_cust where id = p_order;
  perform app.audit('order.customer', 'orders', p_order, jsonb_build_object('customer_id', v_cust), null);
  return jsonb_build_object('customer_id', v_cust, 'name', v_name, 'phone', v_phone, 'points', app.points_balance(v_cust));
end $$;

create or replace function public.redeem_points(p_order uuid, p_points numeric) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; s public.loyalty_settings%rowtype; v_bal numeric; v_due numeric; v_amt numeric; v_pts numeric; v_res jsonb;
begin
  perform app.require_permission('payment.take');
  perform app.require_feature('loyalty');
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.customer_id is null then raise exception 'Add the guest''s phone number to the bill first.'; end if;
  select * into s from public.loyalty_settings where restaurant_id = o.restaurant_id;
  if not found or s.point_value <= 0 then raise exception 'Set up loyalty points in Settings first.'; end if;
  perform pg_advisory_xact_lock(hashtext('points:' || o.customer_id::text));
  v_bal := app.points_balance(o.customer_id);
  v_pts := floor(coalesce(p_points, 0));
  if v_pts <= 0 then raise exception 'Enter the points to use.'; end if;
  if v_pts > v_bal then raise exception 'The guest has only % points.', v_bal; end if;
  if v_pts < s.min_redeem then raise exception 'At least % points must be used at a time.', s.min_redeem; end if;
  v_due := o.grand_total - app.order_covered(o.id);
  v_amt := round(v_pts * s.point_value, 2);
  if v_amt > v_due then
    v_amt := v_due;
    v_pts := ceil(v_amt / s.point_value);
  end if;
  if v_amt <= 0 then raise exception 'Nothing left to pay on this bill.'; end if;
  perform set_config('app.redeem', 'on', true);
  v_res := public.pay_order(o.id, app.system_method(o.restaurant_id, 'loyalty'), null, v_amt, v_pts || ' points', null);
  perform set_config('app.redeem', '', true);
  insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note, created_by)
  values (o.restaurant_id, o.customer_id, o.id, -v_pts, 'redeem', 'Bill ' || o.bill_number, app.current_user_id());
  return v_res || jsonb_build_object('points_used', v_pts, 'points_left', v_bal - v_pts);
end $$;

-- ---------- Gift cards ----------
create table if not exists public.gift_cards (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  code text not null,
  value numeric(14,2) not null check (value > 0),
  expires_on date,
  customer_id uuid references public.customers(id),
  sold_method_id uuid references public.payment_methods(id),
  sold_branch_id uuid references public.branches(id),
  sold_shift_id uuid references public.shifts(id),
  issued_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  unique (restaurant_id, code)
);
create table if not exists public.gift_card_ledger (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  gift_card_id uuid not null references public.gift_cards(id),
  order_id uuid references public.orders(id),
  amount numeric(14,2) not null,
  kind text not null check (kind in ('issue', 'redeem')),
  created_by uuid references public.users(id),
  created_at timestamptz not null default now()
);
drop trigger if exists trg_no_update on public.gift_card_ledger;
create trigger trg_no_update before update on public.gift_card_ledger for each row execute function app.block_update();
drop trigger if exists trg_no_delete on public.gift_card_ledger;
create trigger trg_no_delete before delete on public.gift_card_ledger for each row execute function app.block_delete();
drop trigger if exists trg_no_delete on public.gift_cards;
create trigger trg_no_delete before delete on public.gift_cards for each row execute function app.block_delete();

create or replace function app.gift_balance(p_card uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(amount), 0) from public.gift_card_ledger where gift_card_id = p_card;
$$;

-- Sell a gift card. Cash goes into the drawer as a cash-in on the open shift; other methods are recorded on the card.
create or replace function public.issue_gift_card(p_value numeric, p_method_id uuid, p_phone text default null, p_name text default null, p_valid_days int default 365)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_kind text; v_drawer boolean; v_shift uuid; v_code text; v_id uuid; v_cust uuid; v_phone text := app.clean_phone(p_phone);
begin
  perform app.require_feature('loyalty');
  if coalesce(p_value, 0) <= 0 or p_value > 1000000 then raise exception 'Enter the gift card value.'; end if;
  select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_method_id and restaurant_id = v_rest and is_active;
  if not found or v_kind in ('gift_card', 'loyalty') then raise exception 'Choose how the guest paid for the card.'; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
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
  values (v_rest, v_code, round(p_value, 2), case when coalesce(p_valid_days, 0) > 0 then current_date + p_valid_days end,
          v_cust, p_method_id, v_branch, v_shift, v_user)
  returning id into v_id;
  insert into public.gift_card_ledger (restaurant_id, gift_card_id, amount, kind, created_by) values (v_rest, v_id, round(p_value, 2), 'issue', v_user);
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', round(p_value, 2), 'Gift card sold ' || v_code, v_user);
  end if;
  perform app.audit('giftcard.issue', 'gift_cards', v_id, jsonb_build_object('code', v_code, 'value', p_value, 'method', v_kind), null);
  return jsonb_build_object('id', v_id, 'code', v_code, 'value', round(p_value, 2),
    'expires_on', case when coalesce(p_valid_days, 0) > 0 then current_date + p_valid_days end);
end $$;

create or replace function public.gift_card_lookup(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare g public.gift_cards%rowtype;
begin
  perform app.require_permission('order.create');
  select * into g from public.gift_cards where restaurant_id = app.current_restaurant_id() and code = upper(trim(p_code));
  if not found then raise exception 'No gift card with that code.'; end if;
  return jsonb_build_object('code', g.code, 'value', g.value, 'balance', app.gift_balance(g.id), 'expires_on', g.expires_on,
    'expired', g.expires_on is not null and g.expires_on < current_date);
end $$;

create or replace function public.redeem_gift_card(p_order uuid, p_code text, p_amount numeric default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; g public.gift_cards%rowtype; v_bal numeric; v_due numeric; v_amt numeric; v_res jsonb;
begin
  perform app.require_permission('payment.take');
  perform app.require_feature('loyalty');
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  select * into g from public.gift_cards where restaurant_id = o.restaurant_id and code = upper(trim(p_code)) for update;
  if not found then raise exception 'No gift card with that code.'; end if;
  if g.expires_on is not null and g.expires_on < current_date then raise exception 'Gift card % expired on %.', g.code, g.expires_on; end if;
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
end $$;

-- ---------- Reservations and waitlist ----------
create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  branch_id uuid not null references public.branches(id),
  guest_name text not null check (length(guest_name) between 1 and 80),
  phone text,
  party_size integer not null check (party_size between 1 and 200),
  reserved_for timestamptz,
  dining_table_id uuid references public.dining_tables(id),
  status text not null check (status in ('booked', 'waiting', 'seated', 'cancelled', 'no_show')),
  note text check (note is null or length(note) <= 200),
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  seated_at timestamptz
);
create index if not exists reservations_day_idx on public.reservations (restaurant_id, branch_id, reserved_for);

-- p_when null = walk-in waiting list.
create or replace function public.save_reservation(p_id uuid, p_name text, p_phone text, p_party int, p_when timestamptz, p_table uuid, p_note text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_id uuid;
begin
  perform app.require_permission('order.create');
  perform app.require_feature('reservations');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the guest''s name.'; end if;
  if coalesce(p_party, 0) < 1 then raise exception 'Enter how many people.'; end if;
  if p_table is not null and not exists (select 1 from public.dining_tables where id = p_table and restaurant_id = v_rest and branch_id = v_branch and is_active) then
    raise exception 'That table does not exist.';
  end if;
  if p_id is null then
    insert into public.reservations (restaurant_id, branch_id, guest_name, phone, party_size, reserved_for, dining_table_id, status, note, created_by)
    values (v_rest, v_branch, left(trim(p_name), 80), app.clean_phone(p_phone), p_party, p_when, p_table,
            case when p_when is null then 'waiting' else 'booked' end, nullif(left(trim(p_note), 200), ''), app.current_user_id())
    returning id into v_id;
  else
    update public.reservations set guest_name = left(trim(p_name), 80), phone = app.clean_phone(p_phone), party_size = p_party,
           reserved_for = p_when, dining_table_id = p_table, note = nullif(left(trim(p_note), 200), ''), updated_at = now()
     where id = p_id and restaurant_id = v_rest and status in ('booked', 'waiting')
     returning id into v_id;
    if v_id is null then raise exception 'That booking cannot be changed any more.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.set_reservation_status(p_id uuid, p_status text, p_table uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('order.create');
  if p_status not in ('seated', 'cancelled', 'no_show', 'booked', 'waiting') then raise exception 'Unknown status.'; end if;
  update public.reservations set status = p_status, updated_at = now(),
         dining_table_id = coalesce(p_table, dining_table_id),
         seated_at = case when p_status = 'seated' then now() else seated_at end
   where id = p_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'Booking not found.'; end if;
end $$;

-- ---------- Staff timesheets ----------
create table if not exists public.time_entries (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  branch_id uuid not null references public.branches(id),
  user_id uuid not null references public.users(id),
  clock_in timestamptz not null,
  clock_out timestamptz,
  edited_by uuid references public.users(id),
  edit_reason text,
  created_at timestamptz not null default now(),
  check (clock_out is null or clock_out > clock_in)
);
create unique index if not exists time_entries_one_open on public.time_entries (user_id) where clock_out is null;
create index if not exists time_entries_day_idx on public.time_entries (restaurant_id, clock_in);

create or replace function public.clock_in() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.current_user_id(); v_id uuid;
begin
  perform app.require_feature('timesheets');
  if v_user is null then raise exception 'Not signed in.'; end if;
  if exists (select 1 from public.time_entries where user_id = v_user and clock_out is null) then raise exception 'You are already clocked in.'; end if;
  insert into public.time_entries (restaurant_id, branch_id, user_id, clock_in) values (app.current_restaurant_id(), app.current_branch_id(), v_user, now())
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'clock_in', now());
end $$;

create or replace function public.clock_out() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.current_user_id(); e public.time_entries%rowtype;
begin
  perform app.require_feature('timesheets');
  update public.time_entries set clock_out = now() where user_id = v_user and clock_out is null returning * into e;
  if e.id is null then raise exception 'You are not clocked in.'; end if;
  return jsonb_build_object('id', e.id, 'hours', round(extract(epoch from (e.clock_out - e.clock_in)) / 3600.0, 2));
end $$;

-- Manager fixes a forgotten clock-out or a wrong time; the reason is kept and logged.
create or replace function public.fix_time_entry(p_id uuid, p_in timestamptz, p_out timestamptz, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare old public.time_entries%rowtype;
begin
  perform app.require_permission('user.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'Enter a reason for the change.'; end if;
  if p_out is not null and p_out <= p_in then raise exception 'Clock-out must be after clock-in.'; end if;
  select * into old from public.time_entries where id = p_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Entry not found.'; end if;
  update public.time_entries set clock_in = p_in, clock_out = p_out, edited_by = app.current_user_id(), edit_reason = left(trim(p_reason), 200)
   where id = p_id;
  perform app.audit('timesheet.fix', 'time_entries', p_id,
    jsonb_build_object('clock_in', p_in, 'clock_out', p_out, 'reason', p_reason),
    jsonb_build_object('clock_in', old.clock_in, 'clock_out', old.clock_out));
end $$;

-- ---------- Read access (writes only through the functions above) ----------
do $$
declare t text;
begin
  foreach t in array array['loyalty_settings', 'loyalty_ledger', 'gift_cards', 'gift_card_ledger', 'time_entries'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists tenant_read on public.%I', t);
    execute format('create policy tenant_read on public.%I for select to authenticated using (restaurant_id = (select app.current_restaurant_id()))', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete on public.%I from authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
  alter table public.reservations enable row level security;
  drop policy if exists tenant_read on public.reservations;
  create policy tenant_read on public.reservations for select to authenticated
    using (restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id()));
  revoke all on public.reservations from anon;
  revoke insert, update, delete on public.reservations from authenticated;
  grant select on public.reservations to authenticated;
end $$;

revoke all on function public.save_loyalty_settings(numeric, numeric, int), public.attach_customer(uuid, text, text), public.redeem_points(uuid, numeric),
  public.issue_gift_card(numeric, uuid, text, text, int), public.gift_card_lookup(text), public.redeem_gift_card(uuid, text, numeric),
  public.save_reservation(uuid, text, text, int, timestamptz, uuid, text), public.set_reservation_status(uuid, text, uuid),
  public.clock_in(), public.clock_out(), public.fix_time_entry(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.save_loyalty_settings(numeric, numeric, int), public.attach_customer(uuid, text, text), public.redeem_points(uuid, numeric),
  public.issue_gift_card(numeric, uuid, text, text, int), public.gift_card_lookup(text), public.redeem_gift_card(uuid, text, numeric),
  public.save_reservation(uuid, text, text, int, timestamptz, uuid, text), public.set_reservation_status(uuid, text, uuid),
  public.clock_in(), public.clock_out(), public.fix_time_entry(uuid, timestamptz, timestamptz, text) to authenticated;
revoke all on function app.system_method(uuid, text), app.points_balance(uuid), app.gift_balance(uuid) from public, anon, authenticated;
