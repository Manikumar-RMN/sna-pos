-- 114: Offline bills no longer have to be believed.
--
-- Found while testing (e2e/offline.e2e.test.ts): the function that records bills made while the internet was down
-- accepted whatever price, discount and payment method the till sent, and only wrote a note ("flag") nobody ever saw:
-- the app never showed offline_flags, and the owner alerts did not include offline bills. A till that said a dosa cost
-- 1.00 got two dosas recorded for 2.00; a cashier without the discount right got a discount.
--
-- Now:
--   * A price that this menu never had is corrected to the real price (happy-hour rules included) and reported.
--     A price that was right when the till last copied the menu (the bill carries `snapshot_at`, honoured up to 14 days
--     before the bill) is still accepted, so a price change made while the till was offline is not a false alarm.
--   * A discount from someone without the discount right is removed and reported.
--   * An unknown payment method is reported (it is still recorded as cash).
--   * A till clock more than 5 minutes ahead is reported (it was already clamped to now).
--   * Every flagged bill writes an audit record 'order.offline_flagged', which becomes an owner alert
--     "Offline bill needs a look" (the bill screen also shows the notes: see app code).
-- The business day was never taken from the till's clock (it is always the open day), so a till clock cannot move a bill
-- into a closed day; that did not need a change.
--
-- Safe to run again (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION public.sync_offline_bill(p_bill jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_ref uuid; ser public.offline_series; v_seq int; v_no text; v_expected text; v_at timestamptz; v_liq boolean := false;
  v_shift uuid; v_existing uuid; it jsonb; v_prod public.products%rowtype; v_incl boolean; v_rate uuid; v_comps jsonb;
  v_lines jsonb := '[]'::jsonb; v_calc_lines jsonb := '[]'::jsonb; i int := 0; v_hist numeric; v_flags jsonb := '[]'::jsonb;
  v_opts jsonb; v_text text; v_delta numeric; v_price numeric; v_disc numeric; v_sc boolean; bs record; v_c jsonb;
  v_order uuid := gen_random_uuid(); v_ids uuid[]; v_method uuid; v_kind text; v_amount numeric(14,2); v_round numeric(14,2) := 0;
  v_tendered numeric; v_currency char(3); v_rmode text; v_device uuid;
  v_snap timestamptz; v_bp numeric; v_hsnap numeric; v_srv numeric; v_ok boolean; v_claim timestamptz; v_summary text;
begin
  v_ref := (p_bill->>'client_id')::uuid;
  if v_ref is null then raise exception 'Offline bill without an id.'; end if;
  perform pg_advisory_xact_lock(hashtext('order_ref:' || v_ref::text));
  select id into v_existing from public.orders where restaurant_id = v_rest and client_ref = v_ref;
  if found then return jsonb_build_object('ok', true, 'order_id', v_existing, 'repeat', true); end if;

  select * into ser from public.offline_series where branch_id = v_branch and device_key = p_bill->>'device_key' for update;
  if not found then raise exception 'This device has no offline bill series.'; end if;
  v_seq := (p_bill->>'seq')::int;
  if v_seq is null or v_seq < 1 or v_seq > 999999 then raise exception 'Bad offline bill number.'; end if;
  v_no := p_bill->>'number';
  -- New numbers: <one of this outlet's bill prefixes>-X<device>-<seq>. Older devices: <code>-X01-<fy>-<seq>.
  v_expected := '-X' || (substr(ser.prefix, 2)::int) || '-' || lpad(v_seq::text, greatest(4, length(v_seq::text)), '0');
  if not (right(coalesce(v_no, ''), length(v_expected)) = v_expected
          and (exists (select 1 from public.bill_series bs2 where bs2.branch_id = v_branch
                       and bs2.prefix = left(v_no, length(v_no) - length(v_expected)))
               or exists (select 1 from public.liquor_series ls where ls.branch_id = v_branch
                       and ls.prefix = left(v_no, length(v_no) - length(v_expected))))) then
    v_expected := (select code from public.branches where id = v_branch) || '-' || ser.prefix || '-' ||
                  case when p_bill->>'fy' is not null then (p_bill->>'fy') || '-' else '' end || lpad(v_seq::text, greatest(4, length(v_seq::text)), '0');
    if v_no is distinct from v_expected then raise exception 'Offline bill number % does not match this device.', v_no; end if;
  end if;
  v_liq := exists (select 1 from public.liquor_series ls where ls.branch_id = v_branch and v_no like ls.prefix || '-X%');
  if exists (select 1 from public.orders where branch_id = v_branch and bill_number = v_no) then
    raise exception 'Bill number % is already used.', v_no;
  end if;
  v_claim := coalesce((p_bill->>'created_at')::timestamptz, now());
  v_at := least(v_claim, now());
  -- A till clock that runs ahead is clamped to now (as before) and now reported, so the owner can have the clock fixed.
  if v_claim > now() + interval '5 minutes' then
    v_flags := v_flags || jsonb_build_object('flag', 'device_clock_ahead', 'till_time', v_claim, 'server_time', now());
  end if;
  -- When the till last copied the menu: its prices were right at that moment even if the owner changed them since.
  -- Only believed if it is no older than 14 days before the bill, so an old time cannot be used to reach old, cheap prices.
  begin v_snap := nullif(p_bill->>'snapshot_at', '')::timestamptz; exception when others then v_snap := null; end;
  if v_snap is not null and (v_snap > v_at or v_snap < v_at - interval '14 days') then v_snap := null; end if;
  if v_at < now() - interval '7 days' then v_flags := v_flags || jsonb_build_object('flag', 'older_than_7_days'); end if;

  select s.id into v_shift from public.shifts s where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1; if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then return jsonb_build_object('ok', false, 'reason', 'Open a shift to send offline bills.'); end if;

  -- Lines at the prices shown offline; any price that was not the menu price at that time is flagged for the owner.
  for it in select * from jsonb_array_elements(coalesce(p_bill->'items', '[]'::jsonb)) loop
    select * into v_prod from public.products where id = (it->>'product_id')::uuid and restaurant_id = v_rest;
    if not found then raise exception 'An item on offline bill % no longer exists.', v_no; end if;
    v_opts := '[]'::jsonb; v_delta := 0; v_text := null;
    if jsonb_typeof(it->'options') = 'array' and jsonb_array_length(it->'options') > 0 then
      select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price_delta', mi.price_delta, 'group', mg.name) order by mg.name, mi.display_order), '[]'::jsonb),
             coalesce(sum(mi.price_delta), 0), string_agg(mi.name, ', ' order by mg.name, mi.display_order)
        into v_opts, v_delta, v_text
        from jsonb_array_elements_text(it->'options') x
        join public.modifier_items mi on mi.id = x::uuid and mi.restaurant_id = v_rest
        join public.modifier_groups mg on mg.id = mi.modifier_group_id;
    end if;
    v_price := round((it->>'price')::numeric, 2);
    select price into v_hist from public.product_price_history
     where product_id = v_prod.id and valid_from <= v_at and (valid_to is null or valid_to > v_at) order by valid_from desc limit 1;
    if v_hist is null then
      select price into v_hist from public.product_price_history where product_id = v_prod.id order by valid_from limit 1;
    end if;
    v_bp := (select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = v_prod.id);
    -- the price this menu really had when the bill was made (happy-hour rules included)
    v_srv := app.rule_price(v_rest, v_branch, v_prod.id, coalesce(v_bp, v_hist, v_prod.price), v_at) + v_delta;
    v_ok := v_price = v_srv or v_price = coalesce(v_hist, v_prod.price) + v_delta or v_price = v_prod.price + v_delta
            or (v_bp is not null and v_price = v_bp + v_delta);
    if not v_ok and v_snap is not null then
      select price into v_hsnap from public.product_price_history
       where product_id = v_prod.id and valid_from <= v_snap and (valid_to is null or valid_to > v_snap) order by valid_from desc limit 1;
      if v_hsnap is not null then
        v_ok := v_price = v_hsnap + v_delta or v_price = app.rule_price(v_rest, v_branch, v_prod.id, coalesce(v_bp, v_hsnap), v_snap) + v_delta;
      end if;
    end if;
    if not v_ok then
      -- Not a price this menu has ever had: it is NOT trusted. The bill is recorded at the real price, and the owner is told.
      v_flags := v_flags || jsonb_build_object('flag', 'price_corrected', 'item', v_prod.name, 'offline_price', v_price, 'menu_price', v_srv);
      v_price := v_srv;
    end if;
    select g2.is_price_inclusive into v_incl from public.tax_groups g2 where g2.id = v_prod.tax_group_id;
    select tr.id into v_rate from public.tax_rates tr where tr.tax_group_id = v_prod.tax_group_id
       and tr.valid_from <= v_at::date and (tr.valid_to is null or tr.valid_to >= v_at::date) order by tr.valid_from desc limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'rate', rate, 'compound', is_compound) order by display_order), '[]'::jsonb)
      into v_comps from public.tax_rate_components where tax_rate_id = v_rate and applies_when in ('always', 'intra_region');
    if coalesce((it->>'qty')::numeric, 0) <= 0 or (it->>'qty')::numeric > 999 then raise exception 'Bad quantity on offline bill %.', v_no; end if;
    i := i + 1;
    v_lines := v_lines || jsonb_build_object('key', i, 'product_id', v_prod.id, 'name', v_prod.name, 'base_price', v_price - v_delta,
      'price', v_price, 'options', v_opts, 'options_text', v_text, 'qty', (it->>'qty')::numeric,
      'note', nullif(left(coalesce(it->>'note', ''), 200), ''), 'inclusive', coalesce(v_incl, false), 'comps', v_comps);
  end loop;
  if i = 0 then raise exception 'Offline bill % has no items.', v_no; end if;

  v_disc := round(coalesce((p_bill->>'discount')::numeric, 0), 2);
  if v_disc < 0 then v_disc := 0; end if;
  if v_disc > 0 and not app.allowed('order.discount') then
    -- Online, a discount needs a manager. Offline nobody can approve it, so without the right it is not honoured here.
    v_flags := v_flags || jsonb_build_object('flag', 'discount_removed', 'amount', v_disc);
    v_disc := 0;
  end if;
  select coalesce(s.service_charge_percent, 0) pct, coalesce(s.service_charge_taxable, false) tx,
         coalesce(s.cash_rounding_mode, 'none') rmode, coalesce(s.rounding_cash_only, false) rcash
    into bs from public.branch_settings s where s.branch_id = v_branch;
  v_sc := coalesce((p_bill->>'service_charge')::boolean, false) and bs.pct > 0;
  v_rmode := case when bs.rcash then 'none' else bs.rmode end;

  select d.id into v_device from public.devices d where d.branch_id = v_branch and d.is_active and d.device_type <> 'counter' order by d.created_at limit 1;
  select currency_code into v_currency from public.restaurants where id = v_rest;

  perform set_config('app.liquor_bill', case when v_liq then 'on' else '' end, true);
  insert into public.orders (id, restaurant_id, branch_id, device_id, bill_number, order_type, cashier_id, shift_id, currency_code,
                             status, payment_status, client_created_at, created_at, calc_params, client_ref, offline_flags)
  values (v_order, v_rest, v_branch, v_device, v_no, case when p_bill->>'order_type' in ('dine_in', 'takeaway', 'delivery') then p_bill->>'order_type' else 'takeaway' end,
          v_user, v_shift, v_currency, 'open', 'unpaid', v_at, v_at,
          jsonb_build_object('discount', v_disc, 'sc_percent', case when v_sc then bs.pct else 0 end, 'sc_taxable', bs.tx, 'senior', null, 'rounding', v_rmode),
          v_ref, nullif(v_flags, '[]'::jsonb));
  v_ids := app.insert_order_lines(v_order, v_rest, v_lines);
  v_c := app.recalc_order(v_order);
  if (v_c->>'discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (v_rest, v_order, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric, 'Offline bill', v_user);
  end if;
  if p_bill ? 'grand_total' and round((p_bill->>'grand_total')::numeric, 2) <> (v_c->>'grand_total')::numeric then
    v_flags := v_flags || jsonb_build_object('flag', 'total_differs', 'printed', (p_bill->>'grand_total')::numeric, 'recorded', (v_c->>'grand_total')::numeric);
  end if;

  v_method := (p_bill->>'method_id')::uuid;
  select kind into v_kind from public.payment_methods where id = v_method and restaurant_id = v_rest;
  if not found then
    v_flags := v_flags || jsonb_build_object('flag', 'method_unknown', 'sent', p_bill->>'method_id');
    select id, kind into v_method, v_kind from public.payment_methods where restaurant_id = v_rest and kind = 'cash' limit 1;
  end if;
  v_amount := (v_c->>'grand_total')::numeric;
  if v_kind = 'cash' and bs.rcash and bs.rmode <> 'none' then
    v_amount := app.round_cash(v_amount, bs.rmode);
    v_round := v_amount - (v_c->>'grand_total')::numeric;
  end if;
  v_tendered := nullif((p_bill->>'tendered')::numeric, 0);
  if v_amount > 0 then
    insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, tendered_amount, change_amount,
                                 status, received_by, client_created_at, rounding_adjustment, reference_no, client_ref, shift_id)
    values (gen_random_uuid(), v_rest, v_order, v_method, v_amount, v_currency, case when v_tendered >= v_amount then v_tendered end,
            case when v_tendered >= v_amount then v_tendered - v_amount else 0 end, 'captured', v_user, v_at, v_round,
            nullif(left(trim(coalesce(p_bill->>'reference', '')), 60), ''), v_ref, v_shift);
  end if;
  update public.orders set status = 'completed', payment_status = 'paid', paid_total = v_amount, synced_at = now() where id = v_order;
  -- The kitchen already got a printed ticket offline; keep a served ticket for the record.
  perform app.create_kitchen_ticket(v_order, v_ids);
  update public.kitchen_tickets set status = 'served', printed_at = v_at where order_id = v_order;

  if v_liq then
    update public.offline_series set liquor_next_seq = greatest(liquor_next_seq, v_seq + 1), last_sync_at = now() where id = ser.id;
  else
  update public.offline_series set next_seq = greatest(next_seq, v_seq + 1), last_sync_at = now() where id = ser.id;
  end if;
  if jsonb_array_length(v_flags) > 0 then
    update public.orders set offline_flags = v_flags where id = v_order;
    select string_agg(case f->>'flag'
             when 'price_corrected' then 'price of ' || (f->>'item') || ' corrected ' || (f->>'offline_price') || ' -> ' || (f->>'menu_price')
             when 'discount_removed' then 'discount ' || (f->>'amount') || ' removed (no right to give it)'
             when 'method_unknown' then 'unknown payment method, recorded as cash'
             when 'total_differs' then 'till total ' || (f->>'printed') || ' but bill ' || (f->>'recorded')
             when 'device_clock_ahead' then 'till clock was ahead'
             when 'older_than_7_days' then 'bill is over 7 days old'
             else f->>'flag' end, '; ') into v_summary
      from jsonb_array_elements(v_flags) f;
    perform app.audit('order.offline_flagged', 'orders', v_order,
      jsonb_build_object('bill_number', v_no, 'summary', v_summary, 'flags', v_flags));
  end if;
  perform app.audit('order.offline_sync', 'orders', v_order,
    jsonb_build_object('bill_number', v_no, 'grand_total', (v_c->>'grand_total')::numeric, 'made_at', v_at, 'flags', v_flags));
  return jsonb_build_object('ok', true, 'order_id', v_order, 'bill_number', v_no, 'grand_total', (v_c->>'grand_total')::numeric,
                            'flags', v_flags);
