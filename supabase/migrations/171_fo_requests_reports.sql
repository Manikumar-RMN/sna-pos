-- 171: Front Office batch D. Guest requests, messages and wake-up calls, plus the management reports.
--
-- Requests are a to-do list the desk works through: nothing here touches money. The reports only read.
-- Occupancy and revenue come from charges that were really posted (room charges are posted by night audit),
-- so a day with no audit shows no sales. The report says so instead of guessing.

create table if not exists public.fo_requests (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  stay_id uuid not null,
  kind text not null check (kind in ('request', 'message', 'wakeup')),
  text text not null check (btrim(text) <> ''),
  due_date date,
  due_time time,
  status text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  closed_by uuid,
  closed_at timestamptz,
  client_ref uuid,
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, stay_id) references public.fo_stays(restaurant_id, id) on delete cascade,
  constraint fo_requests_wakeup_check check (kind <> 'wakeup' or (due_date is not null and due_time is not null)),
  constraint fo_requests_closed_check check (status = 'open' or closed_at is not null)
);
create unique index if not exists fo_requests_client_ref_uq on public.fo_requests (restaurant_id, client_ref) where client_ref is not null;
create index if not exists fo_requests_open_idx on public.fo_requests (branch_id, status, due_date);
create index if not exists fo_requests_stay_idx on public.fo_requests (stay_id);

alter table public.fo_requests enable row level security;
revoke insert, update, delete, truncate, references, trigger on public.fo_requests from authenticated, anon;
grant select on public.fo_requests to authenticated;
drop policy if exists tenant_read on public.fo_requests;
create policy tenant_read on public.fo_requests for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));

