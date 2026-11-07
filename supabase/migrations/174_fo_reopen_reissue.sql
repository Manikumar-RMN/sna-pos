-- 174: Fixing a stay after check-out.
--
-- Two ways, chosen by what the law and the hotel's day allow:
--
--   1. REOPEN (hotels in India only), until the night audit for the check-out's business date has been run.
--      The guest goes back in-house, the folio can be corrected, and check-out is done again. The tax invoice that
--      was issued is CANCELLED (kept on record, marked cancelled, never deleted), and the next check-out issues a
--      new invoice with the next number. A cancelled invoice is left out of the GST register totals and the GST report.
--      Needs the fo.reopen right and a reason. Refused if a credit note was already raised on the invoice, if the room
--      has since been cleaned or given to someone else, or if part of the folio is billed to a company.
--
--   2. CANCEL AND REISSUE (any country, any time inside the credit-note deadline). The whole invoice is taken back by
--      a credit note, the invoice is marked cancelled, and a new invoice is issued from the same folio with the
--      corrected bill-to details. The credit note offsets the old invoice in the GST report. This fixes the bill-to
--      name, GSTIN, address and state. It does not change the amounts: for those, use a partial credit note.
--
-- Invoices stay immutable. The only change an invoice accepts is, once, being stamped cancelled, and, once, being linked
-- to the invoice that replaced it. Nothing else can be edited and nothing can be deleted.
-- Whether the invoice-cancellation route meets a particular hotel's GST filing position is for its accountant.
-- Safe to run again.

insert into public.permissions (key, description, is_sensitive) values
  ('fo.reopen', 'Reopen a checked-out stay, or cancel and reissue a tax invoice', true)
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_key)
select r.id, 'fo.reopen' from public.roles r
 where r.is_system and r.name in ('Owner', 'Manager')
on conflict do nothing;

alter table public.fo_invoices
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid,
  add column if not exists cancel_reason text,
  add column if not exists cancel_kind text,
  add column if not exists replaced_by uuid;

alter table public.fo_invoices drop constraint if exists fo_invoices_cancel_check;
alter table public.fo_invoices add constraint fo_invoices_cancel_check check (
  (cancelled_at is null and cancelled_by is null and cancel_reason is null and cancel_kind is null)
  or (cancelled_at is not null and cancel_kind in ('reopen', 'credit_reissue') and coalesce(btrim(cancel_reason), '') <> ''));

-- One ACTIVE invoice per party per stay; cancelled ones stay on record beside it.
alter table public.fo_invoices drop constraint if exists fo_invoices_stay_party_key;
create unique index if not exists fo_invoices_active_stay_party_uq on public.fo_invoices (stay_id, party) where cancelled_at is null;

create or replace function app.fo_invoice_immutable() returns trigger
language plpgsql as $$
declare k text[] := array['cancelled_at', 'cancelled_by', 'cancel_reason', 'cancel_kind', 'replaced_by'];
begin
  if tg_op = 'UPDATE'
     and (to_jsonb(new) - k) = (to_jsonb(old) - k)
     and (
       -- being cancelled, once
       (old.cancelled_at is null and new.cancelled_at is not null and new.replaced_by is null)
       -- being linked to its replacement, once
       or (old.cancelled_at is not null and old.replaced_by is null and new.replaced_by is not null
           and new.cancelled_at = old.cancelled_at and new.cancelled_by is not distinct from old.cancelled_by
           and new.cancel_reason = old.cancel_reason and new.cancel_kind = old.cancel_kind)
     ) then
    return new;
  end if;
  raise exception 'An issued tax invoice cannot be changed or deleted. Raise a credit note instead.';
end $$;

-- The business date a past moment fell on: the same rule as app.business_today, for any timestamp.
create or replace function app.fo_business_date_of(p_branch uuid, p_ts timestamptz) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select ((p_ts at time zone coalesce(b.timezone, r.timezone, 'UTC')) - coalesce(bs.day_cutoff, '04:00'::time)::interval)::date
    from public.branches b join public.restaurants r on r.id = b.restaurant_id
    left join public.branch_settings bs on bs.branch_id = b.id where b.id = p_branch;
$$;
revoke all on function app.fo_business_date_of(uuid, timestamptz) from public, anon, authenticated;

-- ================================================================ readers: only an active invoice counts
-- (Each of these is the previous definition, unchanged except for the cancelled-invoice rule.)

