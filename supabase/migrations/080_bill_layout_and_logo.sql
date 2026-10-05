-- 080: bill layout the owner can adjust, and the restaurant's logo on the bill
--
-- The layout is a small set of on/off choices (paper width, text size, which
-- lines to print). Unknown keys are dropped, so the stored value is always one
-- the bill screen understands. The logo is kept as a small picture inside the
-- database, so it also prints when the internet is down.

alter table public.branch_settings add column if not exists bill_format jsonb not null default '{}'::jsonb;

create or replace function app.clean_bill_format(p jsonb)
returns jsonb
language sql
immutable
set search_path to 'public', 'pg_temp'
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'paper',      case when p->>'paper' in ('58', '80') then p->>'paper' end,
    'text',       case when p->>'text' in ('small', 'normal', 'large') then p->>'text' end,
    'kot_text',   case when p->>'kot_text' in ('normal', 'large') then p->>'kot_text' end,
    'logo',       case when jsonb_typeof(p->'logo') = 'boolean' then p->'logo' end,
    'legal_name', case when jsonb_typeof(p->'legal_name') = 'boolean' then p->'legal_name' end,
    'branch',     case when jsonb_typeof(p->'branch') = 'boolean' then p->'branch' end,
    'address',    case when jsonb_typeof(p->'address') = 'boolean' then p->'address' end,
    'phone',      case when jsonb_typeof(p->'phone') = 'boolean' then p->'phone' end,
    'cashier',    case when jsonb_typeof(p->'cashier') = 'boolean' then p->'cashier' end,
    'guest',      case when jsonb_typeof(p->'guest') = 'boolean' then p->'guest' end,
    'rate',       case when jsonb_typeof(p->'rate') = 'boolean' then p->'rate' end,
    'upi_qr',     case when jsonb_typeof(p->'upi_qr') = 'boolean' then p->'upi_qr' end,
    'powered_by', case when jsonb_typeof(p->'powered_by') = 'boolean' then p->'powered_by' end))
$$;
revoke all on function app.clean_bill_format(jsonb) from public, anon, authenticated;

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
  v_country char(2); v_taxno text; v_logo text;
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
  if s ? 'bill_format' and (jsonb_typeof(s->'bill_format') <> 'object' or length((s->'bill_format')::text) > 4000) then
    raise exception 'The bill layout could not be saved.';
  end if;
  if s ? 'logo' then
    v_logo := nullif(s->>'logo', '');
    if v_logo is not null and (length(v_logo) > 150000 or v_logo !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$') then
      raise exception 'The logo must be a PNG or JPEG picture of about 100 KB or less.';
    end if;
  end if;
  if s ? 'fssai_no' and nullif(trim(s->>'fssai_no'), '') is not null and trim(s->>'fssai_no') !~ '^[0-9]{14}$' then
    raise exception 'The FSSAI licence number has 14 digits.';
  end if;
  if s ? 'sac_code' and nullif(trim(s->>'sac_code'), '') is not null and trim(s->>'sac_code') !~ '^[0-9]{4,8}$' then
    raise exception 'The SAC / HSN code is 4 to 8 digits.';
  end if;

  update public.restaurants set
    logo_url = case when s ? 'logo' then v_logo else logo_url end,
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
    bill_format = case when s ? 'bill_format' then app.clean_bill_format(s->'bill_format') else bill_format end,
    service_charge_percent = case when s ? 'service_charge_percent' then round((s->>'service_charge_percent')::numeric, 2) else service_charge_percent end,
    service_charge_taxable = case when s ? 'service_charge_taxable' then (s->>'service_charge_taxable')::boolean else service_charge_taxable end,
    service_charge_default_on = case when s ? 'service_charge_default_on' then (s->>'service_charge_default_on')::boolean else service_charge_default_on end,
    service_charge_label = case when s ? 'service_charge_label' and coalesce(trim(s->>'service_charge_label'), '') <> ''
                                then left(trim(s->>'service_charge_label'), 40) else service_charge_label end
  where branch_id = v_branch;

  -- The audit log keeps what changed, not the picture itself.
  perform app.audit('settings.update', 'restaurants', v_rest,
    (s - 'logo') || case when s ? 'logo' then jsonb_build_object('logo', case when v_logo is null then 'removed' else 'changed' end) else '{}'::jsonb end);
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
         s.receipt_header, s.receipt_footer, s.bill_format, s.packing_product_id, s.packing_per, s.packing_takeaway, s.packing_delivery
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
                                  'invoice_title', (select invoice_title from public.countries where code = v_country),
                                  'format', coalesce(v_bs.bill_format, '{}'::jsonb), 'logo', v_r.logo_url));
end $function$;
