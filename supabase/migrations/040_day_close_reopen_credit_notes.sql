-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928091352, name '40_day_close_reopen_credit_notes'. This is the SQL that actually ran.

alter table public.orders add constraint orders_rest_id_uq unique (restaurant_id, id);

insert into public.role_permissions (role_id, permission_key)
select r.id, 'day.reopen' from public.roles r where r.is_system and r.name = 'Manager' on conflict do nothing;

create table public.credit_notes (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  order_id uuid not null,
  number text not null,
  business_date date not null,
  shift_id uuid,
  amount numeric(14,2) not null check (amount > 0),
  tax_amount numeric(14,2) not null default 0,
  taxes jsonb not null default '[]'::jsonb,
  reason text not null,
  payment_method_id uuid not null,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  unique (restaurant_id, id),
  unique (branch_id, number),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, order_id) references public.orders(restaurant_id, id),
  foreign key (restaurant_id, payment_method_id) references public.payment_methods(restaurant_id, id)
);
alter table public.credit_notes enable row level security;
create policy tenant_read on public.credit_notes for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()));
grant select on public.credit_notes to authenticated;
create trigger trg_no_update_credit_notes before update on public.credit_notes for each row execute function app.block_update();
create trigger trg_no_delete_credit_notes before delete on public.credit_notes for each row execute function app.block_delete();

create or replace function app.fy_label(p_country text, p_date date) returns text language sql immutable as $$
  select case when p_country = 'IN'
    then case when extract(month from p_date) >= 4
              then extract(year from p_date)::int || '-' || lpad(((extract(year from p_date)::int + 1) % 100)::text, 2, '0')
              else (extract(year from p_date)::int - 1) || '-' || lpad((extract(year from p_date)::int % 100)::text, 2, '0') end
    else extract(year from p_date)::int::text end
$$;

create or replace function app.z_report(p_day uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public','pg_temp' as $$
declare d public.business_days; v jsonb; v_pay jsonb; v_tax jsonb; v_cn jsonb; v_shifts jsonb; v_types jsonb;
begin
  select * into d from public.business_days where id = p_day;
  if not found then return null; end if;
  select jsonb_build_object(
      'bills', count(*) filter (where status = 'completed'),
      'first_bill', min(bill_number) filter (where status <> 'voided'),
      'last_bill', max(bill_number) filter (where status <> 'voided'),
      'gross_sales', coalesce(sum(subtotal) filter (where status = 'completed'), 0),
      'discounts', coalesce(sum(discount_total) filter (where status = 'completed'), 0),
      'service_charge', coalesce(sum(service_charge) filter (where status = 'completed'), 0),
      'tax', coalesce(sum(tax_total) filter (where status = 'completed'), 0),
      'tax_included', coalesce(sum(tax_included) filter (where status = 'completed'), 0),
      'rounding', coalesce(sum(rounding_adjustment) filter (where status = 'completed'), 0),
      'total_billed', coalesce(sum(grand_total) filter (where status = 'completed'), 0),
      'voided_bills', count(*) filter (where status = 'voided'),
      'voided_value', coalesce(sum(grand_total) filter (where status = 'voided'), 0),
      'unpaid_bills', count(*) filter (where status = 'completed' and payment_status in ('unpaid', 'partial')))
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
    'payments', v_pay, 'taxes', v_tax, 'credit_notes', v_cn, 'shifts', v_shifts, 'by_type', v_types,
    'net_sales_after_credit_notes', (v->>'total_billed')::numeric - (v_cn->>'amount')::numeric,
    'reopen_count', d.reopen_count);
end $$;

create or replace function public.day_status() returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_branch uuid := app.current_branch_id(); d public.business_days; v_unpaid jsonb; v_shift boolean; v_days jsonb;
begin
  if app.current_user_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  select * into d from public.business_days where branch_id = v_branch and status = 'open';
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'bill_number', o.bill_number, 'total', o.grand_total,
            'balance', o.grand_total - app.order_covered(o.id)) order by o.created_at), '[]'::jsonb)
    into v_unpaid from public.orders o
   where d.id is not null and o.branch_id = v_branch and o.business_date = d.business_date
     and o.status = 'completed' and o.payment_status in ('unpaid', 'partial') and o.merged_into is null;
  select exists (select 1 from public.shifts where branch_id = v_branch and status = 'open') into v_shift;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'business_date', business_date, 'status', status,
            'closed_at', closed_at, 'total', z_report->'total_billed') order by business_date desc), '[]'::jsonb)
    into v_days from (select * from public.business_days where branch_id = v_branch and status <> 'open'
                       order by business_date desc limit 14) x;
  return jsonb_build_object(
    'open_day', case when d.id is null then null else jsonb_build_object('id', d.id, 'business_date', d.business_date,
                  'opened_at', d.opened_at, 'bills', (select count(*) from public.orders where branch_id = v_branch
                    and business_date = d.business_date and status <> 'voided' and merged_into is null)) end,
    'unpaid', v_unpaid, 'shift_open', v_shift, 'recent', v_days,
    'can_close', app.has_permission('day.close'), 'can_reopen', app.has_permission('day.reopen'));
