-- Quotation comparison (request for quotation).
-- 1. Ask several suppliers to price the same list of items.
-- 2. Type in each supplier's rates as they reply.
-- 3. See the rates side by side, with the lowest marked, then award each item to a supplier.
-- Awarding writes one draft purchase order per supplier at the quoted rates (or sends them when asked),
-- through the normal purchase order rules, so approvals and the requisition rule still apply.
-- The tables are read only through the functions below.

create table if not exists public.rfqs (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  branch_id uuid not null references public.branches(id),
  number text not null,
  needed_by date,
  notes text,
  status text not null default 'open' check (status in ('open', 'awarded', 'cancelled')),
  cancel_reason text,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  unique (branch_id, number)
);
create table if not exists public.rfq_lines (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  rfq_id uuid not null references public.rfqs(id) on delete cascade,
  ingredient_id uuid not null references public.ingredients(id),
  qty numeric(14,3) not null check (qty > 0),
  unique (rfq_id, ingredient_id)
);
create table if not exists public.rfq_suppliers (
  rfq_id uuid not null references public.rfqs(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id),
  restaurant_id uuid not null references public.restaurants(id),
  quoted_at timestamptz,
  primary key (rfq_id, supplier_id)
);
create table if not exists public.rfq_quotes (
  rfq_id uuid not null references public.rfqs(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id),
  ingredient_id uuid not null references public.ingredients(id),
  restaurant_id uuid not null references public.restaurants(id),
  unit_cost numeric(14,4) not null check (unit_cost >= 0),
  primary key (rfq_id, supplier_id, ingredient_id)
);
create table if not exists public.rfq_awards (
  rfq_id uuid not null references public.rfqs(id) on delete cascade,
  ingredient_id uuid not null references public.ingredients(id),
  supplier_id uuid not null references public.suppliers(id),
  restaurant_id uuid not null references public.restaurants(id),
  purchase_order_id uuid references public.purchase_orders(id),
  unit_cost numeric(14,4) not null,
  primary key (rfq_id, ingredient_id)
);
do $$ declare t text; begin
  foreach t in array array['rfqs', 'rfq_lines', 'rfq_suppliers', 'rfq_quotes', 'rfq_awards'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

create or replace function public.create_rfq(p_lines jsonb, p_suppliers uuid[], p_needed_by date default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_id uuid := gen_random_uuid(); v_no text; v_seq int; v_today date; e jsonb; v_ing uuid; v_qty numeric; v_seen uuid[] := '{}'; s uuid; v_ns int;
begin
  perform app.require_feature('stock');
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Choose what you want quotes for.'; end if;
  if p_suppliers is null or cardinality(p_suppliers) < 2 then raise exception 'Choose at least two suppliers to compare.'; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;
  if p_needed_by is not null and p_needed_by < v_today then raise exception 'The needed-by date cannot be in the past.'; end if;
  select count(distinct x) into v_ns from unnest(p_suppliers) x;
  if v_ns <> cardinality(p_suppliers) then raise exception 'A supplier is chosen twice.'; end if;
  foreach s in array p_suppliers loop
    if not exists (select 1 from public.suppliers u where u.id = s and u.restaurant_id = v_rest and u.is_active and not u.blocked) then
      raise exception 'A chosen supplier is not available.';
    end if;
  end loop;
  perform pg_advisory_xact_lock(hashtext('rfq:' || v_branch::text));
  select count(*) + 1 into v_seq from public.rfqs where branch_id = v_branch;
  v_no := 'RFQ-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');
  insert into public.rfqs (id, restaurant_id, branch_id, number, needed_by, notes, created_by)
  values (v_id, v_rest, v_branch, v_no, p_needed_by, nullif(left(btrim(coalesce(p_notes, '')), 300), ''), v_user);
  for e in select * from jsonb_array_elements(p_lines) loop
    v_ing := (e->>'ingredient_id')::uuid; v_qty := round((e->>'qty')::numeric, 3);
    if v_ing = any (v_seen) then raise exception 'An item is on the list twice. Put it on one line.'; end if;
    v_seen := v_seen || v_ing;
    if v_qty is null or v_qty <= 0 then raise exception 'Enter a quantity greater than zero on each line.'; end if;
    if not exists (select 1 from public.ingredients i where i.id = v_ing and i.restaurant_id = v_rest and i.is_active) then
      raise exception 'An item on the list no longer exists.';
    end if;
    insert into public.rfq_lines (restaurant_id, rfq_id, ingredient_id, qty) values (v_rest, v_id, v_ing, v_qty);
  end loop;
  insert into public.rfq_suppliers (rfq_id, supplier_id, restaurant_id) select v_id, x, v_rest from unnest(p_suppliers) x;
  perform app.audit('rfq.create', 'rfqs', v_id, jsonb_build_object('number', v_no, 'items', cardinality(v_seen), 'suppliers', cardinality(p_suppliers)));
  return jsonb_build_object('id', v_id, 'number', v_no);
end $$;

-- Replaces one supplier's rates. Leaving an item out means that supplier did not quote it.
create or replace function public.save_rfq_quotes(p_rfq uuid, p_supplier uuid, p_quotes jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  r public.rfqs%rowtype; e jsonb; v_ing uuid; v_rate numeric; v_n int := 0;
begin
  perform app.require_feature('stock');
  select * into r from public.rfqs where id = p_rfq and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'Quotation request not found.'; end if;
  if r.status <> 'open' then raise exception '% is already %, so quotes cannot be changed.', r.number, r.status; end if;
  if not exists (select 1 from public.rfq_suppliers where rfq_id = r.id and supplier_id = p_supplier) then
    raise exception 'That supplier was not asked to quote on %.', r.number;
  end if;
  delete from public.rfq_quotes where rfq_id = r.id and supplier_id = p_supplier;
  for e in select * from jsonb_array_elements(coalesce(p_quotes, '[]'::jsonb)) loop
    v_ing := (e->>'ingredient_id')::uuid;
    if nullif(btrim(coalesce(e->>'unit_cost', '')), '') is null then continue; end if;
    v_rate := round((e->>'unit_cost')::numeric, 4);
    if v_rate < 0 then raise exception 'A rate cannot be negative.'; end if;
    if not exists (select 1 from public.rfq_lines where rfq_id = r.id and ingredient_id = v_ing) then
      raise exception 'An item in the quote is not on %.', r.number;
    end if;
    insert into public.rfq_quotes (rfq_id, supplier_id, ingredient_id, restaurant_id, unit_cost) values (r.id, p_supplier, v_ing, v_rest, v_rate);
    v_n := v_n + 1;
  end loop;
  update public.rfq_suppliers set quoted_at = case when v_n > 0 then now() else null end where rfq_id = r.id and supplier_id = p_supplier;
  perform app.audit('rfq.quotes', 'rfqs', r.id, jsonb_build_object('number', r.number, 'supplier', p_supplier, 'rates', v_n));
  return jsonb_build_object('number', r.number, 'rates', v_n);
end $$;

create or replace function public.cancel_rfq(p_rfq uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('stock.manage'); r public.rfqs%rowtype;
begin
  perform app.require_feature('stock');
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for cancelling.'; end if;
  select * into r from public.rfqs where id = p_rfq and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Quotation request not found.'; end if;
  if r.status <> 'open' then raise exception '% is already %.', r.number, r.status; end if;
  update public.rfqs set status = 'cancelled', cancel_reason = left(btrim(p_reason), 300) where id = r.id;
  perform app.audit('rfq.cancel', 'rfqs', r.id, jsonb_build_object('number', r.number, 'reason', left(btrim(p_reason), 300)));
  return jsonb_build_object('number', r.number);
end $$;

-- p_awards: [{ingredient_id, supplier_id}]. One purchase order per supplier, at that supplier's quoted rate.
create or replace function public.award_rfq(p_rfq uuid, p_awards jsonb, p_place boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  r public.rfqs%rowtype; e jsonb; v_ing uuid; v_sup uuid; v_rate numeric; v_qty numeric; g record; v_po jsonb; v_pos jsonb := '[]'::jsonb; v_n int := 0;
begin
  perform app.require_feature('stock');
  select * into r from public.rfqs where id = p_rfq and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'Quotation request not found.'; end if;
  if r.status <> 'open' then raise exception '% is already %.', r.number, r.status; end if;
  if p_awards is null or jsonb_typeof(p_awards) <> 'array' or jsonb_array_length(p_awards) = 0 then raise exception 'Choose a supplier for at least one item.'; end if;
  for e in select * from jsonb_array_elements(p_awards) loop
    v_ing := (e->>'ingredient_id')::uuid; v_sup := (e->>'supplier_id')::uuid;
    select q.unit_cost into v_rate from public.rfq_quotes q where q.rfq_id = r.id and q.supplier_id = v_sup and q.ingredient_id = v_ing;
    if v_rate is null then raise exception 'That supplier has not quoted a rate for one of the items you chose.'; end if;
    if exists (select 1 from public.rfq_awards a where a.rfq_id = r.id and a.ingredient_id = v_ing) then raise exception 'An item is chosen twice.'; end if;
    insert into public.rfq_awards (rfq_id, ingredient_id, supplier_id, restaurant_id, unit_cost) values (r.id, v_ing, v_sup, v_rest, v_rate);
    v_n := v_n + 1;
  end loop;
  for g in select supplier_id from public.rfq_awards where rfq_id = r.id group by supplier_id order by 1 loop
    v_po := public.save_purchase_order(null, g.supplier_id,
      (select jsonb_agg(jsonb_build_object('ingredient_id', a.ingredient_id, 'qty', l.qty, 'unit_cost', a.unit_cost) order by a.ingredient_id)
         from public.rfq_awards a join public.rfq_lines l on l.rfq_id = a.rfq_id and l.ingredient_id = a.ingredient_id
        where a.rfq_id = r.id and a.supplier_id = g.supplier_id),
      r.needed_by, left('From ' || r.number, 300), coalesce(p_place, false));
    update public.rfq_awards set purchase_order_id = (v_po->>'id')::uuid where rfq_id = r.id and supplier_id = g.supplier_id;
    v_pos := v_pos || jsonb_build_array(jsonb_build_object('supplier_id', g.supplier_id, 'id', v_po->>'id', 'number', v_po->>'number', 'total', v_po->'total', 'status', v_po->>'status'));
  end loop;
  update public.rfqs set status = 'awarded' where id = r.id;
  perform app.audit('rfq.award', 'rfqs', r.id, jsonb_build_object('number', r.number, 'items', v_n, 'orders', jsonb_array_length(v_pos)));
  return jsonb_build_object('number', r.number, 'orders', v_pos);
end $$;

create or replace function public.list_rfqs()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'status', r.status, 'needed_by', r.needed_by,
      'created_on', r.created_at::date, 'notes', r.notes,
      'items', (select count(*) from public.rfq_lines l where l.rfq_id = r.id),
      'suppliers', (select count(*) from public.rfq_suppliers s where s.rfq_id = r.id),
      'quoted', (select count(*) from public.rfq_suppliers s where s.rfq_id = r.id and s.quoted_at is not null)) order by r.created_at desc)
    from public.rfqs r where r.restaurant_id = v_rest and (v_rb is null or r.branch_id = v_rb)), '[]'::jsonb);
