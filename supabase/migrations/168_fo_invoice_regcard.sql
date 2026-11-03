-- 168: Front Office billing documents (SNA Hospitality, batch B). Depends on 160-167. Additive: new columns, two new tables,
-- new functions. Nothing existing is replaced. Safe to run again.
--
-- The GST tax invoice for a hotel stay, and the registration card.
--
-- Rules this follows (CGST Rule 46; sources and the open points are in docs/front-office-gst-invoice.md):
--   * Invoice number: consecutive, unique within the financial year, at most 16 characters. Format
--     <prefix>/<yyzz>/<6 digits>, e.g. FO/2627/000001 (14 characters with the default two-letter prefix, 16 with a
--     four-letter one). One counter per outlet per financial year; the year starts on 1 April.
--   * Supplier name, address and GSTIN on every invoice. A hotel that has tax on its folio but no GSTIN cannot issue one.
--   * Recipient: the guest by default; a company name and GSTIN when the guest is billed to a business. An unregistered
--     recipient on a bill of 50,000 or more needs an address and a state (Rule 46).
--   * SAC code, taxable value, rate and CGST + SGST on every line, and a summary by SAC and rate.
--   * Place of supply is the hotel's own state (IGST Act s.12(3), immovable property), so the tax is always CGST + SGST,
--     never IGST. ASSUMPTION, confirm with a local accountant.
--   * An invoice is issued once, after check-out, when the folio is final and settled. It is never edited or deleted
--     (a database trigger refuses both). A correction is a credit note, which is NOT built yet; the folio screen says so.
--   * The SAC codes below are the ones the sources listed; they are ASSUMPTIONS to confirm. 996311 room, 996331
--     restaurant and room service, 999711 laundry, 999799 everything else.
--   * E-invoicing (IRN/QR) is NOT built. A business above the e-invoice turnover limit that bills another GST-registered
--     business needs it. CONFIRM the limit that applies to this hotel.

-- ---------------------------------------------------------------- 1. business details
alter table public.fo_branch_settings
  add column if not exists legal_name text,
  add column if not exists gstin text,
  add column if not exists state_code text,
  add column if not exists address text,
  add column if not exists phone text,
  add column if not exists email text,
  add column if not exists invoice_prefix text not null default 'FO',
  add column if not exists invoice_footer text;
alter table public.fo_branch_settings drop constraint if exists fo_settings_gstin_check;
alter table public.fo_branch_settings add constraint fo_settings_gstin_check
  check (gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');
alter table public.fo_branch_settings drop constraint if exists fo_settings_state_check;
alter table public.fo_branch_settings add constraint fo_settings_state_check
  check (state_code is null or state_code ~ '^[0-9]{2}$');
alter table public.fo_branch_settings drop constraint if exists fo_settings_prefix_check;
alter table public.fo_branch_settings add constraint fo_settings_prefix_check
  check (invoice_prefix ~ '^[A-Z0-9]{1,4}$');

-- What the last invoice to a guest used, so the next one starts filled in.
alter table public.fo_guests
  add column if not exists bill_company text,
  add column if not exists bill_gstin text,
  add column if not exists bill_state_code text;

-- ---------------------------------------------------------------- 2. invoices
create table if not exists public.fo_invoice_counters (
  branch_id uuid not null references public.branches(id) on delete cascade,
  fy text not null,
  last_no int not null default 0,
  primary key (branch_id, fy)
);

create table if not exists public.fo_invoices (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  stay_id uuid not null,
  invoice_no text not null,
  fy text not null,
  seq int not null,
  invoice_date date not null,
  bill_to_name text not null,
  bill_to_gstin text,
  bill_to_address text,
  bill_to_state_code text,
  taxable numeric(14,2) not null,
  tax numeric(14,2) not null,
  total numeric(14,2) not null,
  snapshot jsonb not null,
  issued_by uuid,
  issued_at timestamptz not null default now(),
  unique (restaurant_id, id),
  unique (restaurant_id, invoice_no),
  unique (branch_id, fy, seq),
  unique (stay_id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, stay_id) references public.fo_stays(restaurant_id, id)
);
create index if not exists fo_invoices_date_idx on public.fo_invoices (branch_id, invoice_date);

-- An issued invoice is a tax document: no edit, no delete, by anyone, whatever role they hold.
create or replace function app.fo_invoice_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'An issued tax invoice cannot be changed or deleted. Raise a credit note instead.';
end $$;
drop trigger if exists trg_fo_invoice_immutable on public.fo_invoices;
create trigger trg_fo_invoice_immutable before update or delete on public.fo_invoices
  for each row execute function app.fo_invoice_immutable();

do $$
declare t text;
begin
  foreach t in array array['fo_invoices', 'fo_invoice_counters'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from authenticated, anon', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists tenant_read on public.%I', t);
  end loop;
end $$;
create policy tenant_read on public.fo_invoices for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));
-- fo_invoice_counters: no read policy. It is bookkeeping, not business data.

