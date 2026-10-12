-- 095: Business type (restaurant, café, QSR, bar, bakery, cloud kitchen…) and the order types an outlet uses.
--
-- The business type only sets starting defaults; the owner can change any of them afterwards:
--   which kinds of bill the billing screen offers (dine-in / takeaway / delivery), which one it starts on,
--   and token numbers. Features that are paid add-ons stay under Plan and modules.

alter table public.restaurants
  add column business_type text not null default 'restaurant'
    check (business_type in ('restaurant', 'cafe', 'fine_dine', 'bar', 'food_court', 'canteen', 'pizzeria', 'qsr',
                             'desserts', 'bakery', 'cloud_kitchen', 'chain'));

alter table public.branch_settings
  add column order_types text[] not null default '{dine_in,takeaway,delivery}'
    check (cardinality(order_types) between 1 and 3 and order_types <@ '{dine_in,takeaway,delivery}'::text[]),
  add constraint branch_settings_default_type_offered check (default_order_type = any (order_types)),
  add constraint branch_settings_default_type_known check (default_order_type in ('dine_in', 'takeaway', 'delivery'));

-- The starting settings for each business type.
create or replace function app.business_type_defaults(p_type text)
returns jsonb
language sql
immutable
set search_path to 'public', 'pg_temp'
as $function$
  select case p_type
    when 'restaurant'    then '{"default_order_type":"dine_in","order_types":["dine_in","takeaway","delivery"],"token_numbers":"off"}'
    when 'fine_dine'     then '{"default_order_type":"dine_in","order_types":["dine_in","takeaway"],"token_numbers":"off"}'
    when 'bar'           then '{"default_order_type":"dine_in","order_types":["dine_in","takeaway"],"token_numbers":"off"}'
    when 'chain'         then '{"default_order_type":"dine_in","order_types":["dine_in","takeaway","delivery"],"token_numbers":"off"}'
    when 'cafe'          then '{"default_order_type":"takeaway","order_types":["dine_in","takeaway","delivery"],"token_numbers":"takeaway"}'
    when 'pizzeria'      then '{"default_order_type":"takeaway","order_types":["dine_in","takeaway","delivery"],"token_numbers":"takeaway"}'
    when 'qsr'           then '{"default_order_type":"takeaway","order_types":["dine_in","takeaway","delivery"],"token_numbers":"all"}'
    when 'desserts'      then '{"default_order_type":"takeaway","order_types":["dine_in","takeaway","delivery"],"token_numbers":"all"}'
    when 'food_court'    then '{"default_order_type":"takeaway","order_types":["takeaway"],"token_numbers":"all"}'
    when 'canteen'       then '{"default_order_type":"takeaway","order_types":["takeaway"],"token_numbers":"all"}'
    when 'bakery'        then '{"default_order_type":"takeaway","order_types":["takeaway","delivery"],"token_numbers":"off"}'
    when 'cloud_kitchen' then '{"default_order_type":"delivery","order_types":["takeaway","delivery"],"token_numbers":"off"}'
  end::jsonb
$function$;
revoke all on function app.business_type_defaults(text) from public, anon, authenticated;

-- Sets the business type; with p_apply the type's starting settings are put on every outlet.
create or replace function app.set_business_type(p_restaurant uuid, p_type text, p_apply boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare d jsonb := app.business_type_defaults(p_type);
begin
  if d is null then raise exception 'Unknown business type.'; end if;
  update public.restaurants set business_type = p_type where id = p_restaurant;
  if not found then raise exception 'Restaurant not found.'; end if;
  if p_apply then
    update public.branch_settings
       set order_types = array(select jsonb_array_elements_text(d->'order_types')),
           default_order_type = d->>'default_order_type',
           token_numbers = d->>'token_numbers'
     where restaurant_id = p_restaurant;
  end if;
  return jsonb_build_object('business_type', p_type, 'applied', p_apply, 'defaults', d);
end $function$;
revoke all on function app.set_business_type(uuid, text, boolean) from public, anon, authenticated;

-- The owner (Settings → Company).
create or replace function public.set_business_type(p_type text, p_apply boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  perform app.require_permission('settings.manage');
  return app.set_business_type(app.current_restaurant_id(), p_type, coalesce(p_apply, false));
end $function$;

-- SNA staff (Console → client).
create or replace function public.sna_set_business_type(p_restaurant uuid, p_type text, p_apply boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  perform app.sna_require(array['sales', 'support']);
  return app.set_business_type(p_restaurant, p_type, coalesce(p_apply, false));
end $function$;

-- Which kinds of bill this outlet offers, and the one the billing screen starts on (Settings → Service charge).
create or replace function public.set_order_types(p_types text[], p_default text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_t text[] := array(select distinct x from unnest(coalesce(p_types, '{}')) x where x in ('dine_in', 'takeaway', 'delivery') order by 1);
begin
  perform app.require_permission('settings.manage');
  if cardinality(v_t) = 0 then raise exception 'Keep at least one kind of bill.'; end if;
  if not (p_default = any (v_t)) then raise exception 'The billing screen must start on a kind of bill that is switched on.'; end if;
  update public.branch_settings set order_types = v_t, default_order_type = p_default where branch_id = app.current_branch_id();
  if not found then raise exception 'No outlet chosen.'; end if;
end $function$;

revoke all on function public.set_business_type(text, boolean), public.sna_set_business_type(uuid, text, boolean), public.set_order_types(text[], text) from public, anon;
grant execute on function public.set_business_type(text, boolean), public.sna_set_business_type(uuid, text, boolean), public.set_order_types(text[], text) to authenticated, service_role;

-- The console's client page shows the business type.
CREATE OR REPLACE FUNCTION public.sna_restaurant(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.restaurants%rowtype;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_id;
  if not found then raise exception 'Restaurant not found.'; end if;
  return jsonb_build_object(
    'id', r.id, 'trading_name', r.trading_name, 'legal_name', r.legal_name, 'country_code', r.country_code,
    'currency', r.currency_code, 'edition', r.edition, 'business_type', r.business_type, 'timezone', r.timezone, 'created_at', r.created_at,
    'contact_email', r.contact_email, 'contact_phone', r.contact_phone,
    'monthly', app.monthly_charge(r.id),
    'modules', (select jsonb_agg(jsonb_build_object('key', m.key, 'name', m.name, 'kind', m.kind, 'on', app.feature_on(r.id, m.key),
                  'price', (select monthly_price from public.plan_prices where item = m.key and currency_code = r.currency_code))
                  order by m.display_order) from public.modules m),
    'prices', (select coalesce(jsonb_object_agg(item, monthly_price), '{}'::jsonb) from public.plan_prices where currency_code = r.currency_code),
    'branches', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'city', b.city, 'is_active', b.is_active)
                  order by b.created_at), '[]'::jsonb) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'module_key', q.module_key, 'outlet_name', q.outlet_name,
                  'outlet_city', q.outlet_city, 'note', q.note, 'status', q.status, 'created_at', q.created_at, 'decision_note', q.decision_note)
                  order by q.created_at desc), '[]'::jsonb) from public.plan_requests q where q.restaurant_id = r.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('event', e.event, 'details', e.details, 'created_at', e.created_at,
                  'by', coalesce((select full_name from public.sna_staff where id = e.staff_id), (select full_name from public.users where id = e.user_id)))
                  order by e.created_at desc), '[]'::jsonb)
                 from (select * from public.subscription_events where restaurant_id = r.id order by created_at desc limit 50) e));
end $function$;