create or replace function app.fo_link_company(p_stay uuid, p_company uuid, p_scope text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.fo_stays;
begin
  select * into s from public.fo_stays where id = p_stay for update;
  if s.status not in ('reserved', 'inhouse') then
    raise exception 'Stay #% is %, so its company can no longer be changed.', s.stay_no, s.status; end if;
  if exists (select 1 from public.fo_invoices where stay_id = s.id and cancelled_at is null) then
    raise exception 'Stay #% already has a tax invoice, so its company cannot be changed.', s.stay_no; end if;
  update public.fo_stays set company_id = p_company, company_scope = case when p_company is null then 'none' else p_scope end where id = s.id;
  perform app.audit('fo_stay_company_set', 'fo_stay', s.id, jsonb_build_object('company_id', p_company, 'scope', p_scope),
                    jsonb_build_object('company_id', s.company_id, 'scope', s.company_scope));
end $$;

create or replace function public.fo_company_ledger(p_company uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); co public.fo_companies;
        v_today date; v_paid numeric; v_charged numeric; v_due_before_today numeric; v_stays jsonb; v_pays jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into co from public.fo_companies where id = p_company and restaurant_id = v_rest;
  if not found then return null; end if;
  v_today := app.business_today(v_branch);

  select coalesce(jsonb_agg(x order by (x ->> 'due_date'), (x ->> 'stay_no')::int), '[]'::jsonb),
         coalesce(sum((x ->> 'charged')::numeric), 0),
         coalesce(sum((x ->> 'charged')::numeric) filter (where (x ->> 'due_date')::date < v_today and x ->> 'status' = 'checked_out'), 0)
    into v_stays, v_charged, v_due_before_today
    from (select jsonb_build_object(
                   'stay_id', s.id, 'stay_no', s.stay_no, 'status', s.status, 'guest_name', g.full_name,
                   'room_number', r.room_number, 'arrival', s.arrival, 'departure', s.departure,
                   'charged', app.fo_company_part(s.id), 'scope', s.company_scope,
                   'invoice_no', (select i.invoice_no from public.fo_invoices i where i.stay_id = s.id and i.party = 'company' and i.cancelled_at is null),
                   'due_date', s.departure + co.credit_days) as x
            from public.fo_stays s
            join public.fo_guests g on g.restaurant_id = s.restaurant_id and g.id = s.guest_id
            left join public.fo_rooms r on r.id = s.room_id
           where s.company_id = co.id and s.status in ('inhouse', 'checked_out')
             and app.fo_company_part(s.id) > 0) q;

  select coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'on', p.business_date, 'amount', p.amount,
           'method', p.method_name, 'reference', p.reference, 'voided', p.voided_at is not null, 'void_reason', p.void_reason)
           order by p.business_date, p.created_at), '[]'::jsonb),
         coalesce(sum(p.amount) filter (where p.voided_at is null), 0)
    into v_pays, v_paid
    from public.fo_company_payments p where p.company_id = co.id;

  return jsonb_build_object(
    'company', jsonb_build_object('company_id', co.id, 'name', co.name, 'gstin', co.gstin, 'address', co.address,
               'contact_name', co.contact_name, 'phone', co.phone, 'email', co.email, 'credit_days', co.credit_days,
               'credit_limit', co.credit_limit, 'active', co.active),
    'stays', v_stays, 'payments', v_pays,
    'summary', jsonb_build_object('charged', v_charged, 'paid', v_paid, 'outstanding', v_charged - v_paid,
               'overdue', greatest(0, v_due_before_today - v_paid),
               'over_limit', co.credit_limit is not null and (v_charged - v_paid) > co.credit_limit));
end $$;

create or replace function public.fo_issue_invoice(
  p_stay uuid, p_bill_to_name text default null, p_bill_to_gstin text default null,
  p_bill_to_address text default null, p_bill_to_state_code text default null, p_party text default 'guest') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; cfg public.fo_branch_settings; g public.fo_guests; inv public.fo_invoices; co public.fo_companies;
        v_today date; v_fy text; v_no int; v_number text; v_company boolean := (p_party = 'company');
        v_gstin text := upper(nullif(btrim(coalesce(p_bill_to_gstin, '')), ''));
        v_name text; v_addr text; v_state text;
        v_lines jsonb; v_summary jsonb; v_pay jsonb := '[]'::jsonb; v_taxable numeric; v_tax numeric; v_total numeric;
