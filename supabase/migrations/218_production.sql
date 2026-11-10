-- Production, like Winsar's Production menu but simpler: a recipe (bill of material) for a prepared item,
-- an optional plan, and a production entry that uses the ingredients up and puts the prepared item on the shelf.
--
-- A prepared item is an ordinary stock item (for example "Butter masala gravy", kg). Its recipe says: to make
-- <yield> of it, use these ingredients. Producing scales the recipe to the quantity made. Stock moves through
-- the same stock_movements ledger as everything else (kind 'adjust', reason 'production'), so the stock
-- reports, the ledger, the day and month closure and the count all keep working without change.

alter table public.stock_movements drop constraint if exists stock_movements_reason_check;
alter table public.stock_movements add constraint stock_movements_reason_check check (
  reason is null or reason = any (array['spoilage','expired','spill','breakage','staff_meal','sample','theft','count_correction','issued','opening','production','other']));

create table if not exists public.production_boms (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  output_ingredient_id uuid not null,
  yield_qty numeric(14,3) not null check (yield_qty > 0),
  note text check (note is null or length(note) <= 300),
  updated_at timestamptz not null default now(),
  unique (restaurant_id, output_ingredient_id),
  foreign key (restaurant_id, output_ingredient_id) references public.ingredients (restaurant_id, id)
);

create table if not exists public.production_bom_lines (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  bom_id uuid not null references public.production_boms(id) on delete cascade,
  ingredient_id uuid not null,
  qty numeric(14,4) not null check (qty > 0),
  unique (bom_id, ingredient_id),
  foreign key (restaurant_id, ingredient_id) references public.ingredients (restaurant_id, id)
);

create table if not exists public.production_runs (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  branch_id uuid not null references public.branches(id),
  number text not null,
  output_ingredient_id uuid not null,
  planned_qty numeric(14,3) not null check (planned_qty > 0),
  produced_qty numeric(14,3) check (produced_qty is null or produced_qty > 0),
  planned_for date not null,
  produced_on date,
  status text not null default 'planned' check (status in ('planned','produced','cancelled')),
  value numeric(14,2) not null default 0,
  note text check (note is null or length(note) <= 300),
  created_by uuid not null references public.users(id),
  produced_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  client_ref uuid,
  unique (branch_id, number),
  foreign key (restaurant_id, output_ingredient_id) references public.ingredients (restaurant_id, id)
);
create unique index if not exists production_runs_client_ref on public.production_runs (restaurant_id, client_ref) where client_ref is not null;
create index if not exists production_runs_branch_day on public.production_runs (branch_id, produced_on);

create table if not exists public.production_run_lines (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  run_id uuid not null references public.production_runs(id) on delete cascade,
  ingredient_id uuid not null,
  qty numeric(14,4) not null check (qty > 0),
  unit_cost numeric(14,4) not null,
  foreign key (restaurant_id, ingredient_id) references public.ingredients (restaurant_id, id)
);
create index if not exists production_run_lines_run on public.production_run_lines (run_id);

alter table public.production_boms enable row level security;
alter table public.production_bom_lines enable row level security;
alter table public.production_runs enable row level security;
alter table public.production_run_lines enable row level security;

-- Recipes are the same for every outlet; runs belong to the outlet that made them.
create policy tenant_read on public.production_boms for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()) and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));
create policy tenant_read on public.production_bom_lines for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()) and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));
create policy tenant_read on public.production_runs for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()) and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage')))
         and branch_id = (select app.current_branch_id()));
create policy tenant_read on public.production_run_lines for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()) and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));

revoke all on public.production_boms, public.production_bom_lines, public.production_runs, public.production_run_lines from public, anon, authenticated;
grant select on public.production_boms, public.production_bom_lines, public.production_runs, public.production_run_lines to authenticated;

