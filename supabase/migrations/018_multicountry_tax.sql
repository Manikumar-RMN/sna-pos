-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260924174949, name 'sna_pos_18_multicountry_tax'. This is the SQL that actually ran.

-- SNA POS migration 18: multi-country tax, wired to the engine (migration 17).

-- 1. Schema -------------------------------------------------------------------
alter table public.tax_rate_components add column if not exists is_compound boolean not null default false;

alter table public.branch_settings
  add column if not exists service_charge_taxable    boolean not null default true,
  add column if not exists service_charge_default_on boolean not null default false,
  add column if not exists service_charge_label      text    not null default 'Service charge',
  add column if not exists rounding_cash_only        boolean not null default false;

alter table public.orders
  add column if not exists tax_included      numeric(14,2) not null default 0,
  add column if not exists tax_exempt_amount numeric(14,2) not null default 0,
  add column if not exists exempt_sales      numeric(14,2) not null default 0,
  add column if not exists senior_details    jsonb;

alter table public.order_items
  add column if not exists net_amount     numeric(14,2) not null default 0,
  add column if not exists service_charge numeric(14,2) not null default 0,
  add column if not exists tax_included   numeric(14,2) not null default 0;

alter table public.payments
  add column if not exists rounding_adjustment numeric(14,2) not null default 0;

alter table public.order_discounts drop constraint if exists order_discounts_discount_type_check;
alter table public.order_discounts add constraint order_discounts_discount_type_check
  check (discount_type in ('percentage', 'fixed_amount', 'senior_pwd'));

alter table public.countries
  add column if not exists tax_id_label        text,
  add column if not exists invoice_title       text,
  add column if not exists has_senior_discount boolean not null default false,
  add column if not exists compliance_note     text;

-- 2. Currencies and countries ------------------------------------------------------
insert into public.currencies (code, name, symbol, decimal_places) values
  ('THB', 'Thai Baht', '฿', 2),
  ('IDR', 'Indonesian Rupiah', 'Rp', 0),
  ('PHP', 'Philippine Peso', '₱', 2)
on conflict (code) do nothing;

insert into public.countries (code, name, default_currency, default_timezone, tax_system_name, is_supported) values
  ('TH', 'Thailand', 'THB', 'Asia/Bangkok', 'VAT', true),
  ('ID', 'Indonesia', 'IDR', 'Asia/Jakarta', 'PBJT', true),
  ('PH', 'Philippines', 'PHP', 'Asia/Manila', 'VAT', true)
on conflict (code) do nothing;

update public.countries set is_supported = true where code in ('IN','AE','SG','MY','TH','ID','PH');

update public.countries set tax_id_label = 'GSTIN', invoice_title = 'Tax Invoice', compliance_note =
  'Service charge must be optional for the customer (CCPA guidelines, 2022). Composition-scheme restaurants may not charge GST: set items to "No GST".'
  where code = 'IN';
update public.countries set tax_id_label = 'TRN', invoice_title = 'Tax Invoice', compliance_note =
  'Menu prices must be shown including VAT. The 7% municipality fee applies only to restaurants licensed to sell alcohol in Dubai.'
  where code = 'AE';
update public.countries set tax_id_label = 'GST Reg. No.', invoice_title = 'Tax Invoice', compliance_note =
  'Prices must be shown including GST. If you add a service charge you may show "++" prices, and must say so on the menu.'
  where code = 'SG';
update public.countries set tax_id_label = 'SST No.', invoice_title = 'Receipt', compliance_note =
  'Service tax (6%) applies once annual food and drink sales reach RM1.5 million. MyInvois e-invoicing applies from RM1 million turnover and is not yet built into SNA POS.'
  where code = 'MY';
update public.countries set tax_id_label = 'Tax ID', invoice_title = 'Receipt / Tax Invoice (ABB)', requires_fiscal_certification = true, compliance_note =
  'Before issuing abbreviated tax invoices, each till must be approved by the Revenue Department. SNA POS does not yet have this approval: use it for demos only until then.'
  where code = 'TH';
update public.countries set tax_id_label = 'NPWP', invoice_title = 'Receipt', compliance_note =
  'The restaurant tax (PBJT) rate is set by each city (Jakarta: 10%). Some regions require a tax recording device; check with your local tax office.'
  where code = 'ID';
update public.countries set tax_id_label = 'TIN', invoice_title = 'Invoice', has_senior_discount = true,
  requires_fiscal_certification = true, compliance_note =
  'Each till must be registered with the BIR before issuing invoices. SNA POS is not yet registered: use it for demos only until then.'
  where code = 'PH';