begin
  v_user := app.require_fo(array['fo.manage']);
  if p_party not in ('guest', 'company') then raise exception 'The invoice is for the guest or for the company.'; end if;
  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;

  select * into inv from public.fo_invoices where stay_id = s.id and party = p_party and cancelled_at is null;
  if found then
    return jsonb_build_object('invoice_id', inv.id, 'invoice_no', inv.invoice_no, 'repeat', true);
  end if;
  if s.status <> 'checked_out' then
    raise exception 'The tax invoice is issued after check-out, when the folio is final. This stay is %.', s.status; end if;
  if v_company and s.company_id is null then raise exception 'This stay has no company to invoice.'; end if;

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
    from public.fo_charges c
   where c.stay_id = s.id and c.voided_at is null
     and app.fo_to_company(s.company_id, s.company_scope, c.kind) = v_company;
  if jsonb_array_length(v_lines) = 0 then
    raise exception 'There is nothing on the %''s side of this folio to invoice.', case when v_company then 'company' else 'guest' end; end if;

  if v_tax > 0 and cfg.gstin is null then
    raise exception 'This folio carries GST, so the hotel''s GSTIN is needed on the invoice (Rooms and rates, Business details).'; end if;

  if v_company then
    select * into co from public.fo_companies where id = s.company_id;
    v_gstin := co.gstin; v_name := co.name; v_addr := co.address; v_state := co.state_code;
  else
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
  end if;
  if v_gstin is null and v_total >= 50000 and (v_addr is null or v_state is null) then
    raise exception 'A bill of 50,000 or more to a party without a GSTIN needs an address and state code on the invoice.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sac', x.sac, 'tax_pct', x.tax_pct, 'taxable', x.taxable, 'tax', x.tax,
           'cgst', round(x.tax / 2, 2), 'sgst', x.tax - round(x.tax / 2, 2)) order by x.sac, x.tax_pct), '[]'::jsonb)
    into v_summary
    from (select app.fo_sac(c.kind) as sac, c.tax_pct, sum(c.net_amount) as taxable, sum(c.tax_amount) as tax
            from public.fo_charges c
           where c.stay_id = s.id and c.voided_at is null and app.fo_to_company(s.company_id, s.company_scope, c.kind) = v_company
           group by 1, 2) x;

  if not v_company then
    select coalesce(jsonb_agg(jsonb_build_object('on', p.business_date, 'method', p.method_name, 'amount', p.amount,
             'is_refund', p.is_refund, 'reference', p.reference) order by p.business_date, p.created_at), '[]'::jsonb)
      into v_pay from public.fo_payments p where p.stay_id = s.id and p.voided_at is null;
  end if;

  v_today := app.business_today(v_branch);
  v_fy := app.fy_label('IN', v_today);
  v_fy := substr(v_fy, 3, 2) || substr(v_fy, 6, 2);
  insert into public.fo_invoice_counters (branch_id, fy, last_no) values (v_branch, v_fy, 0) on conflict do nothing;
  update public.fo_invoice_counters set last_no = last_no + 1 where branch_id = v_branch and fy = v_fy returning last_no into v_no;
  v_number := cfg.invoice_prefix || '/' || v_fy || '/' || lpad(v_no::text, 6, '0');

  insert into public.fo_invoices (restaurant_id, branch_id, stay_id, invoice_no, fy, seq, invoice_date,
         bill_to_name, bill_to_gstin, bill_to_address, bill_to_state_code, taxable, tax, total, snapshot, issued_by, party, company_id)
  values (v_rest, v_branch, s.id, v_number, v_fy, v_no, v_today, v_name, v_gstin, v_addr, v_state,
          v_taxable, v_tax, v_total,
          jsonb_build_object(
            'party', p_party,
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
          v_user, p_party, case when v_company then s.company_id end)
  returning * into inv;

  if not v_company and v_gstin is not null then
    update public.fo_guests set bill_company = v_name, bill_gstin = v_gstin, bill_state_code = v_state
     where id = g.id and restaurant_id = v_rest;
  end if;

  perform app.audit('fo_invoice_issued', 'fo_invoice', inv.id,
    jsonb_build_object('invoice_no', v_number, 'stay_id', s.id, 'party', p_party, 'total', v_total, 'gstin', v_gstin));
  return jsonb_build_object('invoice_id', inv.id, 'invoice_no', v_number, 'total', v_total, 'repeat', false);
end $$;

create or replace function public.fo_invoice_for_stay(p_stay uuid, p_party text default 'guest') returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        s public.fo_stays; inv public.fo_invoices; g public.fo_guests; cfg public.fo_branch_settings; co public.fo_companies;
        v_company boolean := (p_party = 'company'); v_lines int;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch;
  if not found then return null; end if;
  select * into inv from public.fo_invoices where stay_id = s.id and party = p_party and cancelled_at is null;
  if found then
    return jsonb_build_object('issued', true, 'party', p_party, 'invoice_id', inv.id, 'invoice_no', inv.invoice_no,
      'invoice_date', inv.invoice_date, 'total', inv.total, 'snapshot', inv.snapshot);
  end if;
  select count(*) into v_lines from public.fo_charges c
   where c.stay_id = s.id and c.voided_at is null and app.fo_to_company(s.company_id, s.company_scope, c.kind) = v_company;
  select * into g from public.fo_guests where id = s.guest_id and restaurant_id = v_rest;
  select * into cfg from public.fo_branch_settings where branch_id = v_branch;
  select * into co from public.fo_companies where id = s.company_id;
  return jsonb_build_object('issued', false, 'party', p_party,
    'has_lines', v_lines > 0 and (not v_company or s.company_id is not null),
    'ready', s.status = 'checked_out' and coalesce(cfg.legal_name, '') <> '' and coalesce(cfg.address, '') <> '',
    'status', s.status,
    'has_business_details', coalesce(cfg.legal_name, '') <> '' and coalesce(cfg.address, '') <> '',
    'has_gstin', cfg.gstin is not null,
    'prefill', case when v_company
      then jsonb_build_object('name', co.name, 'gstin', co.gstin, 'address', co.address, 'state_code', co.state_code)
      else jsonb_build_object('name', coalesce(g.bill_company, g.full_name), 'gstin', g.bill_gstin,
                'address', g.address, 'state_code', g.bill_state_code) end);
end $$;

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
      'stay_id', i.stay_id, 'cancelled', i.cancelled_at is not null, 'cancel_kind', i.cancel_kind,
      'cancel_reason', i.cancel_reason) order by i.invoice_date, i.seq)
      from public.fo_invoices i
     where i.restaurant_id = v_rest and i.branch_id = v_branch and i.invoice_date between p_from and p_to), '[]'::jsonb),
    'totals', coalesce((select jsonb_build_object('taxable', sum(i.taxable), 'tax', sum(i.tax), 'total', sum(i.total), 'count', count(*))
      from public.fo_invoices i
     where i.restaurant_id = v_rest and i.branch_id = v_branch and i.invoice_date between p_from and p_to and i.cancel_kind is distinct from 'reopen'),
      jsonb_build_object('taxable', 0, 'tax', 0, 'total', 0, 'count', 0)));
