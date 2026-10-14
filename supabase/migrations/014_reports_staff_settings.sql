-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260924095831, name 'sna_pos_14_reports_staff_settings'. This is the SQL that actually ran.

-- SNA POS migration 14: sales reports, staff invitations and settings.

-- ===========================================================================
-- Sales report for a date range, in the restaurant's own timezone.
-- Tax and cash detail only for roles with report.view_financial.
-- ===========================================================================
create or replace function public.sales_report(p_from date, p_to date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_rest uuid;
  v_tz text;
  v_start timestamptz;
  v_end timestamptz;
  v_fin boolean;
  v_summary jsonb;
  v_by_day jsonb;
  v_by_hour jsonb;
  v_by_item jsonb;
  v_by_method jsonb;
  v_by_type jsonb;
  v_tax jsonb := '[]'::jsonb;
  v_refunds numeric(14,2);
  v_refund_count int;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a valid date range.';
  end if;
  if p_to - p_from > 366 then
    raise exception 'Choose a range of one year or less.';
  end if;
  v_rest := app.current_restaurant_id();
  v_fin  := app.has_permission('report.view_financial');
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;

  create temp table if not exists _rep_orders (id uuid primary key, created_at timestamptz,
    status text, order_type text, subtotal numeric, discount_total numeric, tax_total numeric,
    rounding_adjustment numeric, grand_total numeric) on commit drop;
  truncate _rep_orders;
  insert into _rep_orders
  select id, created_at, status, order_type, subtotal, discount_total, tax_total,
         rounding_adjustment, grand_total
    from public.orders
   where restaurant_id = v_rest and created_at >= v_start and created_at < v_end
     and status in ('completed','voided');

  select coalesce(sum(r.amount),0), count(*) into v_refunds, v_refund_count
    from public.refunds r
   where r.restaurant_id = v_rest and r.created_at >= v_start and r.created_at < v_end;

  select jsonb_build_object(
      'bills',        count(*) filter (where status='completed'),
      'gross_sales',  coalesce(sum(subtotal) filter (where status='completed'),0),
      'discounts',    coalesce(sum(discount_total) filter (where status='completed'),0),
      'tax',          coalesce(sum(tax_total) filter (where status='completed'),0),
      'rounding',     coalesce(sum(rounding_adjustment) filter (where status='completed'),0),
      'total_billed', coalesce(sum(grand_total) filter (where status='completed'),0),
      'average_bill', coalesce(round(avg(grand_total) filter (where status='completed'),2),0),
      'voided_bills', count(*) filter (where status='voided'),
      'voided_value', coalesce(sum(grand_total) filter (where status='voided'),0),
      'refunds',      v_refunds,
      'refund_count', v_refund_count,
      'net_collected', coalesce(sum(grand_total) filter (where status='completed'),0) - v_refunds)
    into v_summary from _rep_orders;

  select coalesce(jsonb_agg(jsonb_build_object('day', d, 'bills', n, 'total', t) order by d), '[]'::jsonb)
    into v_by_day
    from (select (created_at at time zone v_tz)::date d, count(*) n, sum(grand_total) t
            from _rep_orders where status='completed' group by 1) x;

  select coalesce(jsonb_agg(jsonb_build_object('hour', h, 'bills', n, 'total', t) order by h), '[]'::jsonb)
    into v_by_hour
    from (select extract(hour from created_at at time zone v_tz)::int h, count(*) n, sum(grand_total) t
            from _rep_orders where status='completed' group by 1) x;

  select coalesce(jsonb_agg(jsonb_build_object('item', name, 'qty', q, 'amount', a) order by a desc), '[]'::jsonb)
    into v_by_item
    from (select oi.product_name name, sum(oi.quantity) q, sum(oi.line_subtotal) a
            from public.order_items oi join _rep_orders o on o.id = oi.order_id
           where o.status='completed' group by oi.product_name
           order by 3 desc limit 50) x;

  select coalesce(jsonb_agg(jsonb_build_object('method', name, 'bills', n, 'amount', a) order by a desc), '[]'::jsonb)
    into v_by_method
    from (select pm.name, count(*) n, sum(p.amount) a
            from public.payments p
            join _rep_orders o on o.id = p.order_id
            join public.payment_methods pm on pm.id = p.payment_method_id
           where o.status='completed' group by pm.name) x;

  select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'bills', n, 'total', t) order by t desc), '[]'::jsonb)
    into v_by_type
    from (select order_type, count(*) n, sum(grand_total) t
            from _rep_orders where status='completed' group by 1) x;

  if v_fin then
    select coalesce(jsonb_agg(jsonb_build_object('component', c, 'rate', r, 'taxable', tx, 'tax', ta)
                              order by r, c), '[]'::jsonb)
      into v_tax
      from (select t.component_name c, t.rate r, sum(t.taxable_amount) tx, sum(t.tax_amount) ta
              from public.order_item_taxes t join _rep_orders o on o.id = t.order_id
             where o.status='completed' group by 1,2) x;
  end if;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', v_tz, 'financial', v_fin,
    'summary', v_summary, 'by_day', v_by_day, 'by_hour', v_by_hour,
    'by_item', v_by_item, 'by_method', v_by_method, 'by_type', v_by_type,
    'tax', v_tax);
