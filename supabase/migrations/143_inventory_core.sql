-- 143: Inventory core (Batch 3, plan section 5.1). A DELTA on the live stock module of 050 / 057 / 079 / 093: nothing is recreated.
--
--  1. Rights stock.view (see levels, costs, movements, the four stock reports) and stock.adjust (wastage, stock count, manual adjustment).
--     Granted to every role that has stock.manage (so custom roles keep working) and to the system role Chef (also for restaurants created later,
--     by a small trigger on roles). Cashier / Steward / Waiter get nothing; they still get the POS warning (stock_warnings is behind order.create
--     and returns names and quantities only, no costs).
--  2. stock_movements: business_date (the restaurant's business day, so stock reports agree with sales reports), reason, count_id, client_ref.
--     Old rows are back-filled (business_date from the bill, or from created_at with the branch's day cut-off; unit_cost with the ingredient's
--     CURRENT cost for sale / returned / wastage / count / adjust rows that have none). The append-only update trigger is switched off for
--     the back-fill only, inside this transaction, and switched on again.
--  3. app.stock_stamp(): BEFORE INSERT trigger that fills business_date and unit_cost (cost snapshot at the time of the movement) so the old
--     trigger functions (stock_on_item, stock_on_item_option, transfer_stock, goods receipts) need no change.
--  4. app.stock_on_void REPLACED: returns food by order_item_id of the lines that are on the voided bill NOW (a moved / merged line no longer
--     returns stock for food that sits on another bill). One 'returned' row per line and ingredient, with the line id on it. Same trigger, still once.
--  5. record_stock REPLACED (same signature): purchase needs stock.manage, wastage / count need stock.adjust OR stock.manage; the weighted-average
--     cost uses the total on hand of ALL outlets (the ingredient has one cost for the restaurant). goods_receipts (079) keep their own cost logic
--     (weighted against the receiving outlet's stock): left untouched on purpose.
--  6. stock_in_quick, adjust_stock, stock_count_apply (+ tables stock_counts, stock_count_lines), stock_warnings, low_stock_items.
--  7. RLS: tenant_read on ingredients, recipe_lines, stock_movements now needs stock.view OR stock.manage (stock_movements keeps its outlet
--     condition from 057). stock_report (kept, used by the Stock screen) needs stock.view OR stock.manage and counts days by business_date.
--
-- Rights: stock.manage keeps implying view and adjust everywhere ("stock.view OR stock.manage", "stock.adjust OR stock.manage"), so a role
-- created later with only stock.manage keeps working. Error text names the new right: "(stock.adjust)".
-- Large-wastage owner alert (plan 5.1 item 7): NOT built. app.audit_to_alert (068) works from a fixed list of action names and a fixed message
-- per action; adding one means rewriting that function. The Wastage report shows the big entries instead.
-- Safe to run again.

-- ---------------------------------------------------------------- 1. rights
insert into public.permissions (key, description, is_sensitive) values
  ('stock.view',   'See stock levels, costs and stock reports', true),
  ('stock.adjust', 'Record wastage, stock counts and stock adjustments', true)
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_key)
select r.role_id, k.key
  from (select distinct rp.role_id from public.role_permissions rp where rp.permission_key = 'stock.manage') r
 cross join (values ('stock.view'), ('stock.adjust')) k(key)
on conflict do nothing;

insert into public.role_permissions (role_id, permission_key)
select r.id, k.key from public.roles r cross join (values ('stock.view'), ('stock.adjust')) k(key)
 where r.is_system and r.name = 'Chef'
on conflict do nothing;

-- Restaurants created later: Owner and Manager already get every right at creation; the Chef role gets these two here.
create or replace function app.trg_grant_chef_stock() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.is_system and new.name = 'Chef' then
    insert into public.role_permissions (role_id, permission_key) values (new.id, 'stock.view'), (new.id, 'stock.adjust') on conflict do nothing;
  end if;
  return new;
end $$;
revoke all on function app.trg_grant_chef_stock() from public, anon, authenticated;
drop trigger if exists trg_grant_chef_stock on public.roles;
create trigger trg_grant_chef_stock after insert on public.roles for each row execute function app.trg_grant_chef_stock();

-- Helpers. require_stock_any: signed in + at least one of the rights (error names the first one). stock_num: number from text or null.
create or replace function app.require_stock_any(p_keys text[]) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k text;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  foreach k in array p_keys loop
    if app.has_permission(k) then return app.current_user_id(); end if;
  end loop;
  raise exception 'Your role does not allow this action (%).', p_keys[1];
end $$;
create or replace function app.stock_num(p text) returns numeric
language sql immutable as $$ select case when p ~ '^-?[0-9]{1,12}(\.[0-9]{1,6})?$' then p::numeric end $$;
revoke all on function app.require_stock_any(text[]), app.stock_num(text) from public, anon, authenticated;

-- ---------------------------------------------------------------- 2. stock_movements columns, back-fill
alter table public.stock_movements add column if not exists business_date date;
alter table public.stock_movements add column if not exists reason text;
alter table public.stock_movements add column if not exists count_id uuid;
alter table public.stock_movements add column if not exists client_ref uuid;

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.stock_movements'::regclass and conname = 'stock_movements_reason_check') then
    alter table public.stock_movements add constraint stock_movements_reason_check
      check (reason is null or reason in ('spoilage', 'expired', 'spill', 'breakage', 'staff_meal', 'sample', 'theft', 'count_correction', 'other'));
  end if;
end $$;

alter table public.stock_movements disable trigger trg_no_update_stock;

update public.stock_movements m
   set business_date = coalesce(
         (select o.business_date from public.orders o where o.id = m.order_id),
         ((m.created_at at time zone coalesce(b.timezone, r.timezone, 'UTC')) - coalesce(bs.day_cutoff, '04:00'::time)::interval)::date)
  from public.branches b
  join public.restaurants r on r.id = b.restaurant_id
  left join public.branch_settings bs on bs.branch_id = b.id
 where b.id = m.branch_id and m.business_date is null;

update public.stock_movements m set unit_cost = i.cost_per_unit
  from public.ingredients i
 where i.id = m.ingredient_id and m.unit_cost is null and m.kind in ('sale', 'returned', 'wastage', 'count', 'adjust');

alter table public.stock_movements enable trigger trg_no_update_stock;

alter table public.stock_movements alter column business_date set not null;

create index if not exists stock_movements_bd_idx on public.stock_movements (branch_id, ingredient_id, business_date);
create index if not exists stock_movements_item_idx on public.stock_movements (order_item_id) where order_item_id is not null;
create unique index if not exists stock_movements_client_ref_uq on public.stock_movements (restaurant_id, client_ref) where client_ref is not null;

-- ---------------------------------------------------------------- 3. stamp trigger
create or replace function app.stock_stamp() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.business_date is null then
    if new.order_id is not null then
      select o.business_date into new.business_date from public.orders o where o.id = new.order_id;
    end if;
    if new.business_date is null then
      new.business_date := coalesce(app.business_today(new.branch_id), (now() at time zone 'UTC')::date);
    end if;
  end if;
  if new.unit_cost is null and new.kind in ('sale', 'returned', 'wastage', 'count', 'adjust') then
    if new.kind = 'returned' and new.order_item_id is not null then
      -- food that comes back is valued at what it was taken out at (weighted over that line's earlier sale rows)
      select sum(m.qty * m.unit_cost) / nullif(sum(m.qty), 0) into new.unit_cost
        from public.stock_movements m
       where m.order_item_id = new.order_item_id and m.ingredient_id = new.ingredient_id and m.kind = 'sale' and m.unit_cost is not null;
    end if;
    if new.unit_cost is null then
      select i.cost_per_unit into new.unit_cost from public.ingredients i where i.id = new.ingredient_id;
    end if;
  end if;
  return new;
end $$;
revoke all on function app.stock_stamp() from public, anon, authenticated;
drop trigger if exists trg_stock_stamp on public.stock_movements;
create trigger trg_stock_stamp before insert on public.stock_movements for each row execute function app.stock_stamp();

-- ---------------------------------------------------------------- 4. void returns by line
create or replace function app.stock_on_void() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  if new.status = 'voided' and old.status <> 'voided' then
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id, note)
    select new.restaurant_id, sm.branch_id, sm.ingredient_id, 'returned', -sum(sm.qty), new.id, sm.order_item_id, 'Bill voided'
      from public.stock_movements sm
     where sm.order_item_id in (select oi.id from public.order_items oi where oi.order_id = new.id)
       and sm.kind in ('sale', 'returned')
     group by sm.branch_id, sm.ingredient_id, sm.order_item_id
    having sum(sm.qty) < 0;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------- 5. weighted-average cost, record_stock
-- One cost per ingredient for the restaurant. Call BEFORE the purchase movement is written (the stock held is read first).
-- Stock at zero or below counts as nothing held: the new price becomes the cost.
create or replace function app.apply_purchase_cost(p_ingredient uuid, p_qty numeric, p_cost numeric) returns numeric
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_held numeric; v_cost numeric; v_new numeric;
begin
  if p_cost is null or p_cost < 0 or p_qty is null or p_qty <= 0 then
    select cost_per_unit into v_cost from public.ingredients where id = p_ingredient;
    return v_cost;
  end if;
  perform pg_advisory_xact_lock(hashtext('stockcost:' || p_ingredient::text));
  select coalesce(sum(m.qty), 0) into v_held from public.stock_movements m where m.ingredient_id = p_ingredient;
  select cost_per_unit into v_cost from public.ingredients where id = p_ingredient for update;
  v_new := case when v_held > 0 then round((v_held * v_cost + p_qty * p_cost) / (v_held + p_qty), 4) else round(p_cost, 4) end;
  update public.ingredients set cost_per_unit = v_new where id = p_ingredient;
  return v_new;
end $$;
revoke all on function app.apply_purchase_cost(uuid, numeric, numeric) from public, anon, authenticated;

create or replace function public.record_stock(p_ingredient_id uuid, p_kind text, p_qty numeric, p_unit_cost numeric default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_user uuid; v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_ing public.ingredients%rowtype; v_now numeric; v_move numeric;
begin
  perform app.require_feature('stock');
  if p_kind = 'purchase' then v_user := app.require_permission('stock.manage');
  else v_user := app.require_stock_any(array['stock.adjust', 'stock.manage']); end if;
  select * into v_ing from public.ingredients where id = p_ingredient_id and restaurant_id = v_rest;
  if not found then raise exception 'Ingredient not found.'; end if;
  if p_kind not in ('purchase', 'wastage', 'count') then raise exception 'Choose purchase, wastage or count.'; end if;
  if p_qty is null or p_qty < 0 or (p_kind <> 'count' and p_qty = 0) then raise exception 'Enter a quantity.'; end if;
  perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || v_ing.id::text));
  select coalesce(sum(qty), 0) into v_now from public.stock_movements where branch_id = v_branch and ingredient_id = v_ing.id;
  v_move := case p_kind when 'purchase' then p_qty when 'wastage' then -p_qty else p_qty - v_now end;
  if v_move = 0 and p_kind = 'count' then return jsonb_build_object('stock', v_now, 'change', 0); end if;
  -- A purchase at a new price updates the ingredient's cost (weighted with ALL the stock held, every outlet).
  if p_kind = 'purchase' and p_unit_cost is not null and p_unit_cost >= 0 then
    perform app.apply_purchase_cost(v_ing.id, p_qty, p_unit_cost);
  end if;
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, reason)
  values (v_rest, v_branch, v_ing.id, p_kind, v_move, case when p_kind = 'purchase' then p_unit_cost end,
          nullif(left(trim(coalesce(p_note, '')), 200), ''), v_user,
          case p_kind when 'wastage' then 'other' when 'count' then 'count_correction' end);
  perform app.audit('stock.' || p_kind, 'ingredients', v_ing.id, jsonb_build_object('qty', p_qty, 'change', v_move, 'unit_cost', p_unit_cost, 'note', p_note));
  return jsonb_build_object('stock', v_now + v_move, 'change', v_move);