end $$;

create or replace function public.fo_report_gst(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        v_rows jsonb; v_split jsonb; v_cn_rows jsonb; v_cn jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'Choose a range of one year or less.'; end if;
  select coalesce(jsonb_agg(r order by r.sac, r.tax_pct), '[]'::jsonb) into v_rows from (
    select ts ->> 'sac' as sac, (ts ->> 'tax_pct')::numeric as tax_pct,
           sum((ts ->> 'taxable')::numeric) as taxable,
           sum((ts ->> 'cgst')::numeric) as cgst, sum((ts ->> 'sgst')::numeric) as sgst,
           sum((ts ->> 'tax')::numeric) as tax
      from public.fo_invoices i, jsonb_array_elements(coalesce(i.snapshot -> 'tax_summary', '[]'::jsonb)) ts
     where i.restaurant_id = v_rest and i.branch_id = v_branch and i.invoice_date between p_from and p_to and i.cancel_kind is distinct from 'reopen'
     group by 1, 2) r;
  select jsonb_build_object(
      'b2b_count', count(*) filter (where i.bill_to_gstin is not null),
      'b2b_taxable', coalesce(sum(i.taxable) filter (where i.bill_to_gstin is not null), 0),
      'b2b_tax', coalesce(sum(i.tax) filter (where i.bill_to_gstin is not null), 0),
      'b2c_count', count(*) filter (where i.bill_to_gstin is null),
      'b2c_taxable', coalesce(sum(i.taxable) filter (where i.bill_to_gstin is null), 0),
      'b2c_tax', coalesce(sum(i.tax) filter (where i.bill_to_gstin is null), 0),
      'invoices', count(*), 'taxable', coalesce(sum(i.taxable), 0), 'tax', coalesce(sum(i.tax), 0), 'total', coalesce(sum(i.total), 0))
    into v_split from public.fo_invoices i
   where i.restaurant_id = v_rest and i.branch_id = v_branch and i.invoice_date between p_from and p_to and i.cancel_kind is distinct from 'reopen';

  select coalesce(jsonb_agg(r order by r.sac, r.tax_pct), '[]'::jsonb) into v_cn_rows from (
    select l ->> 'sac' as sac, (l ->> 'tax_pct')::numeric as tax_pct,
           sum((l ->> 'taxable')::numeric) as taxable, sum((l ->> 'cgst')::numeric) as cgst,
           sum((l ->> 'sgst')::numeric) as sgst, sum((l ->> 'tax')::numeric) as tax
      from public.fo_credit_notes n, jsonb_array_elements(n.snapshot -> 'lines') l
     where n.restaurant_id = v_rest and n.branch_id = v_branch and n.note_date between p_from and p_to
     group by 1, 2) r;
  select jsonb_build_object('count', count(*), 'taxable', coalesce(sum(n.taxable), 0), 'tax', coalesce(sum(n.tax), 0), 'total', coalesce(sum(n.total), 0))
    into v_cn from public.fo_credit_notes n
   where n.restaurant_id = v_rest and n.branch_id = v_branch and n.note_date between p_from and p_to;

  return jsonb_build_object('from', p_from, 'to', p_to, 'rows', v_rows, 'totals', v_split,
    'credit_rows', v_cn_rows, 'credit_totals', v_cn,
    'net', jsonb_build_object('taxable', (v_split ->> 'taxable')::numeric - (v_cn ->> 'taxable')::numeric,
                              'tax', (v_split ->> 'tax')::numeric - (v_cn ->> 'tax')::numeric));
end $$;

create or replace function public.fo_credit_note_options(p_invoice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); inv public.fo_invoices;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into inv from public.fo_invoices where id = p_invoice and restaurant_id = v_rest and branch_id = v_branch;
  if not found then raise exception 'That invoice was not found.'; end if;
  return jsonb_build_object(
    'cancelled', inv.cancelled_at is not null, 'invoice_id', inv.id, 'invoice_no', inv.invoice_no, 'invoice_date', inv.invoice_date, 'party', inv.party,
    'bill_to', inv.bill_to_name, 'total', inv.total, 'stay_id', inv.stay_id,
    'deadline', app.fo_credit_deadline(inv.fy),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'sac', r ->> 'sac', 'tax_pct', (r ->> 'tax_pct')::numeric, 'taxable', (r ->> 'taxable')::numeric, 'tax', (r ->> 'tax')::numeric,
        'credited_taxable', coalesce(c.taxable, 0), 'credited_tax', coalesce(c.tax, 0),
        'remaining_taxable', (r ->> 'taxable')::numeric - coalesce(c.taxable, 0),
        'remaining_tax', (r ->> 'tax')::numeric - coalesce(c.tax, 0)) order by r ->> 'sac', (r ->> 'tax_pct')::numeric)
      from jsonb_array_elements(inv.snapshot -> 'tax_summary') r
      left join lateral (select x.taxable, x.tax from app.fo_credited(inv.id) x
                          where x.sac = r ->> 'sac' and x.tax_pct = (r ->> 'tax_pct')::numeric) c on true), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'note_no', n.note_no, 'date', n.note_date,
        'total', n.total, 'reason', n.reason) order by n.seq) from public.fo_credit_notes n where n.invoice_id = inv.id), '[]'::jsonb));
