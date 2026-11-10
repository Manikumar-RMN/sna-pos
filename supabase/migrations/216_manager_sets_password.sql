-- The manager can type the new person's password on the Add-a-person form (like Winsar), instead of
-- handing out a generated temporary one. When they do, the person keeps that password: they are not
-- made to change it at first sign-in, so the manager can tell them what it is and they can start work.
-- Leaving the password boxes empty keeps the old behaviour: a temporary password that must be changed.
drop function if exists public.create_password_staff(text, uuid, text, uuid);

create or replace function public.create_password_staff(
  p_full_name text,
  p_role_id uuid,
  p_phone text,
  p_auth_user_id uuid,
  p_must_change boolean default true
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := app.require_permission('user.manage'); v_rest uuid := app.current_restaurant_id();
  v_role public.roles%rowtype; v_emp text; v_id uuid := gen_random_uuid(); a record;
  v_change boolean := coalesce(p_must_change, true);
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
  values (v_id, v_rest, p_auth_user_id, v_emp, left(trim(p_full_name), 120), a.email, nullif(trim(p_phone), ''), v_role.id, true,
          v_change, case when v_change then a.encrypted_password else null end);
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (v_id, app.current_branch_id(), v_rest);
  perform app.audit('user.create_password_staff', 'users', v_id,
    jsonb_build_object('full_name', trim(p_full_name), 'role', v_role.name, 'password_set_by_manager', not v_change));
  return jsonb_build_object('user_id', v_id, 'employee_code', v_emp, 'client_code', (select client_code from public.restaurants where id = v_rest));
end $$;
revoke all on function public.create_password_staff(text, uuid, text, uuid, boolean) from public, anon;
grant execute on function public.create_password_staff(text, uuid, text, uuid, boolean) to authenticated;