-- ---------------------------------------------------------------- add
create or replace function public.fo_add_request(p_stay uuid, p_kind text, p_text text,
  p_due_date date default null, p_due_time time default null, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; r public.fo_requests; v_today date;
begin
  v_user := app.require_fo(array['fo.manage', 'fo.housekeeping']);
  if p_kind is null or p_kind not in ('request', 'message', 'wakeup') then raise exception 'Choose request, message or wake-up call.'; end if;
  if coalesce(btrim(p_text), '') = '' then raise exception 'Write what the guest asked for.'; end if;
  if length(p_text) > 500 then raise exception 'Keep it under 500 characters.'; end if;

  if p_client_ref is not null then
    select * into r from public.fo_requests where restaurant_id = v_rest and client_ref = p_client_ref;
    if found then return jsonb_build_object('request_id', r.id, 'repeat', true); end if;
  end if;

  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status not in ('reserved', 'inhouse') then raise exception 'This stay is % - requests can only be added to a live stay.', s.status; end if;

  v_today := app.business_today(v_branch);
  if p_kind = 'wakeup' then
    if s.status <> 'inhouse' then raise exception 'A wake-up call needs a guest who is checked in.'; end if;
    if p_due_date is null or p_due_time is null then raise exception 'Choose the date and time of the wake-up call.'; end if;
    if p_due_date < v_today then raise exception 'That wake-up date has already passed.'; end if;
    if p_due_date < s.arrival or p_due_date > s.departure then raise exception 'The wake-up date is outside this stay.'; end if;
  elsif p_due_date is not null and p_due_date < v_today then
    raise exception 'The due date has already passed.';
  end if;

  insert into public.fo_requests (restaurant_id, branch_id, stay_id, kind, text, due_date, due_time, created_by, client_ref)
  values (v_rest, v_branch, s.id, p_kind, btrim(p_text), p_due_date,
          case when p_kind = 'wakeup' then p_due_time else null end, v_user, p_client_ref)
  returning * into r;
  perform app.audit('fo_request_added', 'fo_request', r.id, jsonb_build_object('stay_no', s.stay_no, 'kind', p_kind, 'text', r.text));
  return jsonb_build_object('request_id', r.id, 'repeat', false);
end $$;

-- ---------------------------------------------------------------- close
create or replace function public.fo_close_request(p_request uuid, p_status text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid; r public.fo_requests;
begin
  v_user := app.require_fo(array['fo.manage', 'fo.housekeeping']);
  if p_status is null or p_status not in ('done', 'cancelled') then raise exception 'Mark it done or cancelled.'; end if;
  select * into r from public.fo_requests where id = p_request and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That request was not found.'; end if;
  if r.status <> 'open' then return jsonb_build_object('request_id', r.id, 'status', r.status, 'repeat', true); end if;
  if p_status = 'cancelled' and coalesce(btrim(p_note), '') = '' then raise exception 'Say why it was cancelled.'; end if;
  update public.fo_requests set status = p_status, note = nullif(btrim(coalesce(p_note, '')), ''),
         closed_by = v_user, closed_at = now() where id = r.id;
  perform app.audit('fo_request_' || p_status, 'fo_request', r.id, jsonb_build_object('kind', r.kind, 'note', p_note));
  return jsonb_build_object('request_id', r.id, 'status', p_status, 'repeat', false);
end $$;

-- ---------------------------------------------------------------- list
-- p_scope: 'open' (everything still to do), 'today' (open and due today or earlier, plus undated), 'recent' (last 100 of any status).
create or replace function public.fo_requests_list(p_scope text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_today date;
begin
  perform app.require_fo(array['fo.view', 'fo.manage', 'fo.housekeeping']);
  if p_scope is null or p_scope not in ('open', 'today', 'recent') then raise exception 'Unknown list.'; end if;
  v_today := app.business_today(v_branch);
  return jsonb_build_object('today', v_today, 'rows', coalesce((select jsonb_agg(z.x order by z.ord) from (
    select jsonb_build_object(
        'id', q.id, 'kind', q.kind, 'text', q.text, 'status', q.status, 'note', q.note,
        'due_date', q.due_date, 'due_time', q.due_time, 'created_at', q.created_at, 'closed_at', q.closed_at,
        'stay_id', s.id, 'stay_no', s.stay_no, 'stay_status', s.status, 'room', rm.room_number,
        'guest', g.full_name,
        'overdue', q.status = 'open' and q.due_date is not null and q.due_date < v_today,
        'due_today', q.status = 'open' and q.due_date = v_today) as x,
      row_number() over (order by (q.status = 'open') desc, q.due_date nulls last, q.due_time nulls last, q.created_at) as ord
    from public.fo_requests q
    join public.fo_stays s on s.id = q.stay_id
    join public.fo_guests g on g.id = s.guest_id
    left join public.fo_rooms rm on rm.id = s.room_id
    where q.restaurant_id = v_rest and q.branch_id = v_branch
      and (p_scope = 'recent'
           or (q.status = 'open' and (p_scope = 'open' or q.due_date is null or q.due_date <= v_today)))
    order by (q.status = 'open') desc, q.due_date nulls last, q.due_time nulls last, q.created_at
    limit 100) z), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- report: performance
-- Days, room types, sources and lost bookings for one range. Sales come from posted charges.
create or replace function public.fo_report_performance(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        v_rooms int; v_days jsonb; v_types jsonb; v_sources jsonb; v_lost jsonb; v_tot jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'Choose a range of one year or less.'; end if;
  select count(*) into v_rooms from public.fo_rooms where restaurant_id = v_rest and branch_id = v_branch and active and not out_of_service;

  select coalesce(jsonb_agg(d order by d.dt), '[]'::jsonb) into v_days from (
    select c.business_date as dt,
           count(*) filter (where c.kind = 'room') as rooms_sold,
           coalesce(sum(c.net_amount) filter (where c.kind = 'room'), 0) as room_revenue,
           coalesce(sum(c.net_amount) filter (where c.kind <> 'room'), 0) as other_revenue,
           coalesce(sum(c.tax_amount), 0) as tax,
           case when v_rooms > 0 then round(100.0 * count(*) filter (where c.kind = 'room') / v_rooms, 2) else 0 end as occupancy_pct,
           case when count(*) filter (where c.kind = 'room') > 0
                then round(sum(c.net_amount) filter (where c.kind = 'room') / count(*) filter (where c.kind = 'room'), 2) else 0 end as adr
      from public.fo_charges c
     where c.restaurant_id = v_rest and c.branch_id = v_branch and c.voided_at is null
       and c.business_date between p_from and p_to
     group by c.business_date) d;

  select coalesce(jsonb_agg(t order by t.room_revenue desc), '[]'::jsonb) into v_types from (
    select rt.code, rt.name,
           count(*) filter (where c.kind = 'room') as rooms_sold,
           coalesce(sum(c.net_amount) filter (where c.kind = 'room'), 0) as room_revenue,
           case when count(*) filter (where c.kind = 'room') > 0
                then round(sum(c.net_amount) filter (where c.kind = 'room') / count(*) filter (where c.kind = 'room'), 2) else 0 end as adr,
           coalesce(sum(c.net_amount) filter (where c.kind <> 'room'), 0) as other_revenue
      from public.fo_charges c
      join public.fo_stays s on s.id = c.stay_id
      join public.fo_room_types rt on rt.id = s.room_type_id
     where c.restaurant_id = v_rest and c.branch_id = v_branch and c.voided_at is null
       and c.business_date between p_from and p_to
     group by rt.id, rt.code, rt.name) t;

  select coalesce(jsonb_agg(m order by m.bookings desc), '[]'::jsonb) into v_sources from (
    select s.source,
           count(*) as bookings,
           count(*) filter (where s.status = 'cancelled') as cancelled,
           count(*) filter (where s.status = 'no_show') as no_shows,
           coalesce(sum(s.departure - s.arrival) filter (where s.status in ('reserved', 'inhouse', 'checked_out')), 0) as nights
      from public.fo_stays s
     where s.restaurant_id = v_rest and s.branch_id = v_branch and s.arrival between p_from and p_to
     group by s.source) m;

  select coalesce(jsonb_agg(l order by l.arrival, l.stay_no), '[]'::jsonb) into v_lost from (
    select s.stay_no, g.full_name as guest, s.arrival, s.departure, s.status, s.source,
           s.cancel_reason as reason, s.cancelled_at,
           (s.departure - s.arrival) as nights, ((s.departure - s.arrival) * s.nightly_rate) as value
      from public.fo_stays s join public.fo_guests g on g.id = s.guest_id
     where s.restaurant_id = v_rest and s.branch_id = v_branch and s.status in ('cancelled', 'no_show')
       and s.arrival between p_from and p_to
     order by s.arrival, s.stay_no limit 200) l;

  select jsonb_build_object(
      'rooms_sold', coalesce(sum((x ->> 'rooms_sold')::int), 0),
      'room_revenue', coalesce(sum((x ->> 'room_revenue')::numeric), 0),
      'other_revenue', coalesce(sum((x ->> 'other_revenue')::numeric), 0),
      'tax', coalesce(sum((x ->> 'tax')::numeric), 0),
      'days_with_sales', count(*))
    into v_tot from jsonb_array_elements(v_days) x;

  return jsonb_build_object('from', p_from, 'to', p_to, 'rooms_available', v_rooms,
    'days_in_range', p_to - p_from + 1, 'days', v_days, 'room_types', v_types, 'sources', v_sources, 'lost', v_lost,
    'totals', v_tot || jsonb_build_object(
      'occupancy_pct', case when v_rooms > 0 and (p_to - p_from + 1) > 0
          then round(100.0 * (v_tot ->> 'rooms_sold')::numeric / (v_rooms * (p_to - p_from + 1)), 2) else 0 end,
      'adr', case when (v_tot ->> 'rooms_sold')::numeric > 0
          then round((v_tot ->> 'room_revenue')::numeric / (v_tot ->> 'rooms_sold')::numeric, 2) else 0 end,
      'revpar', case when v_rooms > 0 and (p_to - p_from + 1) > 0
          then round((v_tot ->> 'room_revenue')::numeric / (v_rooms * (p_to - p_from + 1)), 2) else 0 end));
end $$;

-- ---------------------------------------------------------------- report: who owes what right now
create or replace function public.fo_report_outstanding() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_guests jsonb; v_cos jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select coalesce(jsonb_agg(b order by b.balance desc), '[]'::jsonb) into v_guests from (
    select s.id as stay_id, s.stay_no, s.status, g.full_name as guest, rm.room_number as room,
           s.arrival, s.departure, app.fo_balance(s.id) as balance
      from public.fo_stays s join public.fo_guests g on g.id = s.guest_id left join public.fo_rooms rm on rm.id = s.room_id
     where s.restaurant_id = v_rest and s.branch_id = v_branch and s.status in ('reserved', 'inhouse', 'checked_out')
       and app.fo_balance(s.id) <> 0) b;
  select coalesce(jsonb_agg(c order by c.outstanding desc), '[]'::jsonb) into v_cos from (
    select co.id as company_id, co.name, co.credit_days, co.credit_limit, app.fo_company_balance(co.id) as outstanding
      from public.fo_companies co
     where co.restaurant_id = v_rest and app.fo_company_balance(co.id) <> 0) c;
  return jsonb_build_object('guests', v_guests, 'companies', v_cos,
    'guest_owed', coalesce((select sum((x ->> 'balance')::numeric) from jsonb_array_elements(v_guests) x where (x ->> 'balance')::numeric > 0), 0),
    'deposits_held', coalesce((select -sum((x ->> 'balance')::numeric) from jsonb_array_elements(v_guests) x where (x ->> 'balance')::numeric < 0), 0),
    'company_owed', coalesce((select sum((x ->> 'outstanding')::numeric) from jsonb_array_elements(v_cos) x), 0));
end $$;

-- ---------------------------------------------------------------- report: GST summary from issued invoices
-- Built from what was printed on each invoice (its frozen snapshot), so it matches the register.
create or replace function public.fo_report_gst(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_rows jsonb; v_split jsonb;
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
  return jsonb_build_object('from', p_from, 'to', p_to, 'rows', v_rows, 'totals', v_split);
end $$;

revoke all on function
  public.fo_add_request(uuid, text, text, date, time, uuid), public.fo_close_request(uuid, text, text),
  public.fo_requests_list(text), public.fo_report_performance(date, date), public.fo_report_outstanding(),
  public.fo_report_gst(date, date) from public, anon;
grant execute on function
  public.fo_add_request(uuid, text, text, date, time, uuid), public.fo_close_request(uuid, text, text),
  public.fo_requests_list(text), public.fo_report_performance(date, date), public.fo_report_outstanding(),
  public.fo_report_gst(date, date) to authenticated, service_role;
