-- ONE-OFF SCRIPT for the live database (Supabase project lrtoktmfspnypkgrvnzg). Paste into the SQL editor and run once.
-- Safe to run again: every step checks first.
--
--   1. Records migration 112 in Supabase's history table. Its change (a function and a trigger) is ALREADY live; this adds only the history row.
--   2. Applies migration 113: takes INSERT/UPDATE/DELETE/TRUNCATE away from signed-in users on 28 money, audit and permission tables
--      (reads stay). The app never writes to these tables directly, so nothing should change for staff.
--   3. Records 113 in the history table.
-- Everything runs as one transaction: if anything fails, nothing is changed.
--
-- To undo 113 for one table:  grant insert, update, delete on public.<table> to authenticated;

begin;

-- 1. Record 112 (already in effect).
insert into supabase_migrations.schema_migrations (version, name, statements)
select to_char(clock_timestamp() at time zone 'utc', 'YYYYMMDDHH24MISS'), '112_whole_number_check_for_piece_items', array[$sql112$
-- 112: Captured from the live database; ALREADY APPLIED THERE (it was changed directly, outside the migration history).
--
-- Items sold by the piece must be a whole number, and that is checked when a bill line is added AND when its
-- quantity is changed later. Migration 097 created the function and the INSERT trigger without the whole-number
-- rule and without the UPDATE trigger; the live database has both. Written so that running it again changes nothing.

CREATE OR REPLACE FUNCTION app.trg_order_item_unit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_by text;
begin
  select sold_by into v_by from public.products where id = new.product_id;
  if v_by = 'weight' then
    new.unit := 'kg';
    if new.quantity < 0.005 then raise exception 'Weigh % again: the weight is too small.', new.product_name; end if;
  else
    new.unit := null;
    if new.quantity <> trunc(new.quantity) then
      raise exception '% is sold by the piece: enter a whole number.', new.product_name;
    end if;
  end if;
  return new;
end $function$;

DROP TRIGGER IF EXISTS trg_order_item_unit_upd ON public.order_items;
CREATE TRIGGER trg_order_item_unit_upd BEFORE UPDATE OF quantity ON public.order_items
  FOR EACH ROW WHEN (new.quantity IS DISTINCT FROM old.quantity) EXECUTE FUNCTION app.trg_order_item_unit();
$sql112$]
where not exists (select 1 from supabase_migrations.schema_migrations where name = '112_whole_number_check_for_piece_items')
  and exists (select 1 from pg_trigger where tgname = 'trg_order_item_unit_upd');

-- 2. Apply 113.
-- 113: Signed-in users can no longer write directly to the money, audit and security tables.
--
-- Why: the `authenticated` role held INSERT/UPDATE/DELETE/TRUNCATE on these tables. Row Level Security
-- already blocks the writes (these tables have no write policy), so nothing changes for the app today;
-- but that meant ONE careless policy added later would expose bills, payments, credit notes, the audit
-- log or the permission tables. Every change to them goes through a SECURITY DEFINER function, which
-- does not use these grants. Same pattern as migration 108.
--
-- Checked before writing this: the app writes directly (supabase.from(...).insert/update/delete) to only
-- categories, dining_tables, modifier_groups, modifier_items, payment_methods, product_modifier_groups and
-- products, and every one of those has its own write policy. None of them is touched here. Tables that keep
-- write grants: agent_*, branch_settings, branches, categories, customers, dining_tables, floors,
-- modifier_*, payment_methods, printers, product_modifier_groups, products, sync_log, tax_*.
--
-- SELECT is kept (reads stay governed by RLS). service_role and the table owner are unaffected.
-- To undo for one table:  grant insert, update, delete on public.<table> to authenticated;

revoke insert, update, delete, truncate, references, trigger on
  public.agent_usage, public.audit_logs, public.business_days, public.cash_movements, public.countries, public.credit_notes, public.currencies, public.devices, public.ingredients, public.kitchen_ticket_items, public.kitchen_tickets, public.order_discounts, public.order_item_modifiers, public.order_item_taxes, public.order_items, public.orders, public.payments, public.permissions, public.recipe_lines, public.refunds, public.restaurants, public.role_permissions, public.roles, public.shifts, public.stock_movements, public.user_branches, public.v_current_user, public.v_menu
from anon, authenticated;

