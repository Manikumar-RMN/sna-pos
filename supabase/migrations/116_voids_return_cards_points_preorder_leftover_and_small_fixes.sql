-- 116: Voids give back gift-card money and points; leftover pre-order advance is handed back; guest menu shows offer prices;
--      bookings cannot use another restaurant's table; clearer message for a huge party; credit notes cannot "pay" to a gift card.
--
-- Found by the end-to-end tests of the Loyalty, Reservations, Pre-orders and QR screens (app/e2e/extras.e2e.test.ts).
--
-- 1. VOIDING a bill that was paid (wholly or partly) with a gift card left the guest's card short: the money the bill used
--    was never put back. Points were the same: points the bill earned stayed with the guest, and points they spent on it were
--    not returned. A new trigger on orders (the same kind as the stock one) puts all three back when a bill becomes voided.
--    The card ledger gets a new entry kind, 'void' ("Bill voided").
-- 2. A pre-order whose advance was MORE than the final bill (a guest paid 1,000 for a 262 bill): the extra stayed "held" for a
--    bill that was already closed, no cash left the drawer, and the screen never said to give it back. Billing now hands the
--    extra back by the way it came in (newest advance first), records the refund and, for cash, takes it out of the drawer.
-- 3. The guest's QR menu showed the plain price, not the happy-hour / offer price the till charges. It now uses the same price.
-- 4. set_reservation_status accepted any table id, including another restaurant's. It now checks, like save_reservation does.
-- 5. save_reservation: a party over 200 failed with a raw database message. It now says so in words.
-- 6. issue_credit_note: the screen never offers gift card / points as the way money is given back (nothing would credit the card),
--    but the function accepted it. It now refuses.
-- Safe to run again.

alter table public.gift_card_ledger drop constraint if exists gift_card_ledger_kind_check;
alter table public.gift_card_ledger add constraint gift_card_ledger_kind_check
  check (kind = any (array['issue'::text, 'redeem'::text, 'topup'::text, 'payback'::text, 'void'::text]));

create or replace function app.return_on_void()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare r record;
begin
  if new.status <> 'voided' or old.status = 'voided' then return new; end if;
  -- gift card money this bill used goes back to the same card
  for r in select l.gift_card_id, -sum(l.amount) as used
             from public.gift_card_ledger l
            where l.order_id = new.id and l.kind in ('redeem', 'void')
            group by l.gift_card_id having -sum(l.amount) > 0 loop
    insert into public.gift_card_ledger (restaurant_id, gift_card_id, order_id, amount, kind, created_by)
    values (new.restaurant_id, r.gift_card_id, new.id, r.used, 'void', new.voided_by);
  end loop;
  -- points: what the bill earned is taken back, what was spent on it is returned
  for r in select l.customer_id, sum(l.points) as net
             from public.loyalty_ledger l
            where l.order_id = new.id
            group by l.customer_id having sum(l.points) <> 0 loop
    insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note, created_by)
    values (new.restaurant_id, r.customer_id, new.id, -r.net, 'adjust', 'Bill ' || new.bill_number || ' voided', new.voided_by);
  end loop;
  return new;
end $function$;

revoke all on function app.return_on_void() from public;

drop trigger if exists trg_return_on_void on public.orders;
create trigger trg_return_on_void after update of status on public.orders
  for each row when (new.status = 'voided' and old.status is distinct from 'voided')
  execute function app.return_on_void();

