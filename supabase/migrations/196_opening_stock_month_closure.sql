-- Opening stock and month closure (Winsar: Opening Stock, Store Month Closure, Revoke Closure).
-- Opening stock: the starting quantity of an ingredient, entered once (only while the ingredient has no stock entries at the outlet).
-- Month closure: freezes a finished month. The closing quantity and value of every ingredient is saved, and receipts that belong to a
-- closed month can no longer be cancelled or returned. Only the latest closed month can be re-opened, and only by someone who can change settings.

alter table public.stock_movements drop constraint if exists stock_movements_reason_check;
alter table public.stock_movements add constraint stock_movements_reason_check
  check (reason is null or reason = any (array['spoilage','expired','spill','breakage','staff_meal','sample','theft','count_correction','issued','opening','other']::text[]));

create table if not exists public.stock_month_closures (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id     uuid not null,
  month         date not null check (month = date_trunc('month', month)::date),
  total_value   numeric(14,2) not null default 0,
  closed_by     uuid not null references public.users(id),
  closed_at     timestamptz not null default now(),
  revoked_at    timestamptz,
  revoked_by    uuid references public.users(id),
  revoke_reason text,
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id)
);
create unique index if not exists stock_month_closures_open_uq on public.stock_month_closures (branch_id, month) where revoked_at is null;

create table if not exists public.stock_closure_lines (
  closure_id    uuid not null references public.stock_month_closures(id) on delete cascade,
  restaurant_id uuid not null,
  branch_id     uuid not null,
  ingredient_id uuid not null,
  closing_qty   numeric(14,4) not null,
  unit_cost     numeric(12,4) not null default 0,
  value         numeric(14,2) not null default 0,
  primary key (closure_id, ingredient_id),
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id) on delete cascade
);

alter table public.stock_month_closures enable row level security;
alter table public.stock_closure_lines enable row level security;
revoke all on public.stock_month_closures, public.stock_closure_lines from anon, authenticated;
grant select on public.stock_month_closures, public.stock_closure_lines to authenticated;
drop policy if exists tenant_read on public.stock_month_closures;
create policy tenant_read on public.stock_month_closures for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));
drop policy if exists tenant_read on public.stock_closure_lines;
create policy tenant_read on public.stock_closure_lines for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));

create or replace function app.assert_month_open(p_branch uuid, p_date date) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from public.stock_month_closures c where c.branch_id = p_branch and c.revoked_at is null and c.month = date_trunc('month', p_date)::date) then
    raise exception 'The stock for % is closed. Ask the owner to re-open that month first.', to_char(p_date, 'Mon YYYY');
  end if;
end $$;
revoke all on function app.assert_month_open(uuid, date) from public, anon, authenticated;

-- Opening stock: [{ingredient_id, qty, unit_cost?}]
create or replace function public.save_opening_stock(p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  l record; v_ing public.ingredients%rowtype; v_n int := 0; v_val numeric := 0; v_cost numeric;
begin
  perform app.require_feature('stock');
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one ingredient.'; end if;
  if jsonb_array_length(p_lines) > 500 then raise exception 'At most 500 lines at a time.'; end if;
  if (select count(distinct e->>'ingredient_id') from jsonb_array_elements(p_lines) e) <> jsonb_array_length(p_lines) then raise exception 'An ingredient is listed twice.'; end if;
  for l in select (x.e->>'ingredient_id')::uuid as iid, app.stock_num(x.e->>'qty') as qty, app.stock_num(x.e->>'unit_cost') as cost, x.ord
             from jsonb_array_elements(p_lines) with ordinality as x(e, ord) order by x.ord loop
    if l.iid is null then raise exception 'Line %: choose an ingredient.', l.ord; end if;
    if l.qty is null or l.qty <= 0 or l.qty > 9999999 then raise exception 'Line %: enter the opening quantity.', l.ord; end if;
    if l.cost is not null and (l.cost < 0 or l.cost > 9999999) then raise exception 'Line %: the cost is not valid.', l.ord; end if;
    select * into v_ing from public.ingredients where id = l.iid and restaurant_id = v_rest and is_active;
    if not found then raise exception 'Line %: ingredient not found.', l.ord; end if;
    perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || l.iid::text));
    if exists (select 1 from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = l.iid) then
      raise exception '% already has stock entries here. Use a stock count to correct it instead.', v_ing.name;
    end if;
    v_cost := coalesce(l.cost, v_ing.cost_per_unit);
    if coalesce(v_ing.cost_per_unit, 0) = 0 and coalesce(l.cost, 0) > 0 then update public.ingredients set cost_per_unit = l.cost where id = l.iid; end if;
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, reason)
    values (v_rest, v_branch, l.iid, 'adjust', round(l.qty, 4), v_cost, 'Opening stock', v_user, 'opening');
    v_n := v_n + 1; v_val := v_val + round(l.qty * v_cost, 2);
  end loop;
  perform app.audit('stock.opening', 'stock_movements', null, jsonb_build_object('lines', v_n, 'value', v_val));
  return jsonb_build_object('lines', v_n, 'value', v_val);
end $$;
revoke all on function public.save_opening_stock(jsonb) from public, anon;
grant execute on function public.save_opening_stock(jsonb) to authenticated;