end $$;

create or replace function public.close_day(p_notes text default null) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_user uuid := app.require_permission('day.close');
  v_branch uuid := app.current_branch_id(); d public.business_days; v_list text; v_z jsonb;
begin
  select * into d from public.business_days where branch_id = v_branch and status = 'open' for update;
  if not found then raise exception 'There is no open day to close.'; end if;
  if exists (select 1 from public.shifts where branch_id = v_branch and status = 'open') then
    raise exception 'Close the open shift first (count the cash on the Shift screen), then close the day.';
  end if;
  select string_agg(bill_number, ', ' order by created_at) into v_list from (
    select bill_number, created_at from public.orders
     where branch_id = v_branch and business_date = d.business_date and status = 'completed'
       and payment_status in ('unpaid', 'partial') and merged_into is null limit 20) x;
  if v_list is not null then
    raise exception 'These bills are not paid yet: %. Take payment, put them on a pay-later account, or void them before closing the day.', v_list;
  end if;
  update public.business_days set status = 'closed', closed_at = now(), closed_by = v_user,
         close_notes = nullif(left(trim(coalesce(p_notes, '')), 300), '')
   where id = d.id;
  v_z := app.z_report(d.id);
  update public.business_days set z_report = v_z where id = d.id;
  update public.business_days set status = 'open' where branch_id = v_branch and status = 'parked';
  perform app.audit('day.close', 'business_days', d.id,
    jsonb_build_object('business_date', d.business_date, 'total_billed', v_z->'total_billed', 'bills', v_z->'bills'));
  return v_z;
end $$;

create or replace function public.reopen_day(p_reason text) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_user uuid := app.require_permission('day.reopen');
  v_branch uuid := app.current_branch_id(); d public.business_days; cur public.business_days; v_list text;
begin
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for reopening the day.'; end if;
  if exists (select 1 from public.business_days where branch_id = v_branch and status = 'parked') then
    raise exception 'A day is already reopened. Close it first.';
  end if;
  select * into d from public.business_days where branch_id = v_branch and status = 'closed'
   order by business_date desc limit 1 for update;
  if not found then raise exception 'There is no closed day to reopen.'; end if;
  select * into cur from public.business_days where branch_id = v_branch and status = 'open' for update;
  if found then
    if cur.business_date < d.business_date then raise exception 'Only the last closed day can be reopened.'; end if;
    select string_agg(bill_number, ', ' order by created_at) into v_list from (
      select o.bill_number, o.created_at from public.orders o
       where o.branch_id = v_branch and o.business_date = cur.business_date and o.status <> 'voided' and o.merged_into is null
       limit 20) x;
    if v_list is null then
      select string_agg(kt.ticket_number, ', ') into v_list from public.kitchen_tickets kt join public.orders o on o.id = kt.order_id
       where o.branch_id = v_branch and o.business_date = cur.business_date and kt.status not in ('cancelled');
    end if;
    if v_list is not null then
      raise exception 'Bills or kitchen tickets have already been made today: %. Void them first, then reopen the day.', v_list;
    end if;
    if exists (select 1 from public.shifts where branch_id = v_branch and status = 'open') then
      raise exception 'Close the open shift first, then reopen the day.';
    end if;
    if exists (select 1 from public.orders where branch_id = v_branch and business_date = cur.business_date) then
      update public.business_days set status = 'parked' where id = cur.id;
    else
      delete from public.business_days where id = cur.id;
    end if;
  end if;
  update public.business_days set status = 'open', closed_at = null, closed_by = null, reopen_count = reopen_count + 1
   where id = d.id;
  perform app.audit('day.reopen', 'business_days', d.id,
    jsonb_build_object('business_date', d.business_date, 'reason', left(trim(p_reason), 300)),
    jsonb_build_object('z_report_total', d.z_report->'total_billed'));
  return jsonb_build_object('business_date', d.business_date);
end $$;

