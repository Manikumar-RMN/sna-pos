-- 212: who may hold which rights, and who may approve.
-- Rule 1 (RMS-style simple roles): a PIN-only person (counter tablet) can only hold counter rights.
--   Rights that run the back office -- stock.manage, settings.manage, user.manage, tax.manage -- need a personal sign-in.
-- Rule 2 (Winsar-style approval authority): an approver of purchase orders must be able to sign in and hold stock.manage.
-- Rule 3 (Winsar-style user code + password): staff without an email get a user code (EMPnnn) and a temporary password.

create or replace function app.role_is_backoffice(p_role uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.role_permissions rp
                  where rp.role_id = p_role and rp.permission_key in ('stock.manage', 'settings.manage', 'user.manage', 'tax.manage'))
$$;
revoke all on function app.role_is_backoffice(uuid) from public, anon;
grant execute on function app.role_is_backoffice(uuid) to authenticated;

do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.create_pin_staff(text,uuid,text)'::regprocedure); o := d;
  d := replace(d, E'if v_role.name = ''Owner'' then raise exception ''An owner needs an email sign-in, not only a PIN.''; end if;',
    E'if v_role.name = ''Owner'' then raise exception ''An owner needs an email sign-in, not only a PIN.''; end if;\n  if app.role_is_backoffice(v_role.id) then raise exception ''The % role runs purchasing, stock or settings, so the person needs a personal sign-in. Use "Add a staff member" or "Add staff with a user code and password" instead of a PIN-only counter login.'', v_role.name; end if;');
  if d = o then raise exception 'create_pin_staff anchor changed'; end if;
  execute d;

  d := pg_get_functiondef('public.update_staff(uuid,uuid,boolean)'::regprocedure); o := d;
  d := replace(d, E'    update public.users set role_id = v_new_role.id where id = u.id;',
    E'    if u.auth_user_id is null and u.email is null and app.role_is_backoffice(v_new_role.id) then\n      raise exception ''% only has a counter PIN. The % role runs purchasing, stock or settings, so they need a personal sign-in first.'', u.full_name, v_new_role.name;\n    end if;\n    update public.users set role_id = v_new_role.id where id = u.id;');
  if d = o then raise exception 'update_staff anchor changed'; end if;
  execute d;

  d := pg_get_functiondef('public.set_approval_levels(jsonb,boolean)'::regprocedure); o := d;
  d := replace(d, E'    insert into public.purchase_approval_levels (restaurant_id, level, min_amount, approver_id) values (v_rest, v_lv, v_min, v_ap);',
    E'    if not exists (select 1 from public.users u where u.id = v_ap and u.auth_user_id is not null) then\n      raise exception ''% cannot sign in yet, so cannot approve level %. Give them a personal sign-in first.'', (select full_name from public.users where id = v_ap), v_lv;\n    end if;\n    if not exists (select 1 from public.users u join public.role_permissions rp on rp.role_id = u.role_id and rp.permission_key = ''stock.manage'' where u.id = v_ap) then\n      raise exception ''% does not have the purchasing right, so cannot approve level %.'', (select full_name from public.users where id = v_ap), v_lv;\n    end if;\n    insert into public.purchase_approval_levels (restaurant_id, level, min_amount, approver_id) values (v_rest, v_lv, v_min, v_ap);');
  if d = o then raise exception 'set_approval_levels anchor changed'; end if;
  execute d;
end $$;
revoke all on function public.create_pin_staff(text, uuid, text) from public, anon;
grant execute on function public.create_pin_staff(text, uuid, text) to authenticated;
revoke all on function public.update_staff(uuid, uuid, boolean) from public, anon;
grant execute on function public.update_staff(uuid, uuid, boolean) to authenticated;
revoke all on function public.set_approval_levels(jsonb, boolean) from public, anon;
grant execute on function public.set_approval_levels(jsonb, boolean) to authenticated;

-- Staff with a user code and a temporary password (no email). The app creates the sign-in with a made-up address
-- (staff-<id>@staff.sna-pos.app) and passes its id here; this checks it was made a moment ago and is unused.
create or replace function public.create_password_staff(p_full_name text, p_role_id uuid, p_phone text, p_auth_user_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := app.require_permission('user.manage'); v_rest uuid := app.current_restaurant_id();
  v_role public.roles%rowtype; v_emp text; v_id uuid := gen_random_uuid(); a record;
begin
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Enter the staff member''s name.'; end if;
  select * into v_role from public.roles where id = p_role_id and restaurant_id = v_rest;
  if not found then raise exception 'Choose a role.'; end if;
  if v_role.name = 'Owner' and not app.is_owner() then raise exception 'Only an owner can add another owner.'; end if;
  select id, email, encrypted_password, created_at into a from auth.users where id = p_auth_user_id;
  if not found or a.email not like 'staff-%@staff.sna-pos.app' or a.created_at < now() - interval '10 minutes' then
    raise exception 'The sign-in could not be verified. Try again.';
  end if;
  if exists (select 1 from public.users where auth_user_id = p_auth_user_id)
     or exists (select 1 from public.devices where auth_user_id = p_auth_user_id) then
    raise exception 'That sign-in is already in use.';
  end if;
  select 'EMP' || lpad((coalesce(max(nullif(regexp_replace(employee_code, '\D', '', 'g'), '')::int), 0) + 1)::text, 3, '0')
    into v_emp from public.users where restaurant_id = v_rest;
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, email, phone, role_id, is_active, must_change_password, password_reset_hash)
  values (v_id, v_rest, p_auth_user_id, v_emp, left(trim(p_full_name), 120), a.email, nullif(trim(p_phone), ''), v_role.id, true, true, a.encrypted_password);
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (v_id, app.current_branch_id(), v_rest);
  perform app.audit('user.create_password_staff', 'users', v_id, jsonb_build_object('full_name', trim(p_full_name), 'role', v_role.name));
  return jsonb_build_object('user_id', v_id, 'employee_code', v_emp, 'client_code', (select client_code from public.restaurants where id = v_rest));
end $$;
revoke all on function public.create_password_staff(text, uuid, text, uuid) from public, anon;
grant execute on function public.create_password_staff(text, uuid, text, uuid) to authenticated;