-- Close a finished month.
create or replace function public.close_stock_month(p_month date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_tz text; v_m date; v_this date; v_first timestamptz; v_end timestamptz; v_id uuid := gen_random_uuid(); v_total numeric := 0; v_n int;
begin
  perform app.require_feature('stock');
  if p_month is null then raise exception 'Choose a month.'; end if;
  v_m := date_trunc('month', p_month)::date;
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_this := date_trunc('month', (now() at time zone v_tz))::date;
  if v_m >= v_this then raise exception 'Only a finished month can be closed. % is not over yet.', to_char(v_m, 'Mon YYYY'); end if;
  perform pg_advisory_xact_lock(hashtext('monthclose:' || v_branch::text));
  if exists (select 1 from public.stock_month_closures c where c.branch_id = v_branch and c.month = v_m and c.revoked_at is null) then
    raise exception '% is already closed.', to_char(v_m, 'Mon YYYY');
  end if;
  select min(m.created_at) into v_first from public.stock_movements m where m.branch_id = v_branch;
  if v_first is null then raise exception 'There is no stock to close yet.'; end if;
  -- months must be closed in order: the month before must be closed, unless nothing happened before it
  if date_trunc('month', (v_first at time zone v_tz))::date < v_m
     and not exists (select 1 from public.stock_month_closures c where c.branch_id = v_branch and c.month = (v_m - interval '1 month')::date and c.revoked_at is null) then
    raise exception 'Close % first.', to_char((v_m - interval '1 month')::date, 'Mon YYYY');
  end if;
  v_end := ((v_m + interval '1 month')::timestamp at time zone v_tz);
  insert into public.stock_month_closures (id, restaurant_id, branch_id, month, closed_by) values (v_id, v_rest, v_branch, v_m, v_user);
  insert into public.stock_closure_lines (closure_id, restaurant_id, branch_id, ingredient_id, closing_qty, unit_cost, value)
  select v_id, v_rest, v_branch, i.id, q.qty, i.cost_per_unit, round(q.qty * i.cost_per_unit, 2)
    from (select m.ingredient_id, sum(m.qty) as qty from public.stock_movements m where m.branch_id = v_branch and m.created_at < v_end group by m.ingredient_id) q
    join public.ingredients i on i.id = q.ingredient_id;
  get diagnostics v_n = row_count;
  select coalesce(sum(value), 0) into v_total from public.stock_closure_lines where closure_id = v_id;
  update public.stock_month_closures set total_value = v_total where id = v_id;
  perform app.audit('stock.month_close', 'stock_month_closures', v_id, jsonb_build_object('month', v_m, 'lines', v_n, 'value', v_total));
  return jsonb_build_object('id', v_id, 'month', v_m, 'lines', v_n, 'value', v_total);
end $$;
revoke all on function public.close_stock_month(date) from public, anon;
grant execute on function public.close_stock_month(date) to authenticated;

-- Re-open the latest closed month.
create or replace function public.reopen_stock_month(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('settings.manage');
  c public.stock_month_closures%rowtype;
begin
  perform app.require_feature('stock');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for re-opening the month.'; end if;
  select * into c from public.stock_month_closures where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Closed month not found.'; end if;
  if c.revoked_at is not null then raise exception '% is already open.', to_char(c.month, 'Mon YYYY'); end if;
  if exists (select 1 from public.stock_month_closures x where x.branch_id = c.branch_id and x.revoked_at is null and x.month > c.month) then
    raise exception 'Re-open the later months first. Only the latest closed month can be re-opened.';
  end if;
  update public.stock_month_closures set revoked_at = now(), revoked_by = v_user, revoke_reason = left(trim(p_reason), 300) where id = c.id;
  perform app.audit('stock.month_reopen', 'stock_month_closures', c.id, jsonb_build_object('month', c.month, 'reason', left(trim(p_reason), 300)));
  return jsonb_build_object('id', c.id, 'month', c.month);
end $$;
revoke all on function public.reopen_stock_month(uuid, text) from public, anon;
grant execute on function public.reopen_stock_month(uuid, text) to authenticated;

-- Patch: cancelling or returning a receipt that belongs to a closed month is refused; erase lists learn the new tables.
do $patch$
declare d text; d2 text; a text := 'raise exception ''Goods receipt not found.''; end if;';
begin
  d := pg_get_functiondef('public.cancel_goods_receipt(uuid,text)'::regprocedure);
  if position('assert_month_open' in d) = 0 then
    d2 := replace(d, a, a || ' perform app.assert_month_open(g.branch_id, g.received_on);');
    if d2 = d then raise exception '196: anchor not found in cancel_goods_receipt'; end if;
    execute d2;
  end if;
  d := pg_get_functiondef('public.return_goods(uuid,jsonb,text,uuid)'::regprocedure);
  if position('assert_month_open' in d) = 0 then
    d2 := replace(d, a, a || ' perform app.assert_month_open(g.branch_id, g.received_on);');
    if d2 = d then raise exception '196: anchor not found in return_goods'; end if;
    execute d2;
  end if;
  d := pg_get_functiondef('app.erase_groups()'::regprocedure);
  if position('stock_closure_lines' in d) = 0 then
    d2 := replace(d, '''stock_tx'', jsonb_build_array(', '''stock_tx'', jsonb_build_array(''stock_closure_lines'', ''stock_month_closures'', ');
    if d2 = d then raise exception '196: anchor not found in erase_groups'; end if;
    execute d2;
  end if;
end $patch$;