end $$;

-- ---------------------------------------------------------------- 6a. quick stock-in
create or replace function public.stock_in_quick(p_lines jsonb, p_supplier_note text default null, p_bill_ref text default null, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_user uuid; v_rest uuid; v_branch uuid; v_seen record; l record; v_ing public.ingredients%rowtype;
  v_note text; v_total numeric := 0; v_lines jsonb := '[]'::jsonb; v_cost numeric; v_stock numeric; v_n int; v_out jsonb;
begin
  v_user := app.require_permission('stock.manage');
  perform app.require_feature('stock');
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind into v_seen from public.request_refs rr where rr.restaurant_id = v_rest and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'stock_in' then raise exception 'This request was already used for something else. Go back and try once more.'; end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one ingredient.'; end if;
  if jsonb_array_length(p_lines) > 200 then raise exception 'At most 200 lines in one stock-in.'; end if;
  -- check every line first, so a bad one stops the whole receipt before anything is written
  for l in select x.ord, x.e from jsonb_array_elements(p_lines) with ordinality as x(e, ord) order by x.ord loop
    if jsonb_typeof(l.e) <> 'object' or coalesce(l.e->>'ingredient_id', '') !~* '^[0-9a-f-]{36}$' then raise exception 'Line %: choose an ingredient.', l.ord; end if;
    if coalesce(app.stock_num(l.e->>'qty'), 0) <= 0 or app.stock_num(l.e->>'qty') > 9999999 then raise exception 'Line %: enter a quantity above zero.', l.ord; end if;
    if app.stock_num(l.e->>'unit_cost') is null or app.stock_num(l.e->>'unit_cost') < 0 or app.stock_num(l.e->>'unit_cost') > 9999999 then
      raise exception 'Line %: enter the cost per unit (zero or more).', l.ord;
    end if;
    if not exists (select 1 from public.ingredients i where i.id = (l.e->>'ingredient_id')::uuid and i.restaurant_id = v_rest and i.is_active) then
      raise exception 'Line %: ingredient not found.', l.ord;
    end if;
  end loop;
  v_note := nullif(left(concat_ws(' · ', nullif(trim(coalesce(p_supplier_note, '')), ''),
                                   case when nullif(trim(coalesce(p_bill_ref, '')), '') is not null then 'Bill ' || trim(p_bill_ref) end), 200), '');
  -- fixed order, so two people receiving at once cannot block each other
  for l in select (x.e->>'ingredient_id')::uuid as iid, app.stock_num(x.e->>'qty') as qty, app.stock_num(x.e->>'unit_cost') as cost, x.ord
             from jsonb_array_elements(p_lines) with ordinality as x(e, ord) order by (x.e->>'ingredient_id')::uuid, x.ord loop
    perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || l.iid::text));
    select * into v_ing from public.ingredients where id = l.iid;
    v_cost := app.apply_purchase_cost(l.iid, l.qty, l.cost);
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by)
    values (v_rest, v_branch, l.iid, 'purchase', l.qty, l.cost, v_note, v_user);
    select coalesce(sum(m.qty), 0) into v_stock from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = l.iid;
    v_total := v_total + round(l.qty * l.cost, 2);
    v_lines := v_lines || jsonb_build_object('ingredient_id', l.iid, 'name', v_ing.name, 'unit', v_ing.unit, 'qty', l.qty, 'unit_cost', l.cost,
                                             'new_cost', v_cost, 'stock', v_stock);
  end loop;
  v_n := jsonb_array_length(v_lines);
  perform app.audit('stock.in', 'ingredients', null,
    jsonb_build_object('lines', v_n, 'total_value', v_total, 'supplier', nullif(trim(coalesce(p_supplier_note, '')), ''), 'bill_ref', nullif(trim(coalesce(p_bill_ref, '')), '')));
  v_out := jsonb_build_object('lines', v_lines, 'count', v_n, 'total_value', v_total);
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result) values (v_rest, p_client_ref, 'stock_in', null, v_out);
    delete from public.request_refs where restaurant_id = v_rest and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $$;

