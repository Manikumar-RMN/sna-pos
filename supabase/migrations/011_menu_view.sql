-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260923125635, name 'sna_pos_11_menu_view'. This is the SQL that actually ran.

-- A single read the billing and menu screens use: each available product with
-- its category, tax group and the tax rate currently in force. security_invoker
-- means it runs under the caller's policies, so it only ever shows their menu.
create or replace view public.v_menu
with (security_invoker = true)
as
select
  p.id, p.restaurant_id, p.category_id, p.tax_group_id,
  p.name, p.short_name, p.price, p.is_veg, p.is_available, p.display_order,
  c.name as category_name, c.display_order as category_order,
  tg.name as tax_group_name, tg.is_price_inclusive,
  (select tr.total_rate from public.tax_rates tr
     where tr.tax_group_id = p.tax_group_id
       and tr.valid_from <= current_date
       and (tr.valid_to is null or tr.valid_to >= current_date)
     order by tr.valid_from desc limit 1) as tax_rate
from public.products p
join public.categories c on c.id = p.category_id
join public.tax_groups tg on tg.id = p.tax_group_id
where p.deleted_at is null and c.deleted_at is null;

grant select on public.v_menu to authenticated;

notify pgrst, 'reload schema';
