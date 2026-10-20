-- 122: Offline sync checks, licence lock, Z report.
--
--  * Offline bills: a discount cut to the bill, liquor mixed with food (or on the wrong series), skipped bill numbers are flagged
--    for the owner. After the licence has ended a device can no longer fetch a new offline series, and bills dated before the device
--    last connected are refused.
--  * Gift cards, top-ups, pre-orders and advances are new sales: refused while the licence has ended.
--  * Z report: the first and last bill follow the time they were made (not text order), kept apart for the liquor series; cash rounding is shown.

alter table public.offline_series add column if not exists snapshot_at timestamptz;

create or replace function app.require_unlocked()
returns void
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if app.licence_locked(app.current_restaurant_id(), now()) then
    raise exception '%', 'The SNA POS licence for this restaurant has ended, so new sales cannot be made. Please contact SNA to renew.';
  end if;
end $function$;
revoke all on function app.require_unlocked() from public, anon, authenticated;

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
  perform app.require_unlocked();
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
end $function$;

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
  perform app.require_unlocked();
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
end $function$;

CREATE OR REPLACE FUNCTION public.pre_order_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_id uuid := nullif(p->>'id', '')::uuid; v_due timestamptz; v_in jsonb; v_c jsonb; v_est numeric; r public.pre_orders; v_no int;
  v_type text := coalesce(nullif(p->>'order_type', ''), 'takeaway');
begin
  perform app.require_unlocked();
  if v_branch is null then raise exception 'No outlet chosen.'; end if;
  if coalesce(btrim(p->>'guest_name'), '') = '' then raise exception 'Enter the guest''s name.'; end if;
  begin v_due := (p->>'due_at')::timestamptz; exception when others then raise exception 'Enter when the order is due.'; end;
  if v_due is null then raise exception 'Enter when the order is due.'; end if;
  if v_id is null and v_due < now() then raise exception 'The due time is in the past.'; end if;
  if v_due > now() + interval '180 days' then raise exception 'A pre-order can be at most 180 days ahead.'; end if;
  if v_type = 'delivery' and coalesce(btrim(p->>'address'), '') = '' then raise exception 'Enter the delivery address.'; end if;
  -- the same checks as a bill: dishes on the menu, options, sizes
  v_in := app.bill_input(v_rest, v_branch, p->'items', 0, null, null);
  v_c := app.calc_bill(v_in->'calc');
  v_est := coalesce((v_c->>'grand_total')::numeric, 0);
  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('pre_order_no:' || v_rest::text));
    select coalesce(max(number), 0) + 1 into v_no from public.pre_orders where restaurant_id = v_rest;
    insert into public.pre_orders (restaurant_id, branch_id, number, guest_name, guest_phone, due_at, order_type, address, note, items, estimate, created_by)
    values (v_rest, v_branch, v_no, btrim(p->>'guest_name'), app.clean_phone(p->>'guest_phone'), v_due, v_type,
            nullif(btrim(coalesce(p->>'address', '')), ''), nullif(btrim(coalesce(p->>'note', '')), ''), p->'items', v_est, v_user)
    returning * into r;
  else
    update public.pre_orders set guest_name = btrim(p->>'guest_name'), guest_phone = app.clean_phone(p->>'guest_phone'), due_at = v_due,
           order_type = v_type, address = nullif(btrim(coalesce(p->>'address', '')), ''), note = nullif(btrim(coalesce(p->>'note', '')), ''),
           items = p->'items', estimate = v_est, updated_at = now()
     where id = v_id and restaurant_id = v_rest and status = 'booked' returning * into r;
    if not found then raise exception 'That pre-order is not open for changes.'; end if;
  end if;
  return jsonb_build_object('id', r.id, 'number', r.number, 'estimate', r.estimate);
end $function$;

