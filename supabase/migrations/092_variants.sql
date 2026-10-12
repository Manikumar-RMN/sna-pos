-- 092: Variants (sizes): Small / Medium / Large, Half / Full, each with its own price.
--
-- A dish with sizes is a "parent" product; each size is a product of its own whose parent_id points at it.
-- A size keeps its own price, tax group, HSN code, kitchen station, recipe and stock, so bills, kitchen tickets,
-- stock and reports work exactly as for any dish. Its name is always "<dish> (<size>)", e.g. "Margherita (Large)",
-- and it sits in the dish's category. The dish itself cannot be put on a bill: the billing screen asks for a size.
-- Options (add-ons) linked to the dish apply to every size.

alter table public.products
  add column parent_id uuid,
  add column variant_name text,
  add constraint products_parent_same_rest foreign key (restaurant_id, parent_id) references public.products(restaurant_id, id) on delete restrict,
  add constraint products_variant_pair check ((parent_id is null) = (variant_name is null)),
  add constraint products_variant_not_self check (parent_id is null or parent_id <> id),
  add constraint products_variant_name_len check (variant_name is null or length(btrim(variant_name)) between 1 and 30);
create index idx_products_parent on public.products (parent_id) where parent_id is not null and deleted_at is null;
create unique index products_variant_uq on public.products (parent_id, lower(btrim(variant_name))) where parent_id is not null and deleted_at is null;

-- A size: one level only, same category as its dish, name made from the dish's name and the size.
create or replace function app.trg_product_variant()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare par public.products;
begin
  if new.parent_id is not null then
    new.variant_name := btrim(new.variant_name);
    select * into par from public.products where id = new.parent_id;
    if not found or par.restaurant_id <> new.restaurant_id then raise exception 'That dish was not found.'; end if;
    if par.parent_id is not null then raise exception 'A size cannot have sizes of its own.'; end if;
    if par.deleted_at is not null and new.deleted_at is null then raise exception 'The dish % has been removed.', par.name; end if;
    if tg_op = 'UPDATE' and old.parent_id is null and exists (select 1 from public.products c where c.parent_id = new.id and c.deleted_at is null) then
      raise exception '% has sizes, so it cannot become a size itself.', new.name;
    end if;
    new.category_id := par.category_id;
    new.name := left(par.name || ' (' || new.variant_name || ')', 200);
  elsif tg_op = 'UPDATE' and old.parent_id is not null then
    raise exception 'A size cannot be turned back into a separate dish. Remove it and add the dish again.';
  end if;
  return new;
end $function$;
create trigger trg_product_variant before insert or update of parent_id, variant_name, name, category_id, deleted_at on public.products
  for each row execute function app.trg_product_variant();

-- The dish changes: its sizes follow (name, category, removal).
create or replace function app.trg_product_variant_follow()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.parent_id is not null then return null; end if;
  if new.name is distinct from old.name or new.category_id is distinct from old.category_id then
    update public.products c set name = left(new.name || ' (' || c.variant_name || ')', 200), category_id = new.category_id
     where c.parent_id = new.id;
  end if;
  if new.deleted_at is not null and old.deleted_at is null then
    update public.products c set deleted_at = new.deleted_at where c.parent_id = new.id and c.deleted_at is null;
  end if;
  return null;
end $function$;
create trigger trg_product_variant_follow after update of name, category_id, deleted_at on public.products
  for each row execute function app.trg_product_variant_follow();