end $$;

create or replace function public.fo_issue_credit_note(p_invoice uuid, p_reason text, p_lines jsonb, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        inv public.fo_invoices; n public.fo_credit_notes; cfg public.fo_branch_settings; s public.fo_stays;
        v_today date; v_fy text; v_no int; v_number text; v_lines jsonb := '[]'::jsonb; v_summary jsonb;
        v_taxable numeric := 0; v_tax numeric := 0; q record; r jsonb; c record; v_t numeric; v_cg numeric;
begin
  v_user := app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give the reason for the credit note.'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Choose what to credit.'; end if;

  if p_client_ref is not null then
    select * into n from public.fo_credit_notes where restaurant_id = v_rest and client_ref = p_client_ref;
    if found then return jsonb_build_object('note_id', n.id, 'note_no', n.note_no, 'repeat', true); end if;
  end if;

  select * into inv from public.fo_invoices where id = p_invoice and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That invoice was not found.'; end if;
  if inv.party <> 'guest' then
    raise exception 'Credit notes for a company invoice are not supported yet - the company account cannot net them.'; end if;
  if inv.cancelled_at is not null then
    raise exception 'Invoice % was cancelled, so no credit note can be raised on it.', inv.invoice_no; end if;
  select * into s from public.fo_stays where id = inv.stay_id;
  select * into cfg from public.fo_branch_settings where branch_id = v_branch;

  v_today := app.business_today(v_branch);
  if v_today < inv.invoice_date then raise exception 'A credit note cannot be dated before its invoice.'; end if;
  if v_today > app.fo_credit_deadline(inv.fy) then
    raise exception 'The last day for a credit note on this invoice was %.', to_char(app.fo_credit_deadline(inv.fy), 'DD Mon YYYY'); end if;

  for q in
    select e ->> 'sac' as sac, (e ->> 'tax_pct')::numeric as pct, sum((e ->> 'taxable')::numeric) as taxable
      from jsonb_array_elements(p_lines) e group by 1, 2 order by 1, 2
  loop
    if q.taxable is null or q.taxable <= 0 then raise exception 'Each amount to credit must be more than zero.'; end if;
    if q.taxable <> round(q.taxable, 2) then raise exception 'Amounts have at most two decimals.'; end if;
    r := null;
    select r2 into r from jsonb_array_elements(inv.snapshot -> 'tax_summary') r2
     where r2 ->> 'sac' = q.sac and (r2 ->> 'tax_pct')::numeric = q.pct;
    if r is null then raise exception 'This invoice has no % line at % percent.', q.sac, q.pct; end if;
    select coalesce(x.taxable, 0) as taxable, coalesce(x.tax, 0) as tax into c
      from (select 1) d left join app.fo_credited(inv.id) x on x.sac = q.sac and x.tax_pct = q.pct;
    if q.taxable > (r ->> 'taxable')::numeric - c.taxable then
      raise exception 'You can credit at most % more on the % percent line (% was invoiced, % already credited).',
        (r ->> 'taxable')::numeric - c.taxable, q.pct, (r ->> 'taxable')::numeric, c.taxable; end if;
    -- crediting the last of a row takes back exactly the tax that is left, so rounding never leaves a paisa behind
    if q.taxable = (r ->> 'taxable')::numeric - c.taxable then v_t := (r ->> 'tax')::numeric - c.tax;
    else v_t := least(round(q.taxable * q.pct / 100, 2), (r ->> 'tax')::numeric - c.tax); end if;
    v_cg := round(v_t / 2, 2);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('sac', q.sac, 'tax_pct', q.pct, 'taxable', q.taxable,
                 'tax', v_t, 'cgst', v_cg, 'sgst', v_t - v_cg, 'total', q.taxable + v_t));
    v_taxable := v_taxable + q.taxable; v_tax := v_tax + v_t;
  end loop;

  v_fy := app.fy_label('IN', v_today);
  v_fy := substr(v_fy, 3, 2) || substr(v_fy, 6, 2);
  insert into public.fo_credit_note_counters (branch_id, fy, last_no) values (v_branch, v_fy, 0) on conflict do nothing;
  update public.fo_credit_note_counters set last_no = last_no + 1 where branch_id = v_branch and fy = v_fy returning last_no into v_no;
  v_number := cfg.invoice_prefix || '/CN/' || v_fy || '/' || lpad(v_no::text, 6, '0');

  insert into public.fo_credit_notes (restaurant_id, branch_id, invoice_id, stay_id, note_no, fy, seq, note_date, reason,
         taxable, tax, total, snapshot, issued_by, client_ref)
  values (v_rest, v_branch, inv.id, inv.stay_id, v_number, v_fy, v_no, v_today, btrim(p_reason),
          v_taxable, v_tax, v_taxable + v_tax,
          jsonb_build_object(
            'property', inv.snapshot -> 'property', 'bill_to', inv.snapshot -> 'bill_to', 'guest', inv.snapshot -> 'guest',
            'stay', inv.snapshot -> 'stay',
            'against', jsonb_build_object('invoice_no', inv.invoice_no, 'invoice_date', inv.invoice_date, 'invoice_total', inv.total),
            'reason', btrim(p_reason), 'lines', v_lines,
            'totals', jsonb_build_object('taxable', v_taxable, 'tax', v_tax, 'total', v_taxable + v_tax),
            'supply', inv.snapshot -> 'supply'),
          v_user, p_client_ref)
  returning * into n;

  perform app.audit('fo_credit_note_issued', 'fo_credit_note', n.id, jsonb_build_object(
    'note_no', v_number, 'invoice_no', inv.invoice_no, 'stay_no', s.stay_no, 'total', n.total, 'reason', n.reason));
  return jsonb_build_object('note_id', n.id, 'note_no', v_number, 'total', n.total, 'repeat', false);
