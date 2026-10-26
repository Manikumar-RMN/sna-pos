-- 137: copy rights between roles, copy access between people
--
-- Every person holds ONE role (there are no per-person overrides), so "copy someone's permissions" means two things:
--   copy_role_rights(from_role, to_role, mode)  'add' (union) or 'replace': give a profile the rights of another.
--       Owner only. The Owner role is NEVER the target (it always keeps every right), nor may a role copy from itself.
--       Audit `role.rights_copied` with what was added and removed.
--   copy_staff_access(from_user, to_user)       give a person the same ROLE and the same OUTLETS as another person.
--       Needs user.manage. Same guards as update_staff: not yourself, only an owner may change an owner. Access is
--       never copied FROM or TO an owner (make an owner on the Users page, as before). Audit `user.access_copied`.
-- No table changes. Additive: two new functions. Roll back: drop function public.copy_role_rights(uuid,uuid,text), public.copy_staff_access(uuid,uuid);

create or replace function public.copy_role_rights(p_from_role uuid, p_to_role uuid, p_mode text default 'add')
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_rest uuid := app.current_restaurant_id();
  f public.roles%rowtype; t public.roles%rowtype;
  v_added text[]; v_removed text[]; v_total int;
begin
  perform app.require_permission('user.manage');
  if not app.is_owner() then raise exception 'Only an owner can change roles and rights.'; end if;
  if p_mode is null or p_mode not in ('add', 'replace') then raise exception 'Choose add or replace.'; end if;
  select * into f from public.roles where id = p_from_role and restaurant_id = v_rest;
  if not found then raise exception 'The role to copy from was not found.'; end if;
  select * into t from public.roles where id = p_to_role and restaurant_id = v_rest for update;
  if not found then raise exception 'The role to copy to was not found.'; end if;
  if t.name = 'Owner' and t.is_system then raise exception 'The Owner role always has every right and cannot be changed.'; end if;
  if f.id = t.id then raise exception 'Choose a different role to copy from.'; end if;

  select coalesce(array_agg(rp.permission_key order by rp.permission_key), '{}') into v_added
    from public.role_permissions rp
   where rp.role_id = f.id and not exists (select 1 from public.role_permissions x where x.role_id = t.id and x.permission_key = rp.permission_key);
  select coalesce(array_agg(x.permission_key order by x.permission_key), '{}') into v_removed
    from public.role_permissions x
   where p_mode = 'replace' and x.role_id = t.id and not exists (select 1 from public.role_permissions rp where rp.role_id = f.id and rp.permission_key = x.permission_key);

  if p_mode = 'replace' then
    delete from public.role_permissions x
     where x.role_id = t.id and not exists (select 1 from public.role_permissions rp where rp.role_id = f.id and rp.permission_key = x.permission_key);
  end if;
  insert into public.role_permissions (role_id, permission_key)
  select t.id, rp.permission_key from public.role_permissions rp where rp.role_id = f.id on conflict do nothing;
  select count(*) into v_total from public.role_permissions where role_id = t.id;

  perform app.audit('role.rights_copied', 'role', t.id,
    jsonb_build_object('name', t.name, 'from_role', f.name, 'from_role_id', f.id, 'mode', p_mode, 'added', to_jsonb(v_added), 'removed', to_jsonb(v_removed), 'rights', v_total));
  return jsonb_build_object('role_id', t.id, 'mode', p_mode, 'added', to_jsonb(v_added), 'removed', to_jsonb(v_removed), 'total', v_total);
end $$;

create or replace function public.copy_staff_access(p_from_user uuid, p_to_user uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_rest uuid := app.current_restaurant_id(); v_me uuid;
  f public.users%rowtype; t public.users%rowtype;
  fr public.roles%rowtype; tr public.roles%rowtype;
  v_outlets uuid[];
begin
  v_me := app.require_permission('user.manage');
  select * into f from public.users where id = p_from_user and restaurant_id = v_rest and deleted_at is null;
  if not found then raise exception 'The person to copy from was not found.'; end if;
  select * into t from public.users where id = p_to_user and restaurant_id = v_rest and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  if t.id = v_me then raise exception 'You cannot change your own role or access.'; end if;
  if f.id = t.id then raise exception 'Choose a different person to copy from.'; end if;
  select * into fr from public.roles where id = f.role_id;
  select * into tr from public.roles where id = t.role_id;
  if tr.name = 'Owner' and tr.is_system then raise exception 'Access is not copied onto an owner.'; end if;
  if fr.name = 'Owner' and fr.is_system then raise exception 'Access is not copied from an owner. To make someone an owner, change their role on the Users page.'; end if;

  select coalesce(array_agg(ub.branch_id order by ub.branch_id), '{}') into v_outlets from public.user_branches ub where ub.user_id = f.id;
  update public.users set role_id = f.role_id where id = t.id;
  delete from public.user_branches where user_id = t.id and not (branch_id = any(v_outlets));
  insert into public.user_branches (user_id, branch_id, restaurant_id)
  select t.id, x, v_rest from unnest(v_outlets) x on conflict do nothing;

  perform app.audit('user.access_copied', 'users', t.id,
    jsonb_build_object('role', fr.name, 'from_user', f.full_name, 'from_user_id', f.id, 'outlets', to_jsonb(v_outlets), 'all_outlets', cardinality(v_outlets) = 0),
    jsonb_build_object('role', tr.name));
  return jsonb_build_object('user_id', t.id, 'role', fr.name, 'outlets', to_jsonb(v_outlets), 'all_outlets', cardinality(v_outlets) = 0);
end $$;

revoke all on function public.copy_role_rights(uuid, uuid, text), public.copy_staff_access(uuid, uuid) from public, anon;
grant execute on function public.copy_role_rights(uuid, uuid, text), public.copy_staff_access(uuid, uuid) to authenticated;
