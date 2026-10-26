-- 147: sync_offline_bill carries the guest and the discount block (the ONLY rewrite of sync_offline_bill in this batch; a copy of 140 with three small edits).
--
--  (a) Guest. An offline bill may carry guest_phone / guest_name (optional keys of the bill the till sends). The phone finds or starts the customer exactly as
--      create_order does and the bill is stored with customer_id + guest_name + guest_phone, so the loyalty points are EARNED when the bill is marked paid at
--      the end of the sync (the earn trigger of 064 fires on the final payment_status update). A retried sync returns early by client_ref: one order, one earn row.
--      A phone shorter than 7 digits is not a reason to lose a bill that is already paid and printed: it is dropped and flagged 'guest_phone_invalid'.
--      Loyalty REDEEM is online only (the balance must be checked), so there is nothing for redeem here.
--  (b) Discount block. Every line takes 'no_disc' from the product (dish or the dish its size belongs to), like app.bill_input (141). The server recalculates with
--      app.calc_bill, so a till that did not know the flag (old menu copy) is corrected here, and 'discount_cut' (already in 140) reports the difference.
--  (c) The flag summary knows 'guest_phone_invalid'.
--  (d) (integrator, at the end of this file) offline_snapshot gets 'no_discount' on every menu item and settings.loyalty, so the till can mirror the block offline.
-- Bills without guest keys and without restricted dishes behave exactly as in 140. Re-runnable (create or replace; grants kept).

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
  v_has_liq boolean := false; v_has_food boolean := false; v_isliq boolean; v_expect_seq int; v_open boolean;
  v_nodisc boolean; v_gname text; v_gphone text; v_cust uuid; v_gdel timestamptz;
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
  -- After the licence has ended, a bill dated before this device last connected cannot be trusted: it is refused.
  -- Every bill accepted then is flagged so the owner sees it.
  if app.licence_locked(v_rest, now()) then
    if ser.snapshot_at is null or v_at < ser.snapshot_at then
      raise exception 'The SNA POS licence for this restaurant has ended. Offline bill % is dated before this device last connected, so it cannot be accepted.', v_no;
    end if;
    v_flags := v_flags || jsonb_build_object('flag', 'sent_after_licence_ended');
  end if;
  -- Numbers skipped before this one (a bill that has not been sent yet, or one that was lost).
  v_expect_seq := case when v_liq then ser.liquor_next_seq else ser.next_seq end;
  if v_seq > v_expect_seq then
    v_flags := v_flags || jsonb_build_object('flag', 'numbers_skipped', 'from', v_expect_seq, 'to', v_seq - 1);
  end if;

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
    -- Open-priced item (products.is_open_price): the till's price is what the customer paid, there is no menu price to compare with.
    v_open := coalesce(v_prod.is_open_price, false);
    -- 147: a dish (or the dish its size belongs to) marked "Do not allow discounts" takes no share of the bill discount.
    v_nodisc := coalesce(v_prod.discount_restricted, false) or coalesce((select pp.discount_restricted from public.products pp where pp.id = v_prod.parent_id), false);
    if v_open then
      if v_price is null or v_price - v_delta <= 0 then
        raise exception 'Offline bill %: the price of % (open price) is not above zero, so the server cannot accept this bill.', v_no, v_prod.name;
      end if;
      if v_price > 99999999 then
        raise exception 'Offline bill %: the price of % (open price) is too large, so the server cannot accept this bill.', v_no, v_prod.name;
      end if;
      -- The money was already taken and the bill printed, so a user without the right is NOT refused: the bill is recorded and flagged for review.
      if not app.has_permission('order.open_price') then
        v_flags := v_flags || jsonb_build_object('flag', 'open_price_no_right', 'item', v_prod.name, 'price', v_price);
      end if;
    end if;
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
    if not v_ok and not v_open then
      -- Not a price this menu has ever had: it is NOT trusted. The bill is recorded at the real price, and the owner is told.
      v_flags := v_flags || jsonb_build_object('flag', 'price_corrected', 'item', v_prod.name, 'offline_price', v_price, 'menu_price', v_srv);
      v_price := v_srv;
    end if;
    select coalesce(g3.separate_bill, false) and not v_prod.is_charge into v_isliq from public.tax_groups g3 where g3.id = v_prod.tax_group_id;
    if not v_prod.is_charge then
      if coalesce(v_isliq, false) then v_has_liq := true; else v_has_food := true; end if;
    end if;
    select g2.is_price_inclusive into v_incl from public.tax_groups g2 where g2.id = v_prod.tax_group_id;
    select tr.id into v_rate from public.tax_rates tr where tr.tax_group_id = v_prod.tax_group_id
       and tr.valid_from <= v_at::date and (tr.valid_to is null or tr.valid_to >= v_at::date) order by tr.valid_from desc limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'rate', rate, 'compound', is_compound) order by display_order), '[]'::jsonb)
      into v_comps from public.tax_rate_components where tax_rate_id = v_rate and applies_when in ('always', 'intra_region');
    if coalesce((it->>'qty')::numeric, 0) <= 0 or (it->>'qty')::numeric > 999 then raise exception 'Bad quantity on offline bill %.', v_no; end if;
    i := i + 1;
    v_lines := v_lines || (jsonb_build_object('key', i, 'product_id', v_prod.id, 'name', v_prod.name, 'base_price', v_price - v_delta,
      'price', v_price, 'options', v_opts, 'options_text', v_text, 'qty', (it->>'qty')::numeric,
      'note', nullif(left(coalesce(it->>'note', ''), 200), ''), 'inclusive', coalesce(v_incl, false), 'comps', v_comps)
      || case when v_open then jsonb_build_object('open_price', true) else '{}'::jsonb end
      || case when v_nodisc then jsonb_build_object('no_disc', true) else '{}'::jsonb end);
  end loop;
  if i = 0 then raise exception 'Offline bill % has no items.', v_no; end if;
  if v_has_liq and v_has_food then
    v_flags := v_flags || jsonb_build_object('flag', 'liquor_and_food_mixed');
  elsif v_has_liq and not v_liq then
    v_flags := v_flags || jsonb_build_object('flag', 'liquor_on_food_series');
  elsif v_has_food and v_liq then
    v_flags := v_flags || jsonb_build_object('flag', 'food_on_liquor_series');
  end if;

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

  -- 147: the guest the counter keyed offline (optional). The phone finds or starts the customer exactly as create_order does, so the points
  -- are earned when the bill is marked paid below. A phone that is too short is NOT a reason to refuse a bill that was already paid and
  -- printed: it is dropped and flagged for the owner.
  v_gname  := nullif(left(trim(coalesce(p_bill->>'guest_name', '')), 80), '');
  v_gphone := app.clean_phone(p_bill->>'guest_phone');
  if v_gphone is not null and length(regexp_replace(p_bill->>'guest_phone', '[^0-9]', '', 'g')) < 7 then
    v_flags := v_flags || jsonb_build_object('flag', 'guest_phone_invalid');
    v_gphone := null;
  end if;
  if v_gphone is not null then
    select c.id, c.deleted_at into v_cust, v_gdel from public.customers c where c.restaurant_id = v_rest and c.phone = v_gphone;
    if v_cust is null then
      insert into public.customers (restaurant_id, name, phone) values (v_rest, coalesce(v_gname, 'Guest'), v_gphone)
      on conflict (restaurant_id, phone) do nothing returning id into v_cust;
      if v_cust is null then
        select c.id, c.deleted_at into v_cust, v_gdel from public.customers c where c.restaurant_id = v_rest and c.phone = v_gphone;
      end if;
    end if;
    if v_cust is not null then
      update public.customers set deleted_at = null,
             name = case when v_gname is not null and (name is null or name = 'Guest' or v_gdel is not null) then v_gname else name end
       where id = v_cust and (v_gdel is not null or (v_gname is not null and (name is null or name = 'Guest')));
    end if;
  end if;

  perform set_config('app.liquor_bill', case when v_liq then 'on' else '' end, true);
  insert into public.orders (id, restaurant_id, branch_id, device_id, bill_number, order_type, cashier_id, shift_id, currency_code,
                             status, payment_status, client_created_at, created_at, calc_params, client_ref, offline_flags,
                             customer_id, guest_name, guest_phone)
  values (v_order, v_rest, v_branch, v_device, v_no, case when p_bill->>'order_type' in ('dine_in', 'takeaway', 'delivery') then p_bill->>'order_type' else 'takeaway' end,
          v_user, v_shift, v_currency, 'open', 'unpaid', v_at, v_at,
          jsonb_build_object('discount', v_disc, 'sc_percent', case when v_sc then bs.pct else 0 end, 'sc_taxable', bs.tx, 'senior', null, 'rounding', v_rmode),
          v_ref, nullif(v_flags, '[]'::jsonb), v_cust, v_gname, v_gphone);
  v_ids := app.insert_order_lines(v_order, v_rest, v_lines);
  v_c := app.recalc_order(v_order);
  if (v_c->>'discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (v_rest, v_order, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric, 'Offline bill', v_user);
  end if;
  if v_disc > (v_c->>'discount')::numeric then
    v_flags := v_flags || jsonb_build_object('flag', 'discount_cut', 'asked', v_disc, 'recorded', (v_c->>'discount')::numeric);
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
             when 'sent_after_licence_ended' then 'sent after the licence had ended'
             when 'numbers_skipped' then 'bill numbers ' || (f->>'from') || ' to ' || (f->>'to') || ' were skipped'
             when 'liquor_and_food_mixed' then 'liquor and food on one bill'
             when 'liquor_on_food_series' then 'liquor on a food bill number'
             when 'food_on_liquor_series' then 'food on a liquor bill number'
             when 'open_price_no_right' then 'open-price item ' || (f->>'item') || ' at ' || (f->>'price') || ' sold without the open-price right'
             when 'discount_cut' then 'discount ' || (f->>'asked') || ' cut to ' || (f->>'recorded')
             when 'guest_phone_invalid' then 'guest phone number was too short and was not saved'
             else f->>'flag' end, '; ') into v_summary
      from jsonb_array_elements(v_flags) f;
    perform app.audit('order.offline_flagged', 'orders', v_order,
      jsonb_build_object('bill_number', v_no, 'summary', v_summary, 'flags', v_flags));
    if exists (select 1 from jsonb_array_elements(v_flags) f where f->>'flag' = 'open_price_no_right') then
      perform app.audit('order.open_price_offline', 'orders', v_order,
        jsonb_build_object('bill_number', v_no, 'user_id', v_user, 'review', true,
                           'items', (select jsonb_agg(f) from jsonb_array_elements(v_flags) f where f->>'flag' = 'open_price_no_right')));
    end if;
  end if;
  perform app.audit('order.offline_sync', 'orders', v_order,
    jsonb_build_object('bill_number', v_no, 'grand_total', (v_c->>'grand_total')::numeric, 'made_at', v_at, 'flags', v_flags));
  return jsonb_build_object('ok', true, 'order_id', v_order, 'bill_number', v_no, 'grand_total', (v_c->>'grand_total')::numeric,
                            'flags', v_flags);
