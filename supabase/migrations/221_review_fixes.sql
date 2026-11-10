-- Fixes from the full review of 10 Nov 2026 (claude/sna-pos/full-review-2026-11-10.md), group 1.

-- 1 + 2. Offline bills.
--   Tax rate: chosen by the restaurant's own calendar date of the sale, not the UTC date.
--   Business date: a bill made before a day was closed but synced after it stays in the open day (a closed day's
--   Z-report is never altered), and is now flagged 'made_in_closed_day' with the day it was really sold.
do $$
declare d text; a text; tz text := E'(v_at at time zone coalesce((select r.timezone from public.restaurants r where r.id = v_rest), ''UTC''))::date';
begin
  d := pg_get_functiondef('public.sync_offline_bill(jsonb)'::regprocedure);
  if position('made_in_closed_day' in d) > 0 then return; end if;
  if position('v_at::date' in d) = 0 then raise exception 'sync_offline_bill: tax date text did not match; nothing changed'; end if;
  d := replace(d, 'v_at::date', tz);
  a := E'if v_at < now() - interval ''7 days'' then v_flags := v_flags || jsonb_build_object(''flag'', ''older_than_7_days''); end if;';
  if position(a in d) = 0 then raise exception 'sync_offline_bill: flag text did not match; nothing changed'; end if;
  d := replace(d, a, a || E'\n  if exists (select 1 from public.business_days bd where bd.branch_id = v_branch and bd.status = ''closed'' and bd.opened_at <= v_at and bd.closed_at > v_at) then\n    v_flags := v_flags || jsonb_build_object(''flag'', ''made_in_closed_day'', ''sold_on'', (select bd.business_date from public.business_days bd where bd.branch_id = v_branch and bd.status = ''closed'' and bd.opened_at <= v_at and bd.closed_at > v_at order by bd.opened_at desc limit 1));\n  end if;');
  execute d;
end $$;

-- 3. Stock count: "expected" is the stock at the moment the count sheet was opened (sent by the screen), so sales
--    made while people were counting are not turned into a false difference. Without a time it works as before.
do $$
declare d text;
begin
  if to_regprocedure('public.stock_count_apply(jsonb,text,uuid,timestamptz)') is not null then return; end if;
  d := pg_get_functiondef('public.stock_count_apply(jsonb,text,uuid)'::regprocedure);
  if position('p_client_ref uuid DEFAULT NULL::uuid)' in d) = 0 or position('v_var numeric := 0; v_date date;' in d) = 0
     or position('from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = l.iid;' in d) = 0 then
    raise exception 'stock_count_apply text did not match; nothing changed';
  end if;
  d := replace(d, 'p_client_ref uuid DEFAULT NULL::uuid)', 'p_client_ref uuid DEFAULT NULL::uuid, p_counted_at timestamp with time zone DEFAULT NULL::timestamp with time zone)');
  d := replace(d, 'v_var numeric := 0; v_date date;', E'v_var numeric := 0; v_date date;\n  v_asof timestamptz := case when p_counted_at > now() - interval ''24 hours'' and p_counted_at <= now() then p_counted_at end;');
  d := replace(d, 'from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = l.iid;',
                  'from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = l.iid and (v_asof is null or m.created_at <= v_asof);');
  drop function public.stock_count_apply(jsonb, text, uuid);
  execute d;
  revoke all on function public.stock_count_apply(jsonb, text, uuid, timestamptz) from public, anon;
  grant execute on function public.stock_count_apply(jsonb, text, uuid, timestamptz) to authenticated;
end $$;

-- 4. The same supplier bill cannot be received twice.
create or replace function app.block_duplicate_supplier_bill() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_no text;
begin
  if nullif(btrim(coalesce(new.supplier_bill_no, '')), '') is null or new.status = 'cancelled' then return new; end if;
  select g.number into v_no from public.goods_receipts g
   where g.restaurant_id = new.restaurant_id and g.supplier_id = new.supplier_id and g.status <> 'cancelled' and g.id <> new.id
     and lower(btrim(g.supplier_bill_no)) = lower(btrim(new.supplier_bill_no)) limit 1;
  if v_no is not null then
    raise exception 'Bill % from this supplier was already received as %. Check before saving it again.', btrim(new.supplier_bill_no), v_no;
  end if;
  return new;
end $$;
drop trigger if exists goods_receipts_no_duplicate_bill on public.goods_receipts;
create trigger goods_receipts_no_duplicate_bill before insert on public.goods_receipts
  for each row execute function app.block_duplicate_supplier_bill();

-- 5. Nothing is posted into a closed stock day or month, whichever screen it comes from.
--    Sales and their returns are never blocked: a bill must always go through.
create or replace function app.stock_closed_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.kind in ('sale', 'returned') then return new; end if;
  perform app.assert_month_open(new.branch_id, new.business_date);
  return new;