CREATE OR REPLACE FUNCTION public.pre_order_bill(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id();
  r public.pre_orders; v_res jsonb; o public.orders; v_held numeric(14,2); v_apply numeric(14,2); v_shift uuid; v_method uuid;
  v_extra numeric(14,2); v_give numeric(14,2); a record; v_kind text; v_drawer boolean;
begin
  select * into r from public.pre_orders where id = p_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Pre-order not found.'; end if;
  if r.status <> 'booked' then raise exception 'Pre-order % is already %.', r.number, r.status; end if;
  v_res := public.create_order(r.items, r.order_type, null::uuid,
            p_extra := jsonb_strip_nulls(jsonb_build_object('guest_name', r.guest_name, 'guest_phone', r.guest_phone, 'address', r.address)));
  select * into o from public.orders where id = (v_res->>'order_id')::uuid;
  v_held := app.pre_order_held(r.id);
  v_apply := least(v_held, o.grand_total);
  if v_apply > 0 then
    v_method := app.advance_method(v_rest);
    select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
    perform set_config('app.advance', 'on', true);
    insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, status, received_by, client_created_at, reference_no)
    values (gen_random_uuid(), o.restaurant_id, o.id, v_method, v_apply, o.currency_code, 'captured', v_user, now(), 'PO-' || r.number);
    perform set_config('app.advance', 'off', true);
    update public.orders set paid_total = paid_total + v_apply,
           payment_status = case when v_apply >= o.grand_total then 'paid' else 'partial' end,
           shift_id = coalesce(o.shift_id, v_shift)
     where id = o.id;
  end if;
  -- An advance above the bill: the extra is handed back, by the way it came in (newest advance first), and written down.
  v_extra := v_held - v_apply;
  if v_extra > 0 then
    select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
    for a in select p.payment_method_id, sum(case when p.kind = 'advance' then p.amount else -p.amount end) as net
               from public.pre_order_payments p where p.pre_order_id = r.id group by p.payment_method_id
             having sum(case when p.kind = 'advance' then p.amount else -p.amount end) > 0
              order by max(p.created_at) desc, p.payment_method_id loop
      exit when v_extra <= 0;
      v_give := least(a.net, v_extra);
      select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = a.payment_method_id;
      if (v_kind = 'cash' or coalesce(v_drawer, false)) and v_shift is null then
        raise exception 'Open a shift first: the advance is more than the bill, and % has to be handed back from the till.', v_extra;
      end if;
      insert into public.pre_order_payments (restaurant_id, pre_order_id, kind, payment_method_id, amount, shift_id, created_by)
      values (v_rest, r.id, 'refund', a.payment_method_id, v_give, v_shift, v_user);
      if v_kind = 'cash' or coalesce(v_drawer, false) then
        insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
        values (v_rest, v_shift, 'out', v_give, 'Pre-order PO-' || r.number || ' advance above the bill handed back', v_user);
      end if;
      v_extra := v_extra - v_give;
    end loop;
  end if;
  update public.pre_orders set status = 'billed', order_id = o.id, updated_at = now() where id = r.id;
  perform app.audit('preorder.bill', 'pre_orders', r.id, jsonb_build_object('number', r.number, 'bill', o.bill_number, 'advance_applied', v_apply), null);
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'total', o.grand_total, 'advance_applied', v_apply,
                            'balance', o.grand_total - v_apply, 'advance_left_over', v_held - v_apply, 'advance_handed_back', v_held - v_apply - v_extra);
end $function$
;

