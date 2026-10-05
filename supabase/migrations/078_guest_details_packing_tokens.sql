-- 078: counter details the team review asked for
--
--  * Guest name, phone and delivery address on a bill (takeaway, delivery and
--    phone orders); a phone number also finds or starts the customer record.
--  * A packing charge that is added to takeaway and delivery bills. It is an
--    ordinary menu line ("Packing charge"), so tax, reports, offline billing
--    and credit notes treat it like any other item.
--  * Token numbers that restart every business day (takeaway and delivery, or
--    every bill).

alter table public.orders add column if not exists guest_name text;
alter table public.orders add column if not exists guest_phone text;
alter table public.orders add column if not exists delivery_address text;
alter table public.orders add column if not exists token_no integer;

alter table public.business_days add column if not exists last_token integer not null default 0;

alter table public.branch_settings add column if not exists token_numbers text not null default 'off';
alter table public.branch_settings add column if not exists packing_product_id uuid;
-- Marks the menu item that is a charge, not food: never sent to the kitchen, never on the guest QR menu.
alter table public.products add column if not exists is_charge boolean not null default false;
alter table public.branch_settings add column if not exists packing_per text not null default 'bill';
alter table public.branch_settings add column if not exists packing_takeaway boolean not null default true;
alter table public.branch_settings add column if not exists packing_delivery boolean not null default true;

alter table public.branch_settings drop constraint if exists branch_settings_token_numbers_check;
alter table public.branch_settings add constraint branch_settings_token_numbers_check
  check (token_numbers in ('off', 'takeaway', 'all'));
alter table public.branch_settings drop constraint if exists branch_settings_packing_per_check;
alter table public.branch_settings add constraint branch_settings_packing_per_check
  check (packing_per in ('bill', 'item'));
alter table public.branch_settings drop constraint if exists branch_settings_packing_product_same_rest;
alter table public.branch_settings add constraint branch_settings_packing_product_same_rest
  foreign key (restaurant_id, packing_product_id) references public.products(restaurant_id, id);

