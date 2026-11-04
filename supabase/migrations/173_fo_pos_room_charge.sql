-- 173: POS "Charge to room" — a restaurant bill is put on the folio of a guest who is in the hotel.
--
-- Same idea as "charge to account" (migration 100): the bill is paid in full by a hidden payment method, here of the
-- kind "room", and the amount is added to what the guest owes. The guest then settles it with the rest of the folio at
-- check-out.
--
--   * The bill keeps its own GST. The folio line is for the bill total, tax included, with no second GST on top
--     (tax_pct 0), so the guest is never taxed twice. It is worded "Restaurant bill #N (tax included)".
--   * Voiding the bill voids the folio line, until the guest has checked out. After check-out the folio is closed;
--     the answer is then a credit note on the hotel invoice, not a void.
--   * A refund / credit note on the POS side is refused for a room-charged bill, because it would pay cash back for
--     money that was never taken in the restaurant.
--   * The night audit's "other revenue" still includes these lines (they are on the folio). They are separate from the
--     restaurant's own sales report, where the bill is shown with the payment method "Room charge".

alter table public.payment_methods drop constraint payment_methods_kind_check;
alter table public.payment_methods add constraint payment_methods_kind_check
  check (kind = any (array['cash', 'card', 'wallet', 'bank_transfer', 'upi', 'other', 'gift_card', 'loyalty', 'advance', 'account', 'room']));

create or replace function app.room_method(p_rest uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v uuid;
begin
  select id into v from public.payment_methods where restaurant_id = p_rest and kind = 'room' order by display_order limit 1;
  if v is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order)
    values (p_rest, 'Room charge', 'room', false, false, 97) returning id into v;
  end if;
  return v;
end $function$;
revoke all on function app.room_method(uuid) from public, anon, authenticated;

-- Room payments are written only by "Charge to room".
create or replace function app.guard_redeem_payment()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
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
    if k_new = 'room' and coalesce(current_setting('app.room', true), '') <> 'on' then
      raise exception 'Use "Charge to room" on the bill for this payment.';
    end if;
  elsif new.payment_method_id is distinct from old.payment_method_id then
    select kind into k_old from public.payment_methods where id = old.payment_method_id;
    if k_new in ('gift_card', 'loyalty', 'advance', 'account', 'room') or k_old in ('gift_card', 'loyalty', 'advance', 'account', 'room') then
      raise exception 'A gift card, points, advance, account or room payment cannot be changed to another method, or the other way round.';
    end if;
  end if;
  return new;
end $function$;

-- Guests that a bill can be charged to: in the hotel now, in this branch.
create or replace function public.fo_inhouse_for_pos()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  perform app.require_permission('payment.take');
  return coalesce((
    select jsonb_agg(jsonb_build_object('stay_id', s.id, 'stay_no', s.stay_no, 'room_number', r.room_number,
                                        'guest', g.full_name) order by r.room_number)
      from public.fo_stays s
      join public.fo_rooms r on r.restaurant_id = s.restaurant_id and r.id = s.room_id
      join public.fo_guests g on g.restaurant_id = s.restaurant_id and g.id = s.guest_id
     where s.restaurant_id = v_rest and s.branch_id = v_branch and s.status = 'inhouse'), '[]'::jsonb);
end $function$;
revoke all on function public.fo_inhouse_for_pos() from public, anon;
grant execute on function public.fo_inhouse_for_pos() to authenticated;

