-- Purchase requisition with approval (Winsar: Purchase Requisition -> Approval -> Purchase Order).
-- Anyone with a stock right can ask to buy; a manager approves or turns it down; an approved requisition
-- becomes a purchase order. The owner may set an approval limit: above it, only a person who can
-- manage settings (the owner) can approve.

create table if not exists public.purchase_settings (
  restaurant_id  uuid primary key references public.restaurants(id) on delete cascade,
  approval_limit numeric(14,2) check (approval_limit is null or approval_limit > 0),
  updated_at     timestamptz not null default now(),
  updated_by     uuid references public.users(id)
);

create table if not exists public.purchase_requisitions (
  id                uuid primary key default gen_random_uuid(),
  restaurant_id     uuid not null references public.restaurants(id) on delete cascade,
  branch_id         uuid not null,
  number            text not null,
  status            text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled', 'ordered')),
  note              text,
  est_total         numeric(14,2) not null default 0,
  requested_by      uuid not null references public.users(id),
  created_at        timestamptz not null default now(),
  decided_by        uuid references public.users(id),
  decided_at        timestamptz,
  reject_reason     text,
  purchase_order_id uuid,
  client_ref        uuid,
  unique (branch_id, number),
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, purchase_order_id) references public.purchase_orders(restaurant_id, id)
);
create unique index if not exists purchase_requisitions_client_ref_uq on public.purchase_requisitions (restaurant_id, client_ref) where client_ref is not null;
create index if not exists purchase_requisitions_lookup on public.purchase_requisitions (branch_id, status, created_at desc);

create table if not exists public.requisition_lines (
  id             uuid primary key default gen_random_uuid(),
  restaurant_id  uuid not null,
  requisition_id uuid not null,
  ingredient_id  uuid not null,
  qty            numeric(14,3) not null check (qty > 0),
  est_cost       numeric(14,4) not null default 0 check (est_cost >= 0),
  unique (requisition_id, ingredient_id),
  foreign key (restaurant_id, requisition_id) references public.purchase_requisitions(restaurant_id, id) on delete cascade,
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id)
);

do $$
declare t text; v_using text;
begin
  foreach t in array array['purchase_settings', 'purchase_requisitions', 'requisition_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists tenant_read on public.%I', t);
    v_using := 'restaurant_id = (select app.current_restaurant_id()) and ((select app.has_permission(''stock.view'')) or (select app.has_permission(''stock.adjust'')) or (select app.has_permission(''stock.manage'')))';
    if t = 'purchase_requisitions' then
      v_using := v_using || ' and branch_id = (select app.current_branch_id())';
    elsif t = 'requisition_lines' then
      v_using := v_using || ' and exists (select 1 from public.purchase_requisitions h where h.id = requisition_id)';
    end if;
    execute format('create policy tenant_read on public.%I for select to authenticated using (%s)', t, v_using);
  end loop;
end $$;

do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('app.erase_groups()'::regprocedure);
  if v_def like '%requisition_lines%' then return; end if;
  if position('''material_issue_lines'', ' in v_def) = 0 then raise exception 'erase_groups text did not match'; end if;
  v_def := replace(v_def, '''material_issue_lines'', ', '''requisition_lines'', ''purchase_requisitions'', ''material_issue_lines'', ');
  execute v_def;
  revoke all on function app.erase_groups() from public, anon, authenticated;
end $$;

create or replace function public.set_purchase_approval_limit(p_limit numeric)
returns numeric language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id(); v_new numeric(14,2);
begin
  if p_limit is not null then
    if p_limit <= 0 then raise exception 'The approval limit must be more than zero. Leave it empty for no limit.'; end if;
    v_new := round(p_limit, 2);
  end if;
  insert into public.purchase_settings (restaurant_id, approval_limit, updated_at, updated_by) values (v_rest, v_new, now(), v_user)
  on conflict (restaurant_id) do update set approval_limit = excluded.approval_limit, updated_at = now(), updated_by = v_user;
  perform app.audit('settings.purchase_limit', 'purchase_settings', null, jsonb_build_object('approval_limit', v_new));
  return v_new;
end $$;

create or replace function public.save_requisition(p_lines jsonb, p_note text default null, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_user uuid := app.current_user_id(); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_id uuid := gen_random_uuid(); v_no text; v_seq int; x record; v_seen uuid[] := '{}'; v_out jsonb; v_cost numeric; v_total numeric(14,2) := 0; v_qty numeric;
begin
  perform app.require_feature('stock');
  if not (app.has_permission('stock.view') or app.has_permission('stock.adjust') or app.has_permission('stock.manage')) then
    raise exception 'Your role does not allow this action (stock).';
  end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('pr_ref:' || p_client_ref::text));
    select jsonb_build_object('id', r.id, 'number', r.number, 'est_total', r.est_total, 'repeat', true) into v_out
      from public.purchase_requisitions r where r.restaurant_id = v_rest and r.client_ref = p_client_ref;
    if v_out is not null then return v_out; end if;
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one ingredient.'; end if;
  perform pg_advisory_xact_lock(hashtext('requisition:' || v_branch::text));
  select count(*) + 1 into v_seq from public.purchase_requisitions where branch_id = v_branch;
  v_no := 'PR-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');
  insert into public.purchase_requisitions (id, restaurant_id, branch_id, number, note, requested_by, client_ref)
  values (v_id, v_rest, v_branch, v_no, nullif(left(btrim(coalesce(p_note, '')), 300), ''), v_user, p_client_ref);
  for x in select (e->>'ingredient_id')::uuid as ingredient_id, (e->>'qty')::numeric as qty from jsonb_array_elements(p_lines) e loop
    if x.ingredient_id = any (v_seen) then raise exception 'An ingredient is on the list twice. Put it on one line.'; end if;
    v_seen := v_seen || x.ingredient_id;
    if x.qty is null or x.qty <= 0 then raise exception 'Enter a quantity greater than zero on each line.'; end if;
    v_qty := round(x.qty, 3);
    select cost_per_unit into v_cost from public.ingredients where id = x.ingredient_id and restaurant_id = v_rest and is_active;
    if not found then raise exception 'An ingredient on the list no longer exists.'; end if;
    insert into public.requisition_lines (restaurant_id, requisition_id, ingredient_id, qty, est_cost) values (v_rest, v_id, x.ingredient_id, v_qty, coalesce(v_cost, 0));
    v_total := v_total + round(v_qty * coalesce(v_cost, 0), 2);
  end loop;
  update public.purchase_requisitions set est_total = v_total where id = v_id;
  perform app.audit('requisition.save', 'purchase_requisitions', v_id, jsonb_build_object('number', v_no, 'est_total', v_total));
  return jsonb_build_object('id', v_id, 'number', v_no, 'est_total', v_total);