-- ---------------------------------------------------------------- 3. helpers
create or replace function app.fo_sac(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'room' then '996311'
                     when 'food' then '996331'
                     when 'laundry' then '999711'
                     else '999799' end;
$$;
revoke all on function app.fo_sac(text) from public, anon, authenticated;

-- ---------------------------------------------------------------- 4. business details
create or replace function public.fo_save_business(
  p_legal_name text default null, p_gstin text default null, p_state_code text default null,
  p_address text default null, p_phone text default null, p_email text default null,
  p_invoice_prefix text default null, p_invoice_footer text default null,
  p_room_tax_exempt_below numeric default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        v_gstin text := upper(nullif(btrim(coalesce(p_gstin, '')), '')); v_state text; s public.fo_branch_settings;
begin
  perform app.require_fo(array['fo.manage']);
  if p_gstin is not null and v_gstin is not null and v_gstin !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
    raise exception 'That GSTIN does not look right. It has 15 characters, like 33AAACA0000A1Z5.'; end if;
  v_state := nullif(btrim(coalesce(p_state_code, '')), '');
  if v_state is null and v_gstin is not null then v_state := substr(v_gstin, 1, 2); end if;
  if v_state is not null and v_state !~ '^[0-9]{2}$' then
    raise exception 'The state code is two digits, like 33 for Tamil Nadu.'; end if;
  if v_gstin is not null and v_state is not null and substr(v_gstin, 1, 2) <> v_state then
    raise exception 'The GSTIN starts with % but the state code is %. They must match.', substr(v_gstin, 1, 2), v_state; end if;
  if p_invoice_prefix is not null and upper(btrim(p_invoice_prefix)) !~ '^[A-Z0-9]{1,4}$' then
    raise exception 'The invoice prefix is one to four letters or digits.'; end if;
  if p_room_tax_exempt_below is not null and p_room_tax_exempt_below < 0 then
    raise exception 'The no-GST limit cannot be negative.'; end if;

  insert into public.fo_branch_settings (branch_id, restaurant_id) values (v_branch, v_rest) on conflict do nothing;
  update public.fo_branch_settings set
    legal_name = case when p_legal_name is null then legal_name else nullif(btrim(p_legal_name), '') end,
    gstin = case when p_gstin is null then gstin else v_gstin end,
    state_code = case when p_state_code is null and p_gstin is null then state_code else v_state end,
    address = case when p_address is null then address else nullif(btrim(p_address), '') end,
    phone = case when p_phone is null then phone else nullif(btrim(p_phone), '') end,
    email = case when p_email is null then email else nullif(btrim(p_email), '') end,
    invoice_prefix = coalesce(upper(nullif(btrim(coalesce(p_invoice_prefix, '')), '')), invoice_prefix),
    invoice_footer = case when p_invoice_footer is null then invoice_footer else nullif(btrim(p_invoice_footer), '') end,
    room_tax_exempt_below = coalesce(p_room_tax_exempt_below, room_tax_exempt_below),
    updated_at = now()
   where branch_id = v_branch returning * into s;
  perform app.audit('fo_business_saved', 'fo_branch_settings', null,
    jsonb_build_object('legal_name', s.legal_name, 'gstin', s.gstin, 'state_code', s.state_code, 'invoice_prefix', s.invoice_prefix));
  return to_jsonb(s) - 'restaurant_id' - 'branch_id';
end $$;

-- ---------------------------------------------------------------- 5. issue the invoice
create or replace function public.fo_issue_invoice(
  p_stay uuid, p_bill_to_name text default null, p_bill_to_gstin text default null,
  p_bill_to_address text default null, p_bill_to_state_code text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; cfg public.fo_branch_settings; g public.fo_guests; inv public.fo_invoices;
        v_today date; v_fy text; v_no int; v_number text;
        v_gstin text := upper(nullif(btrim(coalesce(p_bill_to_gstin, '')), ''));
        v_name text; v_addr text; v_state text;
        v_lines jsonb; v_summary jsonb; v_pay jsonb; v_taxable numeric; v_tax numeric; v_total numeric;
begin
  v_user := app.require_fo(array['fo.manage']);
  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;

  select * into inv from public.fo_invoices where stay_id = s.id;
  if found then
    return jsonb_build_object('invoice_id', inv.id, 'invoice_no', inv.invoice_no, 'repeat', true);
  end if;
  if s.status <> 'checked_out' then
    raise exception 'The tax invoice is issued after check-out, when the folio is final. This stay is %.', s.status; end if;

  select * into cfg from public.fo_branch_settings where branch_id = v_branch;
  if not found or coalesce(btrim(coalesce(cfg.legal_name, '')), '') = '' or coalesce(btrim(coalesce(cfg.address, '')), '') = '' then
    raise exception 'Fill in the hotel''s legal name and address first (Rooms and rates, Business details).'; end if;

  select * into g from public.fo_guests where id = s.guest_id and restaurant_id = v_rest;

  select coalesce(jsonb_agg(jsonb_build_object(
           'on', c.business_date, 'kind', c.kind, 'description', c.description, 'sac', app.fo_sac(c.kind),
           'quantity', c.quantity, 'unit_amount', c.unit_amount, 'taxable', c.net_amount,
           'tax_pct', c.tax_pct, 'tax', c.tax_amount, 'total', c.total_amount)
           order by c.business_date, c.created_at), '[]'::jsonb),
         coalesce(sum(c.net_amount), 0), coalesce(sum(c.tax_amount), 0), coalesce(sum(c.total_amount), 0)
    into v_lines, v_taxable, v_tax, v_total
    from public.fo_charges c where c.stay_id = s.id and c.voided_at is null;
  if jsonb_array_length(v_lines) = 0 then raise exception 'There is nothing on this folio to invoice.'; end if;

  if v_tax > 0 and cfg.gstin is null then
    raise exception 'This folio carries GST, so the hotel''s GSTIN is needed on the invoice (Rooms and rates, Business details).'; end if;

  -- Who the invoice is made out to.
  if v_gstin is not null then
    if v_gstin !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
      raise exception 'That GSTIN does not look right. It has 15 characters, like 33AAACA0000A1Z5.'; end if;
    if coalesce(btrim(coalesce(p_bill_to_name, '')), '') = '' then
      raise exception 'Give the business name that goes with the GSTIN.'; end if;
  end if;
  v_name := coalesce(nullif(btrim(coalesce(p_bill_to_name, '')), ''), g.full_name);
  v_addr := coalesce(nullif(btrim(coalesce(p_bill_to_address, '')), ''), nullif(btrim(coalesce(g.address, '')), ''));
  v_state := coalesce(nullif(btrim(coalesce(p_bill_to_state_code, '')), ''), case when v_gstin is not null then substr(v_gstin, 1, 2) end);
  if v_state is not null and v_state !~ '^[0-9]{2}$' then raise exception 'The state code is two digits.'; end if;
  if v_gstin is not null and v_state is not null and substr(v_gstin, 1, 2) <> v_state then
    raise exception 'The GSTIN starts with % but the state code is %.', substr(v_gstin, 1, 2), v_state; end if;
  if v_gstin is null and v_total >= 50000 and (v_addr is null or v_state is null) then
    raise exception 'A bill of 50,000 or more to a guest without a GSTIN needs the guest''s address and state code on the invoice.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sac', x.sac, 'tax_pct', x.tax_pct, 'taxable', x.taxable, 'tax', x.tax,
           'cgst', round(x.tax / 2, 2), 'sgst', x.tax - round(x.tax / 2, 2)) order by x.sac, x.tax_pct), '[]'::jsonb)
    into v_summary
    from (select app.fo_sac(c.kind) as sac, c.tax_pct, sum(c.net_amount) as taxable, sum(c.tax_amount) as tax
            from public.fo_charges c where c.stay_id = s.id and c.voided_at is null group by 1, 2) x;

  select coalesce(jsonb_agg(jsonb_build_object('on', p.business_date, 'method', p.method_name, 'amount', p.amount,
           'is_refund', p.is_refund, 'reference', p.reference) order by p.business_date, p.created_at), '[]'::jsonb)
    into v_pay from public.fo_payments p where p.stay_id = s.id and p.voided_at is null;

  -- Number: one counter per outlet per financial year (1 April to 31 March), locked while we take the next one.
  v_today := app.business_today(v_branch);
  v_fy := app.fy_label('IN', v_today);                       -- 2026-27
  v_fy := substr(v_fy, 3, 2) || substr(v_fy, 6, 2);          -- 2627
  insert into public.fo_invoice_counters (branch_id, fy, last_no) values (v_branch, v_fy, 0) on conflict do nothing;
  update public.fo_invoice_counters set last_no = last_no + 1 where branch_id = v_branch and fy = v_fy returning last_no into v_no;
  v_number := cfg.invoice_prefix || '/' || v_fy || '/' || lpad(v_no::text, 6, '0');

  insert into public.fo_invoices (restaurant_id, branch_id, stay_id, invoice_no, fy, seq, invoice_date,
         bill_to_name, bill_to_gstin, bill_to_address, bill_to_state_code, taxable, tax, total, snapshot, issued_by)
  values (v_rest, v_branch, s.id, v_number, v_fy, v_no, v_today, v_name, v_gstin, v_addr, v_state,
          v_taxable, v_tax, v_total,
          jsonb_build_object(
            'property', jsonb_build_object('legal_name', cfg.legal_name, 'gstin', cfg.gstin, 'state_code', cfg.state_code,
                          'address', cfg.address, 'phone', cfg.phone, 'email', cfg.email, 'footer', cfg.invoice_footer),
            'bill_to', jsonb_build_object('name', v_name, 'gstin', v_gstin, 'address', v_addr, 'state_code', v_state),
            'guest', jsonb_build_object('name', g.full_name, 'phone', g.phone),
            'stay', jsonb_build_object('stay_no', s.stay_no, 'arrival', s.arrival, 'departure', s.departure,
                          'nights', s.departure - s.arrival, 'adults', s.adults, 'children', s.children,
                          'room_number', (select r.room_number from public.fo_rooms r where r.id = s.room_id),
                          'room_type', (select rt.name from public.fo_room_types rt where rt.restaurant_id = s.restaurant_id and rt.id = s.room_type_id),
                          'rate_plan', (select pl.name from public.fo_rate_plans pl where pl.id = s.rate_plan_id),
                          'checked_out_at', s.checked_out_at),
            'lines', v_lines, 'tax_summary', v_summary, 'payments', v_pay,
            'totals', jsonb_build_object('taxable', v_taxable, 'tax', v_tax, 'total', v_total),
            'supply', jsonb_build_object('type', 'intra', 'place_of_supply_state_code', cfg.state_code, 'reverse_charge', false)),
          v_user)
  returning * into inv;

  -- Remember who was billed so the next stay starts filled in (only when a business was named).
  if v_gstin is not null then
    update public.fo_guests set bill_company = v_name, bill_gstin = v_gstin, bill_state_code = v_state
     where id = g.id and restaurant_id = v_rest;
  end if;

  perform app.audit('fo_invoice_issued', 'fo_invoice', inv.id,
    jsonb_build_object('invoice_no', v_number, 'stay_id', s.id, 'total', v_total, 'gstin', v_gstin));
  return jsonb_build_object('invoice_id', inv.id, 'invoice_no', v_number, 'total', v_total, 'repeat', false);
