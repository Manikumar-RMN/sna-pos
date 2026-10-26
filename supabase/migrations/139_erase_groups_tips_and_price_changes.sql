-- 139: the "erase test data" lists (app.erase_groups, last defined in 109) learn the three tables added by 133 and 136.
--
--   * order_tips            (133)  -> pos_tx, before 'payments' and 'orders' (it points at both)
--   * price_change_lines    (136)  -> pos_master, before 'price_change_batches' and before 'products'
--   * price_change_batches  (136)  -> pos_master, before 'products'
-- Nothing else changes: the lists are the 109 lists with these three names added. Permission grants need nothing here:
-- order.open_price was inserted and granted to Owner and Manager by 131 (new restaurants give Owner every key and
-- Manager every key except tax/settings/agent, so they get it too), and order.reprint is deliberately NOT granted to Steward.
-- Re-runnable (create or replace).

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
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$;

-- Same lock-down as before (109 / 086): internal helper, not callable from the app.
revoke all on function app.erase_groups() from public, anon, authenticated;