------------------------------------------------------------------
-- Taking a bill
------------------------------------------------------------------
drop function if exists public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text, boolean, jsonb, text, uuid);
CREATE OR REPLACE FUNCTION public.create_order(p_items jsonb, p_order_type text DEFAULT 'dine_in'::text, p_table_id uuid DEFAULT NULL::uuid, p_customer_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_tendered numeric DEFAULT NULL::numeric, p_discount_amount numeric DEFAULT 0, p_discount_reason text DEFAULT NULL::text, p_service_charge boolean DEFAULT NULL::boolean, p_senior jsonb DEFAULT NULL::jsonb, p_reference text DEFAULT NULL::text, p_client_ref uuid DEFAULT NULL::uuid, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_restaurant uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  v_in jsonb; v_c jsonb; v_currency char(3); v_auto_kot boolean; v_shift uuid; v_device uuid;
  v_bill_no text; v_order_id uuid := gen_random_uuid(); v_ids uuid[];
  v_method_kind text; v_grand numeric(14,2); v_amount numeric(14,2); v_cash_round numeric(14,2) := 0;
  v_change numeric(14,2) := 0; v_paid boolean := false; v_rmode text;
  v_gname text; v_gphone text; v_addr text; v_cust uuid := p_customer_id; v_gdel timestamptz;
  v_tok text; v_token int;
begin
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('order_ref:' || p_client_ref::text));
    select jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'grand_total', o.grand_total,
             'amount_paid', o.paid_total, 'cash_rounding', 0, 'change', 0, 'paid', o.payment_status = 'paid', 'repeat', true,
             'token_no', o.token_no)
      into v_in from public.orders o where o.restaurant_id = app.current_restaurant_id() and o.client_ref = p_client_ref;
    if v_in is not null then return v_in; end if;
  end if;
  if nullif(p_senior, 'null'::jsonb) is not null and not app.allowed('order.discount') then
    raise exception 'A manager must approve the senior citizen / PWD discount (order.discount).';
  end if;
  if coalesce(p_discount_amount, 0) < 0 then raise exception 'A discount cannot be negative.'; end if;
  if coalesce(p_discount_amount, 0) > 0 and not app.allowed('order.discount') then
    raise exception 'A manager must approve a discount (order.discount).';
  end if;
  if v_branch is null then raise exception 'No branch is set up for this restaurant.'; end if;
  if coalesce(p_order_type, '') not in ('dine_in', 'takeaway', 'delivery') then raise exception 'Unknown order type.'; end if;

  select s.id into v_shift from public.shifts s
   where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1; if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

  if p_payment_method_id is not null and not app.allowed('payment.take') then
    raise exception 'You do not have the right to take payment (payment.take). Save the bill and ask the cashier to settle it.';
  end if;
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

  -- The guest's name, phone and delivery address, when the counter took them.
  -- A phone number also finds (or starts) that guest's customer record.
  if p_extra is not null and jsonb_typeof(p_extra) = 'object' then
    v_gname  := nullif(left(trim(coalesce(p_extra->>'guest_name', '')), 80), '');
    v_gphone := app.clean_phone(p_extra->>'guest_phone');
    v_addr   := nullif(left(trim(coalesce(p_extra->>'address', '')), 300), '');
    if v_gphone is not null and length(regexp_replace(p_extra->>'guest_phone', '[^0-9]', '', 'g')) < 7 then
      raise exception 'That phone number looks too short.';
    end if;
    if v_gphone is not null and v_cust is null then
      select c.id, c.deleted_at into v_cust, v_gdel from public.customers c
       where c.restaurant_id = v_restaurant and c.phone = v_gphone;
      if v_cust is null then
        insert into public.customers (restaurant_id, name, phone)
        values (v_restaurant, coalesce(v_gname, 'Guest'), v_gphone) returning id into v_cust;
      else
        update public.customers set deleted_at = null,
               name = case when v_gname is not null and (name is null or name = 'Guest' or v_gdel is not null) then v_gname else name end
         where id = v_cust and (v_gdel is not null or (v_gname is not null and (name is null or name = 'Guest')));
      end if;
    end if;
  end if;
  v_in := app.bill_input(v_restaurant, v_branch, p_items, p_discount_amount, p_service_charge, p_senior);
  v_rmode := v_in->>'cash_rounding';

  select r.currency_code into v_currency from public.restaurants r where r.id = v_restaurant;
  select coalesce(bs.auto_print_kot, true) into v_auto_kot from public.branch_settings bs where bs.branch_id = v_branch;
  v_auto_kot := coalesce(v_auto_kot, true);

  select n.device_id, n.bill_no into v_device, v_bill_no from app.next_bill_number(v_branch) n;

  insert into public.orders
    (id, restaurant_id, branch_id, device_id, bill_number, order_type, dining_table_id, customer_id,
     cashier_id, shift_id, currency_code, status, payment_status, client_created_at, calc_params, senior_details,
     guest_name, guest_phone, delivery_address)
  values
    (v_order_id, v_restaurant, v_branch, v_device, v_bill_no, p_order_type, p_table_id, v_cust,
     v_user, v_shift, v_currency, 'open', 'unpaid', now(), (v_in->'calc') - 'lines', nullif(v_in->'senior', 'null'::jsonb),
     v_gname, v_gphone, case when p_order_type = 'delivery' then v_addr end);
  if p_client_ref is not null then update public.orders set client_ref = p_client_ref where id = v_order_id; end if;
  -- Token number for the day (takeaway and delivery, or every bill), if the outlet uses tokens.
  select coalesce(bs.token_numbers, 'off') into v_tok from public.branch_settings bs where bs.branch_id = v_branch;
  if v_tok = 'all' or (v_tok = 'takeaway' and p_order_type <> 'dine_in') then
    update public.business_days d set last_token = d.last_token + 1
     where d.branch_id = v_branch
       and d.business_date = (select o.business_date from public.orders o where o.id = v_order_id)
    returning d.last_token into v_token;
    update public.orders set token_no = v_token where id = v_order_id;
  end if;
  v_ids := app.insert_order_lines(v_order_id, v_restaurant, v_in->'calc'->'lines');
  v_c := app.recalc_order(v_order_id);
  if (v_c->>'discount')::numeric < round(coalesce(p_discount_amount, 0), 2) then
    raise exception 'The discount (%) is more than the bill (%).', round(p_discount_amount, 2), (v_c->>'subtotal')::numeric;
  end if;
  v_grand := (v_c->>'grand_total')::numeric;

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

  if p_payment_method_id is not null and v_grand > 0 then
    v_amount := v_grand;
    if v_method_kind = 'cash' and v_rmode <> 'none' then
      v_amount := app.round_cash(v_grand, v_rmode);
      if v_amount <= 0 then v_amount := v_grand; end if;
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
       change_amount, status, received_by, client_created_at, rounding_adjustment, reference_no)
    values
      (gen_random_uuid(), v_restaurant, v_order_id, p_payment_method_id, v_amount, v_currency,
       p_tendered, v_change, 'captured', v_user, now(), v_cash_round, nullif(left(trim(p_reference), 60), ''));
    v_paid := true;
  end if;

  update public.orders set
      paid_total = case when v_paid then v_amount else 0 end,
      status = 'completed',
      payment_status = case when v_paid or v_grand = 0 then 'paid' else 'unpaid' end,
      synced_at = now()
  where id = v_order_id;

  if v_auto_kot then perform app.create_kitchen_ticket(v_order_id, v_ids); end if;

  perform app.audit('order.create', 'orders', v_order_id,
    jsonb_build_object('bill_number', v_bill_no, 'grand_total', v_grand,
                       'discount', (v_c->>'discount')::numeric, 'senior_discount', (v_c->>'senior_discount')::numeric));

  return jsonb_build_object('order_id', v_order_id, 'bill_number', v_bill_no,
    'grand_total', v_grand, 'amount_paid', case when v_paid then v_amount else 0 end,
    'cash_rounding', v_cash_round, 'change', v_change, 'paid', v_paid or v_grand = 0, 'token_no', v_token);
