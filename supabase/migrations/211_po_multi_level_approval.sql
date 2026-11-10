-- Multi-level approval of purchase orders (Winsar: approval levels 1-6 with an approval authority per level).
-- The owner sets up to six levels. A level has a "from amount" and one person who approves at that level.
-- An order whose total reaches a level's amount needs approval from every level up to the highest one it reaches,
-- in order. An approval belongs to the order total it was given for: change the order and it needs approving again.
alter table public.purchase_settings add column if not exists approval_block_self boolean not null default false;

create table if not exists public.purchase_approval_levels (
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  level int not null check (level between 1 and 6),
  min_amount numeric(14,2) not null check (min_amount >= 0),
  approver_id uuid not null references public.users(id),
  primary key (restaurant_id, level)
);
create table if not exists public.purchase_order_approvals (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  level int not null check (level between 1 and 6),
  approver_id uuid not null references public.users(id),
  po_total numeric(14,2) not null,
  approved_at timestamptz not null default now(),
  unique (purchase_order_id, level)
);
do $$
declare t text;
begin
  foreach t in array array['purchase_approval_levels', 'purchase_order_approvals'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists tenant_read on public.%I', t);
    execute format('create policy tenant_read on public.%I for select to authenticated using (restaurant_id = (select app.current_restaurant_id()) and ((select app.has_permission(''stock.manage'')) or (select app.has_permission(''stock.view''))))', t);
  end loop;
end $$;

-- Raises if the order (at this total) still lacks an approval it needs.
create or replace function app.assert_po_approved(p_po uuid, p_total numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); lv record;
begin
  for lv in select l.level, l.approver_id from public.purchase_approval_levels l
             where l.restaurant_id = v_rest and l.min_amount <= p_total order by l.level loop
    if p_po is null or not exists (select 1 from public.purchase_order_approvals a
                                    where a.purchase_order_id = p_po and a.level = lv.level and a.po_total = round(p_total, 2)) then
      raise exception 'This order needs approval first. Level % (%) has not approved it. Save it as a draft and ask for approval.',
        lv.level, coalesce((select u.full_name from public.users u where u.id = lv.approver_id), 'approver');
    end if;
  end loop;
end $$;
revoke all on function app.assert_po_approved(uuid, numeric) from public, anon, authenticated;

create or replace function public.set_approval_levels(p_levels jsonb, p_block_self boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id();
  e jsonb; v_lv int; v_min numeric(14,2); v_ap uuid; v_prev_lv int := 0; v_prev_min numeric := -1; v_n int := 0;
begin
  perform app.require_feature('stock');
  if p_levels is null or jsonb_typeof(p_levels) <> 'array' then raise exception 'Send the levels as a list.'; end if;
  if jsonb_array_length(p_levels) > 6 then raise exception 'There can be at most 6 levels.'; end if;
  delete from public.purchase_approval_levels where restaurant_id = v_rest;
  for e in select x from jsonb_array_elements(p_levels) x order by (x->>'level')::int loop
    v_lv := (e->>'level')::int; v_min := round((e->>'min_amount')::numeric, 2); v_ap := (e->>'approver_id')::uuid;
    if v_lv is null or v_lv < 1 or v_lv > 6 then raise exception 'A level must be a number from 1 to 6.'; end if;
    if v_lv = v_prev_lv then raise exception 'Level % is on the list twice.', v_lv; end if;
    if v_min is null or v_min < 0 then raise exception 'Level % needs an amount of zero or more.', v_lv; end if;
    if v_min <= v_prev_min then raise exception 'Level % must start at a higher amount than the level before it.', v_lv; end if;
    if not exists (select 1 from public.users u where u.id = v_ap and u.restaurant_id = v_rest and u.is_active and u.deleted_at is null) then
      raise exception 'Choose an active person to approve level %.', v_lv;
    end if;
    insert into public.purchase_approval_levels (restaurant_id, level, min_amount, approver_id) values (v_rest, v_lv, v_min, v_ap);
    v_prev_lv := v_lv; v_prev_min := v_min; v_n := v_n + 1;
  end loop;
  insert into public.purchase_settings (restaurant_id, approval_block_self, updated_by) values (v_rest, coalesce(p_block_self, false), v_user)
  on conflict (restaurant_id) do update set approval_block_self = excluded.approval_block_self, updated_at = now(), updated_by = v_user;
  perform app.audit('settings.approval_levels', 'purchase_settings', v_rest, jsonb_build_object('levels', v_n, 'block_self', coalesce(p_block_self, false)));
  return jsonb_build_object('levels', v_n);
end $$;
revoke all on function public.set_approval_levels(jsonb, boolean) from public, anon;
grant execute on function public.set_approval_levels(jsonb, boolean) to authenticated;

create or replace function public.approve_purchase_order(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id();
  po public.purchase_orders%rowtype; lv record; v_block boolean; v_left int;
begin
  perform app.require_feature('stock');
  select * into po from public.purchase_orders where id = p_id and restaurant_id = v_rest and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Purchase order not found.'; end if;
  if po.status <> 'draft' then raise exception 'Purchase order % has already been sent.', po.number; end if;
  select coalesce(ps.approval_block_self, false) into v_block from public.purchase_settings ps where ps.restaurant_id = v_rest;
  -- The next level that has not approved this total yet.
  select l.level, l.approver_id into lv from public.purchase_approval_levels l
   where l.restaurant_id = v_rest and l.min_amount <= po.total
     and not exists (select 1 from public.purchase_order_approvals a where a.purchase_order_id = po.id and a.level = l.level and a.po_total = po.total)
   order by l.level limit 1;
  if not found then raise exception 'Purchase order % needs no further approval.', po.number; end if;
  if lv.approver_id <> v_user then
    raise exception 'Level % must be approved by %.', lv.level, coalesce((select u.full_name from public.users u where u.id = lv.approver_id), 'its approver');
  end if;
  if coalesce(v_block, false) and po.created_by = v_user then raise exception 'You wrote this order, so someone else has to approve it.'; end if;
  delete from public.purchase_order_approvals where purchase_order_id = po.id and level = lv.level;
  insert into public.purchase_order_approvals (restaurant_id, purchase_order_id, level, approver_id, po_total) values (v_rest, po.id, lv.level, v_user, po.total);
  select count(*) into v_left from public.purchase_approval_levels l
   where l.restaurant_id = v_rest and l.min_amount <= po.total
     and not exists (select 1 from public.purchase_order_approvals a where a.purchase_order_id = po.id and a.level = l.level and a.po_total = po.total);
  perform app.audit('purchase_order.approve', 'purchase_orders', po.id, jsonb_build_object('number', po.number, 'level', lv.level, 'total', po.total));
  return jsonb_build_object('id', po.id, 'number', po.number, 'level', lv.level, 'levels_left', v_left);
end $$;
revoke all on function public.approve_purchase_order(uuid) from public, anon;
grant execute on function public.approve_purchase_order(uuid) to authenticated;

-- Sending an order needs its approvals.
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.set_purchase_order_status(uuid,text)'::regprocedure); o := d;
  d := replace(d, E'    v_new := ''ordered'';', E'    perform app.assert_po_approved(po.id, po.total);\n    v_new := ''ordered'';');
  if d = o then raise exception 'set_purchase_order_status anchor changed'; end if;
  execute d;
  d := pg_get_functiondef('public.save_purchase_order(uuid,uuid,jsonb,date,text,boolean)'::regprocedure); o := d;
  d := replace(d, E'  update public.purchase_orders set total = v_total,\n         status = case when p_place', E'  if p_place then perform app.assert_po_approved(v_id, v_total); end if;\n  update public.purchase_orders set total = v_total,\n         status = case when p_place');
  if d = o then raise exception 'save_purchase_order anchor changed'; end if;
  execute d;
end $$;
revoke all on function public.set_purchase_order_status(uuid, text) from public, anon;
grant execute on function public.set_purchase_order_status(uuid, text) to authenticated;
revoke all on function public.save_purchase_order(uuid, uuid, jsonb, date, text, boolean) from public, anon;
grant execute on function public.save_purchase_order(uuid, uuid, jsonb, date, text, boolean) to authenticated;
