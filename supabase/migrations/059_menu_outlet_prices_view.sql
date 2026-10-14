-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928103529, name '059_menu_outlet_prices_view'. This is the SQL that actually ran.

create or replace view public.v_menu with (security_invoker = true) as
 select p.id, p.restaurant_id, p.category_id, p.tax_group_id, p.name, p.short_name,
        coalesce(bp.price, p.price)::numeric(14,2) as price,
        p.is_veg,
        (p.is_available and coalesce(bp.is_available, true)) as is_available,
        p.display_order, c.name as category_name, c.display_order as category_order,
        tg.name as tax_group_name, tg.is_price_inclusive,
        (select tr.total_rate from public.tax_rates tr
          where tr.tax_group_id = p.tax_group_id and tr.valid_from <= current_date and (tr.valid_to is null or tr.valid_to >= current_date)
          order by tr.valid_from desc limit 1) as tax_rate,
        p.price as menu_price
   from public.products p
   join public.categories c on c.id = p.category_id
   join public.tax_groups tg on tg.id = p.tax_group_id
   left join public.branch_prices bp on bp.product_id = p.id and bp.branch_id = (select app.current_branch_id())
  where p.deleted_at is null and c.deleted_at is null;
