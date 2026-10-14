-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260927044332, name 'sna_pos_30_pin_and_password_hardening'. This is the SQL that actually ran.

-- Hardening from the security review of PIN login and password reset.

alter table public.pin_sessions add column if not exists last_activity_at timestamptz not null default now();
alter table public.users add column if not exists password_reset_hash text;
revoke select (password_reset_hash) on public.users from anon, authenticated;

-- 1. Who is acting. On a counter, the PIN session ends after 10 minutes without
--    use (enforced here, not only by the tablet's timer). A person whose password
--    was reset by a manager can do nothing until they choose their own.
create or replace function app.current_user_id()
 returns uuid language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select case
    when app.device_id() is not null then
      (select ps.user_id from public.pin_sessions ps
         join public.users u on u.id = ps.user_id and u.is_active and u.deleted_at is null
        where ps.device_id = app.device_id() and ps.expires_at > now()
          and ps.last_activity_at > now() - interval '10 minutes'
          and u.restaurant_id = ps.restaurant_id)
    else
      (select u.id from public.users u
        where u.auth_user_id = auth.uid() and u.deleted_at is null and u.is_active
          and not coalesce(u.must_change_password, false) limit 1)
  end
$$;

create or replace function public.my_account_state()
 returns text language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select case
    when auth.uid() is null then 'signed_out'
    when app.device_id() is not null then case when app.current_user_id() is null then 'device_locked' else 'active' end
    when exists (select 1 from public.devices where auth_user_id = auth.uid()) then 'device_removed'
    when exists (select 1 from public.users where auth_user_id = auth.uid() and deleted_at is null and is_active
                   and coalesce(must_change_password, false)) then 'must_change_password'
    when exists (select 1 from public.users where auth_user_id = auth.uid() and deleted_at is null and is_active) then 'active'
    when exists (select 1 from public.users where auth_user_id = auth.uid() and deleted_at is null) then 'deactivated'
    else 'new' end
$$;

-- Keeps an active counter session alive while it is being used. It never
-- revives a session that has already gone idle.
create or replace function public.pin_touch()
 returns boolean language sql security definer set search_path to 'public', 'pg_temp'
as $$
  with t as (
    update public.pin_sessions set last_activity_at = now()
     where device_id = app.device_id() and expires_at > now()
       and last_activity_at > now() - interval '10 minutes'
    returning 1)
  select exists (select 1 from t)
$$;

-- 2. PIN unlock: 5 wrong in 5 minutes pauses the tablet; 15 wrong in a day locks
--    it until a manager clears it in Settings.
create or replace function public.pin_unlock(p_pin text)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_dev uuid := app.device_id(); d public.devices%rowtype; v_fail int; v_fail_day int; u public.users%rowtype; v_role text;
begin
  if v_dev is null then raise exception 'This device is not set up as a counter.'; end if;
  select * into d from public.devices where id = v_dev;
  delete from public.pin_attempts where at < now() - interval '1 day';
  select count(*) filter (where at > now() - interval '5 minutes'), count(*)
    into v_fail, v_fail_day from public.pin_attempts where device_id = v_dev and not ok;
  if v_fail_day >= 15 then
    return jsonb_build_object('ok', false, 'error',
      'Too many wrong PINs today. A manager must clear the lock in Settings → Counter tablets.');
  end if;
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
    if v_fail_day + 1 >= 15 then
      insert into public.audit_logs (restaurant_id, branch_id, action, entity_type, entity_id, actor_type, new_value)
      values (d.restaurant_id, d.branch_id, 'device.pin_lockout', 'devices', v_dev, 'system', jsonb_build_object('device', d.name));
      return jsonb_build_object('ok', false, 'error',
        'Wrong PIN. This tablet is now locked. A manager must clear it in Settings → Counter tablets.');
    end if;
    return jsonb_build_object('ok', false, 'error',
      case when v_fail + 1 >= 5 then 'Wrong PIN. Too many tries — wait 5 minutes.'
           else 'Wrong PIN. ' || (5 - v_fail - 1) || ' tries left.' end);
  end if;
  insert into public.pin_attempts (device_id, ok) values (v_dev, true);
  insert into public.pin_sessions (device_id, restaurant_id, user_id, started_at, expires_at, last_activity_at)
  values (v_dev, d.restaurant_id, u.id, now(), now() + interval '12 hours', now())
  on conflict (device_id) do update set user_id = excluded.user_id, restaurant_id = excluded.restaurant_id,
    started_at = excluded.started_at, expires_at = excluded.expires_at, last_activity_at = excluded.last_activity_at;
  update public.users set last_login_at = now() where id = u.id;
  update public.devices set last_seen_at = now() where id = v_dev;
  select name into v_role from public.roles where id = u.role_id;
  insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, actor_type, new_value)
  values (d.restaurant_id, d.branch_id, u.id, 'device.unlock', 'devices', v_dev, 'user', jsonb_build_object('device', d.name));
  return jsonb_build_object('ok', true, 'name', u.full_name, 'role', v_role,
    'can_bill', exists (select 1 from public.role_permissions where role_id = u.role_id and permission_key = 'order.create'));