-- 3. Country presets --------------------------------------------------------------
-- Adding a country = adding a preset here, not changing the billing code.
create or replace function app.country_preset(p_code text)
returns jsonb language sql immutable set search_path = public, pg_temp as $$
  select case p_code
  when 'IN' then '{
    "prices_include_tax": false, "sc_taxable": false, "rounding": "nearest_1", "rounding_cash_only": false,
    "groups": [
      {"name":"Food 5%","comps":[{"name":"CGST","rate":2.5,"applies_when":"intra_region"},{"name":"SGST","rate":2.5,"applies_when":"intra_region"},{"name":"IGST","rate":5,"applies_when":"inter_region"}]},
      {"name":"Food 18% (hotel restaurants)","comps":[{"name":"CGST","rate":9,"applies_when":"intra_region"},{"name":"SGST","rate":9,"applies_when":"intra_region"},{"name":"IGST","rate":18,"applies_when":"inter_region"}]},
      {"name":"No GST","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"UPI","kind":"upi"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'AE' then '{
    "prices_include_tax": true, "sc_taxable": true, "rounding": "none", "rounding_cash_only": false,
    "groups": [
      {"name":"VAT 5%","comps":[{"name":"VAT","rate":5}]},
      {"name":"VAT 5% + municipality fee 7%","comps":[{"name":"Municipality fee","rate":7},{"name":"VAT","rate":5,"compound":true}]},
      {"name":"Zero-rated","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'SG' then '{
    "prices_include_tax": true, "sc_taxable": true, "rounding": "none", "rounding_cash_only": false,
    "groups": [{"name":"GST 9%","comps":[{"name":"GST","rate":9}]},{"name":"No GST","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"PayNow","kind":"wallet"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'MY' then '{
    "prices_include_tax": false, "sc_taxable": true, "rounding": "nearest_0_05", "rounding_cash_only": true,
    "groups": [{"name":"Service tax 6%","comps":[{"name":"Service Tax","rate":6}]},{"name":"No SST","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"DuitNow QR","kind":"wallet"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'TH' then '{
    "prices_include_tax": true, "sc_taxable": true, "rounding": "none", "rounding_cash_only": false,
    "groups": [{"name":"VAT 7%","comps":[{"name":"VAT","rate":7}]},{"name":"No VAT","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"PromptPay","kind":"wallet"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'ID' then '{
    "prices_include_tax": false, "sc_taxable": true, "rounding": "nearest_1", "rounding_cash_only": false,
    "groups": [{"name":"PBJT 10%","comps":[{"name":"PBJT","rate":10}]},{"name":"No tax","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"QRIS","kind":"wallet"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'PH' then '{
    "prices_include_tax": true, "sc_taxable": true, "rounding": "none", "rounding_cash_only": false,
    "groups": [{"name":"VAT 12%","comps":[{"name":"VAT","rate":12}]},{"name":"VAT-exempt","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"GCash","kind":"wallet"},{"name":"Maya","kind":"wallet"},{"name":"Card","kind":"card"}]}'::jsonb
  end
$$;

-- Effective combined rate (%) of same-region components, compounding included.
create or replace function app.effective_rate(p_comps jsonb)
returns numeric language plpgsql immutable set search_path = public, pg_temp as $$
declare f numeric := 0; c jsonb;
begin
  for c in select * from jsonb_array_elements(coalesce(p_comps, '[]'::jsonb)) loop
    if coalesce(c->>'applies_when', 'always') in ('always', 'intra_region') then
      f := f + coalesce((c->>'rate')::numeric, 0) / 100
             * (1 + case when coalesce((c->>'compound')::boolean, false) then f else 0 end);
    end if;
  end loop;
  return round(f * 100, 3);
end $$;

-- Writes one tax group (new rate version from today) from a components list.
create or replace function app.write_tax_group(p_restaurant uuid, p_group uuid, p_comps jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare cur public.tax_rates%rowtype; v_has boolean; v_rate uuid; c jsonb; k int := 0;
begin
  select * into cur from public.tax_rates
   where tax_group_id = p_group and valid_from <= current_date
     and (valid_to is null or valid_to >= current_date)
   order by valid_from desc limit 1 for update;
  v_has := found;
  if v_has and cur.valid_from = current_date then
    update public.tax_rates set total_rate = app.effective_rate(p_comps) where id = cur.id;
    v_rate := cur.id;
    delete from public.tax_rate_components where tax_rate_id = cur.id;
  else
    if v_has then update public.tax_rates set valid_to = current_date - 1 where id = cur.id; end if;
    insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
    values (p_restaurant, p_group, app.effective_rate(p_comps), current_date) returning id into v_rate;
  end if;
  for c in select * from jsonb_array_elements(coalesce(p_comps, '[]'::jsonb)) loop
    k := k + 1;
    insert into public.tax_rate_components
      (restaurant_id, tax_rate_id, name, rate, applies_when, display_order, is_compound)
    values (p_restaurant, v_rate, left(trim(c->>'name'), 40), (c->>'rate')::numeric,
            coalesce(c->>'applies_when', 'always'), k, coalesce((c->>'compound')::boolean, false));
  end loop;
end $$;
revoke all on function app.write_tax_group(uuid, uuid, jsonb) from public, anon, authenticated;

-- 4. Restaurant bootstrap from the country preset -----------------------------------
create or replace function app.create_restaurant_with_owner(
  p_legal_name text, p_trading_name text, p_country_code character, p_owner_name text,
  p_branch_name text default 'Main Branch', p_branch_code text default 'MN',
  p_timezone text default null, p_tax_registration_no text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $function$
declare
  v_auth_uid uuid := auth.uid();
  v_country public.countries%rowtype;
  v_preset jsonb;
  v_restaurant uuid; v_branch uuid; v_owner_role uuid; v_manager uuid; v_cashier uuid;
  v_waiter uuid; v_chef uuid; v_user uuid; v_tz text; v_group uuid; g jsonb; pm jsonb; k int := 0;
begin
  if v_auth_uid is null then raise exception 'You must be signed in to create a restaurant.'; end if;
  if exists (select 1 from public.users u where u.auth_user_id = v_auth_uid and u.deleted_at is null) then
    raise exception 'This account already belongs to a restaurant.';
  end if;
  select * into v_country from public.countries where code = p_country_code;
  if not found then raise exception 'Unknown country code: %', p_country_code; end if;
  if not v_country.is_supported then
    raise exception 'SNA POS is not available in % yet. Its tax rules must be confirmed locally first.', v_country.name;
  end if;
  v_preset := app.country_preset(p_country_code);
  if v_preset is null then raise exception 'No tax setup exists for % yet.', v_country.name; end if;
  v_tz := coalesce(p_timezone, v_country.default_timezone);

  insert into public.restaurants (legal_name, trading_name, country_code, currency_code, timezone, tax_registration_no)
  values (p_legal_name, p_trading_name, p_country_code, v_country.default_currency, v_tz, nullif(upper(trim(p_tax_registration_no)), ''))
  returning id into v_restaurant;

  insert into public.branches (restaurant_id, name, code, country_code, timezone)
  values (v_restaurant, p_branch_name, p_branch_code, p_country_code, v_tz) returning id into v_branch;

  insert into public.roles (restaurant_id, name, is_system) values (v_restaurant, 'Owner', true) returning id into v_owner_role;
  insert into public.roles (restaurant_id, name, is_system) values (v_restaurant, 'Manager', true) returning id into v_manager;
  insert into public.roles (restaurant_id, name, is_system) values (v_restaurant, 'Cashier', true) returning id into v_cashier;
  insert into public.roles (restaurant_id, name, is_system) values (v_restaurant, 'Waiter', true) returning id into v_waiter;
  insert into public.roles (restaurant_id, name, is_system) values (v_restaurant, 'Chef', true) returning id into v_chef;

  insert into public.role_permissions (role_id, permission_key) select v_owner_role, key from public.permissions;
  insert into public.role_permissions (role_id, permission_key)
    select v_manager, key from public.permissions where key not in ('tax.manage', 'settings.manage', 'agent.configure');
  insert into public.role_permissions (role_id, permission_key) values
    (v_cashier, 'order.create'), (v_cashier, 'order.reprint'), (v_cashier, 'customer.manage'),
    (v_cashier, 'shift.open'), (v_cashier, 'report.view_sales'), (v_cashier, 'agent.use');
  insert into public.role_permissions (role_id, permission_key) values (v_waiter, 'order.create'), (v_waiter, 'customer.manage');
  insert into public.role_permissions (role_id, permission_key) values (v_chef, 'order.reprint');

  insert into public.users (restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
  values (v_restaurant, v_auth_uid, 'EMP001', p_owner_name, v_owner_role, (select email from auth.users where id = v_auth_uid))
  returning id into v_user;
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (v_user, v_branch, v_restaurant);

  -- Tax groups from the country preset.
  for g in select * from jsonb_array_elements(v_preset->'groups') loop
    insert into public.tax_groups (restaurant_id, name, is_price_inclusive)
    values (v_restaurant, g->>'name', (v_preset->>'prices_include_tax')::boolean) returning id into v_group;
    perform app.write_tax_group(v_restaurant, v_group, g->'comps');
  end loop;

  for pm in select * from jsonb_array_elements(v_preset->'payment_methods') loop
    k := k + 1;
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, display_order)
    values (v_restaurant, pm->>'name', pm->>'kind', pm->>'kind' = 'cash', k);
  end loop;

  insert into public.branch_settings
    (branch_id, restaurant_id, receipt_header, cash_rounding_mode, rounding_cash_only,
     service_charge_percent, service_charge_taxable, service_charge_default_on, auto_print_kot)
  values
    (v_branch, v_restaurant, p_trading_name, v_preset->>'rounding', (v_preset->>'rounding_cash_only')::boolean,
     0, (v_preset->>'sc_taxable')::boolean, false, true);

  insert into public.devices (restaurant_id, branch_id, name, device_type, bill_prefix)
  values (v_restaurant, v_branch, 'Counter 1', 'tablet', 'C1');

  insert into public.agent_settings (restaurant_id, is_enabled, preferred_language) values (v_restaurant, false, 'en');

  insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, actor_type, new_value)
  values (v_restaurant, v_branch, v_user, 'restaurant.create', 'restaurants', v_restaurant, 'user',
          jsonb_build_object('trading_name', p_trading_name, 'country', p_country_code));
  return v_restaurant;
end $function$;

-- 5. Bill input: reads the menu, taxes and settings, validates, and returns the
--    engine input. Used by quote_order (preview) and create_order (save).
create or replace function app.bill_input(
  p_restaurant uuid, p_branch uuid, p_items jsonb, p_discount numeric,
  p_service_charge boolean, p_senior jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  bs record; v_country public.countries%rowtype; v_item jsonb; v_product public.products%rowtype;
  v_incl boolean; v_rate uuid; v_comps jsonb; v_lines jsonb := '[]'::jsonb; v_qty numeric; i int := 0;
  v_sc_on boolean; v_senior jsonb := null; v_cnt int; v_din int;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'The order is empty.';
  end if;
  if jsonb_array_length(p_items) > 200 then raise exception 'Too many lines on one bill.'; end if;

  select coalesce(s.service_charge_percent, 0) as sc_pct, coalesce(s.service_charge_taxable, false) as sc_tax,
         coalesce(s.service_charge_default_on, false) as sc_default, coalesce(s.service_charge_label, 'Service charge') as sc_label,
         coalesce(s.cash_rounding_mode, 'none') as rmode, coalesce(s.rounding_cash_only, false) as rcash
    into bs from public.branch_settings s where s.branch_id = p_branch;
  select c.* into v_country from public.restaurants r join public.countries c on c.code = r.country_code
   where r.id = p_restaurant;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_product from public.products
     where id = (v_item->>'product_id')::uuid and restaurant_id = p_restaurant and deleted_at is null;
    if not found then raise exception 'A menu item on the order no longer exists.'; end if;
    if not v_product.is_available then raise exception '% is marked sold out.', v_product.name; end if;
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    if v_qty <= 0 then continue; end if;
    if v_qty > 999 then raise exception 'Quantity for % is too large.', v_product.name; end if;

    select g.is_price_inclusive into v_incl from public.tax_groups g where g.id = v_product.tax_group_id;
    select tr.id into v_rate from public.tax_rates tr
     where tr.tax_group_id = v_product.tax_group_id and tr.valid_from <= current_date
       and (tr.valid_to is null or tr.valid_to >= current_date)
     order by tr.valid_from desc limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'rate', rate, 'compound', is_compound)
                              order by display_order), '[]'::jsonb)
      into v_comps from public.tax_rate_components
     where tax_rate_id = v_rate and applies_when in ('always', 'intra_region');

    i := i + 1;
    v_lines := v_lines || jsonb_build_object(
      'key', i, 'product_id', v_product.id, 'name', v_product.name, 'price', v_product.price,
      'qty', v_qty, 'note', nullif(left(coalesce(v_item->>'note', ''), 200), ''),
      'inclusive', coalesce(v_incl, false), 'comps', v_comps);
  end loop;
  if i = 0 then raise exception 'The order is empty.'; end if;

  v_sc_on := coalesce(p_service_charge, bs.sc_default) and coalesce(bs.sc_pct, 0) > 0;

  if p_senior is not null and p_senior <> 'null'::jsonb then
    if not coalesce(v_country.has_senior_discount, false) then
      raise exception 'The senior citizen / PWD discount applies only in the Philippines.';
    end if;
    v_cnt := coalesce((p_senior->>'count')::int, 0);
    v_din := coalesce((p_senior->>'diners')::int, 0);
    if v_cnt < 1 or v_din < v_cnt then
      raise exception 'Enter how many senior citizens / PWDs and how many people in total.';
    end if;
    if coalesce(trim(p_senior->>'name'), '') = '' or coalesce(trim(p_senior->>'id_no'), '') = '' then
      raise exception 'Enter the senior citizen / PWD name and ID number.';
    end if;
    if coalesce(p_senior->>'kind', '') not in ('senior', 'pwd') then
      raise exception 'Choose senior citizen or PWD.';
    end if;
    v_senior := jsonb_build_object('share', round(v_cnt::numeric / v_din, 6), 'rate', 20,
      'kind', p_senior->>'kind', 'name', left(trim(p_senior->>'name'), 80),
      'id_no', left(trim(p_senior->>'id_no'), 40), 'count', v_cnt, 'diners', v_din);
  end if;

  return jsonb_build_object(
    'calc', jsonb_build_object(
      'lines', v_lines, 'discount', coalesce(p_discount, 0),
      'sc_percent', case when v_sc_on then bs.sc_pct else 0 end, 'sc_taxable', bs.sc_tax,
      'senior', v_senior,
      'rounding', case when bs.rcash then 'none' else bs.rmode end),
    'service_charge_available', coalesce(bs.sc_pct, 0) > 0, 'service_charge_on', v_sc_on,
    'service_charge_percent', bs.sc_pct, 'service_charge_label', bs.sc_label,
    'cash_rounding', case when bs.rcash then bs.rmode else 'none' end,
    'senior', v_senior);
end $$;
revoke all on function app.bill_input(uuid, uuid, jsonb, numeric, boolean, jsonb) from public, anon, authenticated;

-- 6. Preview: exactly what the bill will be, without saving it -----------------------
create or replace function public.quote_order(
  p_items jsonb, p_discount_amount numeric default 0,
  p_service_charge boolean default null, p_senior jsonb default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_in jsonb; v_calc jsonb;
begin
  perform app.require_permission('order.create');
  if coalesce(p_discount_amount, 0) > 0 and not app.has_permission('order.discount') then
    raise exception 'A manager must approve a discount.';
  end if;
  v_in := app.bill_input(app.current_restaurant_id(), app.current_branch_id(), p_items,
                         p_discount_amount, p_service_charge, p_senior);
  v_calc := app.calc_bill(v_in->'calc');
  return v_calc - 'lines'
    || jsonb_build_object(
         'lines', (select coalesce(jsonb_agg(jsonb_build_object('key', l->'key', 'total', l->'total')), '[]'::jsonb)
                     from jsonb_array_elements(v_calc->'lines') l),
         'service_charge_available', v_in->'service_charge_available',
         'service_charge_on', v_in->'service_charge_on',
         'service_charge_percent', v_in->'service_charge_percent',
         'service_charge_label', v_in->'service_charge_label',
         'cash_rounding', v_in->'cash_rounding');
end $$;

-- 7. create_order v3 ---------------------------------------------------------------
drop function if exists public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text);

create or replace function public.create_order(
  p_items jsonb, p_order_type text default 'dine_in', p_table_id uuid default null,
  p_customer_id uuid default null, p_payment_method_id uuid default null,
  p_tendered numeric default null, p_discount_amount numeric default 0,
  p_discount_reason text default null, p_service_charge boolean default null,
  p_senior jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_restaurant uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  v_in jsonb; v_c jsonb; l jsonb; t jsonb; src jsonb;
  v_currency char(3); v_auto_kot boolean; v_shift uuid; v_device uuid; v_prefix text; v_seq bigint;
  v_bill_no text; v_order_id uuid := gen_random_uuid(); v_kot_id uuid; v_line_id uuid;
  v_method_kind text; v_grand numeric(14,2); v_amount numeric(14,2); v_cash_round numeric(14,2) := 0;
  v_change numeric(14,2) := 0; v_paid boolean := false; v_rmode text;
begin
  if coalesce(p_discount_amount, 0) < 0 then raise exception 'A discount cannot be negative.'; end if;
  if coalesce(p_discount_amount, 0) > 0 and not app.has_permission('order.discount') then
    raise exception 'A manager must approve a discount.';
  end if;
  if v_branch is null then raise exception 'No branch is set up for this restaurant.'; end if;

  select s.id into v_shift from public.shifts s
   where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1;
  if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

  if p_payment_method_id is not null then
    select pm.kind into v_method_kind from public.payment_methods pm
     where pm.id = p_payment_method_id and pm.restaurant_id = v_restaurant and pm.is_active;
    if not found then raise exception 'That payment method is not available.'; end if;
  end if;
  if p_table_id is not null and not exists (
      select 1 from public.dining_tables t where t.id = p_table_id and t.restaurant_id = v_restaurant and t.is_active) then
    raise exception 'That table does not exist.';
  end if;
  if p_customer_id is not null and not exists (
      select 1 from public.customers c where c.id = p_customer_id and c.restaurant_id = v_restaurant and c.deleted_at is null) then
    raise exception 'That customer does not exist.';
  end if;

  -- All arithmetic happens in the engine.
  v_in := app.bill_input(v_restaurant, v_branch, p_items, p_discount_amount, p_service_charge, p_senior);
  v_c  := app.calc_bill(v_in->'calc');
  v_grand := (v_c->>'grand_total')::numeric;
  v_rmode := v_in->>'cash_rounding';

  select r.currency_code into v_currency from public.restaurants r where r.id = v_restaurant;
  select coalesce(bs.auto_print_kot, true) into v_auto_kot from public.branch_settings bs where bs.branch_id = v_branch;
  v_auto_kot := coalesce(v_auto_kot, true);

  select d.id, d.bill_prefix, d.next_bill_seq into v_device, v_prefix, v_seq
    from public.devices d where d.branch_id = v_branch and d.is_active order by d.created_at limit 1 for update;
  if v_device is null then raise exception 'No billing device is set up for this branch.'; end if;
  v_bill_no := (select b.code from public.branches b where b.id = v_branch)
               || '-' || coalesce(v_prefix, 'C1') || '-' || lpad(v_seq::text, 4, '0');
  update public.devices set next_bill_seq = next_bill_seq + 1 where id = v_device;

  insert into public.orders
    (id, restaurant_id, branch_id, device_id, bill_number, order_type, dining_table_id, customer_id,
     cashier_id, shift_id, currency_code, status, payment_status, client_created_at)
  values
    (v_order_id, v_restaurant, v_branch, v_device, v_bill_no, p_order_type, p_table_id, p_customer_id,
     v_user, v_shift, v_currency, 'open', 'unpaid', now());

  for l in select * from jsonb_array_elements(v_c->'lines') loop
    select s into src from jsonb_array_elements(v_in->'calc'->'lines') s where s->'key' = l->'key';
    v_line_id := gen_random_uuid();
    insert into public.order_items
      (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity,
       line_subtotal, line_discount, line_tax, line_total, is_price_inclusive, kitchen_note,
       net_amount, service_charge, tax_included)
    values
      (v_line_id, v_restaurant, v_order_id, (src->>'product_id')::uuid, src->>'name',
       (src->>'price')::numeric, (src->>'qty')::numeric,
       (l->>'subtotal')::numeric, (l->>'discount')::numeric + (l->>'senior_discount')::numeric,
       (l->>'tax')::numeric, (l->>'total')::numeric, (l->>'inclusive')::boolean, src->>'note',
       (l->>'net')::numeric, (l->>'service_charge')::numeric, (l->>'tax_included')::numeric);
    for t in select * from jsonb_array_elements(l->'taxes') loop
      insert into public.order_item_taxes
        (restaurant_id, order_id, order_item_id, component_name, rate, taxable_amount, tax_amount)
      values (v_restaurant, v_order_id, v_line_id, t->>'name', (t->>'rate')::numeric,
              (t->>'taxable')::numeric, (t->>'amount')::numeric);
    end loop;
  end loop;

  if (v_c->>'discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (v_restaurant, v_order_id, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric,
            nullif(left(p_discount_reason, 200), ''), v_user);
  end if;
  if (v_c->>'senior_discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (v_restaurant, v_order_id, 'senior_pwd', 20, (v_c->>'senior_discount')::numeric,
            left(upper(v_in->'senior'->>'kind') || ': ' || (v_in->'senior'->>'name') || ', ID ' || (v_in->'senior'->>'id_no'), 200),
            v_user);
  end if;

  -- Payment now (or later with pay_order). Cash-only rounding (e.g. Malaysia's
  -- 5 sen) is applied here, only when the customer pays in cash.
  if p_payment_method_id is not null and v_grand > 0 then
    v_amount := v_grand;
    if v_method_kind = 'cash' and v_rmode <> 'none' then
      v_amount := app.round_cash(v_grand, v_rmode);
      v_cash_round := v_amount - v_grand;
    end if;
    if p_tendered is not null then
      if p_tendered < v_amount then
        raise exception 'Cash received (%) is less than the amount due (%).', p_tendered, v_amount;
      end if;
      v_change := p_tendered - v_amount;
    end if;
    insert into public.payments
      (id, restaurant_id, order_id, payment_method_id, amount, currency_code, tendered_amount,
       change_amount, status, received_by, client_created_at, rounding_adjustment)
    values
      (gen_random_uuid(), v_restaurant, v_order_id, p_payment_method_id, v_amount, v_currency,
       p_tendered, v_change, 'captured', v_user, now(), v_cash_round);
    v_paid := true;
  end if;

  update public.orders set
      subtotal = (v_c->>'subtotal')::numeric,
      discount_total = (v_c->>'discount')::numeric + (v_c->>'senior_discount')::numeric,
      tax_total = (v_c->>'tax_total')::numeric,
      tax_included = (v_c->>'tax_included')::numeric,
      tax_exempt_amount = (v_c->>'tax_exempt_amount')::numeric,
      exempt_sales = (v_c->>'exempt_sales')::numeric,
      service_charge = (v_c->>'service_charge')::numeric,
      rounding_adjustment = (v_c->>'rounding')::numeric,
      grand_total = v_grand,
      senior_details = v_in->'senior',
      paid_total = case when v_paid then v_amount else 0 end,
      status = 'completed',
      payment_status = case when v_paid or v_grand = 0 then 'paid' else 'unpaid' end,
      synced_at = now()
  where id = v_order_id;

  if v_auto_kot then
    v_kot_id := gen_random_uuid();
    insert into public.kitchen_tickets (id, restaurant_id, branch_id, order_id, ticket_number, status, client_created_at)
    values (v_kot_id, v_restaurant, v_branch, v_order_id, 'K-' || v_bill_no, 'new', now());
    insert into public.kitchen_ticket_items (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note)
    select v_restaurant, v_kot_id, oi.id, oi.product_name, oi.quantity, oi.kitchen_note
      from public.order_items oi where oi.order_id = v_order_id order by oi.created_at;
  end if;

  perform app.audit('order.create', 'orders', v_order_id,
    jsonb_build_object('bill_number', v_bill_no, 'grand_total', v_grand,
                       'discount', (v_c->>'discount')::numeric, 'senior_discount', (v_c->>'senior_discount')::numeric));

  return jsonb_build_object('order_id', v_order_id, 'bill_number', v_bill_no,
    'grand_total', v_grand, 'amount_paid', case when v_paid then v_amount else 0 end,
    'cash_rounding', v_cash_round, 'change', v_change, 'paid', v_paid or v_grand = 0);
end $function$;

-- 8. pay_order with cash-only rounding ------------------------------------------------
create or replace function public.pay_order(p_order_id uuid, p_payment_method_id uuid, p_tendered numeric default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; v_kind text; v_change numeric(14,2) := 0; v_shift uuid;
  v_rmode text; v_rcash boolean; v_amount numeric(14,2); v_round numeric(14,2) := 0;
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' then raise exception 'Bill % is already paid.', o.bill_number; end if;
  select pm.kind into v_kind from public.payment_methods pm
   where pm.id = p_payment_method_id and pm.restaurant_id = o.restaurant_id and pm.is_active;
  if not found then raise exception 'That payment method is not available.'; end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
  if v_shift is null then raise exception 'Open a shift before taking payments.'; end if;

  select coalesce(cash_rounding_mode, 'none'), coalesce(rounding_cash_only, false) into v_rmode, v_rcash
    from public.branch_settings where branch_id = o.branch_id;
  v_amount := o.grand_total;
  if v_kind = 'cash' and coalesce(v_rcash, false) and coalesce(v_rmode, 'none') <> 'none' then
    v_amount := app.round_cash(o.grand_total, v_rmode);
    v_round := v_amount - o.grand_total;
  end if;
  if p_tendered is not null then
    if p_tendered < v_amount then
      raise exception 'Cash received (%) is less than the amount due (%).', p_tendered, v_amount;
    end if;
    v_change := p_tendered - v_amount;
  end if;

  insert into public.payments
    (id, restaurant_id, order_id, payment_method_id, amount, currency_code, tendered_amount,
     change_amount, status, received_by, client_created_at, rounding_adjustment)
  values
    (gen_random_uuid(), o.restaurant_id, o.id, p_payment_method_id, v_amount, o.currency_code,
     p_tendered, v_change, 'captured', v_user, now(), v_round);

  update public.orders set paid_total = v_amount, payment_status = 'paid',
      shift_id = case when exists (select 1 from public.shifts s where s.id = o.shift_id and s.status = 'open')
                      then o.shift_id else v_shift end
   where id = o.id;

  perform app.audit('order.pay', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'amount', v_amount, 'method_kind', v_kind));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'amount', v_amount,
                            'cash_rounding', v_round, 'change', v_change);
end $$;

-- 9. Tax settings --------------------------------------------------------------------
-- One switch for the whole menu: "my prices already include tax".
create or replace function public.set_prices_include_tax(p_inclusive boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('tax.manage');
begin
  update public.tax_groups set is_price_inclusive = coalesce(p_inclusive, false)
   where restaurant_id = app.current_restaurant_id();
  perform app.audit('tax.prices_include_tax', 'restaurants', app.current_restaurant_id(),
    jsonb_build_object('prices_include_tax', p_inclusive));
end $$;

-- Create or change a tax group from a simple list of components:
-- [{name, rate, compound, applies_when}]. The change applies from today.
create or replace function public.save_tax_group(p_group_id uuid, p_name text, p_components jsonb)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('tax.manage');
  v_rest uuid := app.current_restaurant_id();
  v_group uuid := p_group_id; v_incl boolean; c jsonb; v_old jsonb;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a name for the tax group.'; end if;
  if p_components is null or jsonb_typeof(p_components) <> 'array' then raise exception 'Invalid tax list.'; end if;
  if jsonb_array_length(p_components) > 6 then raise exception 'A tax group can have at most 6 taxes.'; end if;
  for c in select * from jsonb_array_elements(p_components) loop
    if coalesce(trim(c->>'name'), '') = '' then raise exception 'Every tax needs a name.'; end if;
    if (c->>'rate') is null or (c->>'rate')::numeric < 0 or (c->>'rate')::numeric > 40 then
      raise exception 'Tax rates must be between 0 and 40 percent.';
    end if;
    if coalesce(c->>'applies_when', 'always') not in ('always', 'intra_region', 'inter_region') then
      raise exception 'Unknown option for when a tax applies.';
    end if;
  end loop;

  if v_group is null then
    if exists (select 1 from public.tax_groups where restaurant_id = v_rest and lower(name) = lower(trim(p_name))) then
      raise exception 'A tax group with that name already exists.';
    end if;
    select coalesce(bool_or(is_price_inclusive), false) into v_incl from public.tax_groups where restaurant_id = v_rest;
    insert into public.tax_groups (restaurant_id, name, is_price_inclusive)
    values (v_rest, left(trim(p_name), 60), v_incl) returning id into v_group;
  else
    if not exists (select 1 from public.tax_groups where id = v_group and restaurant_id = v_rest) then
      raise exception 'Tax group not found.';
    end if;
    if exists (select 1 from public.tax_groups where restaurant_id = v_rest and lower(name) = lower(trim(p_name)) and id <> v_group) then
      raise exception 'A tax group with that name already exists.';
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('name', c2.name, 'rate', c2.rate) order by c2.display_order), '[]'::jsonb)
      into v_old
      from public.tax_rates tr join public.tax_rate_components c2 on c2.tax_rate_id = tr.id
     where tr.tax_group_id = v_group and tr.valid_to is null;
    update public.tax_groups set name = left(trim(p_name), 60) where id = v_group;
  end if;

  perform app.write_tax_group(v_rest, v_group, p_components);
  perform app.audit('tax.group_save', 'tax_groups', v_group,
    jsonb_build_object('name', trim(p_name), 'components', p_components), v_old);
  return v_group;
end $$;

-- 10. Settings: service charge and rounding options ----------------------------------
create or replace function public.update_settings(p_settings jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  s jsonb := coalesce(p_settings, '{}'::jsonb);
  v_country char(2); v_taxno text;
begin
  select country_code into v_country from public.restaurants where id = v_rest;

  if s ? 'trading_name' and coalesce(trim(s->>'trading_name'), '') = '' then
    raise exception 'The name customers see cannot be empty.';
  end if;
  if s ? 'legal_name' and coalesce(trim(s->>'legal_name'), '') = '' then
    raise exception 'The registered business name cannot be empty.';
  end if;
  if s ? 'tax_registration_no' then
    v_taxno := upper(nullif(trim(s->>'tax_registration_no'), ''));
    if v_taxno is not null and v_country = 'IN'
       and v_taxno !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
      raise exception 'That GSTIN does not look right. It should be 15 characters, like 33AAACA0000A1Z5.';
    end if;
    if v_taxno is not null and length(v_taxno) > 30 then raise exception 'That tax number is too long.'; end if;
  end if;
  if s ? 'cash_rounding_mode' and (s->>'cash_rounding_mode') not in ('none', 'nearest_1', 'nearest_0_05', 'nearest_0_10') then
    raise exception 'Unknown rounding option.';
  end if;
  if s ? 'service_charge_percent' and ((s->>'service_charge_percent')::numeric < 0 or (s->>'service_charge_percent')::numeric > 30) then
    raise exception 'The service charge must be between 0 and 30 percent.';
  end if;

  update public.restaurants set
    trading_name = case when s ? 'trading_name' then left(trim(s->>'trading_name'), 120) else trading_name end,
    legal_name   = case when s ? 'legal_name' then left(trim(s->>'legal_name'), 160) else legal_name end,
    tax_registration_no = case when s ? 'tax_registration_no' then v_taxno else tax_registration_no end,
    contact_phone = case when s ? 'contact_phone' then nullif(left(trim(s->>'contact_phone'), 30), '') else contact_phone end
  where id = v_rest;

  update public.branches set
    name = case when s ? 'branch_name' and coalesce(trim(s->>'branch_name'), '') <> '' then left(trim(s->>'branch_name'), 80) else name end,
    address_line1 = case when s ? 'address_line1' then nullif(left(trim(s->>'address_line1'), 160), '') else address_line1 end,
    address_line2 = case when s ? 'address_line2' then nullif(left(trim(s->>'address_line2'), 160), '') else address_line2 end,
    city = case when s ? 'city' then nullif(left(trim(s->>'city'), 80), '') else city end,
    state_or_region = case when s ? 'state_or_region' then nullif(left(trim(s->>'state_or_region'), 80), '') else state_or_region end,
    postal_code = case when s ? 'postal_code' then nullif(left(trim(s->>'postal_code'), 12), '') else postal_code end,
    phone = case when s ? 'phone' then nullif(left(trim(s->>'phone'), 30), '') else phone end
  where id = v_branch;

  update public.branch_settings set
    receipt_header = case when s ? 'receipt_header' then nullif(left(trim(s->>'receipt_header'), 120), '') else receipt_header end,
    receipt_footer = case when s ? 'receipt_footer' then nullif(left(trim(s->>'receipt_footer'), 300), '') else receipt_footer end,
    cash_rounding_mode = case when s ? 'cash_rounding_mode' then s->>'cash_rounding_mode' else cash_rounding_mode end,
    rounding_cash_only = case when s ? 'rounding_cash_only' then (s->>'rounding_cash_only')::boolean else rounding_cash_only end,
    auto_print_kot = case when s ? 'auto_print_kot' then (s->>'auto_print_kot')::boolean else auto_print_kot end,
    service_charge_percent = case when s ? 'service_charge_percent' then round((s->>'service_charge_percent')::numeric, 2) else service_charge_percent end,
    service_charge_taxable = case when s ? 'service_charge_taxable' then (s->>'service_charge_taxable')::boolean else service_charge_taxable end,
    service_charge_default_on = case when s ? 'service_charge_default_on' then (s->>'service_charge_default_on')::boolean else service_charge_default_on end,
    service_charge_label = case when s ? 'service_charge_label' and coalesce(trim(s->>'service_charge_label'), '') <> ''
                                then left(trim(s->>'service_charge_label'), 40) else service_charge_label end
  where branch_id = v_branch;

  perform app.audit('settings.update', 'restaurants', v_rest, s);
end $$;

-- 11. Reports: service charge, included tax, net sales -------------------------------
create or replace function public.sales_report(p_from date, p_to date)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_fin boolean;
  v_summary jsonb; v_by_day jsonb; v_by_hour jsonb; v_by_item jsonb; v_by_method jsonb; v_by_type jsonb;
  v_tax jsonb := '[]'::jsonb; v_refunds numeric(14,2); v_refund_count int; v_net numeric(14,2);
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_fin  := app.has_permission('report.view_financial');
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;

  create temp table if not exists _rep_orders (id uuid primary key, created_at timestamptz, status text,
    order_type text, subtotal numeric, discount_total numeric, tax_total numeric, tax_included numeric,
    service_charge numeric, rounding_adjustment numeric, grand_total numeric, exempt_sales numeric) on commit drop;
  truncate _rep_orders;
  insert into _rep_orders
  select id, created_at, status, order_type, subtotal, discount_total, tax_total, tax_included,
         service_charge, rounding_adjustment, grand_total, exempt_sales
    from public.orders
   where restaurant_id = v_rest and created_at >= v_start and created_at < v_end
     and status in ('completed', 'voided');

  select coalesce(sum(r.amount), 0), count(*) into v_refunds, v_refund_count
    from public.refunds r where r.restaurant_id = v_rest and r.created_at >= v_start and r.created_at < v_end;
  select coalesce(sum(oi.net_amount), 0) into v_net
    from public.order_items oi join _rep_orders o on o.id = oi.order_id where o.status = 'completed';

  select jsonb_build_object(
      'bills',          count(*) filter (where status = 'completed'),
      'gross_sales',    coalesce(sum(subtotal) filter (where status = 'completed'), 0),
      'net_sales',      v_net,
      'discounts',      coalesce(sum(discount_total) filter (where status = 'completed'), 0),
      'service_charge', coalesce(sum(service_charge) filter (where status = 'completed'), 0),
      'tax',            coalesce(sum(tax_total) filter (where status = 'completed'), 0),
      'tax_included',   coalesce(sum(tax_included) filter (where status = 'completed'), 0),
      'exempt_sales',   coalesce(sum(exempt_sales) filter (where status = 'completed'), 0),
      'rounding',       coalesce(sum(rounding_adjustment) filter (where status = 'completed'), 0),
      'total_billed',   coalesce(sum(grand_total) filter (where status = 'completed'), 0),
      'average_bill',   coalesce(round(avg(grand_total) filter (where status = 'completed'), 2), 0),
      'voided_bills',   count(*) filter (where status = 'voided'),
      'voided_value',   coalesce(sum(grand_total) filter (where status = 'voided'), 0),
      'refunds',        v_refunds,
      'refund_count',   v_refund_count,
      'net_collected',  coalesce(sum(grand_total) filter (where status = 'completed'), 0) - v_refunds)
    into v_summary from _rep_orders;

  select coalesce(jsonb_agg(jsonb_build_object('day', d, 'bills', n, 'total', t) order by d), '[]'::jsonb) into v_by_day
    from (select (created_at at time zone v_tz)::date d, count(*) n, sum(grand_total) t
            from _rep_orders where status = 'completed' group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('hour', h, 'bills', n, 'total', t) order by h), '[]'::jsonb) into v_by_hour
    from (select extract(hour from created_at at time zone v_tz)::int h, count(*) n, sum(grand_total) t
            from _rep_orders where status = 'completed' group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('item', name, 'qty', q, 'amount', a) order by a desc), '[]'::jsonb) into v_by_item
    from (select oi.product_name name, sum(oi.quantity) q, sum(oi.line_subtotal) a
            from public.order_items oi join _rep_orders o on o.id = oi.order_id
           where o.status = 'completed' group by oi.product_name order by 3 desc limit 50) x;
  select coalesce(jsonb_agg(jsonb_build_object('method', name, 'bills', n, 'amount', a) order by a desc), '[]'::jsonb) into v_by_method
    from (select pm.name, count(*) n, sum(p.amount) a
            from public.payments p join _rep_orders o on o.id = p.order_id
            join public.payment_methods pm on pm.id = p.payment_method_id
           where o.status = 'completed' group by pm.name) x;
  select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'bills', n, 'total', t) order by t desc), '[]'::jsonb) into v_by_type
    from (select order_type, count(*) n, sum(grand_total) t from _rep_orders where status = 'completed' group by 1) x;

  if v_fin then
    select coalesce(jsonb_agg(jsonb_build_object('component', c, 'rate', r, 'taxable', tx, 'tax', ta) order by r, c), '[]'::jsonb)
      into v_tax
      from (select t.component_name c, t.rate r, sum(t.taxable_amount) tx, sum(t.tax_amount) ta
              from public.order_item_taxes t join _rep_orders o on o.id = t.order_id
             where o.status = 'completed' group by 1, 2) x;
  end if;

  return jsonb_build_object('from', p_from, 'to', p_to, 'timezone', v_tz, 'financial', v_fin,
    'summary', v_summary, 'by_day', v_by_day, 'by_hour', v_by_hour, 'by_item', v_by_item,
    'by_method', v_by_method, 'by_type', v_by_type, 'tax', v_tax);
end $$;

-- 12. Completed bills: protect the new money columns too -----------------------------
create or replace function app.protect_completed_orders()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if old.status in ('completed', 'voided') then
    if new.subtotal is distinct from old.subtotal
    or new.discount_total is distinct from old.discount_total
    or new.tax_total is distinct from old.tax_total
    or new.tax_included is distinct from old.tax_included
    or new.tax_exempt_amount is distinct from old.tax_exempt_amount
    or new.service_charge is distinct from old.service_charge
    or new.grand_total is distinct from old.grand_total
    or new.bill_number is distinct from old.bill_number
    or new.branch_id is distinct from old.branch_id then
      raise exception 'Bill % is closed and its amounts cannot be changed. Void it or raise a refund instead.', old.bill_number;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

-- Grants.
revoke all on function public.quote_order(jsonb, numeric, boolean, jsonb),
  public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text, boolean, jsonb),
  public.set_prices_include_tax(boolean), public.save_tax_group(uuid, text, jsonb)
  from public, anon;
grant execute on function public.quote_order(jsonb, numeric, boolean, jsonb),
  public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text, boolean, jsonb),
  public.set_prices_include_tax(boolean), public.save_tax_group(uuid, text, jsonb)
  to authenticated;
revoke all on function app.country_preset(text), app.effective_rate(jsonb) from public, anon;