end $$;

create or replace function public.decide_requisition(p_id uuid, p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_user uuid := app.current_user_id(); r public.purchase_requisitions%rowtype; v_new text; v_limit numeric;
begin
  perform app.require_feature('stock');
  select * into r from public.purchase_requisitions
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Requisition not found.'; end if;
  if r.status not in ('pending', 'approved') then raise exception 'Requisition % is already %.', r.number, r.status; end if;
  if p_action = 'approve' then
    perform app.require_permission('stock.manage');
    if r.status <> 'pending' then raise exception 'Requisition % is already approved.', r.number; end if;
    select approval_limit into v_limit from public.purchase_settings where restaurant_id = r.restaurant_id;
    if v_limit is not null and r.est_total > v_limit and not app.has_permission('settings.manage') then
      raise exception 'Requisition % is worth % which is above the approval limit of %. The owner has to approve it.', r.number, r.est_total, v_limit;
    end if;
    v_new := 'approved';
  elsif p_action = 'reject' then
    perform app.require_permission('stock.manage');
    if r.status <> 'pending' then raise exception 'Requisition % is already approved, so it cannot be turned down.', r.number; end if;
    if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason.'; end if;
    v_new := 'rejected';
  elsif p_action = 'cancel' then
    if r.status <> 'pending' then raise exception 'Requisition % is already approved, so it cannot be withdrawn.', r.number; end if;
    if r.requested_by <> v_user and not app.has_permission('stock.manage') then raise exception 'Only the person who asked, or a manager, can withdraw this requisition.'; end if;
    v_new := 'cancelled';
  else
    raise exception 'Unknown action.';
  end if;
  update public.purchase_requisitions set status = v_new, decided_by = v_user, decided_at = now(),
         reject_reason = case when v_new = 'rejected' then left(btrim(p_reason), 300) else reject_reason end
   where id = r.id;
  perform app.audit('requisition.' || p_action, 'purchase_requisitions', r.id, jsonb_build_object('number', r.number, 'status', v_new, 'est_total', r.est_total));
  return jsonb_build_object('id', r.id, 'number', r.number, 'status', v_new);
end $$;

create or replace function public.requisition_to_order(p_id uuid, p_supplier_id uuid, p_place boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare r public.purchase_requisitions%rowtype; v_po jsonb; v_lines jsonb;
begin
  perform app.require_permission('stock.manage');
  perform app.require_feature('stock');
  select * into r from public.purchase_requisitions
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Requisition not found.'; end if;
  if r.status <> 'approved' then raise exception 'Requisition % is %, so it cannot be turned into an order.', r.number, r.status; end if;
  select jsonb_agg(jsonb_build_object('ingredient_id', l.ingredient_id, 'qty', l.qty, 'unit_cost', l.est_cost)) into v_lines
    from public.requisition_lines l where l.requisition_id = r.id;
  v_po := public.save_purchase_order(null, p_supplier_id, v_lines, null, left('From ' || r.number, 300), coalesce(p_place, false));
  update public.purchase_requisitions set status = 'ordered', purchase_order_id = (v_po->>'id')::uuid where id = r.id;
  perform app.audit('requisition.order', 'purchase_requisitions', r.id, jsonb_build_object('number', r.number, 'purchase_order', v_po->>'number'));
  return jsonb_build_object('id', r.id, 'number', r.number, 'purchase_order', v_po->>'number', 'purchase_order_id', v_po->>'id');
end $$;

revoke all on function public.set_purchase_approval_limit(numeric) from public, anon;
revoke all on function public.save_requisition(jsonb, text, uuid) from public, anon;
revoke all on function public.decide_requisition(uuid, text, text) from public, anon;
revoke all on function public.requisition_to_order(uuid, uuid, boolean) from public, anon;
grant execute on function public.set_purchase_approval_limit(numeric) to authenticated;
grant execute on function public.save_requisition(jsonb, text, uuid) to authenticated;
grant execute on function public.decide_requisition(uuid, text, text) to authenticated;
grant execute on function public.requisition_to_order(uuid, uuid, boolean) to authenticated;