end $function$;

-- ---------------------------------------------------------------- integrator addition: offline_snapshot tells the till about the block and the loyalty module
-- The plan (3.4 "snapshot menu carries no_discount per item") needs the snapshot to carry the flag; without it the till offers a discount on a "no discount" dish
-- offline and the server then cuts it on sync (flag discount_cut). Also settings.loyalty, so the offline receipt can say "Points will be added after sync".
-- Text patch of the live function (same method as 111): two replaces, each checked, done once.
do $patch147$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.offline_snapshot(text)'::regprocedure);
  if position('''no_discount''' in d) > 0 then return; end if;     -- already patched
  d2 := replace(d, '''inclusive'', coalesce(g.is_price_inclusive, false),', '''inclusive'', coalesce(g.is_price_inclusive, false), ''no_discount'', coalesce(p.discount_restricted, false),');
  if d2 = d then raise exception '147: could not find the menu item keys in offline_snapshot'; end if;
  d := d2;
  d2 := replace(d, '''settings'', jsonb_build_object(''sc_percent'', v_bs.pct,', '''settings'', jsonb_build_object(''loyalty'', app.feature_on(v_rest, ''loyalty''), ''sc_percent'', v_bs.pct,');
  if d2 = d then raise exception '147: could not find the settings keys in offline_snapshot'; end if;
  execute d2;
end $patch147$;
