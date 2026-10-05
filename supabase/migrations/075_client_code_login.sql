-- 075: Client code staff login
--
-- Staff sign in with: client code + username (employee code) + password.
-- Each restaurant has its own client code, so the same username can exist
-- in different restaurants without clashing.
--
-- Notes on the choices here:
--   * Client codes are handed out automatically by a sequence, so every new
--     restaurant gets its own code at signup with no manual step.
--   * Email is required only for people who sign in with a password. PIN-only
--     counter staff (created by create_pin_staff) have no email and no auth
--     account, and must keep working.
--   * The password is checked inside this function so that a caller who does
--     not know it learns nothing -- not even whether the username exists.
--     Because that check bypasses Supabase Auth's own rate limiting, this
--     migration adds its own lockout: 5 wrong passwords locks the account for
--     5 minutes.

------------------------------------------------------------------
-- 1. Client code on restaurants, auto-generated
------------------------------------------------------------------

create sequence if not exists public.restaurant_client_code_seq
  as bigint start with 1000 increment by 1 minvalue 1000 no cycle;

alter table public.restaurants add column if not exists client_code text;
alter table public.restaurants add column if not exists backup_phone text;

-- Give every restaurant that already exists a code, oldest first.
do $$
declare r record;
begin
  for r in
    select id from public.restaurants where client_code is null
    order by created_at, id
  loop
    update public.restaurants
       set client_code = nextval('public.restaurant_client_code_seq')::text
     where id = r.id;
  end loop;
end $$;

-- From now on a new restaurant gets the next free code on insert.
alter table public.restaurants
  alter column client_code set default nextval('public.restaurant_client_code_seq')::text;

alter table public.restaurants
  alter column client_code set not null;

alter sequence public.restaurant_client_code_seq
  owned by public.restaurants.client_code;

-- Unique and fast to look up in one index.
create unique index if not exists restaurants_client_code_key
  on public.restaurants (client_code);

comment on column public.restaurants.client_code is
  'Code staff type at sign-in to identify this restaurant. Assigned automatically from restaurant_client_code_seq, starting at 1000. Four digits until 9999, then five -- the login form accepts 4 to 6.';
comment on column public.restaurants.backup_phone is
  'Owner phone for SMS password recovery (not used yet).';

------------------------------------------------------------------
-- 2. Email: required only for password sign-in
------------------------------------------------------------------
-- A blanket NOT NULL on users.email would break create_pin_staff, which
-- deliberately inserts PIN-only staff with no email and no auth account.

alter table public.users
  drop constraint if exists users_email_required_for_password_login;

alter table public.users
  add constraint users_email_required_for_password_login
  check (auth_user_id is null or email is not null);

------------------------------------------------------------------
-- 3. Lockout counters for password sign-in
------------------------------------------------------------------

alter table public.users
  add column if not exists login_failed_count int not null default 0;
alter table public.users
  add column if not exists login_locked_until timestamptz;

------------------------------------------------------------------
-- 4. The sign-in lookup
------------------------------------------------------------------
-- Lives in public so that supabase.rpc('login_staff', ...) finds it -- the
-- same place as approve_with_pin, pin_unlock and the other RPCs the app calls.
--
-- Returns the sign-in email ONLY once the password has been verified. The app
-- then calls supabase.auth.signInWithPassword with that email to mint the
-- actual session; this function never creates one.

create or replace function public.login_staff(
  p_client_code text,
  p_username    text,
  p_password    text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_rest   uuid;
  v_user   record;
  v_stored text;
  v_wait   int;
begin
  if coalesce(trim(p_client_code), '') = ''
     or coalesce(trim(p_username), '') = ''
     or coalesce(p_password, '') = '' then
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  select id into v_rest
    from public.restaurants
   where client_code = trim(p_client_code);
  if not found then
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  select u.id, u.full_name, u.email::text as email, u.role_id, u.is_active,
         u.must_change_password, u.auth_user_id, u.login_locked_until
    into v_user
    from public.users u
   where u.restaurant_id = v_rest
     and lower(u.employee_code) = lower(trim(p_username))
     and u.deleted_at is null;
  if not found then
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  -- Locked out from earlier wrong passwords?
  if v_user.login_locked_until is not null
     and v_user.login_locked_until > now() then
    v_wait := ceil(extract(epoch from (v_user.login_locked_until - now())) / 60.0);
    return jsonb_build_object('error', 'locked', 'minutes', greatest(v_wait, 1));
  end if;

  -- PIN-only staff have no password sign-in at all.
  if v_user.auth_user_id is null or v_user.email is null then
    return jsonb_build_object('error', 'no_password_login');
  end if;

  select a.encrypted_password into v_stored
    from auth.users a
   where a.id = v_user.auth_user_id;

  if v_stored is null
     or v_stored <> extensions.crypt(p_password, v_stored) then
    -- Wrong password: count it, and lock the account at the fifth try.
    -- Postgres evaluates every SET expression against the old row, so both
    -- branches below agree on what "one more failure" means.
    update public.users
       set login_failed_count = case
             when login_failed_count + 1 >= 5 then 0
             else login_failed_count + 1
           end,
           login_locked_until = case
             when login_failed_count + 1 >= 5 then now() + interval '5 minutes'
             else login_locked_until
           end
     where id = v_user.id;
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  if not v_user.is_active then
    return jsonb_build_object('error', 'inactive');
  end if;

  -- Correct password: clear the counters.
  update public.users
     set login_failed_count = 0,
         login_locked_until = null
   where id = v_user.id;

  return jsonb_build_object(
    'email',                v_user.email,
    'user_id',              v_user.id,
    'restaurant_id',        v_rest,
    'full_name',            v_user.full_name,
    'must_change_password', coalesce(v_user.must_change_password, false)
  );
exception when others then
  -- Fail closed: never let an internal error reveal anything about the account.
  return jsonb_build_object('error', 'invalid_credentials');
end $$;

revoke all on function public.login_staff(text, text, text) from public;
grant execute on function public.login_staff(text, text, text) to anon, authenticated;

comment on function public.login_staff(text, text, text) is
  'Verifies client code + username + password and returns the sign-in email so the app can start a Supabase Auth session. Returns {"error": ...} on any failure. Locks an account for 5 minutes after 5 wrong passwords.';