-- Save (create or replace) the recipe of a prepared item.
create or replace function public.save_production_bom(p_output uuid, p_yield numeric, p_lines jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id();
  v_bom uuid; x record; v_seen uuid[] := '{}'; v_name text;
begin
  perform app.require_feature('stock');
  select name into v_name from public.ingredients where id = p_output and restaurant_id = v_rest and is_active;
  if not found then raise exception 'Choose the item that is being made.'; end if;
  if p_yield is null or p_yield <= 0 or p_yield > 9999999 then raise exception 'Enter how much one batch makes (more than zero).'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one ingredient to the recipe.'; end if;
  if jsonb_array_length(p_lines) > 60 then raise exception 'At most 60 ingredients in one recipe.'; end if;
  insert into public.production_boms (restaurant_id, output_ingredient_id, yield_qty, note)
  values (v_rest, p_output, round(p_yield, 3), nullif(left(btrim(coalesce(p_note, '')), 300), ''))
  on conflict (restaurant_id, output_ingredient_id) do update set yield_qty = excluded.yield_qty, note = excluded.note, updated_at = now()
  returning id into v_bom;
  delete from public.production_bom_lines where bom_id = v_bom;
  for x in select (e->>'ingredient_id')::uuid as ingredient_id, (e->>'qty')::numeric as qty from jsonb_array_elements(p_lines) e loop
    if x.ingredient_id = p_output then raise exception '% cannot be used to make itself.', v_name; end if;
    if x.ingredient_id = any (v_seen) then raise exception 'An ingredient is on the recipe twice. Put it on one line.'; end if;
    v_seen := v_seen || x.ingredient_id;
    if x.qty is null or x.qty <= 0 or x.qty > 9999999 then raise exception 'Enter a quantity above zero on each line.'; end if;
    if not exists (select 1 from public.ingredients where id = x.ingredient_id and restaurant_id = v_rest and is_active) then
      raise exception 'An ingredient on the recipe no longer exists.';
    end if;
    insert into public.production_bom_lines (restaurant_id, bom_id, ingredient_id, qty) values (v_rest, v_bom, x.ingredient_id, round(x.qty, 4));
  end loop;
  perform app.audit('production.recipe_saved', 'production_boms', v_bom, jsonb_build_object('item', v_name, 'yield', p_yield, 'lines', array_length(v_seen, 1)));
  return jsonb_build_object('id', v_bom, 'item', v_name);
end $$;

create or replace function public.delete_production_bom(p_output uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_name text;
begin
  perform app.require_permission('stock.manage');
  perform app.require_feature('stock');
  select i.name into v_name from public.production_boms b join public.ingredients i on i.id = b.output_ingredient_id
   where b.restaurant_id = v_rest and b.output_ingredient_id = p_output;
  if not found then raise exception 'That recipe was not found.'; end if;
  if exists (select 1 from public.production_runs where restaurant_id = v_rest and output_ingredient_id = p_output and status = 'planned') then
    raise exception 'There is still a plan for % waiting. Cancel it first.', v_name;
  end if;
  delete from public.production_boms where restaurant_id = v_rest and output_ingredient_id = p_output;
  perform app.audit('production.recipe_deleted', 'production_boms', null, jsonb_build_object('item', v_name));
  return jsonb_build_object('item', v_name);
end $$;

-- Plan a batch for today or a later day. Nothing moves until it is produced.
create or replace function public.plan_production(p_output uuid, p_qty numeric, p_for date default null, p_note text default null, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_today date; v_for date; v_id uuid := gen_random_uuid(); v_no text; v_seq int; v_out jsonb;
begin
  perform app.require_feature('stock');
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('pr_ref:' || p_client_ref::text));
    select jsonb_build_object('id', r.id, 'number', r.number, 'repeat', true) into v_out from public.production_runs r where r.restaurant_id = v_rest and r.client_ref = p_client_ref;
    if v_out is not null then return v_out; end if;
  end if;
  if not exists (select 1 from public.production_boms where restaurant_id = v_rest and output_ingredient_id = p_output) then
    raise exception 'This item has no recipe yet. Add its recipe first.';
  end if;
  if p_qty is null or p_qty <= 0 or p_qty > 9999999 then raise exception 'Enter how much to make (more than zero).'; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;
  v_for := coalesce(p_for, v_today);
  if v_for < v_today then raise exception 'Plan for today or a later day.'; end if;
  if v_for > v_today + 60 then raise exception 'Plan at most 60 days ahead.'; end if;
  perform pg_advisory_xact_lock(hashtext('production:' || v_branch::text));
  select count(*) + 1 into v_seq from public.production_runs where branch_id = v_branch;
  v_no := 'PR-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');
  insert into public.production_runs (id, restaurant_id, branch_id, number, output_ingredient_id, planned_qty, planned_for, status, note, created_by, client_ref)
  values (v_id, v_rest, v_branch, v_no, p_output, round(p_qty, 3), v_for, 'planned', nullif(left(btrim(coalesce(p_note, '')), 300), ''), v_user, p_client_ref);
  perform app.audit('production.planned', 'production_runs', v_id, jsonb_build_object('number', v_no, 'qty', p_qty, 'for', v_for));
  return jsonb_build_object('id', v_id, 'number', v_no);
end $$;

create or replace function public.cancel_production_plan(p_run uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); r public.production_runs%rowtype;
begin
  perform app.require_permission('stock.manage');
  perform app.require_feature('stock');
  select * into r from public.production_runs where id = p_run and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'Plan not found.'; end if;
  if r.status <> 'planned' then raise exception '% is already %.', r.number, r.status; end if;
  update public.production_runs set status = 'cancelled' where id = r.id;
  perform app.audit('production.cancelled', 'production_runs', r.id, jsonb_build_object('number', r.number));
  return jsonb_build_object('number', r.number);
end $$;

-- Make a batch now (from a plan, or straight away). Uses the ingredients up at today's cost and puts the
-- prepared item on the shelf at what the batch cost, blended with what is already held.
create or replace function public.produce_batch(p_run uuid default null, p_output uuid default null, p_qty numeric default null,
                                                p_date date default null, p_note text default null, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  r public.production_runs%rowtype; bom public.production_boms%rowtype; x record;
  v_id uuid; v_no text; v_seq int; v_out uuid; v_qty numeric; v_day date; v_real date; v_bd date; v_cost numeric; v_scaled numeric;
  v_total numeric(14,2) := 0; v_unit numeric; v_name text; v_res jsonb; v_iname text;
begin
  perform app.require_feature('stock');
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('pr_ref:' || p_client_ref::text));
    select jsonb_build_object('id', q.id, 'number', q.number, 'value', q.value, 'repeat', true) into v_res from public.production_runs q
     where q.restaurant_id = v_rest and q.client_ref = p_client_ref and q.status = 'produced';
    if v_res is not null then return v_res; end if;
  end if;
  v_real := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;
  v_day := app.check_doc_date(p_date, false);
  if v_day <> v_real then perform app.assert_month_open(v_branch, v_day); end if;
  v_bd := case when v_day < v_real then v_day else null end;

  if p_run is not null then
    select * into r from public.production_runs where id = p_run and restaurant_id = v_rest and branch_id = v_branch for update;
    if not found then raise exception 'Plan not found.'; end if;
    if r.status <> 'planned' then raise exception '% is already %.', r.number, r.status; end if;
    v_id := r.id; v_no := r.number; v_out := r.output_ingredient_id; v_qty := coalesce(p_qty, r.planned_qty);
  else
    v_out := p_output; v_qty := p_qty;
  end if;
  if v_out is null then raise exception 'Choose the item that is being made.'; end if;
  if v_qty is null or v_qty <= 0 or v_qty > 9999999 then raise exception 'Enter how much was made (more than zero).'; end if;
  v_qty := round(v_qty, 3);
  select * into bom from public.production_boms where restaurant_id = v_rest and output_ingredient_id = v_out;
  if not found then raise exception 'This item has no recipe yet. Add its recipe first.'; end if;
  select name into v_name from public.ingredients where id = v_out and restaurant_id = v_rest and is_active;
  if not found then raise exception 'The item being made no longer exists.'; end if;

  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('production:' || v_branch::text));
    select count(*) + 1 into v_seq from public.production_runs where branch_id = v_branch;
    v_no := 'PR-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');
    v_id := gen_random_uuid();
    insert into public.production_runs (id, restaurant_id, branch_id, number, output_ingredient_id, planned_qty, planned_for, status, created_by, client_ref)
    values (v_id, v_rest, v_branch, v_no, v_out, v_qty, v_day, 'planned', v_user, p_client_ref);
  end if;

  -- ingredients out, in a fixed order so two people producing at once cannot block each other
  for x in select l.ingredient_id, l.qty from public.production_bom_lines l where l.bom_id = bom.id order by l.ingredient_id loop
    v_scaled := round(x.qty * v_qty / bom.yield_qty, 4);
    if v_scaled <= 0 then continue; end if;
    perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || x.ingredient_id::text));
    select name, cost_per_unit into v_iname, v_cost from public.ingredients where id = x.ingredient_id and restaurant_id = v_rest;
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, reason, note, created_by, business_date)
    values (v_rest, v_branch, x.ingredient_id, 'adjust', -v_scaled, v_cost, 'production', left(v_no || ' used to make ' || v_name, 200), v_user, v_bd);
    insert into public.production_run_lines (restaurant_id, run_id, ingredient_id, qty, unit_cost) values (v_rest, v_id, x.ingredient_id, v_scaled, v_cost);
    v_total := v_total + round(v_scaled * v_cost, 2);
  end loop;

  -- prepared item in, at what the batch cost per unit
  perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || v_out::text));
  v_unit := round(v_total / v_qty, 4);
  perform app.apply_purchase_cost(v_out, v_qty, v_unit);
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, reason, note, created_by, business_date)
  values (v_rest, v_branch, v_out, 'adjust', v_qty, v_unit, 'production', left(v_no || ' made', 200), v_user, v_bd);

  update public.production_runs
     set status = 'produced', produced_qty = v_qty, produced_on = v_day, value = v_total, produced_by = v_user,
         note = coalesce(nullif(left(btrim(coalesce(p_note, '')), 300), ''), note), client_ref = coalesce(client_ref, p_client_ref)
   where id = v_id;
  perform app.audit('production.produced', 'production_runs', v_id, jsonb_build_object('number', v_no, 'item', v_name, 'qty', v_qty, 'value', v_total));
  return jsonb_build_object('id', v_id, 'number', v_no, 'item', v_name, 'qty', v_qty, 'value', v_total, 'unit_cost', v_unit);