end $$;

-- ---------------------------------------------------------------- 6. reads
-- The issued invoice for a stay, or, when none is issued yet, what the invoice form should start with.
create or replace function public.fo_invoice_for_stay(p_stay uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        s public.fo_stays; inv public.fo_invoices; g public.fo_guests; cfg public.fo_branch_settings;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch;
  if not found then return null; end if;
  select * into inv from public.fo_invoices where stay_id = s.id;
  if found then
    return jsonb_build_object('issued', true, 'invoice_id', inv.id, 'invoice_no', inv.invoice_no,
      'invoice_date', inv.invoice_date, 'total', inv.total, 'snapshot', inv.snapshot);
  end if;
  select * into g from public.fo_guests where id = s.guest_id and restaurant_id = v_rest;
  select * into cfg from public.fo_branch_settings where branch_id = v_branch;
  return jsonb_build_object('issued', false,
    'ready', s.status = 'checked_out' and coalesce(cfg.legal_name, '') <> '' and coalesce(cfg.address, '') <> '',
    'status', s.status,
    'has_business_details', coalesce(cfg.legal_name, '') <> '' and coalesce(cfg.address, '') <> '',
    'has_gstin', cfg.gstin is not null,
    'prefill', jsonb_build_object('name', coalesce(g.bill_company, g.full_name), 'gstin', g.bill_gstin,
                'address', g.address, 'state_code', g.bill_state_code));
end $$;

-- The registration card: everything a guest signs on arrival.
create or replace function public.fo_reg_card(p_stay uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        s public.fo_stays; g public.fo_guests; cfg public.fo_branch_settings;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch;
  if not found then return null; end if;
  select * into g from public.fo_guests where id = s.guest_id and restaurant_id = v_rest;
  select * into cfg from public.fo_branch_settings where branch_id = v_branch;
  return jsonb_build_object(
    'property', jsonb_build_object('legal_name', cfg.legal_name, 'gstin', cfg.gstin, 'address', cfg.address,
                  'phone', cfg.phone, 'email', cfg.email, 'check_in_time', cfg.check_in_time, 'check_out_time', cfg.check_out_time,
                  'name', (select b.name from public.branches b where b.id = v_branch)),
    'stay', jsonb_build_object('stay_no', s.stay_no, 'status', s.status, 'arrival', s.arrival, 'departure', s.departure,
                  'nights', s.departure - s.arrival, 'adults', s.adults, 'children', s.children, 'source', s.source,
                  'nightly_rate', s.nightly_rate, 'notes', s.notes,
                  'room_number', (select r.room_number from public.fo_rooms r where r.id = s.room_id),
                  'room_type', (select rt.name from public.fo_room_types rt where rt.restaurant_id = s.restaurant_id and rt.id = s.room_type_id),
                  'rate_plan', (select pl.name from public.fo_rate_plans pl where pl.id = s.rate_plan_id),
                  'meal_plan', (select pl.meal_plan from public.fo_rate_plans pl where pl.id = s.rate_plan_id)),
    'guest', jsonb_build_object('full_name', g.full_name, 'phone', g.phone, 'email', g.email, 'id_type', g.id_type,
                  'id_number', g.id_number, 'address', g.address, 'city', g.city, 'country', g.country,
                  'vip', g.vip, 'preferences', g.preferences, 'company', g.bill_company, 'company_gstin', g.bill_gstin),
    'advance_paid', coalesce((select sum(case when p.is_refund then -p.amount else p.amount end)
                                from public.fo_payments p where p.stay_id = s.id and p.voided_at is null), 0));
end $$;

-- GST sales register for a date range: one row per invoice, for the accountant (GSTR-1 working).
create or replace function public.fo_invoice_register(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'Choose a range of one year or less.'; end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object(
      'invoice_no', i.invoice_no, 'date', i.invoice_date, 'bill_to', i.bill_to_name, 'gstin', i.bill_to_gstin,
      'state_code', i.bill_to_state_code, 'taxable', i.taxable, 'tax', i.tax, 'total', i.total,
      'cgst', round(i.tax / 2, 2), 'sgst', i.tax - round(i.tax / 2, 2),
      'stay_id', i.stay_id) order by i.invoice_date, i.seq)
      from public.fo_invoices i
     where i.restaurant_id = v_rest and i.branch_id = v_branch and i.invoice_date between p_from and p_to), '[]'::jsonb),
    'totals', coalesce((select jsonb_build_object('taxable', sum(i.taxable), 'tax', sum(i.tax), 'total', sum(i.total), 'count', count(*))
      from public.fo_invoices i
     where i.restaurant_id = v_rest and i.branch_id = v_branch and i.invoice_date between p_from and p_to),
      jsonb_build_object('taxable', 0, 'tax', 0, 'total', 0, 'count', 0)));
end $$;

revoke all on function
  public.fo_save_business(text, text, text, text, text, text, text, text, numeric),
  public.fo_issue_invoice(uuid, text, text, text, text), public.fo_invoice_for_stay(uuid),
  public.fo_reg_card(uuid), public.fo_invoice_register(date, date) from public, anon;
grant execute on function
  public.fo_save_business(text, text, text, text, text, text, text, text, numeric),
  public.fo_issue_invoice(uuid, text, text, text, text), public.fo_invoice_for_stay(uuid),
  public.fo_reg_card(uuid), public.fo_invoice_register(date, date) to authenticated, service_role;