end $$;

-- ===========================================================================
-- Staff invitations.
--
-- No service-role key is used anywhere. The owner creates the staff record and
-- receives a one-time 8-character invite code to hand over. The staff member
-- creates their own account on the login page and enters the code. The code is
-- stored only as a bcrypt hash, in a table no signed-in user can read.
-- ===========================================================================
create table if not exists public.staff_invites (
  user_id       uuid primary key references public.users(id) on delete cascade,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  code_hash     text not null,
  expires_at    timestamptz not null,
  created_by    uuid references public.users(id) on delete set null,
  created_at    timestamptz not null default now()
);
alter table public.staff_invites enable row level security;
-- Deliberately no policies: only the definer functions below touch it.
revoke all on public.staff_invites from anon, authenticated;

create or replace function app.new_invite_code()
returns text language plpgsql volatile
set search_path = public, pg_temp as $$
declare
  v_alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- 32 symbols, no 0/O/1/I
  v_code text := '';
  v_bytes bytea := extensions.gen_random_bytes(8);
begin
  for i in 0..7 loop
    v_code := v_code || substr(v_alpha, 1 + (get_byte(v_bytes, i) % 32), 1);
  end loop;
  return v_code;
end $$;
revoke all on function app.new_invite_code() from public;

create or replace function public.invite_staff(
  p_full_name text, p_email text, p_role_id uuid, p_phone text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_me uuid := app.require_permission('user.manage');
  v_rest uuid := app.current_restaurant_id();
  v_role public.roles%rowtype;
  v_email text := lower(trim(p_email));
  v_code text := app.new_invite_code();
  v_emp text;
  v_id uuid := gen_random_uuid();
begin
  if coalesce(trim(p_full_name),'') = '' then raise exception 'Enter the staff member''s name.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  select * into v_role from public.roles where id = p_role_id and restaurant_id = v_rest;
  if not found then raise exception 'Choose a role.'; end if;
  if v_role.name = 'Owner' and not app.is_owner() then
    raise exception 'Only an owner can add another owner.';
  end if;
  if exists (select 1 from public.users where restaurant_id = v_rest
             and lower(email::text) = v_email and deleted_at is null) then
    raise exception 'Someone with that email is already on your staff list.';
  end if;

  select 'EMP' || lpad((coalesce(max(nullif(regexp_replace(employee_code,'\D','','g'),'')::int),0) + 1)::text, 3, '0')
    into v_emp from public.users where restaurant_id = v_rest;

  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, email, phone, role_id, is_active)
  values (v_id, v_rest, null, v_emp, left(trim(p_full_name),120), v_email, nullif(trim(p_phone),''), v_role.id, true);

  insert into public.user_branches (user_id, branch_id, restaurant_id)
  values (v_id, app.current_branch_id(), v_rest);

  insert into public.staff_invites (user_id, restaurant_id, code_hash, expires_at, created_by)
  values (v_id, v_rest, extensions.crypt(v_code, extensions.gen_salt('bf')), now() + interval '7 days', v_me);

  perform app.audit('user.invite', 'users', v_id,
    jsonb_build_object('full_name', trim(p_full_name), 'email', v_email, 'role', v_role.name));
  return jsonb_build_object('user_id', v_id, 'employee_code', v_emp, 'invite_code', v_code,
                            'expires_at', now() + interval '7 days');
end $$;

