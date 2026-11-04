-- 172: Front Office batch E. Credit notes against issued guest invoices, and early check-in / late check-out fees.
--
-- A credit note is a tax document in its own number series. It lowers the taxable value and the tax of one or more
-- (SAC, rate) rows of an invoice, never by more than what the invoice carried less earlier credit notes.
-- It does not move money: refunding the guest is a separate refund payment.
-- Assumption, not confirmed by an accountant: s.34 CGST Act - a credit note must be raised by 30 November following the end of
-- the financial year of the invoice. Credit notes for COMPANY invoices are refused until the company account can net them.

create table if not exists public.fo_credit_note_counters (
  branch_id uuid not null references public.branches(id) on delete cascade,
  fy text not null,
  last_no int not null default 0,
  primary key (branch_id, fy)
);

create table if not exists public.fo_credit_notes (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  invoice_id uuid not null,
  stay_id uuid not null,
  note_no text not null,
  fy text not null,
  seq int not null,
  note_date date not null,
  reason text not null check (btrim(reason) <> ''),
  taxable numeric(14,2) not null check (taxable > 0),
  tax numeric(14,2) not null check (tax >= 0),
  total numeric(14,2) not null check (total > 0),
  snapshot jsonb not null,
  issued_by uuid,
  issued_at timestamptz not null default now(),
  client_ref uuid,
  unique (restaurant_id, id),
  unique (restaurant_id, note_no),
  unique (branch_id, fy, seq),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, invoice_id) references public.fo_invoices(restaurant_id, id),
  foreign key (restaurant_id, stay_id) references public.fo_stays(restaurant_id, id)
);
create index if not exists fo_credit_notes_invoice_idx on public.fo_credit_notes (invoice_id);
create index if not exists fo_credit_notes_date_idx on public.fo_credit_notes (branch_id, note_date);
create unique index if not exists fo_credit_notes_client_ref_uq on public.fo_credit_notes (restaurant_id, client_ref) where client_ref is not null;

create or replace function app.fo_credit_note_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'An issued credit note cannot be changed or deleted.';
end $$;
drop trigger if exists fo_credit_notes_immutable on public.fo_credit_notes;
create trigger fo_credit_notes_immutable before update or delete on public.fo_credit_notes
  for each row execute function app.fo_credit_note_immutable();

do $$
declare t text;
begin
  foreach t in array array['fo_credit_notes', 'fo_credit_note_counters'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from authenticated, anon', t);
  end loop;
end $$;
grant select on public.fo_credit_notes to authenticated;
drop policy if exists tenant_read on public.fo_credit_notes;
create policy tenant_read on public.fo_credit_notes for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));

-- The last day a credit note may be raised for an invoice: 30 November after the end of its financial year.
create or replace function app.fo_credit_deadline(p_fy text) returns date
language sql immutable as $$
  select make_date(2000 + substr(p_fy, 1, 2)::int + 1, 11, 30)
$$;
revoke all on function app.fo_credit_deadline(text) from public, anon, authenticated;

