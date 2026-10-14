-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928080343, name '35_role_names_case_insensitive'. This is the SQL that actually ran.

create unique index if not exists roles_restaurant_lower_name on public.roles (restaurant_id, lower(btrim(name)));

CREATE OR REPLACE FUNCTION public.save_role(p_role_id uuid, p_name text, p_permissions text[])
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('user.manage');
  v_rest uuid := app.current_restaurant_id();
  v_name text := btrim(coalesce(p_name, ''));
  v_old public.roles;
  v_id uuid;
  v_bad text;
begin
  if not app.is_owner() then raise exception 'Only an owner can change roles and rights.'; end if;
  if v_name = '' or length(v_name) > 40 then raise exception 'Give the role a name (up to 40 letters).'; end if;
  if lower(v_name) = 'owner' then raise exception 'The name Owner is reserved.'; end if;
  if exists (select 1 from public.roles r where r.restaurant_id = v_rest and lower(btrim(r.name)) = lower(v_name)
             and r.id is distinct from p_role_id) then
    raise exception 'A role called % already exists.', v_name;
  end if;
  select string_agg(k, ', ') into v_bad from unnest(coalesce(p_permissions, '{}')) k
   where not exists (select 1 from public.permissions p where p.key = k);
  if v_bad is not null then raise exception 'Unknown right: %', v_bad; end if;

  if p_role_id is not null then
    select * into v_old from public.roles where id = p_role_id and restaurant_id = v_rest for update;
    if not found then raise exception 'Role not found.'; end if;
    if v_old.name = 'Owner' and v_old.is_system then raise exception 'The Owner role always has every right and cannot be changed.'; end if;
    update public.roles set name = v_name where id = p_role_id;
    delete from public.role_permissions where role_id = p_role_id;
    v_id := p_role_id;
  else
    insert into public.roles (restaurant_id, name, is_system) values (v_rest, v_name, false) returning id into v_id;
  end if;

  insert into public.role_permissions (role_id, permission_key)
  select distinct v_id, k from unnest(coalesce(p_permissions, '{}')) k;

  perform app.audit(case when p_role_id is null then 'role.created' else 'role.changed' end, 'role', v_id,
    jsonb_build_object('name', v_name, 'rights', to_jsonb(coalesce(p_permissions, '{}'))),
    case when p_role_id is null then null else jsonb_build_object('name', v_old.name) end);
  return v_id;
exception when unique_violation then
  raise exception 'A role called % already exists.', v_name;
end $function$;
revoke all on function public.save_role(uuid,text,text[]) from public, anon;
grant execute on function public.save_role(uuid,text,text[]) to authenticated;