end $$;

-- ================================================================ new: can this stay be reopened?
-- Returns the reason it cannot, or null when it can. Shared by the screen and by the reopen itself.
create or replace function app.fo_reopen_block(p_stay uuid) returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.fo_stays; v_country text; v_date date; r public.fo_rooms;
begin
  select * into s from public.fo_stays where id = p_stay;
  if not found then return 'That stay was not found.'; end if;
  select country_code into v_country from public.restaurants where id = s.restaurant_id;
  if v_country is distinct from 'IN' then
    return 'Reopening after check-out is available for hotels in India only. Use "Cancel and reissue invoice" instead.'; end if;
  if s.status <> 'checked_out' then return 'This stay is ' || s.status || ', so there is nothing to reopen.'; end if;
  v_date := app.fo_business_date_of(s.branch_id, s.checked_out_at);
  if exists (select 1 from public.fo_night_audits where branch_id = s.branch_id and business_date = v_date) then
    return 'The night audit for ' || to_char(v_date, 'DD Mon YYYY') || ' has been run, so this stay can no longer be reopened. Use "Cancel and reissue invoice" instead.'; end if;
  select * into r from public.fo_rooms where id = s.room_id;
  if exists (select 1 from public.fo_stays x where x.room_id = s.room_id and x.status = 'inhouse' and x.id <> s.id) then
    return 'Room ' || r.room_number || ' has another guest in it now.'; end if;
  if r.housekeeping_status = 'clean' then
    return 'Room ' || r.room_number || ' has already been cleaned and may be given to a new guest.'; end if;
  if s.company_id is not null and app.fo_company_part(s.id) <> 0 then
    return 'Part of this folio is billed to a company. Reopening such a stay is not supported yet.'; end if;
  if exists (select 1 from public.fo_invoices i where i.stay_id = s.id and i.cancelled_at is null and i.party = 'company') then
    return 'A company invoice has been issued for this stay. Reopening such a stay is not supported yet.'; end if;
  if exists (select 1 from public.fo_invoices i join public.fo_credit_notes n on n.invoice_id = i.id
              where i.stay_id = s.id and i.cancelled_at is null) then
    return 'A credit note has already been raised on this stay''s invoice, so it cannot be reopened.'; end if;
  return null;
