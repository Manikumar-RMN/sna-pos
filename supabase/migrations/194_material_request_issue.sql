-- Material request and material issue (Winsar: Material Request / Material Issue).
-- A kitchen (or bar, housekeeping...) asks for stock; the manager issues it, in full or in part, or rejects it.
-- An issue takes the stock out at today's cost and keeps a document (MI-...) of who got what.
-- An issue can also be made without a request.

alter table public.stock_movements drop constraint if exists stock_movements_reason_check;
alter table public.stock_movements add constraint stock_movements_reason_check
  check (reason is null or reason = any (array['spoilage','expired','spill','breakage','staff_meal','sample','theft','count_correction','issued','other']::text[]));

create table if not exists public.material_requests (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id     uuid not null,
  number        text not null,
  department    text not null check (length(btrim(department)) between 2 and 40),
  status        text not null default 'requested' check (status in ('requested', 'part_issued', 'issued', 'rejected', 'cancelled')),
  note          text,
  requested_by  uuid not null references public.users(id),
  created_at    timestamptz not null default now(),
  decided_by    uuid references public.users(id),
  decided_at    timestamptz,
  reject_reason text,
  client_ref    uuid,
  unique (branch_id, number),
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id)
);
create unique index if not exists material_requests_client_ref_uq on public.material_requests (restaurant_id, client_ref) where client_ref is not null;
create index if not exists material_requests_lookup on public.material_requests (branch_id, status, created_at desc);

create table if not exists public.material_request_lines (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  request_id    uuid not null,
  ingredient_id uuid not null,
  qty           numeric(14,3) not null check (qty > 0),
  issued_qty    numeric(14,3) not null default 0 check (issued_qty >= 0),
  unique (request_id, ingredient_id),
  foreign key (restaurant_id, request_id) references public.material_requests(restaurant_id, id) on delete cascade,
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id)
);

create table if not exists public.material_issues (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id     uuid not null,
  request_id    uuid,
  number        text not null,
  department    text not null,
  issued_on     date not null,
  note          text,
  value         numeric(14,2) not null default 0,
  issued_by     uuid not null references public.users(id),
  created_at    timestamptz not null default now(),
  client_ref    uuid,
  unique (branch_id, number),
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, request_id) references public.material_requests(restaurant_id, id)
);
create unique index if not exists material_issues_client_ref_uq on public.material_issues (restaurant_id, client_ref) where client_ref is not null;

create table if not exists public.material_issue_lines (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  issue_id      uuid not null,
  ingredient_id uuid not null,
  qty           numeric(14,3) not null check (qty > 0),
  unit_cost     numeric(14,4) not null check (unit_cost >= 0),
  foreign key (restaurant_id, issue_id) references public.material_issues(restaurant_id, id) on delete cascade,
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id)
);

-- Reading: anyone with a stock right (view, adjust or manage), own restaurant and outlet. No direct writes.
do $$
declare t text; v_using text;
begin
  foreach t in array array['material_requests', 'material_request_lines', 'material_issues', 'material_issue_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists tenant_read on public.%I', t);
    v_using := 'restaurant_id = (select app.current_restaurant_id()) and ((select app.has_permission(''stock.view'')) or (select app.has_permission(''stock.adjust'')) or (select app.has_permission(''stock.manage'')))';
    if t in ('material_requests', 'material_issues') then
      v_using := v_using || ' and branch_id = (select app.current_branch_id())';
    elsif t = 'material_request_lines' then
      v_using := v_using || ' and exists (select 1 from public.material_requests h where h.id = request_id)';
    else
      v_using := v_using || ' and exists (select 1 from public.material_issues h where h.id = issue_id)';
    end if;
    execute format('create policy tenant_read on public.%I for select to authenticated using (%s)', t, v_using);
  end loop;
end $$;