-- ---------------------------------------------------------------- 6b. wastage / manual adjustment
create or replace function public.adjust_stock(p_ingredient uuid, p_kind text, p_qty numeric, p_reason text, p_note text default null, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_user uuid; v_rest uuid; v_branch uuid; v_ing public.ingredients%rowtype; v_old public.stock_movements%rowtype;
  v_signed numeric; v_mkind text; v_id uuid; v_stock numeric; v_cost numeric; v_val numeric;
begin
  v_user := app.require_stock_any(array['stock.adjust', 'stock.manage']);
  perform app.require_feature('stock');
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select * into v_old from public.stock_movements m where m.restaurant_id = v_rest and m.client_ref = p_client_ref;
    if found then
      if v_old.ingredient_id <> p_ingredient or v_old.branch_id <> v_branch then
        raise exception 'This request was already used for something else. Go back and try once more.';
      end if;
      select coalesce(sum(m.qty), 0) into v_stock from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = v_old.ingredient_id;
      return jsonb_build_object('movement_id', v_old.id, 'kind', p_kind, 'change', v_old.qty, 'value', round(abs(v_old.qty) * coalesce(v_old.unit_cost, 0), 2),
                                'stock', v_stock, 'repeat', true);
    end if;
  end if;
  if p_kind not in ('wastage', 'adjust_in', 'adjust_out') then raise exception 'Choose wastage, stock added or stock removed.'; end if;
  if p_qty is null or p_qty <= 0 or p_qty > 9999999 then raise exception 'Enter a quantity above zero.'; end if;
  if p_reason is null or p_reason not in ('spoilage', 'expired', 'spill', 'breakage', 'staff_meal', 'sample', 'theft', 'count_correction', 'other') then
    raise exception 'Choose a reason.';
  end if;
  select * into v_ing from public.ingredients where id = p_ingredient and restaurant_id = v_rest;
  if not found then raise exception 'Ingredient not found.'; end if;
  perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || v_ing.id::text));
  v_signed := case p_kind when 'adjust_in' then round(p_qty, 4) else -round(p_qty, 4) end;
  v_mkind := case p_kind when 'wastage' then 'wastage' else 'adjust' end;
  if v_signed = 0 then raise exception 'Enter a quantity above zero.'; end if;
  v_id := gen_random_uuid();
  insert into public.stock_movements (id, restaurant_id, branch_id, ingredient_id, kind, qty, note, created_by, reason, client_ref)
  values (v_id, v_rest, v_branch, v_ing.id, v_mkind, v_signed, nullif(left(trim(coalesce(p_note, '')), 200), ''), v_user, p_reason, p_client_ref);
  select m.unit_cost into v_cost from public.stock_movements m where m.id = v_id;
  v_val := round(abs(v_signed) * coalesce(v_cost, 0), 2);
  select coalesce(sum(m.qty), 0) into v_stock from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = v_ing.id;
  perform app.audit(case when p_kind = 'wastage' then 'stock.wastage' else 'stock.adjust' end, 'ingredients', v_ing.id,
    jsonb_build_object('ingredient', v_ing.name, 'kind', p_kind, 'qty', abs(v_signed), 'reason', p_reason, 'note', nullif(trim(coalesce(p_note, '')), ''), 'value', v_val));
  return jsonb_build_object('movement_id', v_id, 'kind', p_kind, 'change', v_signed, 'value', v_val, 'stock', v_stock);
