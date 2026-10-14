-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260924095609, name 'sna_pos_12_permission_aware_rls'. This is the SQL that actually ran.

-- SNA POS migration 12: role-aware Row Level Security.
--
-- Before this migration every table had one policy: "same restaurant, any
-- operation". That isolated tenants from each other, but inside a restaurant
-- any signed-in person could write anything through the API - a Cashier could
-- promote themselves to Owner, void a bill or rewrite settings, bypassing the
-- permission checks in the application.
--
-- After it:
--   * Money, staff and audit tables are READ-ONLY to signed-in users. Every
--     write goes through a SECURITY DEFINER function that checks the caller's
--     permission and writes the audit log.
--   * Configuration tables can be written directly, but only by someone who
--     holds the matching permission (menu.manage, tax.manage, settings.manage,
--     customer.manage, agent.configure).

-- ---------------------------------------------------------------------------
-- 1. Drop the old blanket policies for the authenticated role.
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'orders','order_items','order_item_taxes','order_item_modifiers','order_discounts',
    'payments','refunds','shifts','cash_movements','audit_logs',
    'users','roles','role_permissions','user_branches','devices','restaurants',
    'kitchen_tickets','kitchen_ticket_items','agent_usage','agent_actions',
    'categories','products','modifier_groups','modifier_items','product_modifier_groups',
    'tax_groups','tax_rates','tax_rate_components',
    'branches','branch_settings','printers','payment_methods','floors','dining_tables',
    'customers','agent_settings'
  ] loop
    execute format('drop policy if exists tenant_isolation on public.%I', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Read-only tables: select within your own restaurant, no direct writes.
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'orders','order_items','order_item_taxes','order_item_modifiers','order_discounts',
    'payments','refunds','shifts','cash_movements','audit_logs',
    'users','roles','user_branches','devices',
    'kitchen_tickets','kitchen_ticket_items','agent_usage','agent_actions'
  ] loop
    execute format(
      'create policy tenant_read on public.%I for select to authenticated
         using (restaurant_id = (select app.current_restaurant_id()))', t);
  end loop;
end $$;

create policy tenant_read on public.restaurants for select to authenticated
  using (id = (select app.current_restaurant_id()));

create policy tenant_read on public.role_permissions for select to authenticated
  using (exists (select 1 from public.roles r
                 where r.id = role_permissions.role_id
                   and r.restaurant_id = (select app.current_restaurant_id())));

-- ---------------------------------------------------------------------------
-- 3. Configuration tables: read within your restaurant; write only with the
--    matching permission.
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('categories','menu.manage'), ('products','menu.manage'),
      ('modifier_groups','menu.manage'), ('modifier_items','menu.manage'),
      ('product_modifier_groups','menu.manage'),
      ('tax_groups','tax.manage'), ('tax_rates','tax.manage'),
      ('tax_rate_components','tax.manage'),
      ('branches','settings.manage'), ('branch_settings','settings.manage'),
      ('printers','settings.manage'), ('payment_methods','settings.manage'),
      ('floors','settings.manage'), ('dining_tables','settings.manage'),
      ('customers','customer.manage'),
      ('agent_settings','agent.configure')
    ) as v(tbl, perm)
  loop
    execute format(
      'create policy tenant_read on public.%I for select to authenticated
         using (restaurant_id = (select app.current_restaurant_id()))', r.tbl);
    execute format(
      'create policy perm_insert on public.%I for insert to authenticated
         with check (restaurant_id = (select app.current_restaurant_id())
                     and (select app.has_permission(%L)))', r.tbl, r.perm);
    execute format(
      'create policy perm_update on public.%I for update to authenticated
         using (restaurant_id = (select app.current_restaurant_id())
                and (select app.has_permission(%L)))
         with check (restaurant_id = (select app.current_restaurant_id())
                     and (select app.has_permission(%L)))', r.tbl, r.perm, r.perm);
    execute format(
      'create policy perm_delete on public.%I for delete to authenticated
         using (restaurant_id = (select app.current_restaurant_id())
                and (select app.has_permission(%L)))', r.tbl, r.perm);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Shared helpers for the write functions that follow.
-- ---------------------------------------------------------------------------
create or replace function app.current_user_id()
returns uuid language sql stable security definer
set search_path = public, pg_temp as $$
  select u.id from public.users u
  where u.auth_user_id = auth.uid() and u.deleted_at is null and u.is_active
  limit 1
$$;

create or replace function app.current_branch_id()
returns uuid language sql stable security definer
set search_path = public, pg_temp as $$
  select b.id from public.branches b
  where b.restaurant_id = app.current_restaurant_id() and b.deleted_at is null
  order by b.created_at limit 1
$$;

create or replace function app.is_owner()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.users u join public.roles r on r.id = u.role_id
    where u.auth_user_id = auth.uid() and u.deleted_at is null and u.is_active
      and r.name = 'Owner' and r.is_system)
$$;

-- Raises unless the caller belongs to a restaurant and holds the permission.
-- Returns the caller's public.users id.
create or replace function app.require_permission(p_key text)
returns uuid language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if app.current_restaurant_id() is null then
    raise exception 'You are not signed in to a restaurant.';
  end if;
  if not app.has_permission(p_key) then
    raise exception 'Your role does not allow this action (%).', p_key;
  end if;
  return app.current_user_id();
end $$;

create or replace function app.audit(
  p_action text, p_entity text, p_entity_id uuid,
  p_new jsonb default null, p_old jsonb default null)
returns void language sql security definer
set search_path = public, pg_temp as $$
  insert into public.audit_logs
    (restaurant_id, branch_id, user_id, action, entity_type, entity_id,
     actor_type, old_value, new_value)
  values
    (app.current_restaurant_id(), app.current_branch_id(), app.current_user_id(),
     p_action, p_entity, p_entity_id, 'user', p_old, p_new)
$$;

revoke all on function app.current_user_id(), app.current_branch_id(), app.is_owner(),
  app.require_permission(text), app.audit(text,text,uuid,jsonb,jsonb) from public;
grant execute on function app.current_user_id(), app.current_branch_id(), app.is_owner(),
  app.require_permission(text) to authenticated;

-- The bootstrap wrapper must never be callable anonymously.
revoke execute on function public.create_restaurant_with_owner from anon;