-- What has already been credited on an invoice, per (SAC, rate).
create or replace function app.fo_credited(p_invoice uuid) returns table (sac text, tax_pct numeric, taxable numeric, tax numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  select l ->> 'sac', (l ->> 'tax_pct')::numeric, sum((l ->> 'taxable')::numeric), sum((l ->> 'tax')::numeric)
    from public.fo_credit_notes n, jsonb_array_elements(n.snapshot -> 'lines') l
   where n.invoice_id = p_invoice
   group by 1, 2
$$;
revoke all on function app.fo_credited(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- what can still be credited
create or replace function public.fo_credit_note_options(p_invoice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); inv public.fo_invoices;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into inv from public.fo_invoices where id = p_invoice and restaurant_id = v_rest and branch_id = v_branch;
  if not found then raise exception 'That invoice was not found.'; end if;
  return jsonb_build_object(
    'invoice_id', inv.id, 'invoice_no', inv.invoice_no, 'invoice_date', inv.invoice_date, 'party', inv.party,
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

-- ---------------------------------------------------------------- issue
-- p_lines: [{"sac": "996311", "tax_pct": 5, "taxable": 1000}, ...] - the taxable value to take back per invoice row.
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

-- ---------------------------------------------------------------- read one note (for the printed page)
create or replace function public.fo_credit_note_get(p_note uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); n public.fo_credit_notes;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into n from public.fo_credit_notes where id = p_note and restaurant_id = v_rest and branch_id = v_branch;
  if not found then return null; end if;
  return jsonb_build_object('note_id', n.id, 'note_no', n.note_no, 'date', n.note_date, 'stay_id', n.stay_id,
    'invoice_id', n.invoice_id, 'total', n.total, 'snapshot', n.snapshot);
end $$;

-- ---------------------------------------------------------------- the register of credit notes
create or replace function public.fo_credit_note_register(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'Choose a range of one year or less.'; end if;
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('note_id', n.id, 'note_no', n.note_no, 'date', n.note_date,
        'invoice_no', i.invoice_no, 'bill_to', i.bill_to_name, 'reason', n.reason, 'taxable', n.taxable, 'tax', n.tax, 'total', n.total,
        'cgst', round(n.tax / 2, 2), 'sgst', n.tax - round(n.tax / 2, 2), 'stay_id', n.stay_id) order by n.note_date, n.seq)
        from public.fo_credit_notes n join public.fo_invoices i on i.id = n.invoice_id
       where n.restaurant_id = v_rest and n.branch_id = v_branch and n.note_date between p_from and p_to), '[]'::jsonb),
    'totals', coalesce((select jsonb_build_object('taxable', sum(n.taxable), 'tax', sum(n.tax), 'total', sum(n.total), 'count', count(*))
        from public.fo_credit_notes n
       where n.restaurant_id = v_rest and n.branch_id = v_branch and n.note_date between p_from and p_to),
      jsonb_build_object('taxable', 0, 'tax', 0, 'total', 0, 'count', 0)));
end $$;

-- ---------------------------------------------------------------- GST report: now also shows credit notes and the net
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
     where i.restaurant_id = v_rest and i.branch_id = v_branch and i.invoice_date between p_from and p_to
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
   where i.restaurant_id = v_rest and i.branch_id = v_branch and i.invoice_date between p_from and p_to;

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

-- ---------------------------------------------------------------- early check-in / late check-out fee
-- A share of the nightly rate (or a fixed amount), posted as an ordinary folio charge so tax, invoice and balance follow the usual rules.
-- It is posted as "misc" at the hotel's other-charges tax rate. Whether a hotel treats it as accommodation instead is for its accountant.
create or replace function public.fo_post_stay_fee(p_stay uuid, p_fee text, p_percent numeric default 50, p_amount numeric default null,
  p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); s public.fo_stays;
        v_amt numeric; v_desc text; v_label text;
begin
  perform app.require_fo(array['fo.manage']);
  if p_fee is null or p_fee not in ('early_checkin', 'late_checkout') then raise exception 'Choose early check-in or late check-out.'; end if;
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch;
  if not found then raise exception 'That stay was not found.'; end if;
  if p_fee = 'late_checkout' and s.status <> 'inhouse' then raise exception 'A late check-out fee needs a guest who is checked in.'; end if;
  v_label := case p_fee when 'early_checkin' then 'Early check-in' else 'Late check-out' end;
  if p_amount is not null then
    if p_amount <= 0 then raise exception 'The fee must be more than zero.'; end if;
    v_amt := round(p_amount, 2);
    v_desc := v_label || ' fee';
  else
    if p_percent is null or p_percent <= 0 or p_percent > 100 then raise exception 'The fee is 1 to 100 percent of the room rate.'; end if;
    v_amt := round(s.nightly_rate * p_percent / 100, 2);
    if v_amt <= 0 then raise exception 'The room rate is zero, so give a fixed amount.'; end if;
    v_desc := v_label || ' fee (' || trim(trailing '.' from trim(trailing '0' from round(p_percent, 2)::text)) || '% of room rate)';
  end if;
  return public.fo_post_charge(s.id, 'misc', v_desc, v_amt, 1, p_client_ref);
end $$;

revoke all on function
  public.fo_credit_note_options(uuid), public.fo_issue_credit_note(uuid, text, jsonb, uuid), public.fo_credit_note_get(uuid),
  public.fo_credit_note_register(date, date), public.fo_report_gst(date, date),
  public.fo_post_stay_fee(uuid, text, numeric, numeric, uuid) from public, anon;
grant execute on function
  public.fo_credit_note_options(uuid), public.fo_issue_credit_note(uuid, text, jsonb, uuid), public.fo_credit_note_get(uuid),
  public.fo_credit_note_register(date, date), public.fo_report_gst(date, date),
  public.fo_post_stay_fee(uuid, text, numeric, numeric, uuid) to authenticated, service_role;