end $$;

-- ---------------------------------------------------------------- 6c. stock count
create table if not exists public.stock_counts (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  business_date date not null,
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  client_ref uuid,
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  unique (restaurant_id, id)
);
create unique index if not exists stock_counts_client_ref_uq on public.stock_counts (restaurant_id, client_ref) where client_ref is not null;
create index if not exists stock_counts_branch_idx on public.stock_counts (branch_id, business_date);

create table if not exists public.stock_count_lines (
  count_id uuid not null references public.stock_counts(id) on delete cascade,
  restaurant_id uuid not null,
  branch_id uuid not null,
  ingredient_id uuid not null,
  expected numeric(14,4) not null,
  counted numeric(14,4) not null check (counted >= 0),
  diff numeric(14,4) not null,
  unit_cost numeric(12,4) not null default 0,
  value_diff numeric(14,2) not null default 0,
  primary key (count_id, ingredient_id),
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id) on delete cascade
);

alter table public.stock_counts enable row level security;
alter table public.stock_count_lines enable row level security;
revoke all on public.stock_counts, public.stock_count_lines from anon, authenticated;
grant select on public.stock_counts, public.stock_count_lines to authenticated;
drop policy if exists tenant_read on public.stock_counts;
create policy tenant_read on public.stock_counts for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));
drop policy if exists tenant_read on public.stock_count_lines;
create policy tenant_read on public.stock_count_lines for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));