-- Charge what is left to pay on a bill to the folio of a guest who is in the hotel.
create or replace function public.fo_charge_bill_to_room(p_order uuid, p_stay uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id();
  o public.orders; s public.fo_stays; v_due numeric(14,2); v_shift uuid; v_room text; v_guest text; v_id uuid;
begin
  select * into o from public.orders where id = p_order and restaurant_id = v_rest for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', o.bill_number; end if;
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest for update;
  if not found then raise exception 'That guest was not found.'; end if;
  if s.branch_id <> o.branch_id then raise exception 'That guest is staying at another branch.'; end if;
  if s.status <> 'inhouse' then raise exception 'Only a guest who is in the hotel now can be charged. This stay is %.', s.status; end if;
  v_due := o.grand_total - app.order_covered(o.id);
  if v_due <= 0 then raise exception 'Bill % has nothing left to pay.', o.bill_number; end if;
  select r.room_number into v_room from public.fo_rooms r where r.id = s.room_id;
  select g.full_name into v_guest from public.fo_guests g where g.id = s.guest_id;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;

  perform set_config('app.room', 'on', true);
  insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, status, received_by, client_created_at, reference_no)
  values (gen_random_uuid(), o.restaurant_id, o.id, app.room_method(v_rest), v_due, o.currency_code, 'captured', v_user, now(),
          left('Room ' || coalesce(v_room, '?') || ': ' || v_guest, 60));
  perform set_config('app.room', 'off', true);
  update public.orders set paid_total = paid_total + v_due, payment_status = 'paid', shift_id = coalesce(shift_id, v_shift)
   where id = o.id;

  insert into public.fo_charges (restaurant_id, branch_id, stay_id, business_date, kind, description, quantity, unit_amount,
                                 net_amount, tax_pct, tax_amount, total_amount, order_id, created_by)
  values (v_rest, o.branch_id, s.id, app.business_today(o.branch_id), 'food',
          left('Restaurant bill #' || o.bill_number || ' (tax included)' || coalesce(' - ' || nullif(left(btrim(coalesce(p_note, '')), 80), ''), ''), 200),
          1, v_due, v_due, 0, 0, v_due, o.id, v_user)
  returning id into v_id;

  perform app.audit('room.charge', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'stay_id', s.id, 'room', v_room, 'guest', v_guest, 'amount', v_due, 'charge_id', v_id), null);
  return jsonb_build_object('charged', v_due, 'charge_id', v_id, 'room_number', v_room, 'guest', v_guest);
end $function$;
revoke all on function public.fo_charge_bill_to_room(uuid, uuid, text) from public, anon;
grant execute on function public.fo_charge_bill_to_room(uuid, uuid, text) to authenticated;

-- Voiding a room-charged bill takes its line off the folio. After check-out the folio is closed, so it is refused.
create or replace function app.trg_room_charge_void()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.status = 'voided' and old.status is distinct from 'voided' then
    if exists (select 1 from public.fo_charges c join public.fo_stays s on s.id = c.stay_id
                where c.order_id = new.id and c.voided_at is null and s.status = 'checked_out') then
      raise exception 'Bill % was charged to a room and the guest has checked out. Raise a credit note on the hotel invoice instead of voiding it.', new.bill_number;
    end if;
    update public.fo_charges set voided_at = now(), void_reason = 'Restaurant bill ' || new.bill_number || ' was voided',
           voided_by = new.voided_by
     where order_id = new.id and voided_at is null;
  end if;
  return new;
end $function$;
revoke all on function app.trg_room_charge_void() from public, anon, authenticated;
drop trigger if exists trg_room_charge_void on public.orders;
create trigger trg_room_charge_void before update of status on public.orders
  for each row execute function app.trg_room_charge_void();

-- No cash is given back for a bill whose money is on a guest's folio.
create or replace function app.trg_room_charge_no_refund()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if exists (select 1 from public.fo_charges c where c.order_id = new.order_id and c.voided_at is null) then
    raise exception 'This bill was charged to a room. Void the bill before the guest checks out, or raise a credit note on the hotel invoice.';
  end if;
  return new;
end $function$;
revoke all on function app.trg_room_charge_no_refund() from public, anon, authenticated;
drop trigger if exists trg_room_charge_no_refund on public.refunds;
create trigger trg_room_charge_no_refund before insert on public.refunds
  for each row execute function app.trg_room_charge_no_refund();
