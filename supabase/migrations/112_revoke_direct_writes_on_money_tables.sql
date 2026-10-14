-- 112: Signed-in users can no longer write directly to the money, audit and security tables.
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