create or replace function public.stock_count_apply(p_lines jsonb, p_note text default null, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_user uuid; v_rest uuid; v_branch uuid; v_old public.stock_counts%rowtype; v_id uuid := gen_random_uuid(); l record; v_ing public.ingredients%rowtype;
  v_exp numeric; v_cnt numeric; v_diff numeric; v_n int := 0; v_adj int := 0; v_var numeric := 0; v_date date;
begin
  v_user := app.require_stock_any(array['stock.adjust', 'stock.manage']);
  perform app.require_feature('stock');
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select * into v_old from public.stock_counts c where c.restaurant_id = v_rest and c.client_ref = p_client_ref;
    if found then
      if v_old.branch_id <> v_branch then raise exception 'This request was already used for something else. Go back and try once more.'; end if;
      return jsonb_build_object('count_id', v_old.id,
        'lines', (select count(*) from public.stock_count_lines x where x.count_id = v_old.id),
        'adjusted', (select count(*) from public.stock_count_lines x where x.count_id = v_old.id and x.diff <> 0),
        'variance_value', (select coalesce(sum(x.value_diff), 0) from public.stock_count_lines x where x.count_id = v_old.id), 'repeat', true);
    end if;
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Count at least one ingredient.'; end if;
  if jsonb_array_length(p_lines) > 2000 then raise exception 'At most 2000 lines in one count.'; end if;
  for l in select x.ord, x.e from jsonb_array_elements(p_lines) with ordinality as x(e, ord) order by x.ord loop
    if jsonb_typeof(l.e) <> 'object' or coalesce(l.e->>'ingredient_id', '') !~* '^[0-9a-f-]{36}$' then raise exception 'Line %: choose an ingredient.', l.ord; end if;
    if app.stock_num(l.e->>'counted') is null or app.stock_num(l.e->>'counted') < 0 or app.stock_num(l.e->>'counted') > 9999999 then
      raise exception 'Line %: enter the counted quantity (zero or more).', l.ord;
    end if;
    if not exists (select 1 from public.ingredients i where i.id = (l.e->>'ingredient_id')::uuid and i.restaurant_id = v_rest and i.is_active) then
      raise exception 'Line %: ingredient not found.', l.ord;
    end if;
  end loop;
  if (select count(distinct (e->>'ingredient_id')::uuid) from jsonb_array_elements(p_lines) e) <> jsonb_array_length(p_lines) then
    raise exception 'An ingredient is listed twice in this count.';
  end if;
  -- one count per outlet at a time; expected is read AFTER the lock, at the moment of applying
  perform pg_advisory_xact_lock(hashtext('stockcount:' || v_branch::text));
  v_date := coalesce(app.business_today(v_branch), (now() at time zone 'UTC')::date);
  insert into public.stock_counts (id, restaurant_id, branch_id, business_date, note, created_by, client_ref)
  values (v_id, v_rest, v_branch, v_date, nullif(left(trim(coalesce(p_note, '')), 300), ''), v_user, p_client_ref);
  for l in select (x.e->>'ingredient_id')::uuid as iid, app.stock_num(x.e->>'counted') as counted
             from jsonb_array_elements(p_lines) as x(e) order by (x.e->>'ingredient_id')::uuid loop
    perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || l.iid::text));
    select * into v_ing from public.ingredients where id = l.iid;
    select coalesce(sum(m.qty), 0) into v_exp from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = l.iid;
    v_cnt := round(l.counted, 4); v_exp := round(v_exp, 4); v_diff := v_cnt - v_exp;
    insert into public.stock_count_lines (count_id, restaurant_id, branch_id, ingredient_id, expected, counted, diff, unit_cost, value_diff)
    values (v_id, v_rest, v_branch, l.iid, v_exp, v_cnt, v_diff, v_ing.cost_per_unit, round(v_diff * v_ing.cost_per_unit, 2));
    v_n := v_n + 1;
    if v_diff <> 0 then
      insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, note, created_by, reason, count_id)
      values (v_rest, v_branch, l.iid, 'count', v_diff, 'Stock count', v_user, 'count_correction', v_id);
      v_adj := v_adj + 1; v_var := v_var + round(v_diff * v_ing.cost_per_unit, 2);
    end if;
  end loop;
  perform app.audit('stock.count', 'stock_counts', v_id, jsonb_build_object('lines', v_n, 'adjusted', v_adj, 'variance_value', v_var));
  return jsonb_build_object('count_id', v_id, 'lines', v_n, 'adjusted', v_adj, 'variance_value', v_var);