-- Erase ("go live") clears them first.
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('app.erase_groups()'::regprocedure);
  if v_def like '%material_issue_lines%' then return; end if;
  if position('''goods_return_lines'', ' in v_def) = 0 then raise exception 'erase_groups text did not match'; end if;
  v_def := replace(v_def, '''goods_return_lines'', ', '''material_issue_lines'', ''material_issues'', ''material_request_lines'', ''material_requests'', ''goods_return_lines'', ');
  execute v_def;
  revoke all on function app.erase_groups() from public, anon, authenticated;
end $$;

------------------------------------------------------------------
-- Ask for stock
------------------------------------------------------------------
create or replace function public.save_material_request(p_department text, p_lines jsonb, p_note text default null, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_user uuid := app.current_user_id(); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_id uuid := gen_random_uuid(); v_no text; v_seq int; x record; v_seen uuid[] := '{}'; v_out jsonb;
begin
  perform app.require_feature('stock');
  if not (app.has_permission('stock.view') or app.has_permission('stock.adjust') or app.has_permission('stock.manage')) then
    raise exception 'Your role does not allow this action (stock).';
  end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('mr_ref:' || p_client_ref::text));
    select jsonb_build_object('id', r.id, 'number', r.number, 'repeat', true) into v_out
      from public.material_requests r where r.restaurant_id = v_rest and r.client_ref = p_client_ref;
    if v_out is not null then return v_out; end if;
  end if;
  if length(btrim(coalesce(p_department, ''))) < 2 then raise exception 'Say who the stock is for (for example Kitchen).'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one ingredient.'; end if;
  perform pg_advisory_xact_lock(hashtext('material_request:' || v_branch::text));
  select count(*) + 1 into v_seq from public.material_requests where branch_id = v_branch;
  v_no := 'MR-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');
  insert into public.material_requests (id, restaurant_id, branch_id, number, department, note, requested_by, client_ref)
  values (v_id, v_rest, v_branch, v_no, left(btrim(p_department), 40), nullif(left(btrim(coalesce(p_note, '')), 300), ''), v_user, p_client_ref);
  for x in select (e->>'ingredient_id')::uuid as ingredient_id, (e->>'qty')::numeric as qty from jsonb_array_elements(p_lines) e loop
    if x.ingredient_id = any (v_seen) then raise exception 'An ingredient is on the list twice. Put it on one line.'; end if;
    v_seen := v_seen || x.ingredient_id;
    if x.qty is null or x.qty <= 0 then raise exception 'Enter a quantity greater than zero on each line.'; end if;
    if not exists (select 1 from public.ingredients where id = x.ingredient_id and restaurant_id = v_rest and is_active) then
      raise exception 'An ingredient on the list no longer exists.';
    end if;
    insert into public.material_request_lines (restaurant_id, request_id, ingredient_id, qty) values (v_rest, v_id, x.ingredient_id, round(x.qty, 3));
  end loop;
  perform app.audit('material.request', 'material_requests', v_id, jsonb_build_object('number', v_no, 'department', left(btrim(p_department), 40)));
  return jsonb_build_object('id', v_id, 'number', v_no);
end $$;