end $$;
revoke all on function app.fo_reopen_block(uuid) from public, anon, authenticated;

-- What the stay page offers.
create or replace function public.fo_fix_options(p_stay uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        s public.fo_stays; inv public.fo_invoices; v_can boolean; v_block text; v_cn boolean; v_reissue_block text;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch;
  if not found then return null; end if;
  v_can := app.has_permission('fo.reopen');
  if s.status <> 'checked_out' then
    return jsonb_build_object('status', s.status, 'can_reopen', false, 'can_reissue', false, 'has_right', v_can); end if;

  v_block := app.fo_reopen_block(s.id);
  select * into inv from public.fo_invoices where stay_id = s.id and party = 'guest' and cancelled_at is null;
  if found then
    v_cn := exists (select 1 from public.fo_credit_notes where invoice_id = inv.id);
    if v_cn then v_reissue_block := 'A credit note has already been raised on this invoice, so it cannot be cancelled as a whole.';
    elsif app.business_today(v_branch) > app.fo_credit_deadline(inv.fy) then
      v_reissue_block := 'The last day for a credit note on this invoice was ' || to_char(app.fo_credit_deadline(inv.fy), 'DD Mon YYYY') || '.';
    end if;
  else
    v_reissue_block := 'There is no active guest invoice on this stay.';
  end if;
  return jsonb_build_object('status', s.status, 'has_right', v_can,
    'can_reopen', v_can and v_block is null, 'reopen_blocked', v_block,
    'can_reissue', v_can and v_reissue_block is null, 'reissue_blocked', v_reissue_block,
    'invoice_id', inv.id, 'invoice_no', inv.invoice_no, 'invoice_total', inv.total,
    'bill_to', jsonb_build_object('name', inv.bill_to_name, 'gstin', inv.bill_to_gstin, 'address', inv.bill_to_address, 'state_code', inv.bill_to_state_code));
end $$;

-- ================================================================ reopen (India, until the night audit)
create or replace function public.fo_reopen_stay(p_stay uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; inv record; v_block text; v_cancelled text[] := '{}';
begin
  v_user := app.require_fo(array['fo.reopen']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give a reason for reopening this stay.'; end if;
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status = 'inhouse' then return jsonb_build_object('stay_id', s.id, 'repeat', true); end if;

  v_block := app.fo_reopen_block(s.id);
  if v_block is not null then raise exception '%', v_block; end if;

  for inv in select * from public.fo_invoices where stay_id = s.id and cancelled_at is null for update loop
    update public.fo_invoices set cancelled_at = now(), cancelled_by = v_user, cancel_reason = btrim(p_reason), cancel_kind = 'reopen'
     where id = inv.id;
    v_cancelled := v_cancelled || inv.invoice_no;
    perform app.audit('fo_invoice_cancelled', 'fo_invoice', inv.id,
      jsonb_build_object('invoice_no', inv.invoice_no, 'stay_no', s.stay_no, 'kind', 'reopen', 'reason', btrim(p_reason)));
  end loop;

  update public.fo_stays set status = 'inhouse', checked_out_at = null where id = s.id;
  perform app.audit('fo_stay_reopened', 'fo_stay', s.id,
    jsonb_build_object('stay_no', s.stay_no, 'reason', btrim(p_reason), 'cancelled_invoices', v_cancelled));
  return jsonb_build_object('stay_id', s.id, 'cancelled_invoices', to_jsonb(v_cancelled), 'repeat', false);
end $$;

-- ================================================================ cancel and reissue (any country)
-- The bill-to arguments are what the NEW invoice is made out to. Leaving them blank bills the guest, as at check-out.
create or replace function public.fo_reissue_invoice(
  p_invoice uuid, p_reason text, p_bill_to_name text default null, p_bill_to_gstin text default null,
  p_bill_to_address text default null, p_bill_to_state_code text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        inv public.fo_invoices; s public.fo_stays; v_lines jsonb; v_cn jsonb; v_new jsonb;
begin
  v_user := app.require_fo(array['fo.reopen']);
  perform app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give a reason for reissuing this invoice.'; end if;
  select * into inv from public.fo_invoices where id = p_invoice and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That invoice was not found.'; end if;
  if inv.cancelled_at is not null then raise exception 'Invoice % is already cancelled.', inv.invoice_no; end if;
  if inv.party <> 'guest' then
    raise exception 'Only a guest invoice can be reissued. Credit notes for a company invoice are not supported yet.'; end if;
  if exists (select 1 from public.fo_credit_notes where invoice_id = inv.id) then
    raise exception 'A credit note has already been raised on invoice %, so it cannot be cancelled as a whole.', inv.invoice_no; end if;
  select * into s from public.fo_stays where id = inv.stay_id for update;

  select jsonb_agg(jsonb_build_object('sac', r ->> 'sac', 'tax_pct', (r ->> 'tax_pct')::numeric, 'taxable', (r ->> 'taxable')::numeric))
    into v_lines from jsonb_array_elements(inv.snapshot -> 'tax_summary') r where (r ->> 'taxable')::numeric > 0;
  if v_lines is null then raise exception 'Invoice % has no taxable value to credit.', inv.invoice_no; end if;

  -- 1. take the whole invoice back; 2. mark it cancelled; 3. issue the new one from the same folio.
  v_cn := public.fo_issue_credit_note(inv.id, 'Invoice reissued: ' || btrim(p_reason), v_lines);
  update public.fo_invoices set cancelled_at = now(), cancelled_by = v_user, cancel_reason = btrim(p_reason), cancel_kind = 'credit_reissue'
   where id = inv.id;
  v_new := public.fo_issue_invoice(inv.stay_id, p_bill_to_name, p_bill_to_gstin, p_bill_to_address, p_bill_to_state_code, 'guest');
  update public.fo_invoices set replaced_by = (v_new ->> 'invoice_id')::uuid where id = inv.id;

  perform app.audit('fo_invoice_cancelled', 'fo_invoice', inv.id,
    jsonb_build_object('invoice_no', inv.invoice_no, 'stay_no', s.stay_no, 'kind', 'credit_reissue', 'reason', btrim(p_reason),
                       'credit_note_no', v_cn ->> 'note_no', 'new_invoice_no', v_new ->> 'invoice_no'));
  return jsonb_build_object('old_invoice_no', inv.invoice_no, 'credit_note_no', v_cn ->> 'note_no',
                            'invoice_id', v_new ->> 'invoice_id', 'invoice_no', v_new ->> 'invoice_no');
end $$;

revoke all on function public.fo_fix_options(uuid), public.fo_reopen_stay(uuid, text),
  public.fo_reissue_invoice(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.fo_fix_options(uuid), public.fo_reopen_stay(uuid, text),
  public.fo_reissue_invoice(uuid, text, text, text, text, text) to authenticated, service_role;