end $$;

-- ---------------------------------------------------------------- 6d. POS warning and low-stock card
-- p_items: [{product_id, qty, options:[modifier_item_ids]}], the shape quote_order takes. Names and quantities only (no costs).
create or replace function public.stock_warnings(p_items jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_rest uuid; v_branch uuid;
begin
  perform app.require_permission('order.create');
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  if not app.feature_on(v_rest, 'stock') or p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 100 then
    return jsonb_build_object('warnings', '[]'::jsonb);
  end if;
  return jsonb_build_object('warnings', coalesce((
    with it as (
      select case when e->>'product_id' ~* '^[0-9a-f-]{36}$' then (e->>'product_id')::uuid end as pid,
             greatest(coalesce(app.stock_num(e->>'qty'), 1), 0) as qty,
             case when jsonb_typeof(e->'options') = 'array' then e->'options' else '[]'::jsonb end as opts
        from jsonb_array_elements(p_items) e),
    src as (
      select it.pid as recipe_product, it.qty from it where it.pid is not null
      union all
      select mi.product_id, it.qty
        from it
        cross join lateral jsonb_array_elements_text(it.opts) o
        join public.modifier_items mi on mi.id = case when o ~* '^[0-9a-f-]{36}$' then o::uuid end and mi.restaurant_id = v_rest
       where mi.product_id is not null),
    need as (
      select rl.ingredient_id, sum(rl.qty * s.qty) as need
        from src s join public.recipe_lines rl on rl.product_id = s.recipe_product and rl.restaurant_id = v_rest
       group by rl.ingredient_id having sum(rl.qty * s.qty) > 0),
    lvl as (
      select i.id, i.name, i.unit, i.reorder_level, n.need,
             coalesce((select sum(m.qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id), 0) as on_hand
        from need n join public.ingredients i on i.id = n.ingredient_id and i.restaurant_id = v_rest and i.is_active),
    w as (
      select l.*, l.on_hand - l.need as after,
             case when l.on_hand - l.need <= 0 then 'out' when l.reorder_level > 0 and l.on_hand - l.need <= l.reorder_level then 'low' end as level
        from lvl l)
    select jsonb_agg(jsonb_build_object('ingredient_id', w.id, 'name', w.name, 'unit', w.unit, 'need', round(w.need, 4), 'on_hand', round(w.on_hand, 4),
                                        'after', round(w.after, 4), 'level', w.level)
                     order by (w.level = 'out') desc, w.name)
      from w where w.level is not null), '[]'::jsonb));
end $$;

create or replace function public.low_stock_items(p_limit int default 20) returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $$
declare v_rest uuid; v_branch uuid; v_lim int := least(greatest(coalesce(p_limit, 20), 1), 200);
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  if not app.feature_on(v_rest, 'stock') then
    return jsonb_build_object('items', '[]'::jsonb, 'counts', jsonb_build_object('out', 0, 'low', 0, 'negative', 0));
  end if;
  return (
    with s as (
      select i.id, i.name, i.unit, i.reorder_level,
             coalesce((select sum(m.qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id), 0) as on_hand
        from public.ingredients i where i.restaurant_id = v_rest and i.is_active),
    f as (
      select s.*, case when s.on_hand < 0 then 'negative' when s.on_hand = 0 then 'out' else 'low' end as status
        from s where s.on_hand < 0 or (s.reorder_level > 0 and s.on_hand <= s.reorder_level))
    select jsonb_build_object(
      'items', coalesce((select jsonb_agg(jsonb_build_object('ingredient_id', x.id, 'name', x.name, 'unit', x.unit, 'on_hand', x.on_hand,
                                                              'reorder_level', x.reorder_level, 'status', x.status)
                                           order by x.on_hand / greatest(x.reorder_level, 0.0001), x.name)
                           from (select * from f order by f.on_hand / greatest(f.reorder_level, 0.0001), f.name limit v_lim) x), '[]'::jsonb),
      'counts', jsonb_build_object('out', (select count(*) from f where f.status = 'out'), 'low', (select count(*) from f where f.status = 'low'),
                                   'negative', (select count(*) from f where f.status = 'negative')))
  );
end $$;

-- ---------------------------------------------------------------- 7. RLS tighten, stock_report
drop policy if exists tenant_read on public.ingredients;
create policy tenant_read on public.ingredients for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id())
  and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));