end $$;
drop trigger if exists trg_stock_stamp_z_closed on public.stock_movements;
-- the name sorts after trg_stock_stamp, so the business date is already filled in
create trigger trg_stock_stamp_z_closed before insert on public.stock_movements
  for each row execute function app.stock_closed_guard();

-- 6. Sending stock to another outlet: a double click or a retry sends it once.
drop function if exists public.transfer_stock(uuid, numeric, uuid, text);
create or replace function public.transfer_stock(p_ingredient_id uuid, p_qty numeric, p_to_branch uuid, p_note text default null::text, p_client_ref uuid default null::uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_from uuid := app.current_branch_id();
  v_ing public.ingredients%rowtype; v_now numeric; v_id uuid := coalesce(p_client_ref, gen_random_uuid()); v_from_name text; v_to_name text;
begin
  perform app.require_feature('central_kitchen');
  perform app.require_feature('stock');
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    if exists (select 1 from public.stock_movements m where m.transfer_id = p_client_ref) then
      if not exists (select 1 from public.stock_movements m where m.transfer_id = p_client_ref and m.restaurant_id = v_rest and m.branch_id = v_from and m.kind = 'transfer_out') then
        raise exception 'This request was already used for something else. Go back and try once more.';
      end if;
      return p_client_ref;
    end if;
  end if;
  select * into v_ing from public.ingredients where id = p_ingredient_id and restaurant_id = v_rest;
  if not found then raise exception 'Ingredient not found.'; end if;
  if p_to_branch = v_from then raise exception 'Choose another outlet to send to.'; end if;
  select name into v_to_name from public.branches where id = p_to_branch and restaurant_id = v_rest and deleted_at is null;
  if v_to_name is null then raise exception 'Outlet not found.'; end if;
  select name into v_from_name from public.branches where id = v_from;
  if p_qty is null or p_qty <= 0 then raise exception 'Enter a quantity.'; end if;
  perform pg_advisory_xact_lock(hashtext('stock:' || v_from::text || ':' || v_ing.id::text));
  select coalesce(sum(qty), 0) into v_now from public.stock_movements where branch_id = v_from and ingredient_id = v_ing.id;
  if p_qty > v_now then raise exception 'Only % % of % in stock here.', v_now, v_ing.unit, v_ing.name; end if;
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, transfer_id) values
    (v_rest, v_from, v_ing.id, 'transfer_out', -p_qty, v_ing.cost_per_unit, left('To ' || v_to_name || coalesce(': ' || nullif(trim(p_note), ''), ''), 200), v_user, v_id),
    (v_rest, p_to_branch, v_ing.id, 'transfer_in', p_qty, v_ing.cost_per_unit, left('From ' || v_from_name || coalesce(': ' || nullif(trim(p_note), ''), ''), 200), v_user, v_id);
  perform app.audit('stock.transfer', 'ingredients', v_ing.id, jsonb_build_object('qty', p_qty, 'from', v_from, 'to', p_to_branch, 'transfer', v_id));
  return v_id;
end $function$;
revoke all on function public.transfer_stock(uuid, numeric, uuid, text, uuid) from public, anon;
grant execute on function public.transfer_stock(uuid, numeric, uuid, text, uuid) to authenticated;

-- 7. The old one-line stock entry (no supplier, no receipt, no retry protection) is no longer callable. No screen uses it.
revoke all on function public.record_stock(uuid, text, numeric, numeric, text) from public, anon, authenticated;

-- 8. Editing an item no longer wipes its average cost: a cost that is not sent is kept, and a change is written to the audit trail with the old cost.
do $$
declare d text; a text := 'unit = p_unit, cost_per_unit = coalesce(p_cost, 0), reorder_level'; b text := E'jsonb_build_object(''name'', p_name, ''unit'', p_unit, ''cost'', p_cost,';
begin
  d := pg_get_functiondef('public.save_ingredient(uuid,text,text,numeric,numeric,text,text,numeric,text)'::regprocedure);
  if position('prev_cost' in d) > 0 then return; end if;
  if position(a in d) = 0 or position(b in d) = 0 or position('v_type text :=' in d) = 0 then raise exception 'save_ingredient text did not match; nothing changed'; end if;
  d := replace(d, a, 'unit = p_unit, cost_per_unit = coalesce(p_cost, cost_per_unit), reorder_level');
  d := replace(d, 'v_type text :=', 'v_prev numeric := (select i.cost_per_unit from public.ingredients i where i.id = p_id); v_type text :=');
  d := replace(d, b, E'jsonb_build_object(''name'', p_name, ''unit'', p_unit, ''cost'', p_cost, ''prev_cost'', v_prev,');
  execute d;
end $$;