create or replace function public.regenerate_invite(p_user_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_me uuid := app.require_permission('user.manage');
  u public.users%rowtype;
  v_code text := app.new_invite_code();
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null;
  if not found then raise exception 'Staff member not found.'; end if;
  if u.auth_user_id is not null then raise exception '% has already joined.', u.full_name; end if;
  if (select name from public.roles where id = u.role_id) = 'Owner' and not app.is_owner() then
    raise exception 'Only an owner can manage another owner.';
  end if;
  insert into public.staff_invites (user_id, restaurant_id, code_hash, expires_at, created_by)
  values (u.id, u.restaurant_id, extensions.crypt(v_code, extensions.gen_salt('bf')), now() + interval '7 days', v_me)
  on conflict (user_id) do update set code_hash = excluded.code_hash,
    expires_at = excluded.expires_at, created_by = excluded.created_by, created_at = now();
  perform app.audit('user.invite_regenerated', 'users', u.id, null);
  return jsonb_build_object('user_id', u.id, 'invite_code', v_code, 'expires_at', now() + interval '7 days');
end $$;

-- Called by a newly signed-up person who has an invite code.
create or replace function public.claim_staff_invite(p_code text)
returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_code text := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
  r record;
begin
  if v_uid is null then raise exception 'You must be signed in.'; end if;
  if exists (select 1 from public.users where auth_user_id = v_uid and deleted_at is null) then
    raise exception 'This account already belongs to a restaurant.';
  end if;
  if length(v_code) <> 8 then raise exception 'An invite code is 8 letters and numbers.'; end if;
  select lower(email) into v_email from auth.users where id = v_uid;

  for r in
    select u.id, u.restaurant_id, i.code_hash
      from public.users u join public.staff_invites i on i.user_id = u.id
     where lower(u.email::text) = v_email and u.auth_user_id is null
       and u.deleted_at is null and u.is_active and i.expires_at > now()
  loop
    if extensions.crypt(v_code, r.code_hash) = r.code_hash then
      update public.users set auth_user_id = v_uid, last_login_at = now() where id = r.id;
      delete from public.staff_invites where user_id = r.id;
      insert into public.audit_logs (restaurant_id, user_id, action, entity_type, entity_id, actor_type)
      values (r.restaurant_id, r.id, 'user.join', 'users', r.id, 'user');
      return r.restaurant_id;
    end if;
  end loop;

  raise exception 'That invite code does not match this email, or it has expired. Ask your manager for a new code.';
end $$;

create or replace function public.update_staff(
  p_user_id uuid, p_role_id uuid default null, p_is_active boolean default null)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_me uuid := app.require_permission('user.manage');
  u public.users%rowtype;
  v_cur_role text;
  v_new_role public.roles%rowtype;
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  if u.id = v_me then raise exception 'You cannot change your own role or access.'; end if;
  select name into v_cur_role from public.roles where id = u.role_id;
  if v_cur_role = 'Owner' and not app.is_owner() then
    raise exception 'Only an owner can change another owner.';
  end if;

  if p_role_id is not null and p_role_id <> u.role_id then
    select * into v_new_role from public.roles where id = p_role_id and restaurant_id = u.restaurant_id;
    if not found then raise exception 'Choose a role.'; end if;
    if v_new_role.name = 'Owner' and not app.is_owner() then
      raise exception 'Only an owner can make someone an owner.';
    end if;
    update public.users set role_id = v_new_role.id where id = u.id;
    perform app.audit('user.role_change', 'users', u.id,
      jsonb_build_object('role', v_new_role.name), jsonb_build_object('role', v_cur_role));
  end if;

  if p_is_active is not null and p_is_active <> u.is_active then
    update public.users set is_active = p_is_active where id = u.id;
    perform app.audit(case when p_is_active then 'user.activate' else 'user.deactivate' end,
      'users', u.id, jsonb_build_object('is_active', p_is_active));
  end if;
end $$;

-- Withdraw an invitation nobody has used yet.
create or replace function public.cancel_invite(p_user_id uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_me uuid := app.require_permission('user.manage');
  u public.users%rowtype;
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  if u.auth_user_id is not null then raise exception '% has already joined; deactivate them instead.', u.full_name; end if;
  if (select name from public.roles where id = u.role_id) = 'Owner' and not app.is_owner() then
    raise exception 'Only an owner can manage another owner.';
  end if;
  delete from public.staff_invites where user_id = u.id;
  update public.users set deleted_at = now(), is_active = false where id = u.id;
  perform app.audit('user.invite_cancelled', 'users', u.id, null);
end $$;

-- ===========================================================================
-- Settings: restaurant details, branch address and receipt options.
-- Only keys present in p_settings are changed.
-- ===========================================================================
create or replace function public.update_settings(p_settings jsonb)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_me uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  s jsonb := coalesce(p_settings, '{}'::jsonb);
  v_country char(2);
  v_gstin text;
begin
  select country_code into v_country from public.restaurants where id = v_rest;

  if s ? 'trading_name' and coalesce(trim(s->>'trading_name'),'') = '' then
    raise exception 'The name customers see cannot be empty.';
  end if;
  if s ? 'legal_name' and coalesce(trim(s->>'legal_name'),'') = '' then
    raise exception 'The registered business name cannot be empty.';
  end if;
  if s ? 'tax_registration_no' then
    v_gstin := upper(nullif(trim(s->>'tax_registration_no'),''));
    if v_gstin is not null and v_country = 'IN'
       and v_gstin !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
      raise exception 'That GSTIN does not look right. It should be 15 characters, like 33AAACA0000A1Z5.';
    end if;
  end if;
  if s ? 'cash_rounding_mode' and (s->>'cash_rounding_mode') not in ('none','nearest_1','nearest_0_05','nearest_0_10') then
    raise exception 'Unknown rounding option.';
  end if;

  update public.restaurants set
    trading_name = case when s ? 'trading_name' then left(trim(s->>'trading_name'),120) else trading_name end,
    legal_name   = case when s ? 'legal_name'   then left(trim(s->>'legal_name'),160) else legal_name end,
    tax_registration_no = case when s ? 'tax_registration_no' then v_gstin else tax_registration_no end,
    contact_phone = case when s ? 'contact_phone' then nullif(left(trim(s->>'contact_phone'),30),'') else contact_phone end
  where id = v_rest;

  update public.branches set
    name          = case when s ? 'branch_name' and coalesce(trim(s->>'branch_name'),'') <> '' then left(trim(s->>'branch_name'),80) else name end,
    address_line1 = case when s ? 'address_line1' then nullif(left(trim(s->>'address_line1'),160),'') else address_line1 end,
    address_line2 = case when s ? 'address_line2' then nullif(left(trim(s->>'address_line2'),160),'') else address_line2 end,
    city          = case when s ? 'city' then nullif(left(trim(s->>'city'),80),'') else city end,
    state_or_region = case when s ? 'state_or_region' then nullif(left(trim(s->>'state_or_region'),80),'') else state_or_region end,
    postal_code   = case when s ? 'postal_code' then nullif(left(trim(s->>'postal_code'),12),'') else postal_code end,
    phone         = case when s ? 'phone' then nullif(left(trim(s->>'phone'),30),'') else phone end
  where id = v_branch;

  update public.branch_settings set
    receipt_header = case when s ? 'receipt_header' then nullif(left(trim(s->>'receipt_header'),120),'') else receipt_header end,
    receipt_footer = case when s ? 'receipt_footer' then nullif(left(trim(s->>'receipt_footer'),300),'') else receipt_footer end,
    cash_rounding_mode = case when s ? 'cash_rounding_mode' then s->>'cash_rounding_mode' else cash_rounding_mode end,
    auto_print_kot = case when s ? 'auto_print_kot' then (s->>'auto_print_kot')::boolean else auto_print_kot end
  where branch_id = v_branch;

  perform app.audit('settings.update', 'restaurants', v_rest, s);
end $$;

revoke all on function public.sales_report(date,date), public.invite_staff(text,text,uuid,text),
  public.regenerate_invite(uuid), public.claim_staff_invite(text),
  public.update_staff(uuid,uuid,boolean), public.cancel_invite(uuid),
  public.update_settings(jsonb) from public, anon;
grant execute on function public.sales_report(date,date), public.invite_staff(text,text,uuid,text),
  public.regenerate_invite(uuid), public.claim_staff_invite(text),
  public.update_staff(uuid,uuid,boolean), public.cancel_invite(uuid),
  public.update_settings(jsonb) to authenticated;
