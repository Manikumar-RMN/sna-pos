-- 090: Bill numbers the owner controls: a bill prefix and a number that counts up by itself.
--
-- Each outlet has a bill prefix (for example BILL26) and bills are numbered BILL26-0001, BILL26-0002, ...
-- The owner can change the prefix in Settings → Billing (for example at the start of a financial year);
-- a new prefix starts again from 0001. Going back to a prefix used before carries on from where it
-- stopped, so no number is ever given twice. Numbering does not restart on its own.
-- The prefix is 1 to 7 letters, digits or "/", so every bill number stays within GST's 16 characters,
-- bills made while the internet is off included (BILL26-X1-0007).
-- Existing outlets get the prefix <outlet code><year> (India: MN26) and start at 0001; bills already
-- made keep their numbers.

create table public.bill_series (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete restrict,
  branch_id uuid not null,
  prefix text not null check (prefix ~ '^[A-Za-z0-9/]{1,7}$'),
  next_seq bigint not null default 1 check (next_seq >= 1),
  is_current boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references public.users(id) on delete restrict,
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id) on delete restrict
);
create unique index bill_series_prefix_uq on public.bill_series (restaurant_id, upper(prefix));
create unique index bill_series_current_uq on public.bill_series (branch_id) where is_current;
alter table public.bill_series enable row level security;
revoke all on public.bill_series from anon, authenticated;

alter table public.offline_series add column series_key text;

-- The prefix a new outlet starts with: its code, plus (India) the year the financial year starts.
create or replace function app.default_bill_prefix(p_branch uuid)
returns text
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_code text; v_country text; v_tz text; v_p text;
begin
  select upper(regexp_replace(b.code, '[^A-Za-z0-9]', '', 'g')), r.country_code, coalesce(b.timezone, r.timezone)
    into v_code, v_country, v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = p_branch;
  v_code := left(coalesce(nullif(v_code, ''), 'B'), 5);
  if v_country = 'IN' then
    v_p := v_code || substr(app.fy_label('IN', (now() at time zone coalesce(v_tz, 'Asia/Kolkata'))::date), 3, 2);
  else
    v_p := v_code;
  end if;
  return v_p;
end $function$;

-- The outlet's current bill series, made with the default prefix the first time it is needed.
create or replace function app.current_bill_series(p_branch uuid)
returns public.bill_series
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare s public.bill_series; v_rest uuid; v_p text; v_try text; n int := 1;
begin
  select * into s from public.bill_series where branch_id = p_branch and is_current for update;
  if found then return s; end if;
  perform pg_advisory_xact_lock(hashtext('bill_series:' || p_branch::text));
  select * into s from public.bill_series where branch_id = p_branch and is_current for update;
  if found then return s; end if;
  select restaurant_id into v_rest from public.branches where id = p_branch;
  if v_rest is null then raise exception 'Outlet not found.'; end if;
  v_p := app.default_bill_prefix(p_branch);
  v_try := v_p;
  while exists (select 1 from public.bill_series where restaurant_id = v_rest and upper(prefix) = upper(v_try)) loop
    n := n + 1;
    v_try := left(v_p, 7 - length(n::text)) || n;
  end loop;
  insert into public.bill_series (restaurant_id, branch_id, prefix) values (v_rest, p_branch, v_try) returning * into s;
  return s;
end $function$;

create or replace function app.next_bill_number(p_branch uuid, out device_id uuid, out bill_no text)
returns record
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare s public.bill_series;
begin
  select d.id into device_id
    from public.devices d where d.branch_id = p_branch and d.is_active and d.device_type <> 'counter' order by d.created_at limit 1;
  if device_id is null then raise exception 'No billing device is set up for this branch.'; end if;
  s := app.current_bill_series(p_branch);
  bill_no := s.prefix || '-' || lpad(s.next_seq::text, greatest(4, length(s.next_seq::text)), '0');
  if length(bill_no) > 16 then
    raise exception 'Bill number % would be longer than 16 characters. Choose a shorter bill prefix in Settings → Billing.', bill_no;
  end if;
  update public.bill_series set next_seq = next_seq + 1 where id = s.id;
