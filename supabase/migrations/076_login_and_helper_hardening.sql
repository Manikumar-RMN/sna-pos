-- 076: sign-in and helper hardening
--
-- 1. login_staff no longer tells a caller that a username exists but is
--    PIN-only; every wrong combination gets the same answer.
-- 2. Two internal helpers (app.z_report, app.open_business_day) could be run
--    by any signed-in person and take a day or branch id with no check that
--    it belongs to their restaurant. Nothing in the app calls them directly --
--    the public functions that use them run as the owner -- so direct use is
--    switched off.

CREATE OR REPLACE FUNCTION public.login_staff(p_client_code text, p_username text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  if v_user.login_locked_until is not null
     and v_user.login_locked_until > now() then
    v_wait := ceil(extract(epoch from (v_user.login_locked_until - now())) / 60.0);
    return jsonb_build_object('error', 'locked', 'minutes', greatest(v_wait, 1));
  end if;

  -- PIN-only counter staff have no password sign-in. Answer exactly as for a
  -- wrong password, so the reply never says whether a username exists.
  if v_user.auth_user_id is null or v_user.email is null then
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  select a.encrypted_password into v_stored
    from auth.users a
   where a.id = v_user.auth_user_id;

  if v_stored is null
     or v_stored <> extensions.crypt(p_password, v_stored) then
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
  return jsonb_build_object('error', 'invalid_credentials');
end $function$;

revoke execute on function app.z_report(uuid) from public, anon, authenticated;
revoke execute on function app.open_business_day(uuid) from public, anon, authenticated;