CREATE OR REPLACE FUNCTION public.pre_order_advance(p_id uuid, p_method uuid, p_amount numeric, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('payment.take');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  r public.pre_orders; v_kind text; v_drawer boolean; v_shift uuid; v_amt numeric(14,2) := round(coalesce(p_amount, 0), 2);
begin
  perform app.require_unlocked();
  select * into r from public.pre_orders where id = p_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Pre-order not found.'; end if;
  if r.status <> 'booked' then raise exception 'Pre-order % is already %.', r.number, r.status; end if;
  if v_amt <= 0 then raise exception 'Enter the advance amount.'; end if;
  select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_method and restaurant_id = v_rest and is_active;
  if not found or v_kind in ('gift_card', 'loyalty', 'advance') then raise exception 'Choose how the guest paid the advance.'; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift before taking an advance.'; end if;
  insert into public.pre_order_payments (restaurant_id, pre_order_id, kind, payment_method_id, amount, reference, shift_id, created_by)
  values (v_rest, r.id, 'advance', p_method, v_amt, nullif(left(btrim(coalesce(p_reference, '')), 60), ''), v_shift, v_user);
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', v_amt, 'Pre-order PO-' || r.number || ' advance', v_user);
  end if;
  perform app.audit('preorder.advance', 'pre_orders', r.id, jsonb_build_object('number', r.number, 'amount', v_amt, 'method', v_kind), null);
  return jsonb_build_object('held', app.pre_order_held(r.id));
end $function$;

CREATE OR REPLACE FUNCTION public.offline_snapshot(p_device_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_country text; v_tz text; ser public.offline_series; v_n int; v_menu jsonb; v_methods jsonb; v_bs record; v_r record; v_fy text;
begin
  if coalesce(p_device_key, '') !~ '^[0-9a-f-]{36}$' then raise exception 'Bad device key.'; end if;
  -- No new offline series once the licence has ended.
  if app.licence_locked(v_rest, now()) then
    raise exception 'The SNA POS licence for this restaurant has ended, so offline billing cannot be started. Please contact SNA to renew.';
  end if;
  select r.*, coalesce(b.timezone, r.timezone) as tz into v_r from public.restaurants r join public.branches b on b.id = v_branch where r.id = v_rest;
  v_country := v_r.country_code; v_tz := v_r.tz;
  select * into ser from public.offline_series where branch_id = v_branch and device_key = p_device_key;
  if not found then
    perform pg_advisory_xact_lock(hashtext('offline_series:' || v_branch::text));
    select count(*) + 1 into v_n from public.offline_series where branch_id = v_branch;
    if v_n > 99 then raise exception 'Too many offline devices for this branch.'; end if;
    insert into public.offline_series (restaurant_id, branch_id, device_key, prefix)
    values (v_rest, v_branch, p_device_key, 'X' || lpad(v_n::text, 2, '0')) returning * into ser;
  end if;
  update public.offline_series set snapshot_at = now() where id = ser.id;
  -- Offline bills follow the outlet's bill prefix: BILL26-X1-0001. A new prefix starts them again from 1.
  v_fy := (app.current_bill_series(v_branch)).prefix;
  if v_fy is distinct from ser.series_key then
    update public.offline_series set series_key = v_fy, fy = null, next_seq = 1 where id = ser.id returning * into ser;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'short_name', p.short_name, 'price', coalesce((select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = p.id), p.price), 'category_id', p.category_id,
      'category_name', c.name, 'is_veg', p.is_veg, 'station', coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen'),
      'inclusive', coalesce(g.is_price_inclusive, false),
      'comps', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'rate', t.rate, 'compound', t.is_compound) order by t.display_order)
                           from public.tax_rate_components t
                          where t.tax_rate_id = (select tr.id from public.tax_rates tr where tr.tax_group_id = p.tax_group_id
                                                   and tr.valid_from <= app.local_today(v_rest) and (tr.valid_to is null or tr.valid_to >= app.local_today(v_rest))
                                                 order by tr.valid_from desc limit 1)
                            and t.applies_when in ('always', 'intra_region')), '[]'::jsonb),
      'groups', coalesce((select jsonb_agg(jsonb_build_object('id', mg.id, 'name', mg.name,
                    'min', greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end), 'max', coalesce(mg.max_select, 99),
                    'options', (select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price', mi.price_delta) order by mi.display_order, mi.name), '[]'::jsonb)
                                  from public.modifier_items mi where mi.modifier_group_id = mg.id and mi.is_active)) order by mg.name)
                    from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id and mg.is_active
                   where pmg.product_id = p.id), '[]'::jsonb))
      order by c.display_order, c.name, p.display_order, p.name), '[]'::jsonb)
    into v_menu
    from public.products p join public.categories c on c.id = p.category_id
    left join public.tax_groups g on g.id = p.tax_group_id
   where p.restaurant_id = v_rest and p.deleted_at is null and p.is_available and c.deleted_at is null and coalesce((select bp.is_available from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = p.id), true);

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind, 'ask_reference', ask_reference, 'upi_id', upi_id) order by display_order), '[]'::jsonb)
    into v_methods from public.payment_methods where restaurant_id = v_rest and is_active and kind not in ('gift_card', 'loyalty');
  select coalesce(s.service_charge_percent, 0) pct, coalesce(s.service_charge_taxable, false) tx, coalesce(s.service_charge_default_on, false) def_on,
         coalesce(s.service_charge_label, 'Service charge') lbl, coalesce(s.cash_rounding_mode, 'none') rmode, coalesce(s.rounding_cash_only, false) rcash,
         s.receipt_header, s.receipt_footer, s.bill_format, s.packing_product_id, s.packing_per, s.packing_takeaway, s.packing_delivery
    into v_bs from public.branch_settings s where s.branch_id = v_branch;

  return jsonb_build_object(
    'taken_at', now(), 'device_key', p_device_key, 'user_id', v_user,
    'series', jsonb_build_object('prefix', 'X' || (substr(ser.prefix, 2)::int), 'fy', null, 'next_seq', ser.next_seq,
                                 'branch_code', ser.series_key, 'key', ser.series_key,
                                 'liquor_code', app.offline_liquor_code(v_branch), 'liquor_next_seq', ser.liquor_next_seq),
    'rights', jsonb_build_object('discount', app.has_permission('order.discount'), 'pay', app.has_permission('payment.take')),
    'menu', v_menu, 'methods', v_methods,
    'settings', jsonb_build_object('sc_percent', v_bs.pct, 'sc_taxable', v_bs.tx, 'sc_default_on', v_bs.def_on, 'sc_label', v_bs.lbl,
                                   'rounding', case when v_bs.rcash then 'none' else v_bs.rmode end,
                                   'cash_rounding', case when v_bs.rcash then v_bs.rmode else 'none' end,
                                   'packing', case when v_bs.packing_product_id is not null then jsonb_build_object(
                                     'product_id', v_bs.packing_product_id, 'per', v_bs.packing_per,
                                     'takeaway', v_bs.packing_takeaway, 'delivery', v_bs.packing_delivery) end),
    'receipt', jsonb_build_object('header', coalesce(v_bs.receipt_header, v_r.trading_name), 'legal_name', v_r.legal_name,
                                  'tax_id', v_r.tax_registration_no, 'tax_id_label', (select tax_id_label from public.countries where code = v_country),
                                  'fssai_no', case when v_country = 'IN' then v_r.fssai_no end, 'footer', v_bs.receipt_footer,
                                  'currency', v_r.currency_code, 'timezone', v_tz, 'country', v_country,
                                  'invoice_title', (select invoice_title from public.countries where code = v_country),
                                  'format', coalesce(v_bs.bill_format, '{}'::jsonb), 'logo', v_r.logo_url));