end $$;

-- Production summary: what was made, what it cost, what it used, and the plans still waiting.
create or replace function public.report_production(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  return (
    with d as (
      select r.id, r.number, r.produced_on, coalesce(b.name, '') as outlet, i.name as item, i.unit, r.produced_qty as qty, r.value,
             case when r.produced_qty > 0 then round(r.value / r.produced_qty, 4) else 0 end as unit_cost
        from public.production_runs r
        join public.ingredients i on i.id = r.output_ingredient_id
        left join public.branches b on b.id = r.branch_id
       where r.restaurant_id = v_rest and (v_rb is null or r.branch_id = v_rb) and r.status = 'produced' and r.produced_on between p_from and p_to),
    by_item as (select item, unit, count(*) as runs, sum(qty) as qty, sum(value) as value,
                       case when sum(qty) > 0 then round(sum(value) / sum(qty), 4) else 0 end as avg_cost from d group by item, unit),
    used as (
      select i.name as ingredient, i.unit, sum(l.qty) as qty, round(sum(l.qty * l.unit_cost), 2) as value
        from public.production_run_lines l
        join public.production_runs r on r.id = l.run_id
        join public.ingredients i on i.id = l.ingredient_id
       where r.restaurant_id = v_rest and (v_rb is null or r.branch_id = v_rb) and r.status = 'produced' and r.produced_on between p_from and p_to
       group by i.name, i.unit),
    waiting as (
      select r.number, r.planned_for, coalesce(b.name, '') as outlet, i.name as item, i.unit, r.planned_qty as qty
        from public.production_runs r
        join public.ingredients i on i.id = r.output_ingredient_id
        left join public.branches b on b.id = r.branch_id
       where r.restaurant_id = v_rest and (v_rb is null or r.branch_id = v_rb) and r.status = 'planned')
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(to_jsonb(d) order by d.produced_on desc, d.number desc) from d), '[]'::jsonb),
      'by_item', coalesce((select jsonb_agg(to_jsonb(x) order by x.value desc) from by_item x), '[]'::jsonb),
      'used', coalesce((select jsonb_agg(to_jsonb(u) order by u.value desc) from used u), '[]'::jsonb),
      'waiting', coalesce((select jsonb_agg(to_jsonb(w) order by w.planned_for, w.number) from waiting w), '[]'::jsonb),
      'totals', jsonb_build_object('runs', (select count(*) from d), 'value', coalesce((select sum(value) from d), 0)))
  );
end $$;

do $$
declare f text;
begin
  foreach f in array array['save_production_bom(uuid,numeric,jsonb,text)', 'delete_production_bom(uuid)', 'plan_production(uuid,numeric,date,text,uuid)',
    'cancel_production_plan(uuid)', 'produce_batch(uuid,uuid,numeric,date,text,uuid)', 'report_production(date,date)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;
