-- 136: change many prices at once - preview, apply, undo (menu.price_change)
--
-- An owner can raise or lower a whole category (or a hand-picked list of dishes) by a percentage or an amount,
-- see EXACTLY what will change first (preview), apply it as one batch, and undo that batch later.
--   * price_change_batches: one row per apply (who, mode, value, rounding, scope, reason, status applied|undone).
--   * price_change_lines:   one row per price that moved, scope 'base' (products.price) or 'branch' (a non-null
--                           outlet override in branch_prices - changed too and shown in the preview), old and new price.
--   * bulk_price_preview(...) no write; bulk_price_apply(...) writes; bulk_price_undo(batch) restores only the lines
--     whose price is STILL the price this batch set (a price edited by hand since stays as it is), and a batch can be
--     undone once only.
-- Safety:
--   * Bills already open or paid are never touched: order_items copy the price when the line is added.
--   * Needs menu.price_change (a manager PIN approval also works, as for discounts) and a written reason.
--   * ONE summary audit row (menu.bulk_price_change / menu.bulk_price_undo) and ONE owner alert per batch, instead of one
--     per dish: app.guard_product_change is replaced below with a minimal diff of 033 - while the transaction flag
--     app.bulk_price = 'on' (only the functions below set it) it skips the per-row audit; every other check stays.
--     product_price_history (app.track_price) still records every changed price, which protects offline bills.
--   * Idempotent: the same p_client_ref returns the batch already made, so a double tap cannot apply twice.
--   * Additive and all-or-nothing: two new tables, new functions, one function replaced. Nothing is dropped.
-- Roll back: drop the functions below, drop table price_change_lines, price_change_batches, and re-apply 033's guard.

create table public.price_change_batches (
  id               uuid primary key default gen_random_uuid(),
  restaurant_id    uuid not null references public.restaurants(id) on delete cascade,
  branch_id        uuid references public.branches(id) on delete set null,
  created_by       uuid references public.users(id) on delete set null,
  mode             text not null check (mode in ('percent', 'amount')),
  value            numeric(12,4) not null,
  rounding         numeric(6,2) not null check (rounding in (0.01, 0.5, 1)),
  include_branch   boolean not null default true,
  scope            jsonb not null default '{}'::jsonb,
  reason           text not null check (length(btrim(reason)) >= 3),
  status           text not null default 'applied' check (status in ('applied', 'undone')),
  line_count       int not null default 0,
  client_ref       uuid,
  created_at       timestamptz not null default now(),
  undone_at        timestamptz,
  undone_by        uuid references public.users(id) on delete set null,
  undo_restored    int,
  undo_skipped     int
);
create unique index price_change_batches_ref on public.price_change_batches (restaurant_id, client_ref) where client_ref is not null;
create index price_change_batches_rest on public.price_change_batches (restaurant_id, created_at desc);

create table public.price_change_lines (
  id             bigserial primary key,
  batch_id       uuid not null references public.price_change_batches(id) on delete cascade,
  restaurant_id  uuid not null references public.restaurants(id) on delete cascade,
  product_id     uuid not null references public.products(id) on delete cascade,
  scope          text not null check (scope in ('base', 'branch')),
  branch_id      uuid references public.branches(id) on delete cascade,
  old_price      numeric(14,2) not null,
  new_price      numeric(14,2) not null check (new_price >= 0),
  undo_state     text check (undo_state in ('restored', 'skipped')),
  check ((scope = 'branch') = (branch_id is not null))
);
create index price_change_lines_batch on public.price_change_lines (batch_id);

-- RLS pattern of 064/108/113: read-only for signed-in people with the right, writes only through the definer functions
alter table public.price_change_batches enable row level security;
alter table public.price_change_lines enable row level security;
revoke all on public.price_change_batches, public.price_change_lines from anon, authenticated;
revoke all on sequence public.price_change_lines_id_seq from anon, authenticated;
grant select on public.price_change_batches, public.price_change_lines to authenticated;
create policy tenant_read on public.price_change_batches for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()) and (select app.has_permission('menu.price_change')));
create policy tenant_read on public.price_change_lines for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()) and (select app.has_permission('menu.price_change')));

