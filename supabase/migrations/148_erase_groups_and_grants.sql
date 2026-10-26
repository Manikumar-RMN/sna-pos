-- 148: the closing pass of the batch: (1) the "erase test data" lists, (2) the right grants, (3) new restaurants, (4) a sanity check that raises if anything is missing.
--
-- (1) app.erase_groups (139) learns the two tables 143 creates for stock counts: stock_count_lines and stock_counts join 'stock_tx' (lines before the header,
--     both before 'stock_movements'; app.erase_tables retries on foreign-key errors, so the order is only a help). 141-147 added NO new table of customers or
--     loyalty (columns, functions and policies only), so 'pos_master' / 'pos_tx' are unchanged. NOTE: sna_erase / sna_erase_preview run
--     "delete from public.<name>" for every name in the lists, so this file REFUSES to run when 143 has not created the two tables.
-- (2) Grants (idempotent, safe to repeat; 143 and 145 grant too, this is the single place that proves it):
--       customer.view     -> system roles Owner, Manager, Cashier and every role that has customer.manage
--       loyalty.redeem    -> system roles Owner, Manager, Cashier
--       stock.view, stock.adjust -> every role that has stock.manage, and the system roles Chef and Owner
-- (3) New restaurants: app.create_restaurant_with_owner gives the Owner every right and the Manager every right except tax/settings/agent, so both get the new
--     rights by themselves. The Cashier gets customer.view + loyalty.redeem, the Steward customer.view (as every role with customer.manage): text patch of the live function, only if not patched yet. The Chef's stock.view + stock.adjust come from 143's trigger on roles (not patched here, or the row would be inserted twice).
-- (4) Sanity block: every new right exists and every system Owner role (and the Manager / Cashier / Chef roles named above) holds what it should, every new
--     function exists; otherwise the migration raises and nothing is changed.
--     (3b, integrator) public.log_customer_export(rows, filter): audit row for the customer CSV export (needs customer.export).
-- Re-runnable.

-- ---------------------------------------------------------------- (1) erase lists
CREATE OR REPLACE FUNCTION app.erase_groups()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('online_orders', 'customer_ledger', 'batch_movements', 'pre_order_payments', 'pre_orders', 'order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'order_tips', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('online_channels', 'product_batches', 'price_rules', 'product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'price_change_lines', 'price_change_batches', 'branch_prices',
            'products', 'categories', 'brands', 'dining_tables', 'floors', 'customers', 'riders'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_count_lines', 'stock_counts', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$;
revoke all on function app.erase_groups() from public, anon, authenticated;

-- ---------------------------------------------------------------- (2) grants
insert into public.role_permissions (role_id, permission_key)
select r.id, 'customer.view' from public.roles r
 where (r.is_system and r.name in ('Owner', 'Manager', 'Cashier'))
    or exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = 'customer.manage')
on conflict do nothing;
insert into public.role_permissions (role_id, permission_key)
select r.id, 'loyalty.redeem' from public.roles r where r.is_system and r.name in ('Owner', 'Manager', 'Cashier')
on conflict do nothing;
insert into public.role_permissions (role_id, permission_key)
select r.id, k.key from public.roles r cross join (values ('stock.view'), ('stock.adjust')) k(key)
 where exists (select 1 from public.permissions p where p.key = k.key)
   and ((r.is_system and r.name in ('Chef', 'Owner')) or exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = 'stock.manage'))
on conflict do nothing;

-- ---------------------------------------------------------------- (3) new restaurants
do $patch$
declare d text; d2 text;
begin
  d := pg_get_functiondef('app.create_restaurant_with_owner(text,text,character,text,text,text,text,text)'::regprocedure);
  if position('customer.view' in d) > 0 then return; end if;   -- already patched
  d2 := replace(d, '(v_cashier, ''customer.manage''),', '(v_cashier, ''customer.manage''), (v_cashier, ''customer.view''), (v_cashier, ''loyalty.redeem''),');
  if d2 = d then raise exception '148: could not find the Cashier grants in app.create_restaurant_with_owner'; end if;
  d := d2;
  d2 := replace(d, '(v_waiter, ''customer.manage'');', '(v_waiter, ''customer.manage''), (v_waiter, ''customer.view'');');
  if d2 = d then raise exception '148: could not find the Steward grants in app.create_restaurant_with_owner'; end if;
  -- The Chef gets stock.view + stock.adjust from the trigger on public.roles that 143 installs (trg_grant_chef_stock). It is NOT patched in here as well:
  -- doing both inserted the same role_permissions row twice and made create_restaurant_with_owner fail with a duplicate key (found by the integrator).
  execute d2;
