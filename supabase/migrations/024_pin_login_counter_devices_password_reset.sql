-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260925091715, name 'sna_pos_24_pin_login_counter_devices_password_reset'. This is the SQL that actually ran.

-- Staff PIN login on shared counter devices, and admin password reset.
--
-- A counter device signs in with its own account, which has NO permissions.
-- Only while a staff member has unlocked it with their PIN does it act as that
-- person (their role, their name on every bill and audit entry). A locked
-- device cannot read any restaurant data at all.

create table if not exists app.secrets (key text primary key, value text not null);
revoke all on app.secrets from public, anon, authenticated;
insert into app.secrets (key, value) values ('pin_pepper', encode(extensions.gen_random_bytes(32), 'hex'))
  on conflict (key) do nothing;

alter table public.devices drop constraint if exists devices_device_type_check;
alter table public.devices add constraint devices_device_type_check
  check (device_type in ('tablet', 'desktop', 'phone', 'kiosk', 'counter'));
alter table public.devices add column if not exists auth_user_id uuid unique references auth.users(id) on delete set null;

alter table public.users add column if not exists must_change_password boolean not null default false;
create unique index if not exists users_pin_unique on public.users (restaurant_id, pin_hash)
  where pin_hash is not null and deleted_at is null;

create table if not exists public.pin_sessions (
  device_id uuid primary key references public.devices(id) on delete cascade,
  restaurant_id uuid not null references public.restaurants(id),
  user_id uuid not null references public.users(id),
  started_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create table if not exists public.pin_attempts (
  id bigint generated always as identity primary key,
  device_id uuid not null references public.devices(id) on delete cascade,
  at timestamptz not null default now(),
  ok boolean not null
);
create index if not exists pin_attempts_device_at on public.pin_attempts (device_id, at);
alter table public.pin_sessions enable row level security;
alter table public.pin_attempts enable row level security;
revoke all on public.pin_sessions, public.pin_attempts from anon, authenticated;

-- ---------------------------------------------------------------- identity
create or replace function app.device_id()
 returns uuid language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select d.id from public.devices d where d.auth_user_id = auth.uid() and d.is_active limit 1
$$;

create or replace function app.current_user_id()
 returns uuid language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select case
    when app.device_id() is not null then
      (select ps.user_id from public.pin_sessions ps
         join public.users u on u.id = ps.user_id and u.is_active and u.deleted_at is null
        where ps.device_id = app.device_id() and ps.expires_at > now()
          and u.restaurant_id = ps.restaurant_id)
    else
      (select u.id from public.users u
        where u.auth_user_id = auth.uid() and u.deleted_at is null and u.is_active limit 1)
  end
$$;

create or replace function app.current_restaurant_id()
 returns uuid language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select u.restaurant_id from public.users u where u.id = app.current_user_id()
$$;

create or replace function app.current_branch_id()
 returns uuid language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select coalesce(
    (select d.branch_id from public.devices d where d.id = app.device_id()),
    (select b.id from public.branches b
      where b.restaurant_id = app.current_restaurant_id() and b.deleted_at is null
      order by b.created_at limit 1))
$$;

create or replace function app.has_permission(p_key text)
 returns boolean language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select exists (
    select 1 from public.users u join public.role_permissions rp on rp.role_id = u.role_id
     where u.id = app.current_user_id() and rp.permission_key = p_key)
$$;

create or replace function app.is_owner()
 returns boolean language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select exists (
    select 1 from public.users u join public.roles r on r.id = u.role_id
     where u.id = app.current_user_id() and r.name = 'Owner' and r.is_system)
$$;

drop view if exists public.v_current_user;
create view public.v_current_user with (security_invoker = false) as
  select u.id as user_id, u.restaurant_id, u.full_name, u.email, u.employee_code,
         r.id as role_id, r.name as role_name, res.trading_name, res.country_code, res.currency_code, res.timezone,
         (select coalesce(array_agg(rp.permission_key order by rp.permission_key), '{}'::text[])
            from public.role_permissions rp where rp.role_id = r.id) as permissions,
         u.must_change_password,
         (select d.name from public.devices d where d.id = app.device_id()) as device_name
    from public.users u
    join public.roles r on r.id = u.role_id
    join public.restaurants res on res.id = u.restaurant_id
   where u.id = app.current_user_id();
grant select on public.v_current_user to authenticated;

create or replace function public.my_account_state()
 returns text language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select case
    when auth.uid() is null then 'signed_out'
    when app.device_id() is not null then case when app.current_user_id() is null then 'device_locked' else 'active' end
    when exists (select 1 from public.devices where auth_user_id = auth.uid()) then 'device_removed'
    when exists (select 1 from public.users where auth_user_id = auth.uid() and deleted_at is null and is_active) then 'active'
    when exists (select 1 from public.users where auth_user_id = auth.uid() and deleted_at is null) then 'deactivated'
    else 'new' end
$$;

-- A counter device account can never create a restaurant or join as staff.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.claim_staff_invite(text)'::regprocedure);
  d := replace(d, $x$  if v_uid is null then raise exception 'You must be signed in.'; end if;$x$,
    $x$  if v_uid is null then raise exception 'You must be signed in.'; end if;
  if exists (select 1 from public.devices where auth_user_id = v_uid) then
    raise exception 'This is a shared counter device. Staff unlock it with their PIN.';
  end if;$x$);
  execute d;
  if pg_get_functiondef('public.claim_staff_invite(text)'::regprocedure) not like '%shared counter device%' then
    raise exception 'claim patch failed';
  end if;
end $$;

create or replace function public.create_restaurant_with_owner(p_legal_name text, p_trading_name text, p_country_code character,
  p_owner_name text, p_branch_name text default 'Main Branch', p_branch_code text default 'MN',
  p_timezone text default null, p_tax_registration_no text default null)
 returns uuid language plpgsql set search_path to 'public', 'pg_temp'
as $$
begin
  if exists (select 1 from public.devices where auth_user_id = auth.uid()) then
    raise exception 'This is a shared counter device. Sign in on your own device to set up a restaurant.';
  end if;
  return app.create_restaurant_with_owner(p_legal_name, p_trading_name, p_country_code, p_owner_name,
    p_branch_name, p_branch_code, p_timezone, p_tax_registration_no);
end $$;

-- Bill numbers stay on the branch's main series, not a counter device's.
do $$
declare d text;
begin
  d := pg_get_functiondef('app.next_bill_number(uuid)'::regprocedure);
  d := replace(d, 'where d.branch_id = p_branch and d.is_active order by', $x$where d.branch_id = p_branch and d.is_active and d.device_type <> 'counter' order by$x$);
  execute d;
  if pg_get_functiondef('app.next_bill_number(uuid)'::regprocedure) not like '%<> ''counter''%' then raise exception 'bill no patch failed'; end if;
end $$;

-- ---------------------------------------------------------------- PINs
create or replace function app.pin_hash(p_restaurant uuid, p_pin text)
 returns text language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select encode(extensions.hmac(p_restaurant::text || ':' || p_pin,
                (select value from app.secrets where key = 'pin_pepper'), 'sha256'), 'hex')
$$;
revoke all on function app.pin_hash(uuid, text), app.device_id() from public, anon, authenticated;

-- Sets (or generates) a staff member's PIN. Unique within the restaurant.
create or replace function public.set_staff_pin(p_user_id uuid, p_pin text default null)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_me uuid := app.require_permission('user.manage');
  u public.users%rowtype; v_role text; v_pin text := nullif(trim(coalesce(p_pin, '')), ''); v_hash text; i int := 0;
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  select name into v_role from public.roles where id = u.role_id;
  if v_role = 'Owner' and not app.is_owner() and u.id <> v_me then
    raise exception 'Only an owner can set another owner''s PIN.';
  end if;

  if v_pin is null then
    loop
      i := i + 1;
      v_pin := lpad((floor(random() * 10000))::int::text, 4, '0');
      exit when v_pin !~ '^(\d)\1+$' and v_pin not in ('1234', '4321', '0123', '9876')
        and not exists (select 1 from public.users where restaurant_id = u.restaurant_id and deleted_at is null
                          and id <> u.id and pin_hash = app.pin_hash(u.restaurant_id, v_pin));
      if i > 200 then raise exception 'Could not find a free PIN. Type one of 5 or 6 digits instead.'; end if;
    end loop;
  else
    if v_pin !~ '^\d{4,6}$' then raise exception 'A PIN is 4 to 6 digits.'; end if;
    if v_pin ~ '^(\d)\1+$' or v_pin in ('1234', '12345', '123456', '4321', '54321', '654321', '0123', '9876') then
      raise exception 'That PIN is too easy to guess. Choose another.';
    end if;
  end if;
  v_hash := app.pin_hash(u.restaurant_id, v_pin);
  if exists (select 1 from public.users where restaurant_id = u.restaurant_id and deleted_at is null
               and id <> u.id and pin_hash = v_hash) then
    raise exception 'That PIN is already used by someone else. Choose a different PIN.';
  end if;
  update public.users set pin_hash = v_hash, pin_set_at = now() where id = u.id;
  delete from public.pin_sessions where user_id = u.id;
  perform app.audit('user.pin_set', 'users', u.id, jsonb_build_object('full_name', u.full_name));
  return jsonb_build_object('user_id', u.id, 'pin', v_pin);
end $$;

create or replace function public.clear_staff_pin(p_user_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid := app.require_permission('user.manage'); u public.users%rowtype; v_role text;
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id() and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  select name into v_role from public.roles where id = u.role_id;
  if v_role = 'Owner' and not app.is_owner() then raise exception 'Only an owner can change another owner.'; end if;
  update public.users set pin_hash = null, pin_set_at = null where id = u.id;
  delete from public.pin_sessions where user_id = u.id;
  perform app.audit('user.pin_removed', 'users', u.id, jsonb_build_object('full_name', u.full_name));
end $$;

-- A staff member who signs in only with a PIN (no email account).
create or replace function public.create_pin_staff(p_full_name text, p_role_id uuid, p_phone text default null)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_me uuid := app.require_permission('user.manage');
  v_rest uuid := app.current_restaurant_id(); v_role public.roles%rowtype; v_emp text; v_id uuid := gen_random_uuid(); v_pin jsonb;
begin
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Enter the staff member''s name.'; end if;
  select * into v_role from public.roles where id = p_role_id and restaurant_id = v_rest;
  if not found then raise exception 'Choose a role.'; end if;
  if v_role.name = 'Owner' then raise exception 'An owner needs an email sign-in, not only a PIN.'; end if;
  select 'EMP' || lpad((coalesce(max(nullif(regexp_replace(employee_code,'\D','','g'),'')::int),0) + 1)::text, 3, '0')
    into v_emp from public.users where restaurant_id = v_rest;
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, email, phone, role_id, is_active)
  values (v_id, v_rest, null, v_emp, left(trim(p_full_name), 120), null, nullif(trim(p_phone), ''), v_role.id, true);
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (v_id, app.current_branch_id(), v_rest);
  perform app.audit('user.create_pin_staff', 'users', v_id, jsonb_build_object('full_name', trim(p_full_name), 'role', v_role.name));
  v_pin := public.set_staff_pin(v_id, null);
  return jsonb_build_object('user_id', v_id, 'employee_code', v_emp, 'pin', v_pin->>'pin');
end $$;

-- ---------------------------------------------------------------- counter devices
-- Called by an owner/manager right after the app created the device's own sign-in.
create or replace function public.register_counter_device(p_auth_user_id uuid, p_name text)
 returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid := app.require_permission('settings.manage'); v_id uuid := gen_random_uuid(); a record;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the device a name, e.g. Counter 1.'; end if;
  select id, email, created_at into a from auth.users where id = p_auth_user_id;
  if not found or a.email not like 'counter-%@devices.sna-pos.app' or a.created_at < now() - interval '10 minutes' then
    raise exception 'The device sign-in could not be verified. Try again.';
  end if;
  if exists (select 1 from public.users where auth_user_id = p_auth_user_id)
     or exists (select 1 from public.devices where auth_user_id = p_auth_user_id) then
    raise exception 'The device sign-in is already in use.';
  end if;
  insert into public.devices (id, restaurant_id, branch_id, name, device_type, is_active, auth_user_id)
  values (v_id, app.current_restaurant_id(), app.current_branch_id(), left(trim(p_name), 60), 'counter', true, p_auth_user_id);
  perform app.audit('device.register', 'devices', v_id, jsonb_build_object('name', trim(p_name)));
  return v_id;
end $$;

create or replace function public.remove_counter_device(p_device_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid := app.require_permission('settings.manage'); d public.devices%rowtype;
begin
  select * into d from public.devices where id = p_device_id and restaurant_id = app.current_restaurant_id()
    and device_type = 'counter' for update;
  if not found then raise exception 'Counter device not found.'; end if;
  update public.devices set is_active = false where id = d.id;
  delete from public.pin_sessions where device_id = d.id;
  if d.auth_user_id is not null then delete from auth.sessions where user_id = d.auth_user_id; end if;
  perform app.audit('device.remove', 'devices', d.id, jsonb_build_object('name', d.name));
end $$;

-- What the PIN screen needs to show. Works while the device is locked.
create or replace function public.my_device_state()
 returns jsonb language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select case when d.id is null then jsonb_build_object('is_device', false)
  else jsonb_build_object('is_device', true, 'device_name', d.name, 'restaurant', r.trading_name,
    'unlocked_as', (select u.full_name from public.users u where u.id = app.current_user_id()))
  end
  from (select 1) one
  left join public.devices d on d.id = app.device_id()
  left join public.restaurants r on r.id = d.restaurant_id
$$;

-- Unlock with a PIN. Wrong PINs are counted, not raised, so the count survives.
create or replace function public.pin_unlock(p_pin text)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_dev uuid := app.device_id(); d public.devices%rowtype; v_fail int; u public.users%rowtype; v_role text;
begin
  if v_dev is null then raise exception 'This device is not set up as a counter.'; end if;
  select * into d from public.devices where id = v_dev;
  delete from public.pin_attempts where at < now() - interval '1 day';
  select count(*) into v_fail from public.pin_attempts where device_id = v_dev and not ok and at > now() - interval '5 minutes';
  if v_fail >= 5 then
    return jsonb_build_object('ok', false, 'error', 'Too many wrong PINs. Wait 5 minutes, then try again.');
  end if;
  if coalesce(p_pin, '') ~ '^\d{4,6}$' then
    select * into u from public.users
     where restaurant_id = d.restaurant_id and deleted_at is null and is_active
       and pin_hash = app.pin_hash(d.restaurant_id, p_pin);
  end if;
  if u.id is null then
    insert into public.pin_attempts (device_id, ok) values (v_dev, false);
    return jsonb_build_object('ok', false, 'error',
      case when v_fail + 1 >= 5 then 'Wrong PIN. Too many tries — wait 5 minutes.'
           else 'Wrong PIN. ' || (5 - v_fail - 1) || ' tries left.' end);
  end if;
  insert into public.pin_attempts (device_id, ok) values (v_dev, true);
  insert into public.pin_sessions (device_id, restaurant_id, user_id, started_at, expires_at)
  values (v_dev, d.restaurant_id, u.id, now(), now() + interval '12 hours')
  on conflict (device_id) do update set user_id = excluded.user_id, restaurant_id = excluded.restaurant_id,
    started_at = excluded.started_at, expires_at = excluded.expires_at;
  update public.users set last_login_at = now() where id = u.id;
  update public.devices set last_seen_at = now() where id = v_dev;
  select name into v_role from public.roles where id = u.role_id;
  insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, actor_type, new_value)
  values (d.restaurant_id, d.branch_id, u.id, 'device.unlock', 'devices', v_dev, 'user', jsonb_build_object('device', d.name));
  return jsonb_build_object('ok', true, 'name', u.full_name, 'role', v_role);
end $$;

create or replace function public.pin_lock()
 returns void language sql security definer set search_path to 'public', 'pg_temp'
as $$
  delete from public.pin_sessions where device_id = app.device_id();
$$;

-- ---------------------------------------------------------------- passwords
-- An owner or manager sets a temporary password; the person must change it
-- the next time they sign in. Their other sessions are signed out.
create or replace function public.admin_reset_password(p_user_id uuid, p_new_password text)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid := app.require_permission('user.manage'); u public.users%rowtype; v_role text;
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  if u.id = v_me then raise exception 'To change your own password, use Change password.'; end if;
  if u.auth_user_id is null then
    raise exception '% signs in with a PIN only. Set a new PIN instead.', u.full_name;
  end if;
  select name into v_role from public.roles where id = u.role_id;
  if v_role = 'Owner' and not app.is_owner() then raise exception 'Only an owner can reset another owner''s password.'; end if;
  if length(coalesce(p_new_password, '')) < 8 then raise exception 'Use a password of at least 8 characters.'; end if;
  if length(p_new_password) > 72 then raise exception 'Use a password of at most 72 characters.'; end if;

  update auth.users set encrypted_password = extensions.crypt(p_new_password, extensions.gen_salt('bf', 10)),
         updated_at = now()
   where id = u.auth_user_id;
  delete from auth.sessions where user_id = u.auth_user_id;
  update public.users set must_change_password = true where id = u.id;
  perform app.audit('user.password_reset', 'users', u.id, jsonb_build_object('full_name', u.full_name));
end $$;

-- Called after a person has chosen their own new password.
create or replace function public.password_changed()
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid;
begin
  select id into v_id from public.users where auth_user_id = auth.uid() and deleted_at is null;
  if v_id is null then return; end if;
  update public.users set must_change_password = false where id = v_id;
  insert into public.audit_logs (restaurant_id, user_id, action, entity_type, entity_id, actor_type)
  select restaurant_id, id, 'user.password_changed', 'users', id, 'user' from public.users where id = v_id;
end $$;

grant execute on function public.set_staff_pin(uuid, text), public.clear_staff_pin(uuid), public.create_pin_staff(text, uuid, text),
  public.register_counter_device(uuid, text), public.remove_counter_device(uuid), public.my_device_state(),
  public.pin_unlock(text), public.pin_lock(), public.admin_reset_password(uuid, text), public.password_changed()
  to authenticated;
revoke execute on function public.set_staff_pin(uuid, text), public.clear_staff_pin(uuid), public.create_pin_staff(text, uuid, text),
  public.register_counter_device(uuid, text), public.remove_counter_device(uuid), public.my_device_state(),
  public.pin_unlock(text), public.pin_lock(), public.admin_reset_password(uuid, text), public.password_changed()
  from anon, public;
