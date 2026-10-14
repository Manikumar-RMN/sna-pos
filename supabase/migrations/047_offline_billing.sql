-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928093244, name '47_offline_billing'. This is the SQL that actually ran.

-- Price history, so an offline bill can be checked against the price that applied when it was made.
create table public.product_price_history (
  id bigserial primary key,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  product_id uuid not null,
  price numeric(12,2) not null,
  valid_from timestamptz not null default now(),
  valid_to timestamptz
);
create index pph_lookup on public.product_price_history (product_id, valid_from);
alter table public.product_price_history enable row level security;
revoke all on public.product_price_history from anon, authenticated;
insert into public.product_price_history (restaurant_id, product_id, price, valid_from)
select restaurant_id, id, price, created_at from public.products;
create or replace function app.track_price() returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if tg_op = 'INSERT' or new.price is distinct from old.price then
    update public.product_price_history set valid_to = now() where product_id = new.id and valid_to is null;
    insert into public.product_price_history (restaurant_id, product_id, price) values (new.restaurant_id, new.id, new.price);
  end if;
  return new;
end $$;
create trigger trg_track_price after insert or update of price on public.products for each row execute function app.track_price();

-- Each device that may bill offline gets its own bill-number series (e.g. MN-X01-2627-0001), so numbers never clash.
create table public.offline_series (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  device_key text not null check (device_key ~ '^[0-9a-f-]{36}$'),
  prefix text not null,
  fy text,
  next_seq int not null default 1,
  created_at timestamptz not null default now(),
  last_sync_at timestamptz,
  unique (branch_id, device_key),
  unique (branch_id, prefix),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id)
);
alter table public.offline_series enable row level security;
revoke all on public.offline_series from anon, authenticated;
alter table public.orders add column offline_flags jsonb;

-- Everything the counter needs to keep billing without the internet.
create or replace function public.offline_snapshot(p_device_key text) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
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
      'id', p.id, 'name', p.name, 'short_name', p.short_name, 'price', p.price, 'category_id', p.category_id,
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
   where p.restaurant_id = v_rest and p.deleted_at is null and p.is_available and c.deleted_at is null;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind, 'ask_reference', ask_reference, 'upi_id', upi_id) order by display_order), '[]'::jsonb)
    into v_methods from public.payment_methods where restaurant_id = v_rest and is_active;
  select coalesce(s.service_charge_percent, 0) pct, coalesce(s.service_charge_taxable, false) tx, coalesce(s.service_charge_default_on, false) def_on,
         coalesce(s.service_charge_label, 'Service charge') lbl, coalesce(s.cash_rounding_mode, 'none') rmode, coalesce(s.rounding_cash_only, false) rcash,
         s.receipt_header, s.receipt_footer
    into v_bs from public.branch_settings s where s.branch_id = v_branch;

  return jsonb_build_object(
    'taken_at', now(), 'device_key', p_device_key, 'user_id', v_user,
    'series', jsonb_build_object('prefix', ser.prefix, 'fy', ser.fy, 'next_seq', ser.next_seq,
                                 'branch_code', (select code from public.branches where id = v_branch)),
    'rights', jsonb_build_object('discount', app.has_permission('order.discount'), 'pay', app.has_permission('payment.take')),
    'menu', v_menu, 'methods', v_methods,
    'settings', jsonb_build_object('sc_percent', v_bs.pct, 'sc_taxable', v_bs.tx, 'sc_default_on', v_bs.def_on, 'sc_label', v_bs.lbl,
                                   'rounding', case when v_bs.rcash then 'none' else v_bs.rmode end,
                                   'cash_rounding', case when v_bs.rcash then v_bs.rmode else 'none' end),
    'receipt', jsonb_build_object('header', coalesce(v_bs.receipt_header, v_r.trading_name), 'legal_name', v_r.legal_name,
                                  'tax_id', v_r.tax_registration_no, 'tax_id_label', (select tax_id_label from public.countries where code = v_country),
                                  'fssai_no', case when v_country = 'IN' then v_r.fssai_no end, 'footer', v_bs.receipt_footer,
                                  'currency', v_r.currency_code, 'timezone', v_tz, 'country', v_country,
                                  'invoice_title', (select invoice_title from public.countries where code = v_country)));
end $$;

-- Records one bill made while offline. Safe to call again: the same bill is never recorded twice.
create or replace function public.sync_offline_bill(p_bill jsonb) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
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
  v_expected := (select code from public.branches where id = v_branch) || '-' || ser.prefix || '-' ||
                case when p_bill->>'fy' is not null then (p_bill->>'fy') || '-' else '' end || lpad(v_seq::text, 4, '0');
  v_no := p_bill->>'number';
  if v_no is distinct from v_expected then raise exception 'Offline bill number % does not match this device (expected %).', v_no, v_expected; end if;
  if exists (select 1 from public.orders where branch_id = v_branch and bill_number = v_no) then
    raise exception 'Bill number % is already used.', v_no;
  end if;
  v_at := least(coalesce((p_bill->>'created_at')::timestamptz, now()), now());
  if v_at < now() - interval '7 days' then v_flags := v_flags || jsonb_build_object('flag', 'older_than_7_days'); end if;

  select s.id into v_shift from public.shifts s where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1;
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
    if v_hist is null or v_price <> v_hist + v_delta then
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

  select n.device_id into v_device from app.next_bill_number(v_branch) n;   -- only to get the billing device; its counter is put back below
  update public.devices set next_bill_seq = next_bill_seq - 1 where id = v_device;
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
end $$;

revoke all on function public.offline_snapshot(text) from public, anon;
revoke all on function public.sync_offline_bill(jsonb) from public, anon;
grant execute on function public.offline_snapshot(text), public.sync_offline_bill(jsonb) to authenticated;
