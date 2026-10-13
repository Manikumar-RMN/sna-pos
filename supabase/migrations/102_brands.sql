-- 102: Brands and stalls.
-- Cloud kitchen: several brands cooked in one kitchen. Food court: several stalls billed at one counter.
-- A brand owns main categories (their sub-categories go with them). Each bill line remembers its brand at the
-- time of sale, so the settlement per brand stays right even if the menu is reorganised later.
-- The settlement shows each brand's sales, tax, the operator's commission and what is payable to the brand.

create table public.brands (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 60),
  legal_name text check (legal_name is null or length(legal_name) <= 120),
  gstin text check (gstin is null or gstin ~ '^[0-9A-Z]{15}$'),
  commission_percent numeric(5,2) not null default 0 check (commission_percent between 0 and 100),
  is_active boolean not null default true,
  display_order smallint not null default 0,
  created_at timestamptz not null default now(),
  unique (restaurant_id, id)
);
create unique index brands_name_uq on public.brands (restaurant_id, lower(btrim(name)));
alter table public.brands enable row level security;
create policy tenant_read on public.brands for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
revoke all on public.brands from anon;
grant select on public.brands to authenticated;

alter table public.categories
  add column brand_id uuid,
  add constraint categories_brand_same_rest foreign key (restaurant_id, brand_id) references public.brands (restaurant_id, id) on delete restrict;

alter table public.order_items add column brand_id uuid references public.brands(id) on delete restrict;
create index idx_order_items_brand on public.order_items (brand_id) where brand_id is not null;

-- A sub-category always belongs to its main category's brand; moving a main category moves its sub-categories.
create or replace function app.trg_category_brand()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.parent_id is not null then
    select brand_id into new.brand_id from public.categories where id = new.parent_id;
  end if;
  return new;
end $function$;
create trigger trg_category_brand before insert or update of parent_id, brand_id on public.categories
  for each row execute function app.trg_category_brand();

create or replace function app.trg_category_brand_follow()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.brand_id is distinct from old.brand_id then
    update public.categories set brand_id = new.brand_id where parent_id = new.id and brand_id is distinct from new.brand_id;
  end if;
  return null;
end $function$;
create trigger trg_category_brand_follow after update of brand_id on public.categories
  for each row execute function app.trg_category_brand_follow();

-- Each bill line takes its brand from the dish's category when it is added.
create or replace function app.trg_order_item_brand()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.brand_id is null then
    select c.brand_id into new.brand_id from public.products p join public.categories c on c.id = p.category_id where p.id = new.product_id;
  end if;
  return new;
end $function$;
create trigger trg_order_item_brand before insert on public.order_items
  for each row execute function app.trg_order_item_brand();

-- Add or change a brand (settings.manage).
create or replace function public.brand_save(p_id uuid, p_name text, p_commission numeric default 0, p_legal_name text default null,
                                             p_gstin text default null, p_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id(); v_id uuid;
  v_name text := btrim(coalesce(p_name, '')); v_gstin text := nullif(upper(btrim(coalesce(p_gstin, ''))), '');
begin
  if v_name = '' then raise exception 'Enter the brand or stall name.'; end if;
  if length(v_name) > 60 then raise exception 'The name is too long (60 letters at most).'; end if;
  if coalesce(p_commission, 0) < 0 or coalesce(p_commission, 0) > 100 then raise exception 'Commission is 0 to 100 percent.'; end if;
  if v_gstin is not null and v_gstin !~ '^[0-9A-Z]{15}$' then raise exception 'A GSTIN has 15 letters and digits.'; end if;
  if exists (select 1 from public.brands where restaurant_id = v_rest and lower(btrim(name)) = lower(v_name) and id is distinct from p_id) then
    raise exception 'There is already a brand called %.', v_name;
  end if;
  if p_id is null then
    insert into public.brands (restaurant_id, name, legal_name, gstin, commission_percent, is_active, display_order)
    values (v_rest, v_name, nullif(btrim(coalesce(p_legal_name, '')), ''), v_gstin, round(coalesce(p_commission, 0), 2), coalesce(p_active, true),
            coalesce((select max(display_order) + 1 from public.brands where restaurant_id = v_rest), 0))
    returning id into v_id;
  else
    update public.brands set name = v_name, legal_name = nullif(btrim(coalesce(p_legal_name, '')), ''), gstin = v_gstin,
           commission_percent = round(coalesce(p_commission, 0), 2), is_active = coalesce(p_active, true)
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'That brand was not found.'; end if;
  end if;
  perform app.audit('brand.save', 'brands', v_id, jsonb_build_object('name', v_name, 'commission', p_commission), null);
  return v_id;
end $function$;

-- Put a main category under a brand (or no brand).
create or replace function public.category_set_brand(p_category uuid, p_brand uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('menu.manage'); v_rest uuid := app.current_restaurant_id(); c public.categories;
begin
  select * into c from public.categories where id = p_category and restaurant_id = v_rest and deleted_at is null;
  if not found then raise exception 'That category was not found.'; end if;
  if c.parent_id is not null then raise exception 'A sub-category goes with its main category. Change the main category instead.'; end if;
  if p_brand is not null and not exists (select 1 from public.brands where id = p_brand and restaurant_id = v_rest) then
    raise exception 'That brand was not found.';
  end if;
  update public.categories set brand_id = p_brand where id = p_category;
end $function$;

-- What each brand / stall sold and what it is owed, for a date range (by bill date).
create or replace function public.brand_settlement(p_from date, p_to date)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end := (p_to + 1)::timestamp at time zone v_tz;
  return jsonb_build_object('from', p_from, 'to', p_to, 'brands', coalesce((
    select jsonb_agg(jsonb_build_object('brand_id', x.brand_id, 'brand', coalesce(b.name, 'No brand'), 'gstin', b.gstin,
             'bills', x.bills, 'qty', x.qty, 'sales', x.sales, 'tax', x.tax, 'billed', x.sales + x.tax,
             'commission_percent', coalesce(b.commission_percent, 0),
             'commission', round(x.sales * coalesce(b.commission_percent, 0) / 100, 2),
             'payable', x.sales + x.tax - round(x.sales * coalesce(b.commission_percent, 0) / 100, 2))
           order by b.display_order nulls last, b.name)
      from (select oi.brand_id, count(distinct o.id) bills, sum(oi.quantity) qty,
                   sum(oi.net_amount) sales, sum(oi.line_tax + oi.tax_included) tax
              from public.order_items oi join public.orders o on o.id = oi.order_id
             where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.created_at >= v_start and o.created_at < v_end
               and o.status = 'completed' and o.merged_into is null and o.comp_kind is null and oi.cancelled_at is null
               and not exists (select 1 from public.products p where p.id = oi.product_id and p.is_charge)
             group by oi.brand_id) x
      left join public.brands b on b.id = x.brand_id), '[]'::jsonb));
end $function$;

revoke all on function public.brand_save(uuid, text, numeric, text, text, boolean), public.category_set_brand(uuid, uuid), public.brand_settlement(date, date) from public, anon;
grant execute on function public.brand_save(uuid, text, numeric, text, text, boolean), public.category_set_brand(uuid, uuid), public.brand_settlement(date, date) to authenticated, service_role;

-- Erasing a test restaurant also removes its brands.
CREATE OR REPLACE FUNCTION app.erase_groups()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('customer_ledger', 'batch_movements', 'pre_order_payments', 'pre_orders', 'order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('product_batches', 'price_rules', 'product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'branch_prices',
            'products', 'categories', 'brands', 'dining_tables', 'floors', 'customers'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$;