-- ---------------------------------------------------------------- the guard (033 body + the bulk flag)
create or replace function app.guard_product_change() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bulk boolean := coalesce(current_setting('app.bulk_price', true), '') = 'on';
begin
  -- no signed-in person (trusted server work); signed-in people without rights are already stopped by row security
  if app.current_user_id() is null then return new; end if;
  if tg_op = 'UPDATE' then
    if new.price is distinct from old.price and not app.has_permission('menu.price_change')
       -- a bulk change was already checked by bulk_price_apply, which accepts a manager PIN approval as well
       and not (v_bulk and coalesce(current_setting('app.approved.menu_price_change', true), '') = 'on') then
      raise exception 'You do not have the right to change prices.';
    end if;
    if new.tax_group_id is distinct from old.tax_group_id and not app.has_permission('tax.manage') then
      raise exception 'You do not have the right to change the tax on an item.';
    end if;
    if (new.price is distinct from old.price or new.tax_group_id is distinct from old.tax_group_id) and not v_bulk then
      perform app.audit('menu.price_or_tax_changed', 'product', new.id,
        jsonb_build_object('name', new.name, 'price', new.price, 'tax_group_id', new.tax_group_id),
        jsonb_build_object('price', old.price, 'tax_group_id', old.tax_group_id));
    end if;
  else
    perform app.audit('menu.item_added', 'product', new.id,
      jsonb_build_object('name', new.name, 'price', new.price, 'tax_group_id', new.tax_group_id));
  end if;
  return new;
end $$;
revoke all on function app.guard_product_change() from public, anon, authenticated;

-- ---------------------------------------------------------------- maths and the shared line list
create or replace function app.bulk_price_new(p_mode text, p_value numeric, p_rounding numeric, p_old numeric)
returns numeric language sql immutable as $$
  select least(10000000::numeric, greatest(0::numeric,
    round((case when p_mode = 'percent' then p_old * (1 + p_value / 100) else p_old + p_value end) / p_rounding) * p_rounding))
$$;

-- validates the inputs (shared by preview and apply) and returns the rows that would change
create or replace function app.bulk_price_lines(p_mode text, p_value numeric, p_rounding numeric, p_scope jsonb, p_include_branch boolean)
returns table (product_id uuid, product_name text, category_name text, line_scope text, branch_id uuid, branch_name text, old_price numeric, new_price numeric)
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_rest uuid := app.current_restaurant_id();
  v_cats uuid[]; v_prods uuid[]; v_all boolean;
begin
  if p_mode is null or p_mode not in ('percent', 'amount') then raise exception 'Choose percent or amount.'; end if;
  if p_value is null or p_value = 0 then raise exception 'Enter how much to change the prices by.'; end if;
  if p_mode = 'percent' and (p_value < -90 or p_value > 500) then raise exception 'A percentage change must be between -90 and 500.'; end if;
  if p_mode = 'amount' and abs(p_value) > 1000000 then raise exception 'Enter a sensible amount.'; end if;
  if p_rounding is null or p_rounding not in (0.01, 0.5, 1) then raise exception 'Round to 0.01, 0.5 or 1.'; end if;
  if p_scope is null or jsonb_typeof(p_scope) <> 'object' then raise exception 'Choose which dishes to change.'; end if;
  v_all := coalesce((p_scope ->> 'all')::boolean, false);
  v_cats := coalesce(array(select jsonb_array_elements_text(coalesce(p_scope -> 'category_ids', '[]'::jsonb))::uuid), '{}');
  v_prods := coalesce(array(select jsonb_array_elements_text(coalesce(p_scope -> 'product_ids', '[]'::jsonb))::uuid), '{}');
  if not v_all and cardinality(v_cats) = 0 and cardinality(v_prods) = 0 then raise exception 'Choose which dishes to change.'; end if;

  return query
  with recursive cat as (
    select c.id from public.categories c where c.restaurant_id = v_rest and c.deleted_at is null and c.id = any(v_cats)
    union
    select c.id from public.categories c join cat on c.parent_id = cat.id where c.restaurant_id = v_rest and c.deleted_at is null
  ), picked as (
    select p.id, p.name, p.price, p.category_id from public.products p
     where p.restaurant_id = v_rest and p.deleted_at is null
       and (v_all or p.category_id in (select cat.id from cat) or p.id = any(v_prods))
  ), base as (
    select pk.id as pid, pk.name as pname, 'base'::text as sc, null::uuid as bid, pk.price as oldp, pk.category_id as cid from picked pk
    union all
    select pk.id, pk.name, 'branch', bp.branch_id, bp.price, pk.category_id
      from picked pk join public.branch_prices bp on bp.product_id = pk.id and bp.restaurant_id = v_rest and bp.price is not null
     where p_include_branch
  ), calc as (
    select b.*, app.bulk_price_new(p_mode, p_value, p_rounding, b.oldp) as newp from base b
  )
  select c.pid, c.pname, coalesce(ca.name, ''), c.sc, c.bid, br.name, c.oldp, c.newp
    from calc c
    left join public.categories ca on ca.id = c.cid
    left join public.branches br on br.id = c.bid
   where c.newp is distinct from c.oldp
   order by coalesce(ca.name, ''), c.pname, c.sc desc, br.name;
