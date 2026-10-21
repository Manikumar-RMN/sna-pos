-- 127: sign-in no longer reveals which usernames exist (via the lock answer)
--
-- Before: after 5 wrong tries a REAL username answered {"error":"locked","minutes":n} while an
-- unknown username never did, so anyone could tell the two apart. Wrong-password work also took
-- longer than unknown-user work.
-- Now:
--   * a locked real username gets exactly the same {"error":"invalid_credentials"} as an unknown one
--     (no 'locked', no minutes). The lock itself still holds: while it lasts the password is not
--     even checked, so a correct password is refused until the 5 minutes are over.
--   * an unknown client code or username runs a dummy extensions.crypt so the time taken is
--     about the same as for a wrong password.
-- Unchanged: 5 wrong passwords lock the account for 5 minutes; 'inactive' is only answered after
-- a correct password; PIN-only users answer invalid_credentials.
-- Starts from the 076 body of public.login_staff (no later migration redefines it).

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
    perform extensions.crypt(p_password, extensions.gen_salt('bf', 10));
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
    perform extensions.crypt(p_password, extensions.gen_salt('bf', 10));
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  -- Locked: answer exactly as for a wrong password or an unknown username.
  -- (Same work as a wrong password, so the time does not give it away either.)
  if v_user.login_locked_until is not null
     and v_user.login_locked_until > now() then
    perform extensions.crypt(p_password, extensions.gen_salt('bf', 10));
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  -- PIN-only counter staff have no password sign-in. Answer exactly as for a
  -- wrong password, so the reply never says whether a username exists.
  if v_user.auth_user_id is null or v_user.email is null then
    perform extensions.crypt(p_password, extensions.gen_salt('bf', 10));
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

revoke all on function public.login_staff(text, text, text) from public;
grant execute on function public.login_staff(text, text, text) to anon, authenticated;

comment on function public.login_staff(text, text, text) is
  'Verifies client code + username + password and returns the sign-in email so the app can start a Supabase Auth session. Returns {"error": ...} on failure; a locked account answers exactly like a wrong password. Locks an account for 5 minutes after 5 wrong passwords.';