end $function$;
revoke all on function public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text, boolean, jsonb, text, uuid, jsonb) from public, anon;
grant execute on function public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text, boolean, jsonb, text, uuid, jsonb) to authenticated, service_role;

------------------------------------------------------------------
-- Change the guest details on a bill
------------------------------------------------------------------
create or replace function public.set_order_guest(p_order_id uuid, p_name text, p_phone text, p_address text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id();
  o public.orders%rowtype;
  v_name text := nullif(left(trim(coalesce(p_name, '')), 80), '');
  v_phone text := app.clean_phone(p_phone);
  v_addr text := nullif(left(trim(coalesce(p_address, '')), 300), '');
  v_cust uuid; v_del timestamptz;
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if v_phone is not null and length(regexp_replace(p_phone, '[^0-9]', '', 'g')) < 7 then raise exception 'That phone number looks too short.'; end if;
  v_cust := o.customer_id;
  -- Once a bill is paid, the customer it was paid under (and any points earned) stays;
  -- only the name and phone printed on the bill change.
  if v_phone is not null and v_phone is distinct from o.guest_phone
     and (o.customer_id is null or o.payment_status <> 'paid') then
    select c.id, c.deleted_at into v_cust, v_del from public.customers c where c.restaurant_id = v_rest and c.phone = v_phone;
    if v_cust is null then
      insert into public.customers (restaurant_id, name, phone) values (v_rest, coalesce(v_name, 'Guest'), v_phone) returning id into v_cust;
    else
      update public.customers set deleted_at = null,
             name = case when v_name is not null and (name is null or name = 'Guest' or v_del is not null) then v_name else name end
       where id = v_cust and (v_del is not null or (v_name is not null and (name is null or name = 'Guest')));
    end if;
  end if;
  update public.orders set guest_name = v_name, guest_phone = v_phone,
         delivery_address = case when o.order_type = 'delivery' then v_addr else delivery_address end,
         customer_id = v_cust
   where id = o.id;
  perform app.audit('order.guest', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'name', v_name, 'phone', v_phone),
    jsonb_build_object('name', o.guest_name, 'phone', o.guest_phone));
  return jsonb_build_object('bill_number', o.bill_number, 'guest_name', v_name, 'guest_phone', v_phone, 'customer_id', v_cust);