------------------------------------------------------------------
-- Turn a request down, or withdraw it
------------------------------------------------------------------
create or replace function public.close_material_request(p_id uuid, p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_user uuid := app.current_user_id(); r public.material_requests%rowtype; v_new text;
begin
  perform app.require_feature('stock');
  select * into r from public.material_requests
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.status not in ('requested', 'part_issued') then raise exception 'Request % is already %.', r.number, replace(r.status, '_', ' '); end if;
  if p_action = 'reject' then
    perform app.require_permission('stock.manage');
    if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason.'; end if;
    v_new := 'rejected';
  elsif p_action = 'cancel' then
    if r.status <> 'requested' then raise exception 'Part of request % has been issued already, so it cannot be withdrawn.', r.number; end if;
    if r.requested_by <> v_user and not app.has_permission('stock.manage') then raise exception 'Only the person who asked, or a manager, can withdraw this request.'; end if;
    v_new := 'cancelled';
  elsif p_action = 'close' then
    -- "Nothing more coming" on a part-issued request.
    perform app.require_permission('stock.manage');
    if r.status <> 'part_issued' then raise exception 'Only a part-issued request can be closed this way.'; end if;
    v_new := 'issued';
  else
    raise exception 'Unknown action.';
  end if;
  update public.material_requests set status = v_new, decided_by = v_user, decided_at = now(),
         reject_reason = case when v_new = 'rejected' then left(btrim(p_reason), 300) else reject_reason end
   where id = r.id;
  perform app.audit('material.' || p_action, 'material_requests', r.id, jsonb_build_object('number', r.number, 'status', v_new));
  return jsonb_build_object('id', r.id, 'number', r.number, 'status', v_new);
end $$;

------------------------------------------------------------------
-- Issue stock (against a request, or on its own)
------------------------------------------------------------------
create or replace function public.issue_material(p_request uuid, p_department text, p_lines jsonb, p_note text default null, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  rq public.material_requests%rowtype; rl public.material_request_lines%rowtype; x record;
  v_id uuid := gen_random_uuid(); v_no text; v_seq int; v_today date; v_dept text; v_cost numeric; v_total numeric(14,2) := 0;
  v_out jsonb; v_seen uuid[] := '{}'; v_qty numeric; v_status text; v_name text;
begin
  perform app.require_feature('stock');
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('mi_ref:' || p_client_ref::text));
    select jsonb_build_object('id', i.id, 'number', i.number, 'value', i.value, 'repeat', true) into v_out
      from public.material_issues i where i.restaurant_id = v_rest and i.client_ref = p_client_ref;
    if v_out is not null then return v_out; end if;
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Choose what is being issued.'; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;
  if p_request is not null then
    select * into rq from public.material_requests where id = p_request and restaurant_id = v_rest and branch_id = v_branch for update;
    if not found then raise exception 'Request not found.'; end if;
    if rq.status not in ('requested', 'part_issued') then raise exception 'Request % is already %.', rq.number, replace(rq.status, '_', ' '); end if;
    v_dept := rq.department;
  else
    v_dept := left(btrim(coalesce(p_department, '')), 40);
    if length(v_dept) < 2 then raise exception 'Say who the stock is for (for example Kitchen).'; end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('material_issue:' || v_branch::text));
  select count(*) + 1 into v_seq from public.material_issues where branch_id = v_branch;
  v_no := 'MI-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');
  insert into public.material_issues (id, restaurant_id, branch_id, request_id, number, department, issued_on, note, issued_by, client_ref)
  values (v_id, v_rest, v_branch, p_request, v_no, v_dept, v_today, nullif(left(btrim(coalesce(p_note, '')), 300), ''), v_user, p_client_ref);

  for x in select (e->>'ingredient_id')::uuid as ingredient_id, (e->>'qty')::numeric as qty from jsonb_array_elements(p_lines) e order by 1 loop
    if x.ingredient_id = any (v_seen) then raise exception 'An ingredient is on the list twice. Put it on one line.'; end if;
    v_seen := v_seen || x.ingredient_id;
    if x.qty is null or x.qty <= 0 then raise exception 'Enter a quantity greater than zero on each line.'; end if;
    v_qty := round(x.qty, 3);
    select name, cost_per_unit into v_name, v_cost from public.ingredients where id = x.ingredient_id and restaurant_id = v_rest and is_active;
    if not found then raise exception 'An ingredient on the list no longer exists.'; end if;
    if p_request is not null then
      select * into rl from public.material_request_lines where request_id = p_request and ingredient_id = x.ingredient_id for update;
      if not found then raise exception '% is not on request %.', v_name, rq.number; end if;
      if v_qty > rl.qty - rl.issued_qty then raise exception 'Only % of % is still to be issued on request %.', rl.qty - rl.issued_qty, v_name, rq.number; end if;
      update public.material_request_lines set issued_qty = issued_qty + v_qty where id = rl.id;
    end if;
    perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || x.ingredient_id::text));
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, reason, note, created_by)
    values (v_rest, v_branch, x.ingredient_id, 'adjust', -v_qty, v_cost, 'issued', left(v_no || ' issued to ' || v_dept, 200), v_user);
    insert into public.material_issue_lines (restaurant_id, issue_id, ingredient_id, qty, unit_cost) values (v_rest, v_id, x.ingredient_id, v_qty, v_cost);
    v_total := v_total + round(v_qty * v_cost, 2);
  end loop;

  update public.material_issues set value = v_total where id = v_id;
  if p_request is not null then
    v_status := case when exists (select 1 from public.material_request_lines where request_id = p_request and issued_qty < qty) then 'part_issued' else 'issued' end;
    update public.material_requests set status = v_status, decided_by = v_user, decided_at = now() where id = p_request;
  end if;
  perform app.audit('material.issue', 'material_issues', v_id, jsonb_build_object('number', v_no, 'department', v_dept, 'value', v_total, 'request', rq.number));
  return jsonb_build_object('id', v_id, 'number', v_no, 'value', v_total, 'request_status', v_status);
end $$;

revoke all on function public.save_material_request(text, jsonb, text, uuid) from public, anon;
revoke all on function public.close_material_request(uuid, text, text) from public, anon;
revoke all on function public.issue_material(uuid, text, jsonb, text, uuid) from public, anon;
grant execute on function public.save_material_request(text, jsonb, text, uuid) to authenticated;
grant execute on function public.close_material_request(uuid, text, text) to authenticated;
grant execute on function public.issue_material(uuid, text, jsonb, text, uuid) to authenticated;