create or replace function public.day_report(p_day_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare d public.business_days;
begin
  perform app.require_permission('report.view_sales');
  select * into d from public.business_days where id = p_day_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'Day not found.'; end if;
  return case when d.status = 'closed' and d.z_report is not null then d.z_report else app.z_report(d.id) end;
end $$;

create or replace function public.issue_credit_note(p_order_id uuid, p_amount numeric, p_method_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_user uuid := app.require_permission('order.refund');
  o public.orders%rowtype; v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_done numeric(14,2); v_left numeric(14,2); v_country text; v_day public.business_days; v_shift uuid;
  v_kind text; v_ratio numeric; v_tax numeric(14,2); v_taxes jsonb; v_no text; v_seq int; v_fy text; v_code text;
  v_id uuid := gen_random_uuid(); v_deadline date;
begin
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for the credit note.'; end if;
  if v_amount <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status <> 'completed' or o.merged_into is not null then raise exception 'Only a completed bill can get a credit note.'; end if;
  if o.payment_status in ('unpaid', 'partial') then
    raise exception 'Bill % is not fully paid. Cancel items or void it instead.', o.bill_number;
  end if;
  select coalesce(sum(amount), 0) into v_done from public.refunds where order_id = o.id;
  v_left := o.paid_total - v_done;
  if v_left <= 0 then raise exception 'Bill % has already been fully refunded.', o.bill_number; end if;
  if v_amount > v_left then raise exception 'The most that can be refunded on bill % is %.', o.bill_number, v_left; end if;

  select country_code into v_country from public.restaurants where id = o.restaurant_id;
  v_day := app.open_business_day(o.branch_id);
  if v_country = 'IN' then
    v_deadline := make_date(case when extract(month from o.business_date) >= 4 then extract(year from o.business_date)::int + 1
                                 else extract(year from o.business_date)::int end, 11, 30);
    if v_day.business_date > v_deadline then
      raise exception 'Under GST rules a credit note for bill % could only be issued until %.', o.bill_number, to_char(v_deadline, 'DD Mon YYYY');
    end if;
  end if;

  select pm.kind into v_kind from public.payment_methods pm where pm.id = p_method_id and pm.restaurant_id = o.restaurant_id and pm.is_active;
  if not found then raise exception 'Choose how the money is given back.'; end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
  if v_kind = 'cash' and v_shift is null then raise exception 'Open a shift before giving cash back.'; end if;

  v_ratio := case when o.grand_total > 0 then v_amount / o.grand_total else 0 end;
  select coalesce(jsonb_agg(jsonb_build_object('name', c, 'rate', r, 'amount', round(a * v_ratio, 2)) order by r, c), '[]'::jsonb),
         coalesce(sum(round(a * v_ratio, 2)), 0)
    into v_taxes, v_tax
    from (select component_name c, rate r, sum(tax_amount) a from public.order_item_taxes where order_id = o.id group by 1, 2) x;

  perform pg_advisory_xact_lock(hashtext('credit_note:' || o.branch_id::text));
  v_fy := app.fy_label(v_country, v_day.business_date);
  select code into v_code from public.branches where id = o.branch_id;
  select count(*) + 1 into v_seq from public.credit_notes
   where branch_id = o.branch_id and number like 'CN-' || v_code || '-' || v_fy || '-%';
  v_no := 'CN-' || v_code || '-' || v_fy || '-' || lpad(v_seq::text, 4, '0');

  insert into public.credit_notes (id, restaurant_id, branch_id, order_id, number, business_date, shift_id, amount,
                                   tax_amount, taxes, reason, payment_method_id, created_by)
  values (v_id, o.restaurant_id, o.branch_id, o.id, v_no, v_day.business_date, v_shift, v_amount, v_tax, v_taxes,
          left(trim(p_reason), 300), p_method_id, v_user);
  insert into public.refunds (id, restaurant_id, order_id, payment_id, amount, reason, approved_by, client_created_at,
                              shift_id, payment_method_id, credit_note_id)
  values (gen_random_uuid(), o.restaurant_id, o.id, null, v_amount, left(trim(p_reason), 300), v_user, now(),
          v_shift, p_method_id, v_id);

  perform set_config('app.day_ok', 'on', true);
  update public.orders set payment_status = case when v_done + v_amount >= o.paid_total then 'refunded' else 'partially_refunded' end
   where id = o.id;
  perform set_config('app.day_ok', 'off', true);

  perform app.audit('credit_note.issue', 'credit_notes', v_id,
    jsonb_build_object('number', v_no, 'bill_number', o.bill_number, 'amount', v_amount, 'tax', v_tax,
                       'method_kind', v_kind, 'reason', left(trim(p_reason), 300)));
  return jsonb_build_object('credit_note_id', v_id, 'number', v_no, 'amount', v_amount, 'tax', v_tax,
                            'remaining', v_left - v_amount);
end $$;

create or replace function public.refund_order(p_order_id uuid, p_amount numeric, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_method uuid;
begin
  select payment_method_id into v_method from public.payments
   where order_id = p_order_id and restaurant_id = app.current_restaurant_id() order by created_at limit 1;
  if v_method is null then raise exception 'Bill not found.'; end if;
  return public.issue_credit_note(p_order_id, p_amount, v_method, p_reason);
end $$;

revoke all on function public.day_status() from public, anon;
revoke all on function public.close_day(text) from public, anon;
revoke all on function public.reopen_day(text) from public, anon;
revoke all on function public.day_report(uuid) from public, anon;
revoke all on function public.issue_credit_note(uuid,numeric,uuid,text) from public, anon;
grant execute on function public.day_status(), public.close_day(text), public.reopen_day(text), public.day_report(uuid), public.issue_credit_note(uuid,numeric,uuid,text) to authenticated;