end $$;

create or replace function public.clear_pin_lockout(p_device_id uuid)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid := app.require_permission('settings.manage'); d public.devices%rowtype;
begin
  select * into d from public.devices where id = p_device_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'Counter device not found.'; end if;
  delete from public.pin_attempts where device_id = d.id and not ok;
  perform app.audit('device.clear_lockout', 'devices', d.id, jsonb_build_object('name', d.name));
end $$;

-- 3. PINs are always picked by the system, so nobody can test which PINs are
--    taken. Owners and people who manage staff or settings get 6 digits.
create or replace function public.set_staff_pin(p_user_id uuid, p_pin text default null)
 returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_me uuid := app.require_permission('user.manage');
  u public.users%rowtype; v_role text; v_pin text; v_len int; i int := 0;
begin
  if nullif(trim(coalesce(p_pin, '')), '') is not null then
    raise exception 'PINs are picked by SNA POS so they stay private and unique. Use "Pick a PIN".';
  end if;
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  select name into v_role from public.roles where id = u.role_id;
  if v_role = 'Owner' and not app.is_owner() and u.id <> v_me then
    raise exception 'Only an owner can set another owner''s PIN.';
  end if;
  v_len := case when v_role = 'Owner' or exists (select 1 from public.role_permissions
                  where role_id = u.role_id and permission_key in ('user.manage', 'settings.manage', 'order.void', 'order.refund'))
                then 6 else 4 end;
  loop
    i := i + 1;
    v_pin := lpad((floor(random() * power(10, v_len)))::bigint::text, v_len, '0');
    exit when v_pin !~ '^(\d)\1+$' and v_pin not in ('1234', '4321', '0123', '9876', '123456', '654321', '012345')
      and not exists (select 1 from public.users where restaurant_id = u.restaurant_id and deleted_at is null
                        and id <> u.id and pin_hash = app.pin_hash(u.restaurant_id, v_pin));
    if i > 500 then raise exception 'Could not find a free PIN. Try again.'; end if;
  end loop;
  update public.users set pin_hash = app.pin_hash(u.restaurant_id, v_pin), pin_set_at = now() where id = u.id;
  delete from public.pin_sessions where user_id = u.id;
  perform app.audit('user.pin_set', 'users', u.id, jsonb_build_object('full_name', u.full_name, 'digits', v_len));
  return jsonb_build_object('user_id', u.id, 'pin', v_pin);
end $$;

-- 4. A reset only counts as done once the person really changed the password.
create or replace function public.admin_reset_password(p_user_id uuid, p_new_password text)
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid := app.require_permission('user.manage'); u public.users%rowtype; v_role text; v_hash text;
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  if u.id = v_me then raise exception 'To change your own password, use Change password.'; end if;
  if u.auth_user_id is null then
    raise exception '% signs in with a PIN only. Pick a new PIN instead.', u.full_name;
  end if;
  select name into v_role from public.roles where id = u.role_id;
  if v_role = 'Owner' and not app.is_owner() then raise exception 'Only an owner can reset another owner''s password.'; end if;
  if length(coalesce(p_new_password, '')) < 8 then raise exception 'Use a password of at least 8 characters.'; end if;
  if length(p_new_password) > 72 then raise exception 'Use a password of at most 72 characters.'; end if;
  v_hash := extensions.crypt(p_new_password, extensions.gen_salt('bf', 10));
  update auth.users set encrypted_password = v_hash, updated_at = now() where id = u.auth_user_id;
  delete from auth.sessions where user_id = u.auth_user_id;
  update public.users set must_change_password = true, password_reset_hash = v_hash where id = u.id;
  perform app.audit('user.password_reset', 'users', u.id, jsonb_build_object('full_name', u.full_name));
end $$;

create or replace function public.password_changed()
 returns void language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare u public.users%rowtype; v_now text;
begin
  select * into u from public.users where auth_user_id = auth.uid() and deleted_at is null;
  if u.id is null then return; end if;
  select encrypted_password into v_now from auth.users where id = auth.uid();
  if u.password_reset_hash is not null and v_now is not distinct from u.password_reset_hash then
    raise exception 'Choose a new password first.';
  end if;
  update public.users set must_change_password = false, password_reset_hash = null where id = u.id;
  insert into public.audit_logs (restaurant_id, user_id, action, entity_type, entity_id, actor_type)
  values (u.restaurant_id, u.id, 'user.password_changed', 'users', u.id, 'user');
end $$;

grant execute on function public.pin_touch(), public.clear_pin_lockout(uuid) to authenticated;
revoke execute on function public.pin_touch(), public.clear_pin_lockout(uuid) from anon;