CREATE OR REPLACE FUNCTION public.qr_menu(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.dining_tables%rowtype := app.qr_table(p_token); r record;
begin
  select res.trading_name, res.currency_code, res.second_language, b.name as branch_name
    into r from public.restaurants res join public.branches b on b.id = t.branch_id where res.id = t.restaurant_id;
  return jsonb_build_object(
    'restaurant', r.trading_name, 'outlet', r.branch_name, 'currency', r.currency_code,
    'second_language', r.second_language, 'table', t.table_number, 'kiosk', t.is_kiosk,
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items', c.items) order by c.display_order, c.name)
        from (
          -- A sub-category's dishes are shown under its main category, headed by the sub-category's name ('sub').
          select top.id, top.name, top.display_order,
                 jsonb_agg(jsonb_build_object(
                   'id', p.id, 'name', p.name, 'name_local', p.name_local, 'is_veg', p.is_veg,
                   'sub', case when c.parent_id is not null then c.name end,
                   'price', app.rule_price(t.restaurant_id, t.branch_id, p.id, coalesce(bp.price, p.price), now()),
                   'option_groups', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'id', mg.id, 'name', mg.name,
                              'min', greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end),
                              'max', coalesce(mg.max_select, 99),
                              'options', (select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price_delta', mi.price_delta)
                                                             order by mi.display_order, mi.name), '[]'::jsonb)
                                            from public.modifier_items mi where mi.modifier_group_id = mg.id and mi.is_active))
                            order by mg.is_required desc, mg.name)
                       from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id
                      where pmg.product_id = p.id and mg.is_active), '[]'::jsonb))
                   order by (c.parent_id is not null), c.display_order, c.name, p.display_order, p.name) as items
            from public.categories c
            join public.categories top on top.id = coalesce(c.parent_id, c.id) and top.deleted_at is null
            join public.products p on p.category_id = c.id and p.deleted_at is null
            left join public.branch_prices bp on bp.product_id = p.id and bp.branch_id = t.branch_id
           where c.restaurant_id = t.restaurant_id and c.deleted_at is null
             and p.is_available and coalesce(bp.is_available, true)
             and not p.is_charge
             -- a dish with sizes is ordered by its sizes, which are listed as dishes of their own
             and not exists (select 1 from public.products ch where ch.parent_id = p.id and ch.deleted_at is null)
           group by top.id, top.name, top.display_order
        ) c), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.set_reservation_status(p_id uuid, p_status text, p_table uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('order.create');
  if p_status not in ('seated', 'cancelled', 'no_show', 'booked', 'waiting') then raise exception 'Unknown status.'; end if;
  if p_table is not null and not exists (select 1 from public.dining_tables
        where id = p_table and restaurant_id = app.current_restaurant_id() and is_active) then
    raise exception 'That table does not exist.';
  end if;
  update public.reservations set status = p_status, updated_at = now(),
         dining_table_id = coalesce(p_table, dining_table_id),
         seated_at = case when p_status = 'seated' then now() else seated_at end
   where id = p_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'Booking not found.'; end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.save_reservation(p_id uuid, p_name text, p_phone text, p_party integer, p_when timestamp with time zone, p_table uuid, p_note text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_id uuid;
begin
  perform app.require_permission('order.create');
  perform app.require_feature('reservations');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the guest''s name.'; end if;
  if coalesce(p_party, 0) < 1 then raise exception 'Enter how many people.'; end if;
  if p_party > 200 then raise exception 'A booking can be for at most 200 people.'; end if;
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
end $function$
;

CREATE OR REPLACE FUNCTION public.issue_credit_note(p_order_id uuid, p_amount numeric, p_method_id uuid, p_reason text, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid;
  o public.orders%rowtype; v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_done numeric(14,2); v_left numeric(14,2); v_country text; v_day public.business_days; v_shift uuid;
  v_kind text; v_ratio numeric; v_tax numeric(14,2); v_taxes jsonb; v_no text; v_seq int; v_fy text; v_code text;
  v_id uuid := gen_random_uuid(); v_deadline date;
  v_seen record; v_out jsonb;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen
      from public.request_refs rr where rr.restaurant_id = app.current_restaurant_id() and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'credit_note' or v_seen.order_id is distinct from p_order_id then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  v_user := app.require_permission('order.refund');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for the credit note.'; end if;
  if v_amount <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status <> 'completed' or o.merged_into is not null then raise exception 'Only a completed bill can get a credit note.'; end if;
  if o.payment_status in ('unpaid', 'partial') then
    raise exception 'Bill % is not fully paid. Cancel items or void it instead.', o.bill_number;
  end if;
  select coalesce(sum(amount), 0) into v_done from public.refunds where order_id = o.id;
  v_left := o.paid_total - v_done;
  if v_left <= 0 then raise exception 'Bill % has already been fully refunded.', o.bill_number; end if;
  if v_amount > v_left then raise exception 'The most that can be refunded on bill % is %.', o.bill_number, v_left; end if;

  select country_code into v_country from public.restaurants where id = o.restaurant_id;
  v_day := app.open_business_day(o.branch_id);
  if v_country = 'IN' then
    v_deadline := make_date(case when extract(month from o.business_date) >= 4 then extract(year from o.business_date)::int + 1
                                 else extract(year from o.business_date)::int end, 11, 30);
    if v_day.business_date > v_deadline then
      raise exception 'Under GST rules a credit note for bill % could only be issued until %.', o.bill_number, to_char(v_deadline, 'DD Mon YYYY');
    end if;
  end if;

  select pm.kind into v_kind from public.payment_methods pm where pm.id = p_method_id and pm.restaurant_id = o.restaurant_id and pm.is_active;
  if not found then raise exception 'Choose how the money is given back.'; end if;
  if v_kind in ('gift_card', 'loyalty', 'advance') then raise exception 'Money cannot be given back to a gift card, points or an advance. Choose cash, UPI, card or another payment mode.'; end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_kind = 'cash' and v_shift is null then raise exception 'Open a shift before giving cash back.'; end if;

  v_ratio := case when o.grand_total > 0 then v_amount / o.grand_total else 0 end;
  select coalesce(jsonb_agg(jsonb_build_object('name', c, 'rate', r, 'amount', round(a * v_ratio, 2)) order by r, c), '[]'::jsonb),
         coalesce(sum(round(a * v_ratio, 2)), 0)
    into v_taxes, v_tax
    from (select component_name c, rate r, sum(tax_amount) a from public.order_item_taxes where order_id = o.id group by 1, 2) x;

  perform pg_advisory_xact_lock(hashtext('credit_note:' || o.branch_id::text));
  v_fy := app.fy_label(v_country, v_day.business_date);
  if v_country = 'IN' then v_fy := substr(v_fy, 3, 2) || substr(v_fy, 6, 2); end if;  -- 2026-27 -> 2627 (GST: max 16 characters)
  select code into v_code from public.branches where id = o.branch_id;
  select count(*) + 1 into v_seq from public.credit_notes
   where branch_id = o.branch_id and number like 'CN-' || v_code || '-' || v_fy || '-%';
  v_no := 'CN-' || v_code || '-' || v_fy || '-' || lpad(v_seq::text, 4, '0');

  insert into public.credit_notes (id, restaurant_id, branch_id, order_id, number, business_date, shift_id, amount,
                                   tax_amount, taxes, reason, payment_method_id, created_by)
  values (v_id, o.restaurant_id, o.branch_id, o.id, v_no, v_day.business_date, v_shift, v_amount, v_tax, v_taxes,
          left(trim(p_reason), 300), p_method_id, v_user);
  insert into public.refunds (id, restaurant_id, order_id, payment_id, amount, reason, approved_by, client_created_at,
                              shift_id, payment_method_id, credit_note_id)
  values (gen_random_uuid(), o.restaurant_id, o.id, null, v_amount, left(trim(p_reason), 300), v_user, now(),
          v_shift, p_method_id, v_id);

  perform set_config('app.day_ok', 'on', true);
  update public.orders set payment_status = case when v_done + v_amount >= o.paid_total then 'refunded' else 'partially_refunded' end
   where id = o.id;
  perform set_config('app.day_ok', 'off', true);

  perform app.audit('credit_note.issue', 'credit_notes', v_id,
    jsonb_build_object('number', v_no, 'bill_number', o.bill_number, 'amount', v_amount, 'tax', v_tax,
                       'method_kind', v_kind, 'reason', left(trim(p_reason), 300)));
  v_out := jsonb_build_object('credit_note_id', v_id, 'number', v_no, 'amount', v_amount, 'tax', v_tax,
                            'remaining', v_left - v_amount);
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result)
    values (app.current_restaurant_id(), p_client_ref, 'credit_note', p_order_id, v_out);
    -- Request ids only matter for a retry within minutes; old ones are cleared as new ones arrive.
    delete from public.request_refs
     where restaurant_id = app.current_restaurant_id() and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $function$
;
