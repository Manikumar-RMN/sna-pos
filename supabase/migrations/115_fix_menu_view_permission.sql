-- 115: The billing screen's menu was empty for every signed-in user since migration 094 (13 Oct 2026).
--
-- Found by the browser tests (e2e-ui): a cashier opens Bill and sees "There is nothing to sell yet", although the restaurant
-- has a menu. Cause: 094 rebuilt the menu view public.v_menu (a security_invoker view, so it runs with the signed-in
-- person's rights) so that its `price` column calls app.rule_price() (happy-hour prices), and in the same file REVOKED
-- execute on app.rule_price from signed-in users. Reading `price` from the view therefore fails with
-- "permission denied for function rule_price". Three screens fail on it: the billing screen, Pre-orders and the Captain app (found by the screen sweep, e2e-ui/screens.ui.test.ts, which
-- also reads it in Settings -> Charges to show the packing price).
-- The offline menu copy and bills were not affected (they run inside definer functions).
--
-- Fix, without loosening rule_price itself (it takes a restaurant id, so it must not be callable with anyone else's):
-- a small wrapper that always uses the SIGNED-IN person's own restaurant and outlet, which signed-in users may run;
-- the view calls the wrapper. Same prices as before 094 intended: outlet price, then the happy-hour rule.
-- Safe to run again.

create or replace function app.menu_price(p_product uuid, p_price numeric)
 returns numeric
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select app.rule_price(app.current_restaurant_id(), app.current_branch_id(), p_product, p_price, now())
$function$;

revoke all on function app.menu_price(uuid, numeric) from public, anon;
grant execute on function app.menu_price(uuid, numeric) to authenticated;

create or replace view public.v_menu with (security_invoker = true) as
 SELECT p.id,
    p.restaurant_id,
    p.category_id,
    p.tax_group_id,
    p.name,
    p.short_name,
    app.menu_price(p.id, COALESCE(bp.price, p.price))::numeric(14,2) AS price,
    p.is_veg,
    p.is_available AND COALESCE(bp.is_available, true) AS is_available,
    p.display_order,
    c.name AS category_name,
    c.display_order AS category_order,
    tg.name AS tax_group_name,
    tg.is_price_inclusive,
    ( SELECT tr.total_rate
           FROM tax_rates tr
          WHERE tr.tax_group_id = p.tax_group_id AND tr.valid_from <= CURRENT_DATE AND (tr.valid_to IS NULL OR tr.valid_to >= CURRENT_DATE)
          ORDER BY tr.valid_from DESC
         LIMIT 1) AS tax_rate,
    p.price AS menu_price,
    p.name_local,
    p.parent_id,
    p.variant_name,
    p.is_combo,
    COALESCE(bp.price, p.price)::numeric(14,2) AS list_price
   FROM products p
     JOIN categories c ON c.id = p.category_id
     JOIN tax_groups tg ON tg.id = p.tax_group_id
     LEFT JOIN branch_prices bp ON bp.product_id = p.id AND bp.branch_id = (( SELECT app.current_branch_id() AS current_branch_id))
  WHERE p.deleted_at IS NULL AND c.deleted_at IS NULL;