end $function$;

CREATE OR REPLACE FUNCTION app.audit_to_alert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_title text; v_body text; v_who text; v_outlet text; v_cur text; n jsonb := coalesce(new.new_value, '{}'::jsonb); o jsonb := coalesce(new.old_value, '{}'::jsonb); v_bill text;
begin
  if new.restaurant_id is null or new.action not in ('order.void', 'credit_note.issue', 'day.close', 'day.reopen', 'shift.close', 'order.adjust',
      'order.cancel_item', 'payment.change_mode', 'approval.granted', 'menu.price_or_tax_changed', 'order.offline_flagged') then
    return new;
  end if;
  if not app.feature_on(new.restaurant_id, 'owner_app') then return new; end if;
  if new.action = 'order.adjust' and coalesce((n->>'discount')::numeric, 0) = 0 then return new; end if;
  if new.action = 'shift.close' and coalesce((n->>'variance')::numeric, 0) = 0 then return new; end if;
  select full_name into v_who from public.users where id = new.user_id;
  select name into v_outlet from public.branches where id = new.branch_id;
  select currency_code into v_cur from public.restaurants where id = new.restaurant_id;
  if new.action = 'order.void' then select bill_number into v_bill from public.orders where id = new.entity_id; end if;
  v_title := case new.action
    when 'order.void' then 'Bill voided'
    when 'credit_note.issue' then 'Credit note (refund)'
    when 'day.close' then 'Day closed'
    when 'day.reopen' then 'Day reopened'
    when 'shift.close' then 'Cash short / over at shift close'
    when 'order.adjust' then 'Discount given'
    when 'order.cancel_item' then 'Item cancelled'
    when 'payment.change_mode' then 'Payment mode changed'
    when 'approval.granted' then 'Manager PIN used'
    when 'order.offline_flagged' then 'Offline bill needs a look'
    else 'Price changed' end;
  v_body := concat_ws(' · ',
    case new.action
      when 'order.void' then concat('Bill ', v_bill, ' ', v_cur, ' ', o->>'grand_total', ' — ', n->>'reason')
      when 'credit_note.issue' then concat(n->>'number', ' on bill ', n->>'bill_number', ': ', v_cur, ' ', n->>'amount', ' — ', n->>'reason')
      when 'day.close' then concat(n->>'business_date', ': ', n->>'bills', ' bills, ', v_cur, ' ', n->>'total_billed')
      when 'day.reopen' then concat(n->>'business_date', ' — ', n->>'reason')
      when 'shift.close' then concat('Counted ', v_cur, ' ', n->>'counted_cash', ', expected ', n->>'expected_cash', ' (', n->>'variance', ')')
      when 'order.adjust' then concat('Bill ', n->>'bill_number', ': discount ', v_cur, ' ', n->>'discount', coalesce(' — ' || (n->>'reason'), ''))
      when 'order.cancel_item' then concat('Bill ', n->>'bill_number', ': ', n->>'qty', ' × ', n->>'item', ' — ', n->>'reason')
      when 'payment.change_mode' then concat('Bill ', n->>'bill_number', ': ', o->>'method', ' → ', n->>'method', ' — ', n->>'reason')
      when 'approval.granted' then concat(n->>'approver', ' approved ', n->>'permission')
      when 'order.offline_flagged' then concat('Bill ', n->>'bill_number', ': ', n->>'summary')
      else concat(n->>'name', ': ', o->>'price', ' → ', n->>'price') end,
    v_who, v_outlet);
  insert into public.owner_alerts (restaurant_id, branch_id, kind, title, body) values (new.restaurant_id, new.branch_id, new.action, v_title, left(v_body, 300));
  return new;
end $function$
;