end $patch$;

-- ---------------------------------------------------------------- (3b) audit row for the customer CSV export
-- The export is built by the app from customer_list pages; this function writes the one audit row ("customer.export": how many rows, which filter; never the
-- phone numbers). Integrator addition (the plan named the audit action but no function). Needs the existing right customer.export.
create or replace function public.log_customer_export(p_rows int, p_filter text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('customer.export');
  perform app.audit('customer.export', 'customers', null,
    jsonb_build_object('rows', greatest(coalesce(p_rows, 0), 0), 'filter', left(coalesce(p_filter, 'all'), 20)), null);
end $$;
revoke all on function public.log_customer_export(int, text) from public, anon;
grant execute on function public.log_customer_export(int, text) to authenticated;

-- ---------------------------------------------------------------- (4) sanity
do $check$
declare k text; n int; f text;
begin
  if to_regclass('public.stock_counts') is null or to_regclass('public.stock_count_lines') is null then
    raise exception '148 STOPPED: stock_counts / stock_count_lines do not exist. Apply 143 (inventory core) first. Nothing was changed.';
  end if;
  foreach k in array array['customer.view', 'loyalty.redeem', 'stock.view', 'stock.adjust'] loop
    if not exists (select 1 from public.permissions where key = k) then raise exception '148 CHECK FAILED: the right % does not exist.', k; end if;
    select count(*) into n from public.roles r where r.is_system and r.name = 'Owner'
       and not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = k);
    if n > 0 then raise exception '148 CHECK FAILED: % Owner role(s) lack %.', n, k; end if;
    -- a Manager keeps the stock rights only when the Manager role has stock.manage (checked below for every role), so they are not demanded here
    select count(*) into n from public.roles r where r.is_system and r.name = 'Manager' and k not in ('stock.view', 'stock.adjust')
       and not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = k);
    if n > 0 then raise exception '148 CHECK FAILED: % Manager role(s) lack %.', n, k; end if;
  end loop;
  foreach k in array array['customer.view', 'loyalty.redeem'] loop
    select count(*) into n from public.roles r where r.is_system and r.name = 'Cashier'
       and not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = k);
    if n > 0 then raise exception '148 CHECK FAILED: % Cashier role(s) lack %.', n, k; end if;
  end loop;
  select count(*) into n from public.roles r join public.role_permissions m on m.role_id = r.id and m.permission_key = 'customer.manage'
   where not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = 'customer.view');
  if n > 0 then raise exception '148 CHECK FAILED: % role(s) have customer.manage but not customer.view.', n; end if;
  select count(*) into n from public.roles r join public.role_permissions m on m.role_id = r.id and m.permission_key = 'stock.manage'
   where not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key in ('stock.view'))
      or not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key in ('stock.adjust'));
  if n > 0 then raise exception '148 CHECK FAILED: % role(s) have stock.manage but not stock.view + stock.adjust.', n; end if;
  foreach f in array array[
    'public.customer_list(text,text,text,integer,integer)', 'public.customer_detail(uuid)', 'public.find_customer(text)',
    'public.update_customer(uuid,text,text,text,date,boolean)', 'public.forget_customer(uuid,text)',
    'public.redeem_points_discount(uuid,numeric,uuid)', 'public.remove_points_discount(uuid)',
    'public.save_loyalty_settings(numeric,numeric,integer,text,numeric)', 'public.report_customers(date,date)', 'public.report_loyalty_ledger(date,date)',
    'public.log_customer_export(integer,text)', 'app.loyalty_trim(uuid,numeric)', 'public.floor_status()', 'public.sync_offline_bill(jsonb)'] loop
    if to_regprocedure(f) is null then raise exception '148 CHECK FAILED: the function % does not exist.', f; end if;
  end loop;
  if position('stock_count_lines' in app.erase_groups()::text) = 0 then raise exception '148 CHECK FAILED: erase_groups does not list stock_count_lines.'; end if;
end $check$;