end $function$;

-- Settings → Billing: the prefix, the next number, and the prefixes used before.
create or replace function public.bill_prefix_info()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_branch uuid := app.current_branch_id(); s public.bill_series;
begin
  perform app.require_permission('order.create');
  if v_branch is null then raise exception 'No outlet chosen.'; end if;
  s := app.current_bill_series(v_branch);
  return jsonb_build_object(
    'prefix', s.prefix,
    'next_number', s.prefix || '-' || lpad(s.next_seq::text, greatest(4, length(s.next_seq::text)), '0'),
    'bills_in_series', s.next_seq - 1,
    'since', s.created_at,
    'earlier', coalesce((select jsonb_agg(jsonb_build_object('prefix', x.prefix, 'last_number',
                          case when x.next_seq > 1 then x.prefix || '-' || lpad((x.next_seq - 1)::text, greatest(4, length((x.next_seq - 1)::text)), '0') end) order by x.created_at desc)
                           from public.bill_series x where x.branch_id = v_branch and not x.is_current), '[]'::jsonb));
end $function$;

create or replace function public.set_bill_prefix(p_prefix text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_p text := btrim(coalesce(p_prefix, '')); cur public.bill_series; old public.bill_series; v_other text; v_had boolean;
begin
  if v_branch is null then raise exception 'No outlet chosen.'; end if;
  if v_p !~ '^[A-Za-z0-9/]{1,7}$' then
    raise exception 'The bill prefix is 1 to 7 letters, digits or "/" (for example BILL26). No spaces or "-": the number is added after a "-".';
  end if;
  cur := app.current_bill_series(v_branch);
  if upper(cur.prefix) = upper(v_p) and cur.prefix = v_p then
    return jsonb_build_object('changed', false, 'prefix', cur.prefix, 'next_number', cur.prefix || '-' || lpad(cur.next_seq::text, greatest(4, length(cur.next_seq::text)), '0'));
  end if;
  select * into old from public.bill_series where restaurant_id = v_rest and upper(prefix) = upper(v_p) for update;
  v_had := found;
  if v_had and old.branch_id <> v_branch then
    select name into v_other from public.branches where id = old.branch_id;
    raise exception 'The prefix % is used by the outlet %. Choose another.', old.prefix, v_other;
  end if;
  if v_had and old.id = cur.id then
    -- Only the letters' case changes; the numbers carry on.
    if exists (select 1 from public.orders where branch_id = v_branch and bill_number like cur.prefix || '-%') then
      raise exception 'Bills have already been made with %. Choose a new prefix instead of changing its capital letters.', cur.prefix;
    end if;
    update public.bill_series set prefix = v_p where id = cur.id returning * into cur;
  else
    update public.bill_series set is_current = false where id = cur.id;
    if v_had then
      update public.bill_series set is_current = true where id = old.id returning * into cur;   -- back to an earlier prefix: carry on
    else
      insert into public.bill_series (restaurant_id, branch_id, prefix, created_by) values (v_rest, v_branch, v_p, v_user) returning * into cur;
    end if;
  end if;
  perform app.audit('settings.bill_prefix', 'branches', v_branch,
    jsonb_build_object('prefix', cur.prefix, 'next_number', cur.prefix || '-' || lpad(cur.next_seq::text, greatest(4, length(cur.next_seq::text)), '0')),
    jsonb_build_object('prefix', (select prefix from public.bill_series where id <> cur.id and branch_id = v_branch order by created_at desc limit 1)));
  return jsonb_build_object('changed', true, 'prefix', cur.prefix, 'next_number', cur.prefix || '-' || lpad(cur.next_seq::text, greatest(4, length(cur.next_seq::text)), '0'));
end $function$;

revoke all on function app.default_bill_prefix(uuid), app.current_bill_series(uuid) from public, anon, authenticated;
revoke all on function public.bill_prefix_info(), public.set_bill_prefix(text) from public, anon;
grant execute on function public.bill_prefix_info(), public.set_bill_prefix(text) to authenticated, service_role;

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
         s.receipt_header, s.receipt_footer, s.bill_format, s.packing_product_id, s.packing_per, s.packing_takeaway, s.packing_delivery
    into v_bs from public.branch_settings s where s.branch_id = v_branch;

  return jsonb_build_object(
    'taken_at', now(), 'device_key', p_device_key, 'user_id', v_user,
    'series', jsonb_build_object('prefix', 'X' || (substr(ser.prefix, 2)::int), 'fy', null, 'next_seq', ser.next_seq,
                                 'branch_code', ser.series_key, 'key', ser.series_key),
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
  v_ref uuid; ser public.offline_series; v_seq int; v_no text; v_expected text; v_at timestamptz;
  v_shift uuid; v_existing uuid; it jsonb; v_prod public.products%rowtype; v_incl boolean; v_rate uuid; v_comps jsonb;
  v_lines jsonb := '[]'::jsonb; v_calc_lines jsonb := '[]'::jsonb; i int := 0; v_hist numeric; v_flags jsonb := '[]'::jsonb;
  v_opts jsonb; v_text text; v_delta numeric; v_price numeric; v_disc numeric; v_sc boolean; bs record; v_c jsonb;
  v_order uuid := gen_random_uuid(); v_ids uuid[]; v_method uuid; v_kind text; v_amount numeric(14,2); v_round numeric(14,2) := 0;
  v_tendered numeric; v_currency char(3); v_rmode text; v_device uuid;
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
          and exists (select 1 from public.bill_series bs2 where bs2.branch_id = v_branch
                       and bs2.prefix = left(v_no, length(v_no) - length(v_expected)))) then
    v_expected := (select code from public.branches where id = v_branch) || '-' || ser.prefix || '-' ||
                  case when p_bill->>'fy' is not null then (p_bill->>'fy') || '-' else '' end || lpad(v_seq::text, greatest(4, length(v_seq::text)), '0');
    if v_no is distinct from v_expected then raise exception 'Offline bill number % does not match this device.', v_no; end if;
  end if;
  if exists (select 1 from public.orders where branch_id = v_branch and bill_number = v_no) then
    raise exception 'Bill number % is already used.', v_no;
  end if;
  v_at := least(coalesce((p_bill->>'created_at')::timestamptz, now()), now());
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
    if v_hist is null or (v_price <> v_hist + v_delta and v_price <> v_prod.price + v_delta and v_price <> coalesce((select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = v_prod.id), -1) + v_delta) then
      v_flags := v_flags || jsonb_build_object('flag', 'price', 'item', v_prod.name, 'offline_price', v_price, 'menu_price', coalesce(v_hist, v_prod.price) + v_delta);
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
  if v_disc > 0 and not app.allowed('order.discount') then
    v_flags := v_flags || jsonb_build_object('flag', 'discount_without_right', 'amount', v_disc);
  end if;
  select coalesce(s.service_charge_percent, 0) pct, coalesce(s.service_charge_taxable, false) tx,
         coalesce(s.cash_rounding_mode, 'none') rmode, coalesce(s.rounding_cash_only, false) rcash
    into bs from public.branch_settings s where s.branch_id = v_branch;
  v_sc := coalesce((p_bill->>'service_charge')::boolean, false) and bs.pct > 0;
  v_rmode := case when bs.rcash then 'none' else bs.rmode end;

  select d.id into v_device from public.devices d where d.branch_id = v_branch and d.is_active and d.device_type <> 'counter' order by d.created_at limit 1;
  select currency_code into v_currency from public.restaurants where id = v_rest;

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
    update public.orders set offline_flags = v_flags where id = v_order;
  end if;

  v_method := (p_bill->>'method_id')::uuid;
  select kind into v_kind from public.payment_methods where id = v_method and restaurant_id = v_rest;
  if not found then
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

  update public.offline_series set next_seq = greatest(next_seq, v_seq + 1), last_sync_at = now() where id = ser.id;
  perform app.audit('order.offline_sync', 'orders', v_order,
    jsonb_build_object('bill_number', v_no, 'grand_total', (v_c->>'grand_total')::numeric, 'made_at', v_at, 'flags', v_flags));
  return jsonb_build_object('ok', true, 'order_id', v_order, 'bill_number', v_no, 'grand_total', (v_c->>'grand_total')::numeric,
                            'flags', v_flags);
end $function$;

CREATE OR REPLACE FUNCTION public.sna_erase(p_restaurant uuid, p_pos_tx boolean, p_pos_master boolean, p_stock_tx boolean, p_stock_master boolean, p_client_code text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid; r public.restaurants%rowtype; v_live timestamptz;
  v_reason text := trim(coalesce(p_reason, ''));
  v_pos_tx boolean := coalesce(p_pos_tx, false); v_pos_ms boolean := coalesce(p_pos_master, false);
  v_stk_tx boolean := coalesce(p_stock_tx, false); v_stk_ms boolean := coalesce(p_stock_master, false);
  v_g jsonb := app.erase_groups(); v_done jsonb := '{}'::jsonb; v_n bigint; v_more bigint;
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_restaurant and deleted_at is null for update;
  if not found then raise exception 'Restaurant not found.'; end if;
  if not (v_pos_tx or v_pos_ms or v_stk_tx or v_stk_ms) then raise exception 'Tick what to erase.'; end if;
  if v_pos_ms and not v_pos_tx then
    raise exception 'To erase POS masters, tick POS transactions too. The menu and tables cannot go while bills still point at them.';
  end if;
  if v_stk_ms and not v_stk_tx then
    raise exception 'To erase Stock masters, tick Stock transactions too. Ingredients and suppliers cannot go while stock entries still point at them.';
  end if;
  select live_at into v_live from public.sna_accounts where restaurant_id = p_restaurant;
  if v_live is not null then
    raise exception 'This client is live, so its data cannot be erased. These are real bills the restaurant must keep.';
  end if;
  if trim(coalesce(p_client_code, '')) is distinct from r.client_code then
    raise exception 'The client code does not match. Type % to confirm.', r.client_code;
  end if;
  if length(v_reason) < 5 then raise exception 'Write why this data is being erased.'; end if;

  -- From here to the end of this transaction, the "cannot be deleted" guards let this one restaurant through.
  perform set_config('app.erase_restaurant', p_restaurant::text, true);

  if v_pos_tx then
    v_n := app.erase_tables(p_restaurant, v_g->'pos_tx');
    -- The stock those bills used goes with them (sales and returns are stock entries tied to a bill).
    if not v_stk_tx then
      delete from public.stock_movements where restaurant_id = p_restaurant and order_id is not null;
      get diagnostics v_more = row_count;
      v_n := v_n + v_more;
    end if;
    update public.devices set next_bill_seq = 1 where restaurant_id = p_restaurant;
    update public.offline_series set next_seq = 1 where restaurant_id = p_restaurant;
    update public.bill_series set next_seq = 1 where restaurant_id = p_restaurant;
    v_done := v_done || jsonb_build_object('pos_tx', v_n);
  end if;
  if v_stk_tx then
    v_done := v_done || jsonb_build_object('stock_tx', app.erase_tables(p_restaurant, v_g->'stock_tx'));
  end if;
  if v_pos_ms then
    -- The packing charge is a dish; the outlet setting that points at it is switched off.
    update public.branch_settings set packing_product_id = null where restaurant_id = p_restaurant and packing_product_id is not null;
    v_done := v_done || jsonb_build_object('pos_master', app.erase_tables(p_restaurant, v_g->'pos_master'));
  end if;
  if v_stk_ms then
    v_done := v_done || jsonb_build_object('stock_master', app.erase_tables(p_restaurant, v_g->'stock_master'));
  end if;

  perform set_config('app.erase_restaurant', '', true);
  perform app.log_plan(p_restaurant, 'data.erased', jsonb_build_object('rows', v_done, 'reason', left(v_reason, 300)));
  return jsonb_build_object('rows', v_done);
end $function$;

-- Every outlet gets its bill series now, so the first bill after this change shows the new number.
do $$ begin perform app.current_bill_series(b.id) from public.branches b where b.deleted_at is null; end $$;