end $$;
revoke all on function public.set_order_guest(uuid, text, text, text) from public, anon;
grant execute on function public.set_order_guest(uuid, text, text, text) to authenticated, service_role;

------------------------------------------------------------------
-- Packing charge
------------------------------------------------------------------
create or replace function public.save_packing_charge(p_amount numeric, p_per text, p_tax_group_id uuid,
                                                      p_takeaway boolean default true, p_delivery boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_cat uuid; v_prod uuid; v_outlets int;
begin
  if v_branch is null then raise exception 'No branch is set up for this restaurant.'; end if;
  if v_amount < 0 then raise exception 'The packing charge cannot be negative.'; end if;
  if v_amount > 100000 then raise exception 'That packing charge is too large.'; end if;

  -- One "Packing charge" menu item per restaurant, found by its mark (so renaming it is harmless).
  select p.id into v_prod from public.products p
   where p.restaurant_id = v_rest and p.is_charge and p.deleted_at is null order by p.created_at limit 1;

  -- Switched off: this outlet's bills stop getting the line and the item leaves
  -- this outlet's menu. Old bills and reports keep their name for it.
  if v_amount = 0 then
    update public.branch_settings set packing_product_id = null where branch_id = v_branch;
    if v_prod is not null then
      insert into public.branch_prices (restaurant_id, branch_id, product_id, is_available, updated_by)
      values (v_rest, v_branch, v_prod, false, v_user)
      on conflict (branch_id, product_id) do update set is_available = false, updated_at = now(), updated_by = excluded.updated_by;
    end if;
    perform app.audit('settings.packing', 'branch_settings', v_branch, jsonb_build_object('amount', 0));
    return jsonb_build_object('on', false);
  end if;

  if coalesce(p_per, '') not in ('bill', 'item') then raise exception 'Choose per bill or per item.'; end if;
  if not coalesce(p_takeaway, false) and not coalesce(p_delivery, false) then
    raise exception 'Tick takeaway, delivery or both.';
  end if;
  if not exists (select 1 from public.tax_groups g where g.id = p_tax_group_id and g.restaurant_id = v_rest and g.is_active) then
    raise exception 'Choose the tax for the packing charge.';
  end if;

  if v_prod is null then
    select c.id into v_cat from public.categories c
     where c.restaurant_id = v_rest and c.deleted_at is null and lower(trim(c.name)) = 'charges' order by c.created_at limit 1;
    if v_cat is null then
      insert into public.categories (restaurant_id, name, display_order) values (v_rest, 'Charges', 999) returning id into v_cat;
    end if;
    insert into public.products (restaurant_id, category_id, tax_group_id, name, price, display_order, is_charge)
    values (v_rest, v_cat, p_tax_group_id, 'Packing charge', v_amount, 999, true) returning id into v_prod;
  else
    -- The tax is the menu item's, so it is the same at every outlet. Touch the
    -- item only when something really changes (price and tax changes are guarded).
    update public.products set tax_group_id = p_tax_group_id, is_available = true
     where id = v_prod and (tax_group_id is distinct from p_tax_group_id or not is_available);
    -- With a single outlet the menu price follows too, so the Menu screen shows the same amount.
    select count(*) into v_outlets from public.branches b where b.restaurant_id = v_rest and b.deleted_at is null and b.is_active;
    if v_outlets <= 1 then
      update public.products set price = v_amount where id = v_prod and price is distinct from v_amount;
    end if;
  end if;

  -- The amount belongs to this outlet: another outlet can charge a different one.
  insert into public.branch_prices (restaurant_id, branch_id, product_id, price, is_available, updated_by)
  values (v_rest, v_branch, v_prod, v_amount, true, v_user)
  on conflict (branch_id, product_id) do update
     set price = excluded.price, is_available = true, updated_at = now(), updated_by = excluded.updated_by;

  update public.branch_settings
     set packing_product_id = v_prod, packing_per = p_per,
         packing_takeaway = coalesce(p_takeaway, false), packing_delivery = coalesce(p_delivery, false)
   where branch_id = v_branch;

  perform app.audit('settings.packing', 'branch_settings', v_branch,
    jsonb_build_object('amount', v_amount, 'per', p_per, 'takeaway', p_takeaway, 'delivery', p_delivery));
  return jsonb_build_object('on', true, 'product_id', v_prod, 'amount', v_amount);
end $$;
revoke all on function public.save_packing_charge(numeric, text, uuid, boolean, boolean) from public, anon;
grant execute on function public.save_packing_charge(numeric, text, uuid, boolean, boolean) to authenticated, service_role;

------------------------------------------------------------------
-- Settings: token numbers
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_settings(p_settings jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  if s ? 'token_numbers' and (s->>'token_numbers') not in ('off', 'takeaway', 'all') then
    raise exception 'Unknown token number option.';
  end if;
  if s ? 'fssai_no' and nullif(trim(s->>'fssai_no'), '') is not null and trim(s->>'fssai_no') !~ '^[0-9]{14}$' then
    raise exception 'The FSSAI licence number has 14 digits.';
  end if;
  if s ? 'sac_code' and nullif(trim(s->>'sac_code'), '') is not null and trim(s->>'sac_code') !~ '^[0-9]{4,8}$' then
    raise exception 'The SAC / HSN code is 4 to 8 digits.';
  end if;

  update public.restaurants set
    fssai_no = case when s ? 'fssai_no' then nullif(trim(s->>'fssai_no'), '') else fssai_no end,
    sac_code = case when s ? 'sac_code' then nullif(trim(s->>'sac_code'), '') else sac_code end,
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
    token_numbers = case when s ? 'token_numbers' then s->>'token_numbers' else token_numbers end,
    service_charge_percent = case when s ? 'service_charge_percent' then round((s->>'service_charge_percent')::numeric, 2) else service_charge_percent end,
    service_charge_taxable = case when s ? 'service_charge_taxable' then (s->>'service_charge_taxable')::boolean else service_charge_taxable end,
    service_charge_default_on = case when s ? 'service_charge_default_on' then (s->>'service_charge_default_on')::boolean else service_charge_default_on end,
    service_charge_label = case when s ? 'service_charge_label' and coalesce(trim(s->>'service_charge_label'), '') <> ''
                                then left(trim(s->>'service_charge_label'), 40) else service_charge_label end
  where branch_id = v_branch;

  perform app.audit('settings.update', 'restaurants', v_rest, s);
end $function$;

------------------------------------------------------------------
-- The packing line is not food: keep it off kitchen tickets and the guest QR menu
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.create_kitchen_ticket(p_order uuid, p_items uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; v_n int; v_id uuid; v_first uuid; st record;
begin
  select * into o from public.orders where id = p_order;
  for st in
    select case when app.feature_on(o.restaurant_id, 'kitchen_stations') then coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen') else 'Kitchen' end as station
      from public.order_items oi left join public.products p on p.id = oi.product_id
     where oi.id = any(p_items) and not oi.held
       and not exists (select 1 from public.products cp where cp.id = oi.product_id and cp.is_charge)
     group by 1 order by 1
  loop
    v_id := gen_random_uuid();
    select count(*) + 1 into v_n from public.kitchen_tickets where order_id = p_order;
    insert into public.kitchen_tickets (id, restaurant_id, branch_id, order_id, ticket_number, station, status, client_created_at)
    values (v_id, o.restaurant_id, o.branch_id, o.id,
            'K-' || o.bill_number || case when v_n > 1 then '-' || v_n else '' end, st.station, 'new', now());
    insert into public.kitchen_ticket_items (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note)
    select o.restaurant_id, v_id, oi.id,
           oi.product_name || coalesce(' (' || oi.options_text || ')', ''), oi.quantity, oi.kitchen_note
      from public.order_items oi left join public.products p on p.id = oi.product_id
     where oi.id = any(p_items) and not oi.held
       and not exists (select 1 from public.products cp where cp.id = oi.product_id and cp.is_charge)
       and case when app.feature_on(o.restaurant_id, 'kitchen_stations') then coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen') else 'Kitchen' end = st.station
     order by oi.created_at, oi.id;
    v_first := coalesce(v_first, v_id);
  end loop;
  return v_first;
end $function$;

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
    'second_language', r.second_language, 'table', t.table_number,
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items', c.items) order by c.display_order, c.name)
        from (
          select c.id, c.name, c.display_order,
                 jsonb_agg(jsonb_build_object(
                   'id', p.id, 'name', p.name, 'name_local', p.name_local, 'is_veg', p.is_veg,
                   'price', coalesce(bp.price, p.price),
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
                   order by p.display_order, p.name) as items
            from public.categories c
            join public.products p on p.category_id = c.id and p.deleted_at is null
            left join public.branch_prices bp on bp.product_id = p.id and bp.branch_id = t.branch_id
           where c.restaurant_id = t.restaurant_id and c.deleted_at is null
             and p.is_available and coalesce(bp.is_available, true)
             and not p.is_charge
           group by c.id, c.name, c.display_order
        ) c), '[]'::jsonb));
end $function$;

------------------------------------------------------------------
-- Offline billing knows the packing rule too
------------------------------------------------------------------
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
  v_fy := case when v_country = 'IN' then (select substr(f, 3, 2) || substr(f, 6, 2) from app.fy_label('IN', (now() at time zone v_tz)::date) f) else null end;
  if v_fy is distinct from ser.fy then
    update public.offline_series set fy = v_fy, next_seq = case when v_fy is not null and ser.fy is not null then 1 else next_seq end
     where id = ser.id returning * into ser;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'short_name', p.short_name, 'price', coalesce((select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = p.id), p.price), 'category_id', p.category_id,
      'category_name', c.name, 'is_veg', p.is_veg, 'station', coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen'),
      'inclusive', coalesce(g.is_price_inclusive, false),
      'comps', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'rate', t.rate, 'compound', t.is_compound) order by t.display_order)
                           from public.tax_rate_components t
                          where t.tax_rate_id = (select tr.id from public.tax_rates tr where tr.tax_group_id = p.tax_group_id
                                                   and tr.valid_from <= current_date and (tr.valid_to is null or tr.valid_to >= current_date)
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
         s.receipt_header, s.receipt_footer, s.packing_product_id, s.packing_per, s.packing_takeaway, s.packing_delivery
    into v_bs from public.branch_settings s where s.branch_id = v_branch;

  return jsonb_build_object(
    'taken_at', now(), 'device_key', p_device_key, 'user_id', v_user,
    'series', jsonb_build_object('prefix', ser.prefix, 'fy', ser.fy, 'next_seq', ser.next_seq,
                                 'branch_code', (select code from public.branches where id = v_branch)),
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
                                  'invoice_title', (select invoice_title from public.countries where code = v_country)));
end $function$;