-- Post-check: nothing left with write rights on the tables above. Raises (and rolls back) if not.
do $$
declare bad text;
begin
  select string_agg(table_name || ':' || privilege_type, ', ') into bad
    from information_schema.role_table_grants
   where table_schema = 'public' and grantee in ('anon', 'authenticated')
     and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
     and table_name in ('agent_usage', 'audit_logs', 'business_days', 'cash_movements', 'countries', 'credit_notes', 'currencies', 'devices', 'ingredients', 'kitchen_ticket_items', 'kitchen_tickets', 'order_discounts', 'order_item_modifiers', 'order_item_taxes', 'order_items', 'orders', 'payments', 'permissions', 'recipe_lines', 'refunds', 'restaurants', 'role_permissions', 'roles', 'shifts', 'stock_movements', 'user_branches', 'v_current_user', 'v_menu');
  if bad is not null then raise exception 'Revoke did not take effect: %', bad; end if;
end $$;

-- 3. Record 113 (a second later, so the version numbers stay in order).
insert into supabase_migrations.schema_migrations (version, name, statements)
select to_char(clock_timestamp() at time zone 'utc' + interval '1 second', 'YYYYMMDDHH24MISS'), '113_revoke_direct_writes_on_money_tables', array[$sql113$
-- 113: Signed-in users can no longer write directly to the money, audit and security tables.
--
-- Why: the `authenticated` role held INSERT/UPDATE/DELETE/TRUNCATE on these tables. Row Level Security
-- already blocks the writes (these tables have no write policy), so nothing changes for the app today;
-- but that meant ONE careless policy added later would expose bills, payments, credit notes, the audit
-- log or the permission tables. Every change to them goes through a SECURITY DEFINER function, which
-- does not use these grants. Same pattern as migration 108.
--
-- Checked before writing this: the app writes directly (supabase.from(...).insert/update/delete) to only
-- categories, dining_tables, modifier_groups, modifier_items, payment_methods, product_modifier_groups and
-- products, and every one of those has its own write policy. None of them is touched here. Tables that keep
-- write grants: agent_*, branch_settings, branches, categories, customers, dining_tables, floors,
-- modifier_*, payment_methods, printers, product_modifier_groups, products, sync_log, tax_*.
--
-- SELECT is kept (reads stay governed by RLS). service_role and the table owner are unaffected.
-- To undo for one table:  grant insert, update, delete on public.<table> to authenticated;

revoke insert, update, delete, truncate, references, trigger on
  public.agent_usage, public.audit_logs, public.business_days, public.cash_movements, public.countries, public.credit_notes, public.currencies, public.devices, public.ingredients, public.kitchen_ticket_items, public.kitchen_tickets, public.order_discounts, public.order_item_modifiers, public.order_item_taxes, public.order_items, public.orders, public.payments, public.permissions, public.recipe_lines, public.refunds, public.restaurants, public.role_permissions, public.roles, public.shifts, public.stock_movements, public.user_branches, public.v_current_user, public.v_menu
from anon, authenticated;

-- Post-check: nothing left with write rights on the tables above. Raises (and rolls back) if not.
do $$
declare bad text;
begin
  select string_agg(table_name || ':' || privilege_type, ', ') into bad
    from information_schema.role_table_grants
   where table_schema = 'public' and grantee in ('anon', 'authenticated')
     and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
     and table_name in ('agent_usage', 'audit_logs', 'business_days', 'cash_movements', 'countries', 'credit_notes', 'currencies', 'devices', 'ingredients', 'kitchen_ticket_items', 'kitchen_tickets', 'order_discounts', 'order_item_modifiers', 'order_item_taxes', 'order_items', 'orders', 'payments', 'permissions', 'recipe_lines', 'refunds', 'restaurants', 'role_permissions', 'roles', 'shifts', 'stock_movements', 'user_branches', 'v_current_user', 'v_menu');
  if bad is not null then raise exception 'Revoke did not take effect: %', bad; end if;
end $$;
$sql113$]
where not exists (select 1 from supabase_migrations.schema_migrations where name = '113_revoke_direct_writes_on_money_tables');

commit;

-- Check afterwards (should list 112 and 113, and 20 tables still writable):
-- select version, name from supabase_migrations.schema_migrations where version > '20261013045224' order by version;
-- select count(distinct table_name) from information_schema.role_table_grants where table_schema = 'public' and grantee = 'authenticated' and privilege_type in ('INSERT','UPDATE','DELETE');
