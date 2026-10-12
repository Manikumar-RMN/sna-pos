-- 091: Sub-categories in the guest QR menu and the Open API.
-- QR menu: a sub-category's dishes show under its main category, with the sub-category as a heading.
-- Open API /menu: main categories, each with its dishes and a "sub_categories" list (each with its dishes).

create or replace function app.api_menu_items(p_category uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'name_local', p.name_local, 'price', p.price,
           'is_veg', p.is_veg, 'available', p.is_available, 'tax_group', tg.name, 'price_includes_tax', tg.is_price_inclusive,
           'kitchen_station', p.kitchen_station) order by p.display_order, p.name), '[]'::jsonb)
    from public.products p join public.tax_groups tg on tg.id = p.tax_group_id
   where p.category_id = p_category and p.deleted_at is null
$function$;
revoke all on function app.api_menu_items(uuid) from public, anon, authenticated;

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
           group by top.id, top.name, top.display_order
        ) c), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.api_v1(p_key text, p_action text, p_params jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare k public.api_keys%rowtype; v_rest uuid; v_from date; v_to date; v_calls int;
begin
  if coalesce(length(p_key), 0) < 20 or length(p_key) > 100 then raise exception 'Invalid API key.'; end if;
  select * into k from public.api_keys where key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex') and revoked_at is null;
  if not found then raise exception 'Invalid API key.'; end if;
  v_rest := k.restaurant_id;
  if not app.feature_on(v_rest, 'open_api') then raise exception 'The Open API is not switched on for this restaurant.'; end if;
  select count(*) into v_calls from public.api_calls where key_id = k.id and at > now() - interval '1 minute';
  if v_calls >= 60 then raise exception 'Too many requests: at most 60 per minute per key.'; end if;
  insert into public.api_calls (key_id, action) values (k.id, left(coalesce(p_action, ''), 20));
  update public.api_keys set last_used_at = now() where id = k.id;

  if p_action in ('orders', 'sales') then
    begin
      v_from := coalesce((p_params->>'from')::date, current_date);
      v_to := coalesce((p_params->>'to')::date, v_from);
    exception when others then raise exception 'Dates must look like 2026-09-28.';
    end;
    if v_to < v_from or v_to - v_from > 31 then raise exception 'Choose at most 31 days (from ≤ to).'; end if;
  end if;

  if p_action = 'menu' then
    -- Main categories, each with its own dishes and its sub-categories (each with their dishes).
    return jsonb_build_object('categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items', app.api_menu_items(c.id),
               'sub_categories', coalesce((
                 select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'items', app.api_menu_items(s.id)) order by s.display_order, s.name)
                   from public.categories s where s.parent_id = c.id and s.deleted_at is null), '[]'::jsonb)) order by c.display_order, c.name)
        from public.categories c where c.restaurant_id = v_rest and c.deleted_at is null and c.parent_id is null), '[]'::jsonb));
  elsif p_action = 'orders' then
    return jsonb_build_object('from', v_from, 'to', v_to, 'orders', coalesce((
      select jsonb_agg(x order by x->>'created_at') from (
        select jsonb_build_object('id', o.id, 'bill_number', o.bill_number, 'business_date', o.business_date, 'created_at', o.created_at,
                 'outlet', b.name, 'order_type', o.order_type, 'status', o.status, 'payment_status', o.payment_status,
                 'currency', o.currency_code, 'subtotal', o.subtotal, 'discount', o.discount_total, 'service_charge', o.service_charge,
                 'tax', o.tax_total, 'tax_included', o.tax_included, 'rounding', o.rounding_adjustment, 'grand_total', o.grand_total,
                 'paid', o.paid_total, 'buyer_gstin', o.buyer_gstin,
                 'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.product_name, 'qty', i.quantity, 'unit_price', i.unit_price,
                                'amount', i.line_subtotal, 'options', i.options_text, 'cancelled', i.cancelled_at is not null)), '[]'::jsonb)
                             from public.order_items i where i.order_id = o.id),
                 'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', pm.name, 'kind', pm.kind, 'amount', pa.amount, 'at', pa.created_at)), '[]'::jsonb)
                                from public.payments pa join public.payment_methods pm on pm.id = pa.payment_method_id
                               where pa.order_id = o.id and pa.status in ('captured', 'refunded'))) as x
          from public.orders o join public.branches b on b.id = o.branch_id
         where o.restaurant_id = v_rest and o.business_date between v_from and v_to
         order by o.created_at limit 5000) q), '[]'::jsonb));
  elsif p_action = 'sales' then
    return jsonb_build_object('from', v_from, 'to', v_to, 'days', coalesce((
      select jsonb_agg(jsonb_build_object('date', d, 'outlet', outlet, 'bills', bills, 'gross', gross, 'discount', disc, 'tax', tax,
                                          'total', total, 'voided_bills', voided) order by d, outlet)
        from (select o.business_date d, b.name outlet,
                     count(*) filter (where o.status <> 'voided') bills,
                     sum(o.subtotal) filter (where o.status <> 'voided') gross,
                     sum(o.discount_total) filter (where o.status <> 'voided') disc,
                     sum(o.tax_total + o.tax_included) filter (where o.status <> 'voided') tax,
                     sum(o.grand_total) filter (where o.status <> 'voided') total,
                     count(*) filter (where o.status = 'voided') voided
                from public.orders o join public.branches b on b.id = o.branch_id
               where o.restaurant_id = v_rest and o.business_date between v_from and v_to
               group by 1, 2) s), '[]'::jsonb),
      'credit_notes', coalesce((select jsonb_agg(jsonb_build_object('number', cn.number, 'date', cn.business_date, 'amount', cn.amount, 'tax', cn.tax_amount))
                                  from public.credit_notes cn where cn.restaurant_id = v_rest and cn.business_date between v_from and v_to), '[]'::jsonb));
  elsif p_action = 'stock' then
    if not app.feature_on(v_rest, 'stock') then raise exception 'Stock is not switched on for this restaurant.'; end if;
    return jsonb_build_object('ingredients', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'reorder_level', i.reorder_level,
               'by_outlet', (select coalesce(jsonb_agg(jsonb_build_object('outlet', b.name, 'stock', x.q)), '[]'::jsonb)
                               from (select m.branch_id, sum(m.qty) q from public.stock_movements m where m.ingredient_id = i.id group by 1) x
                               join public.branches b on b.id = x.branch_id)) order by i.name)
        from public.ingredients i where i.restaurant_id = v_rest and i.is_active), '[]'::jsonb));
  end if;
  raise exception 'Unknown action. Use menu, orders, sales or stock.';
end $function$;