end $$;

create or replace function public.get_rfq(p_rfq uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; r public.rfqs%rowtype;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  select * into r from public.rfqs where id = p_rfq and restaurant_id = v_rest and (v_rb is null or branch_id = v_rb);
  if not found then raise exception 'Quotation request not found.'; end if;
  return jsonb_build_object('id', r.id, 'number', r.number, 'status', r.status, 'needed_by', r.needed_by, 'notes', r.notes, 'cancel_reason', r.cancel_reason,
    'suppliers', coalesce((select jsonb_agg(jsonb_build_object('id', s.supplier_id, 'name', u.name, 'quoted', s.quoted_at is not null) order by u.name)
        from public.rfq_suppliers s join public.suppliers u on u.id = s.supplier_id where s.rfq_id = r.id), '[]'::jsonb),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('ingredient_id', l.ingredient_id, 'name', i.name, 'unit', i.unit, 'qty', l.qty,
        'last_cost', i.cost_per_unit,
        'quotes', coalesce((select jsonb_object_agg(q.supplier_id::text, q.unit_cost) from public.rfq_quotes q where q.rfq_id = r.id and q.ingredient_id = l.ingredient_id), '{}'::jsonb),
        'award', (select jsonb_build_object('supplier_id', a.supplier_id, 'unit_cost', a.unit_cost, 'po_id', a.purchase_order_id, 'po_number', p.number)
                    from public.rfq_awards a left join public.purchase_orders p on p.id = a.purchase_order_id where a.rfq_id = r.id and a.ingredient_id = l.ingredient_id))
        order by i.name) from public.rfq_lines l join public.ingredients i on i.id = l.ingredient_id where l.rfq_id = r.id), '[]'::jsonb));
end $$;

do $$ declare f text; begin
  foreach f in array array['create_rfq(jsonb,uuid[],date,text)', 'save_rfq_quotes(uuid,uuid,jsonb)', 'cancel_rfq(uuid,text)',
                           'award_rfq(uuid,jsonb,boolean)', 'list_rfqs()', 'get_rfq(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;