-- Options linked to the dish are linked to every size (and a new size gets the dish's options).
create or replace function app.trg_variant_options()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if tg_table_name = 'products' then
    if new.parent_id is not null then
      insert into public.product_modifier_groups (product_id, modifier_group_id, restaurant_id)
      select new.id, l.modifier_group_id, l.restaurant_id from public.product_modifier_groups l where l.product_id = new.parent_id
      on conflict do nothing;
    end if;
    return null;
  end if;
  if tg_op = 'INSERT' then
    insert into public.product_modifier_groups (product_id, modifier_group_id, restaurant_id)
    select c.id, new.modifier_group_id, new.restaurant_id from public.products c where c.parent_id = new.product_id
    on conflict do nothing;
  else
    delete from public.product_modifier_groups l
     using public.products c where c.parent_id = old.product_id and l.product_id = c.id and l.modifier_group_id = old.modifier_group_id;
  end if;
  return null;
end $function$;
create trigger trg_variant_options_new after insert on public.products for each row execute function app.trg_variant_options();
create trigger trg_variant_options_link after insert or delete on public.product_modifier_groups for each row execute function app.trg_variant_options();

-- A dish with sizes cannot go on a bill: a size must be chosen.
create or replace function app.trg_order_item_needs_size()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_name text;
begin
  if exists (select 1 from public.products c where c.parent_id = new.product_id and c.deleted_at is null) then
    select name into v_name from public.products where id = new.product_id;
    raise exception 'Choose a size for %.', v_name;
  end if;
  return new;
end $function$;
create trigger trg_order_item_needs_size before insert on public.order_items for each row execute function app.trg_order_item_needs_size();

revoke all on function app.trg_product_variant(), app.trg_product_variant_follow(), app.trg_variant_options(), app.trg_order_item_needs_size() from public, anon, authenticated;

-- The menu view carries the size link (new columns at the end).
create or replace view public.v_menu with (security_invoker = true) as
 SELECT p.id,
    p.restaurant_id,
    p.category_id,
    p.tax_group_id,
    p.name,
    p.short_name,
    COALESCE(bp.price, p.price)::numeric(14,2) AS price,
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
    p.variant_name
   FROM products p
     JOIN categories c ON c.id = p.category_id
     JOIN tax_groups tg ON tg.id = p.tax_group_id
     LEFT JOIN branch_prices bp ON bp.product_id = p.id AND bp.branch_id = (( SELECT app.current_branch_id() AS current_branch_id))
  WHERE p.deleted_at IS NULL AND c.deleted_at IS NULL;

-- Guest QR menu: a dish with sizes shows its sizes, not itself.
CREATE OR REPLACE FUNCTION public.qr_menu(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.dining_tables%rowtype := app.qr_table(p_token); r record;
begin
  select res.trading_name, res.currency_code, res.second_language, b.name as branch_name
    into r from public.restaurants res join public.branches b on b.id = t.branch_id where res.id = t.restaurant_id;
  return jsonb_build_object(
    'restaurant', r.trading_name, 'outlet', r.branch_name, 'currency', r.currency_code,
    'second_language', r.second_language, 'table', t.table_number,
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items', c.items) order by c.display_order, c.name)
        from (
          -- A sub-category's dishes are shown under its main category, headed by the sub-category's name ('sub').
          select top.id, top.name, top.display_order,
                 jsonb_agg(jsonb_build_object(
                   'id', p.id, 'name', p.name, 'name_local', p.name_local, 'is_veg', p.is_veg,
                   'sub', case when c.parent_id is not null then c.name end,
                   'price', coalesce(bp.price, p.price),
                   'option_groups', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'id', mg.id, 'name', mg.name,
                              'min', greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end),
                              'max', coalesce(mg.max_select, 99),
                              'options', (select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price_delta', mi.price_delta)
                                                             order by mi.display_order, mi.name), '[]'::jsonb)
                                            from public.modifier_items mi where mi.modifier_group_id = mg.id and mi.is_active))
                            order by mg.is_required desc, mg.name)
                       from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id
                      where pmg.product_id = p.id and mg.is_active), '[]'::jsonb))
                   order by (c.parent_id is not null), c.display_order, c.name, p.display_order, p.name) as items
            from public.categories c
            join public.categories top on top.id = coalesce(c.parent_id, c.id) and top.deleted_at is null
            join public.products p on p.category_id = c.id and p.deleted_at is null
            left join public.branch_prices bp on bp.product_id = p.id and bp.branch_id = t.branch_id
           where c.restaurant_id = t.restaurant_id and c.deleted_at is null
             and p.is_available and coalesce(bp.is_available, true)
             and not p.is_charge
             -- a dish with sizes is ordered by its sizes, which are listed as dishes of their own
             and not exists (select 1 from public.products ch where ch.parent_id = p.id and ch.deleted_at is null)
           group by top.id, top.name, top.display_order
        ) c), '[]'::jsonb));
end $function$;

-- Open API: each dish says whether it has sizes and which dish a size belongs to.
create or replace function app.api_menu_items(p_category uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'name_local', p.name_local, 'price', p.price,
           'is_veg', p.is_veg, 'available', p.is_available, 'tax_group', tg.name, 'price_includes_tax', tg.is_price_inclusive,
           'kitchen_station', p.kitchen_station, 'variant_of', p.parent_id, 'variant', p.variant_name,
           'has_variants', exists (select 1 from public.products ch where ch.parent_id = p.id and ch.deleted_at is null))
           order by p.display_order, p.name), '[]'::jsonb)
    from public.products p join public.tax_groups tg on tg.id = p.tax_group_id
   where p.category_id = p_category and p.deleted_at is null
$function$;