end $$;
revoke all on function app.bulk_price_new(text, numeric, numeric, numeric), app.bulk_price_lines(text, numeric, numeric, jsonb, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------- preview (no write)
create or replace function public.bulk_price_preview(p_mode text, p_value numeric, p_rounding numeric default 1,
                                                     p_scope jsonb default '{}'::jsonb, p_include_branch boolean default true)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare v_out jsonb;
begin
  perform app.require_permission('menu.price_change');
  with x as (select * from app.bulk_price_lines(p_mode, p_value, p_rounding, p_scope, p_include_branch))
  select jsonb_build_object(
      'lines', coalesce((select jsonb_agg(jsonb_build_object('product_id', y.product_id, 'name', y.product_name, 'category', y.category_name,
                  'scope', y.line_scope, 'branch_id', y.branch_id, 'branch', y.branch_name, 'old_price', y.old_price, 'new_price', y.new_price))
                from (select * from x limit 1000) y), '[]'::jsonb),
      'total_lines', (select count(*) from x),
      'base_lines', (select count(*) from x where line_scope = 'base'),
      'branch_lines', (select count(*) from x where line_scope = 'branch'),
      'truncated', (select count(*) from x) > 1000,
      'include_branch', coalesce(p_include_branch, true))
    into v_out;
  return v_out;
end $$;

-- ---------------------------------------------------------------- apply
create or replace function public.bulk_price_apply(p_mode text, p_value numeric, p_rounding numeric, p_scope jsonb, p_include_branch boolean,
                                                   p_reason text, p_client_ref uuid default null, p_expect_lines int default null)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_rest uuid := app.current_restaurant_id(); v_me uuid; v_reason text := btrim(coalesce(p_reason, ''));
  b public.price_change_batches%rowtype; v_n int; v_base int; v_branch int; v_cur text; v_who text; v_outlet text;
begin
  v_me := app.require_permission('menu.price_change');
  if length(v_reason) < 3 then raise exception 'Give a reason for the price change.'; end if;
  perform pg_advisory_xact_lock(hashtext('bulk_price:' || v_rest::text));
  if p_client_ref is not null then
    select * into b from public.price_change_batches where restaurant_id = v_rest and client_ref = p_client_ref;
    if found then
      return jsonb_build_object('batch_id', b.id, 'total_lines', b.line_count, 'already_applied', true);
    end if;
  end if;

  create temp table _bpa on commit drop as select * from app.bulk_price_lines(p_mode, p_value, p_rounding, p_scope, p_include_branch);
  select count(*), count(*) filter (where line_scope = 'base'), count(*) filter (where line_scope = 'branch') into v_n, v_base, v_branch from _bpa;
  if v_n = 0 then raise exception 'No price would change.'; end if;
  if v_n > 5000 then raise exception 'That would change % prices. Change a smaller group at a time (up to 5000).', v_n; end if;
  if p_expect_lines is not null and p_expect_lines <> v_n then
    raise exception 'The menu changed since the preview (% prices now, % shown). Preview again.', v_n, p_expect_lines;
  end if;

  insert into public.price_change_batches (restaurant_id, branch_id, created_by, mode, value, rounding, include_branch, scope, reason, line_count, client_ref)
  values (v_rest, app.current_branch_id(), v_me, p_mode, p_value, p_rounding, coalesce(p_include_branch, true), p_scope, v_reason, v_n, p_client_ref)
  returning * into b;
  insert into public.price_change_lines (batch_id, restaurant_id, product_id, scope, branch_id, old_price, new_price)
  select b.id, v_rest, a.product_id, a.line_scope, a.branch_id, a.old_price, a.new_price from _bpa a;

  perform set_config('app.bulk_price', 'on', true);
  update public.products p set price = a.new_price from _bpa a where a.line_scope = 'base' and p.id = a.product_id and p.restaurant_id = v_rest;
  update public.branch_prices bp set price = a.new_price, updated_at = now(), updated_by = v_me
    from _bpa a where a.line_scope = 'branch' and bp.product_id = a.product_id and bp.branch_id = a.branch_id and bp.restaurant_id = v_rest;
  perform set_config('app.bulk_price', 'off', true);
  drop table _bpa;

  perform app.audit('menu.bulk_price_change', 'price_change_batches', b.id,
    jsonb_build_object('batch_id', b.id, 'mode', p_mode, 'value', p_value, 'rounding', p_rounding, 'reason', v_reason,
                       'prices_changed', v_n, 'base_prices', v_base, 'outlet_prices', v_branch, 'scope', p_scope));
  if app.feature_on(v_rest, 'owner_app') then
    select currency_code into v_cur from public.restaurants where id = v_rest;
    select full_name into v_who from public.users where id = v_me;
    select name into v_outlet from public.branches where id = app.current_branch_id();
    insert into public.owner_alerts (restaurant_id, branch_id, kind, title, body)
    values (v_rest, app.current_branch_id(), 'menu.bulk_price_change', 'Prices changed in bulk',
            left(concat_ws(' · ', concat(v_n, ' prices ', case when p_mode = 'percent' then concat(p_value, '%') else concat(v_cur, ' ', p_value) end, ' — ', v_reason), v_who, v_outlet), 300));
  end if;
  return jsonb_build_object('batch_id', b.id, 'total_lines', v_n, 'base_lines', v_base, 'branch_lines', v_branch, 'already_applied', false);
end $$;

-- ---------------------------------------------------------------- undo
create or replace function public.bulk_price_undo(p_batch uuid, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_rest uuid := app.current_restaurant_id(); v_me uuid; b public.price_change_batches%rowtype;
  v_ok int := 0; v_skip int := 0; l record; v_hit int; v_cur text; v_who text; v_outlet text;
begin
  v_me := app.require_permission('menu.price_change');
  perform pg_advisory_xact_lock(hashtext('bulk_price:' || v_rest::text));
  select * into b from public.price_change_batches where id = p_batch and restaurant_id = v_rest for update;
  if not found then raise exception 'Price change not found.'; end if;
  if b.status = 'undone' then raise exception 'This price change was already undone.'; end if;

  perform set_config('app.bulk_price', 'on', true);
  for l in select * from public.price_change_lines where batch_id = b.id order by id loop
    if l.scope = 'base' then
      update public.products set price = l.old_price where id = l.product_id and restaurant_id = v_rest and deleted_at is null and price = l.new_price;
    else
      update public.branch_prices set price = l.old_price, updated_at = now(), updated_by = v_me
       where product_id = l.product_id and branch_id = l.branch_id and restaurant_id = v_rest and price = l.new_price;
    end if;
    get diagnostics v_hit = row_count;
    update public.price_change_lines set undo_state = case when v_hit > 0 then 'restored' else 'skipped' end where id = l.id;
    if v_hit > 0 then v_ok := v_ok + 1; else v_skip := v_skip + 1; end if;
  end loop;
  perform set_config('app.bulk_price', 'off', true);

  update public.price_change_batches set status = 'undone', undone_at = now(), undone_by = v_me, undo_restored = v_ok, undo_skipped = v_skip where id = b.id;
  perform app.audit('menu.bulk_price_undo', 'price_change_batches', b.id,
    jsonb_build_object('batch_id', b.id, 'restored', v_ok, 'skipped', v_skip, 'reason', nullif(btrim(coalesce(p_reason, '')), '')),
    jsonb_build_object('reason', b.reason));
  if app.feature_on(v_rest, 'owner_app') then
    select full_name into v_who from public.users where id = v_me;
    select name into v_outlet from public.branches where id = app.current_branch_id();
    insert into public.owner_alerts (restaurant_id, branch_id, kind, title, body)
    values (v_rest, app.current_branch_id(), 'menu.bulk_price_undo', 'Bulk price change undone',
            left(concat_ws(' · ', concat(v_ok, ' prices restored, ', v_skip, ' left as edited since'), v_who, v_outlet), 300));
  end if;
  return jsonb_build_object('batch_id', b.id, 'restored', v_ok, 'skipped', v_skip);
end $$;

-- ---------------------------------------------------------------- history (newest first) for the screen
create or replace function public.bulk_price_history(p_limit int default 20)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('menu.price_change');
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'created_at', x.created_at, 'by', x.by_name, 'mode', x.mode, 'value', x.value,
            'rounding', x.rounding, 'include_branch', x.include_branch, 'reason', x.reason, 'status', x.status, 'lines', x.line_count,
            'undone_at', x.undone_at, 'undone_by', x.undone_by_name, 'restored', x.undo_restored, 'skipped', x.undo_skipped) order by x.created_at desc)
     from (select b.*, u.full_name as by_name, u2.full_name as undone_by_name from public.price_change_batches b
             left join public.users u on u.id = b.created_by left join public.users u2 on u2.id = b.undone_by
            where b.restaurant_id = app.current_restaurant_id() order by b.created_at desc limit greatest(1, least(coalesce(p_limit, 20), 100))) x), '[]'::jsonb);
end $$;

revoke all on function public.bulk_price_preview(text, numeric, numeric, jsonb, boolean) from public, anon;
revoke all on function public.bulk_price_apply(text, numeric, numeric, jsonb, boolean, text, uuid, int) from public, anon;
revoke all on function public.bulk_price_undo(uuid, text) from public, anon;
grant execute on function public.bulk_price_preview(text, numeric, numeric, jsonb, boolean) to authenticated;
grant execute on function public.bulk_price_apply(text, numeric, numeric, jsonb, boolean, text, uuid, int) to authenticated;
grant execute on function public.bulk_price_undo(uuid, text) to authenticated;
revoke all on function public.bulk_price_history(int) from public, anon;
grant execute on function public.bulk_price_history(int) to authenticated;
