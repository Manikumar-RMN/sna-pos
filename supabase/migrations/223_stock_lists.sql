-- Category (item group) and department master lists for stock.
-- Once a restaurant has at least one active entry of a kind, new item groups / new requests and issues must use a name from the list.
-- A restaurant with no entries keeps the old free-text behaviour. Existing items are never rejected: the check only runs when the group is set or changed.

grant select (block_expired_issue) on public.purchase_settings to authenticated;

create table if not exists public.stock_lists (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  kind text not null check (kind in ('category', 'department')),
  name text not null check (length(btrim(name)) between 1 and 40),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists stock_lists_unique on public.stock_lists (restaurant_id, kind, lower(btrim(name)));
alter table public.stock_lists enable row level security;
revoke all on public.stock_lists from anon, authenticated;
grant select on public.stock_lists to authenticated;
drop policy if exists tenant_read on public.stock_lists;
create policy tenant_read on public.stock_lists for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));

create or replace function public.save_stock_list_item(p_kind text, p_name text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_id uuid; v_n text := btrim(coalesce(p_name, ''));
begin
  perform app.require_feature('stock');
  if p_kind not in ('category', 'department') then raise exception 'Choose category or department.'; end if;
  if length(v_n) < 1 or length(v_n) > 40 then raise exception 'Enter a name of up to 40 letters.'; end if;
  select id into v_id from public.stock_lists where restaurant_id = v_rest and kind = p_kind and lower(btrim(name)) = lower(v_n);
  if v_id is not null then
    update public.stock_lists set is_active = true where id = v_id;
  else
    insert into public.stock_lists (restaurant_id, kind, name) values (v_rest, p_kind, v_n) returning id into v_id;
  end if;
  perform app.audit('stock.list', 'stock_lists', v_id, jsonb_build_object('kind', p_kind, 'name', v_n));
  return v_id;
end $$;

create or replace function public.set_stock_list_item_active(p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id();
begin
  perform app.require_feature('stock');
  update public.stock_lists set is_active = coalesce(p_active, true) where id = p_id and restaurant_id = v_rest;
  if not found then raise exception 'Entry not found.'; end if;
  perform app.audit('stock.list', 'stock_lists', p_id, jsonb_build_object('active', coalesce(p_active, true)));
end $$;

-- Start the lists from what is already in use (item groups, departments on earlier requests and issues).
create or replace function app.seed_stock_lists(p_rest uuid) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n integer := 0;
begin
  insert into public.stock_lists (restaurant_id, kind, name)
  select p_rest, 'category', min(btrim(category)) from public.ingredients
   where restaurant_id = p_rest and nullif(btrim(coalesce(category, '')), '') is not null group by lower(btrim(category))
  on conflict do nothing;
  get diagnostics v_n = row_count;
  insert into public.stock_lists (restaurant_id, kind, name)
  select p_rest, 'department', min(btrim(d)) from (
    select department as d from public.material_requests where restaurant_id = p_rest
    union all select department from public.material_issues where restaurant_id = p_rest) x
   where nullif(btrim(coalesce(d, '')), '') is not null group by lower(btrim(d))
  on conflict do nothing;
  return v_n;
end $$;
revoke all on function app.seed_stock_lists(uuid) from public, anon, authenticated;

create or replace function public.seed_stock_lists_from_use() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_n integer;
begin
  perform app.require_feature('stock');
  v_n := app.seed_stock_lists(v_rest);
  insert into public.stock_lists (restaurant_id, kind, name)
  select v_rest, 'department', d from unnest(array['Kitchen', 'Bar', 'Bakery', 'Housekeeping', 'Other']) d on conflict do nothing;
  perform app.audit('stock.list', 'stock_lists', v_rest, jsonb_build_object('seeded', true));
  return v_n;
end $$;

do $$ declare f text; begin
  foreach f in array array['save_stock_list_item(text,text)', 'set_stock_list_item_active(uuid,boolean)', 'seed_stock_lists_from_use()'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

-- Existing restaurants: start the lists from what is already in use, so nothing they have is rejected later.
do $$ declare r record; begin
  for r in select id from public.restaurants loop
    perform app.seed_stock_lists(r.id);
  end loop;
end $$;

-- The check. Skipped when the restaurant has no active entry of that kind.
create or replace function app.check_stock_list() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_kind text; v_val text;
begin
  if tg_table_name = 'ingredients' then
    if tg_op = 'UPDATE' and new.category is not distinct from old.category then return new; end if;
    v_kind := 'category'; v_val := new.category;
  else
    v_kind := 'department'; v_val := new.department;
  end if;
  if nullif(btrim(coalesce(v_val, '')), '') is null then return new; end if;
  if exists (select 1 from public.stock_lists l where l.restaurant_id = new.restaurant_id and l.kind = v_kind and l.is_active)
     and not exists (select 1 from public.stock_lists l where l.restaurant_id = new.restaurant_id and l.kind = v_kind and l.is_active and lower(btrim(l.name)) = lower(btrim(v_val))) then
    raise exception '% is not in the % list. Choose one from the list, or ask the owner to add it (Stock, Lists).', btrim(v_val), v_kind;
  end if;
  return new;
end $$;

drop trigger if exists ingredients_check_category on public.ingredients;
create trigger ingredients_check_category before insert or update of category on public.ingredients for each row execute function app.check_stock_list();
drop trigger if exists material_requests_check_department on public.material_requests;
create trigger material_requests_check_department before insert on public.material_requests for each row execute function app.check_stock_list();
drop trigger if exists material_issues_check_department on public.material_issues;
create trigger material_issues_check_department before insert on public.material_issues for each row execute function app.check_stock_list();