end $function$;

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
  v_has_liq boolean := false; v_has_food boolean := false; v_isliq boolean; v_expect_seq int;
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
    v_lines := v_lines || jsonb_build_object('key', i, 'product_id', v_prod.id, 'name', v_prod.name, 'base_price', v_price - v_delta,
      'price', v_price, 'options', v_opts, 'options_text', v_text, 'qty', (it->>'qty')::numeric,
      'note', nullif(left(coalesce(it->>'note', ''), 200), ''), 'inclusive', coalesce(v_incl, false), 'comps', v_comps);
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
             when 'discount_cut' then 'discount ' || (f->>'asked') || ' cut to ' || (f->>'recorded')
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

CREATE OR REPLACE FUNCTION app.z_report(p_day uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.business_days; v jsonb; v_pay jsonb; v_tax jsonb; v_cn jsonb; v_shifts jsonb; v_types jsonb;
begin
  select * into d from public.business_days where id = p_day;
  if not found then return null; end if;
  select jsonb_build_object(
      'bills', count(*) filter (where status = 'completed' and comp_kind is null),
      -- first and last by the time they were made (the series can change during a day), the liquor series apart
      'first_bill', (array_agg(bill_number order by created_at, bill_number) filter (where status <> 'voided' and not is_liquor))[1],
      'last_bill', (array_agg(bill_number order by created_at desc, bill_number desc) filter (where status <> 'voided' and not is_liquor))[1],
      'first_liquor_bill', (array_agg(bill_number order by created_at, bill_number) filter (where status <> 'voided' and is_liquor))[1],
      'last_liquor_bill', (array_agg(bill_number order by created_at desc, bill_number desc) filter (where status <> 'voided' and is_liquor))[1],
      'gross_sales', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind is null), 0),
      'discounts', coalesce(sum(discount_total) filter (where status = 'completed' and comp_kind is null), 0),
      'complimentary_bills', count(*) filter (where status = 'completed' and comp_kind = 'complimentary'),
      'complimentary_value', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind = 'complimentary'), 0),
      'staff_meal_bills', count(*) filter (where status = 'completed' and comp_kind = 'staff_meal'),
      'staff_meal_value', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind = 'staff_meal'), 0),
      'service_charge', coalesce(sum(service_charge) filter (where status = 'completed'), 0),
      'tax', coalesce(sum(tax_total) filter (where status = 'completed'), 0),
      'tax_included', coalesce(sum(tax_included) filter (where status = 'completed'), 0),
      'rounding', coalesce(sum(rounding_adjustment) filter (where status = 'completed'), 0),
      'cash_rounding', (select coalesce(sum(p.rounding_adjustment), 0) from public.payments p join public.orders o2 on o2.id = p.order_id
                         where o2.branch_id = d.branch_id and o2.business_date = d.business_date and o2.status = 'completed' and o2.merged_into is null and p.status = 'captured'),
      'total_billed', coalesce(sum(grand_total) filter (where status = 'completed'), 0),
      'voided_bills', count(*) filter (where status = 'voided'),
      'voided_value', coalesce(sum(grand_total) filter (where status = 'voided'), 0),
      'unpaid_bills', count(*) filter (where status = 'completed' and payment_status in ('unpaid', 'partial')),
      'unpaid_amount', coalesce(sum(grand_total - app.order_covered(id)) filter (where status = 'completed' and payment_status in ('unpaid', 'partial')), 0))
    into v from public.orders
   where branch_id = d.branch_id and business_date = d.business_date and merged_into is null;

  select coalesce(jsonb_agg(jsonb_build_object('method', name, 'count', n, 'amount', a) order by a desc), '[]'::jsonb)
    into v_pay from (
      select pm.name, count(*) n, sum(p.amount) a from public.payments p
        join public.orders o on o.id = p.order_id join public.payment_methods pm on pm.id = p.payment_method_id
       where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status <> 'voided' and p.status = 'captured'
       group by pm.name) x;
  select coalesce(jsonb_agg(jsonb_build_object('component', c, 'rate', r, 'taxable', tx, 'tax', ta) order by r, c), '[]'::jsonb)
    into v_tax from (
      select t.component_name c, t.rate r, sum(t.taxable_amount) tx, sum(t.tax_amount) ta
        from public.order_item_taxes t join public.orders o on o.id = t.order_id
       where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status = 'completed'
       group by 1, 2) x;
  select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0), 'tax', coalesce(sum(tax_amount), 0),
           'list', coalesce(jsonb_agg(jsonb_build_object('number', number, 'amount', amount, 'bill',
                     (select bill_number from public.orders where id = cn.order_id), 'reason', reason) order by number), '[]'::jsonb))
    into v_cn from public.credit_notes cn where cn.branch_id = d.branch_id and cn.business_date = d.business_date;
  select coalesce(jsonb_agg(app.shift_figures(s.id) order by s.opened_at), '[]'::jsonb) into v_shifts
    from public.shifts s where s.branch_id = d.branch_id
     and exists (select 1 from public.orders o where o.shift_id = s.id and o.business_date = d.business_date
                 union all select 1 from public.payments p join public.orders o on o.id = p.order_id
                  where p.shift_id = s.id and o.business_date = d.business_date);
  select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'bills', n, 'total', t) order by t desc), '[]'::jsonb) into v_types
    from (select order_type, count(*) n, sum(grand_total) t from public.orders
           where branch_id = d.branch_id and business_date = d.business_date and status = 'completed' and merged_into is null
           group by 1) x;

  return v || jsonb_build_object(
    'business_date', d.business_date, 'branch', (select name from public.branches where id = d.branch_id),
    'status', d.status, 'opened_at', d.opened_at, 'closed_at', d.closed_at,
    'closed_by', (select full_name from public.users where id = d.closed_by),
    'payments', v_pay, 'taxes', v_tax, 'credit_notes', v_cn, 'shifts', v_shifts, 'by_type', v_types, 'sessions', (select coalesce(jsonb_agg(jsonb_build_object('session', sn, 'bills', c, 'total', t) order by first_at), '[]'::jsonb) from (select coalesce(o.session_name, 'Other') sn, count(*) c, sum(o.grand_total) t, min(o.created_at) first_at from public.orders o where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status = 'completed' and o.merged_into is null group by 1) ss),
    'net_sales_after_credit_notes', (v->>'total_billed')::numeric - (v_cn->>'amount')::numeric,
    'reopen_count', d.reopen_count);
end $function$;
