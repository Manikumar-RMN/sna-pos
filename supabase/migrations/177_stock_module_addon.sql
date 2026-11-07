-- 177: Purchase and inventory ('stock') becomes a sellable add-on module, like Front office, so the sales team can switch it
-- on or off per client in the SNA console. Clients that have it today (Professional edition) keep it. No price is attached
-- to 'stock' in plan_prices, so billing does not change. Safe to run again.
insert into public.restaurant_modules (restaurant_id, module_key)
select r.id, 'stock' from public.restaurants r where r.edition = 'professional'
on conflict do nothing;

update public.modules set kind = 'addon', name = 'Purchase and inventory',
  description = 'Stock, recipes, purchases, suppliers, wastage, food cost'
 where key = 'stock';
