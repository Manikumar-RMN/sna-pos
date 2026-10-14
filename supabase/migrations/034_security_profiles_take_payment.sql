-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928074757, name '34_security_profiles_take_payment'. This is the SQL that actually ran.

-- 34: Security profiles (editable roles with tick-box rights) and a separate "Take payment" right.

insert into public.permissions (key, description, is_sensitive)
values ('payment.take', 'Take payment and settle bills', true)
on conflict (key) do nothing;

-- Existing roles that can bill (except stewards/waiters and chefs) keep being able to take payment.
insert into public.role_permissions (role_id, permission_key)
select r.id, 'payment.take' from public.roles r
 where exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = 'order.create')
   and r.name not in ('Waiter', 'Steward', 'Chef')
on conflict do nothing;

-- New restaurants: the preset "Waiter" is called "Steward"; Cashier gets Take payment.
do $mig$
declare d text := pg_get_functiondef('app.create_restaurant_with_owner(text,text,character,text,text,text,text,text)'::regprocedure);
begin
  if position('''Waiter''' in d) = 0 or position('(v_cashier, ''order.create''), ' in d) = 0 then
    raise exception 'create_restaurant_with_owner patch points not found';
  end if;
  d := replace(d, '''Waiter''', '''Steward''');
  d := replace(d, '(v_cashier, ''order.create''), ', '(v_cashier, ''order.create''), (v_cashier, ''payment.take''), ');
  execute d;
end $mig$;

-- Taking money needs the Take payment right.
do $mig$
declare d text := pg_get_functiondef('public.pay_order'::regproc);
begin
  if position('v_user uuid := app.require_permission(''order.create'');' in d) = 0 then raise exception 'pay_order patch point not found'; end if;
  d := replace(d, 'v_user uuid := app.require_permission(''order.create'');', 'v_user uuid := app.require_permission(''payment.take'');');
  execute d;
end $mig$;

do $mig$
declare d text := pg_get_functiondef('public.create_order'::regproc);
  marker text := E'  if p_payment_method_id is not null then\n';
begin
  if (length(d) - length(replace(d, marker, ''))) / length(marker) <> 1 then raise exception 'create_order patch point not unique'; end if;
  d := replace(d, marker, E'  if p_payment_method_id is not null and not app.has_permission(''payment.take'') then\n    raise exception ''You do not have the right to take payment. Save the bill and ask the cashier to settle it.'';\n  end if;\n' || marker);
  execute d;
end $mig$;

-- Create or change a role and its rights. Owner only; the Owner role itself is fixed.
create or replace function public.save_role(p_role_id uuid, p_name text, p_permissions text[])
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
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
end $$;

create or replace function public.delete_role(p_role_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := app.require_permission('user.manage');
  v_old public.roles;
  v_people int;
begin
  if not app.is_owner() then raise exception 'Only an owner can remove roles.'; end if;
  select * into v_old from public.roles where id = p_role_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Role not found.'; end if;
  if v_old.name = 'Owner' and v_old.is_system then raise exception 'The Owner role cannot be removed.'; end if;
  select count(*) into v_people from public.users where role_id = p_role_id and deleted_at is null;
  if v_people > 0 then raise exception 'Move the % people with this role to another role first.', v_people; end if;
  delete from public.roles where id = p_role_id;
  perform app.audit('role.removed', 'role', p_role_id, null, jsonb_build_object('name', v_old.name));
end $$;

revoke all on function public.save_role(uuid, text, text[]) from public, anon;
revoke all on function public.delete_role(uuid) from public, anon;
grant execute on function public.save_role(uuid, text, text[]) to authenticated;
grant execute on function public.delete_role(uuid) to authenticated;