drop policy if exists tenant_read on public.recipe_lines;
create policy tenant_read on public.recipe_lines for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id())
  and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));
drop policy if exists tenant_read on public.stock_movements;
create policy tenant_read on public.stock_movements for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));

-- stock_report keeps its shape; it now needs stock.view OR stock.manage and counts days by business_date (the sales reports' day).
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.stock_report(date,date)'::regprocedure);
  if position('require_stock_any' in v_def) = 0 then
    v_def := replace(v_def, 'perform app.require_permission(''stock.manage'');', 'perform app.require_stock_any(array[''stock.view'', ''stock.manage'']);');
    v_def := replace(v_def, 'm.created_at >= v_start and m.created_at < v_end', 'm.business_date between p_from and p_to');
    if position('require_stock_any' in v_def) = 0 or position('m.created_at >= v_start' in v_def) > 0 then raise exception 'stock_report patch failed'; end if;
    execute v_def;
  end if;
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function public.record_stock(uuid,text,numeric,numeric,text), public.stock_in_quick(jsonb,text,text,uuid),
  public.adjust_stock(uuid,text,numeric,text,text,uuid), public.stock_count_apply(jsonb,text,uuid), public.stock_warnings(jsonb),
  public.low_stock_items(int), public.stock_report(date,date) from public, anon;
grant execute on function public.record_stock(uuid,text,numeric,numeric,text), public.stock_in_quick(jsonb,text,text,uuid),
  public.adjust_stock(uuid,text,numeric,text,text,uuid), public.stock_count_apply(jsonb,text,uuid), public.stock_warnings(jsonb),
  public.low_stock_items(int), public.stock_report(date,date) to authenticated;
