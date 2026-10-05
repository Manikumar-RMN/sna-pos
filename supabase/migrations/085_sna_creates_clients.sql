-- 085: restaurants are created by SNA staff, not by public sign-up
--
-- Founder's rule (5 Oct 2026): the support team does the sign-up. There is no
-- trial and no self-service restaurant.
--
--   * public.sna_create_client: SNA staff create a restaurant for an owner's
--     sign-in. The sign-in itself is made by the app through the normal
--     sign-up call just before; this function finds it by email, gives it the
--     temporary password SNA will pass on, and builds the restaurant with the
--     same code that built every restaurant so far (app.create_restaurant_with_owner).
--   * The self-service door is closed: signed-in people can no longer call
--     public.create_restaurant_with_owner. Joining a restaurant with an invite
--     code (claim_staff_invite) is unchanged.
--
-- No existing function is replaced.

begin;

create function public.sna_create_client(
  p_owner_email text, p_owner_name text, p_legal_name text, p_trading_name text, p_country_code text,
  p_temp_password text,
  p_branch_name text default 'Main Branch', p_branch_code text default 'MN', p_tax_registration_no text default null,
  p_edition text default 'basic', p_licence_start date default null, p_licence_expiry date default null
) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_me uuid; v_auth uuid; v_rest uuid; v_hash text; v_is_sna boolean;
  v_email text := lower(trim(coalesce(p_owner_email, '')));
  v_owner text := trim(coalesce(p_owner_name, ''));
  v_legal text := trim(coalesce(p_legal_name, ''));
  v_trading text := trim(coalesce(p_trading_name, ''));
  v_branch text := coalesce(nullif(trim(coalesce(p_branch_name, '')), ''), 'Main Branch');
  v_code text := upper(coalesce(nullif(trim(coalesce(p_branch_code, '')), ''), 'MN'));
  v_claims text; v_sub text;
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  -- Edition and licence dates are a sales matter, as they are on the client page.
  if coalesce(p_edition, 'basic') <> 'basic' or p_licence_start is not null or p_licence_expiry is not null then
    perform app.sna_require(array['sales']);
  end if;
  if coalesce(p_edition, 'basic') not in ('basic', 'professional') then raise exception 'Unknown edition.'; end if;
  if p_licence_start is not null and p_licence_expiry is not null and p_licence_expiry < p_licence_start then
    raise exception 'The licence cannot end before it starts.';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(v_email) > 200 then raise exception 'Enter the owner''s email address.'; end if;
  if length(v_owner) = 0 or length(v_legal) = 0 or length(v_trading) = 0 then raise exception 'Fill in the business name, the display name and the owner''s name.'; end if;
  if length(v_owner) > 120 or length(v_legal) > 200 or length(v_trading) > 200 or length(v_branch) > 120 then raise exception 'One of the names is too long.'; end if;
  if v_code !~ '^[A-Z0-9]{2,4}$' then raise exception 'The outlet code is 2 to 4 letters or digits, for example MN.'; end if;

  select id into v_auth from auth.users where lower(email) = v_email;
  if v_auth is null then raise exception 'The sign-in for % could not be made. Try again.', v_email; end if;
  if exists (select 1 from public.devices where auth_user_id = v_auth) then raise exception 'That email belongs to a counter tablet.'; end if;
  if exists (select 1 from public.users where auth_user_id = v_auth and deleted_at is null) then
    raise exception '% already belongs to a restaurant. Use a different email for this owner.', v_email;
  end if;
  v_is_sna := exists (select 1 from public.sna_staff where auth_user_id = v_auth);

  -- The owner gets the temporary password SNA hands over, whoever made the sign-in and whenever:
  -- an address someone else registered first must not keep that person's password.
  -- An SNA staff member testing with their own address keeps their own password.
  if not v_is_sna then
    if length(coalesce(p_temp_password, '')) < 8 or length(p_temp_password) > 72 then raise exception 'The temporary password must be 8 to 72 characters.'; end if;
    v_hash := extensions.crypt(p_temp_password, extensions.gen_salt('bf', 10));
    update auth.users set encrypted_password = v_hash, email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now() where id = v_auth;
    delete from auth.sessions where user_id = v_auth;
  end if;

  -- Build the restaurant exactly as a sign-up always has: as the owner, for this one call.
  v_claims := current_setting('request.jwt.claims', true);
  v_sub := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_auth::text, true);
  v_rest := app.create_restaurant_with_owner(v_legal, v_trading, p_country_code::character(2), v_owner, v_branch, v_code, null, p_tax_registration_no);
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
  if app.sna_staff_id() is distinct from v_me then raise exception 'Could not finish creating the client.'; end if;

  if p_edition = 'professional' then update public.restaurants set edition = 'professional' where id = v_rest; end if;
  update public.restaurants set subscription_status = 'active' where id = v_rest;
  insert into public.sna_accounts (restaurant_id, licence_start, licence_expiry, updated_by)
  values (v_rest, p_licence_start, p_licence_expiry, v_me);
  if not v_is_sna then
    update public.users set must_change_password = true, password_reset_hash = v_hash where restaurant_id = v_rest and auth_user_id = v_auth;
  end if;
  perform app.log_plan(v_rest, 'client.created', jsonb_strip_nulls(jsonb_build_object(
    'owner', v_email, 'edition', coalesce(p_edition, 'basic'), 'licence_start', p_licence_start, 'licence_expiry', p_licence_expiry)));

  return jsonb_build_object('id', v_rest, 'client_code', (select client_code from public.restaurants where id = v_rest),
                            'owner_email', v_email, 'kept_password', v_is_sna);
end $$;

revoke all on function public.sna_create_client(text, text, text, text, text, text, text, text, text, text, date, date) from public, anon;
grant execute on function public.sna_create_client(text, text, text, text, text, text, text, text, text, text, date, date) to authenticated, service_role;

-- The self-service door: closed. (SNA's function above calls the inner builder directly.)
revoke execute on function public.create_restaurant_with_owner(text, text, character, text, text, text, text, text) from public, anon, authenticated;

commit;
