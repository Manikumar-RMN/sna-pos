-- Return goods to a supplier (a "debit note"). Winsar calls it Receipt Return.
-- The receipt keeps what was delivered; the return takes the stock back out and
-- lowers what is owed. `total` stays the amount still payable, so every place
-- that already works out "owed = total - paid" keeps working. The original
-- invoice total is total + returned_total.

alter table public.goods_receipts      add column if not exists returned_total numeric(14,2) not null default 0 check (returned_total >= 0);
alter table public.goods_receipt_lines add column if not exists returned_qty   numeric(14,3) not null default 0 check (returned_qty >= 0);

create table if not exists public.goods_returns (
  id               uuid primary key default gen_random_uuid(),
  restaurant_id    uuid not null references public.restaurants(id) on delete cascade,
  branch_id        uuid not null,
  goods_receipt_id uuid not null,
  supplier_id      uuid not null,
  number           text not null,
  returned_on      date not null,
  reason           text not null,
  total            numeric(14,2) not null default 0 check (total >= 0),
  created_by       uuid not null references public.users(id),
  created_at       timestamptz not null default now(),
  client_ref       uuid,
  unique (branch_id, number),
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, goods_receipt_id) references public.goods_receipts(restaurant_id, id),
  foreign key (restaurant_id, supplier_id) references public.suppliers(restaurant_id, id)
);
create unique index if not exists goods_returns_client_ref_uq on public.goods_returns (restaurant_id, client_ref) where client_ref is not null;
create index if not exists goods_returns_receipt on public.goods_returns (goods_receipt_id);

create table if not exists public.goods_return_lines (
  id              uuid primary key default gen_random_uuid(),
  restaurant_id   uuid not null,
  goods_return_id uuid not null,
  ingredient_id   uuid not null,
  qty             numeric(14,3) not null check (qty > 0),
  unit_cost       numeric(14,4) not null check (unit_cost >= 0),
  line_total      numeric(14,2) not null check (line_total >= 0),
  foreign key (restaurant_id, goods_return_id) references public.goods_returns(restaurant_id, id) on delete cascade,
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id)
);
create index if not exists goods_return_lines_return on public.goods_return_lines (goods_return_id);

do $$
declare t text; v_using text;
begin
  foreach t in array array['goods_returns', 'goods_return_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists tenant_read on public.%I', t);
    v_using := 'restaurant_id = (select app.current_restaurant_id()) and (select app.has_permission(''stock.manage''))';
    if t = 'goods_returns' then
      v_using := v_using || ' and branch_id = (select app.current_branch_id())';
    else
      v_using := v_using || ' and exists (select 1 from public.goods_returns h where h.id = goods_return_id)';
    end if;
    execute format('create policy tenant_read on public.%I for select to authenticated using (%s)', t, v_using);
  end loop;
end $$;

drop trigger if exists trg_no_delete_goods_returns on public.goods_returns;
create trigger trg_no_delete_goods_returns before delete on public.goods_returns for each row execute function app.block_delete();

-- Erase ("go live") must clear the new tables, children first.
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('app.erase_groups()'::regprocedure);
  if v_def like '%goods_return_lines%' then return; end if;
  if position('''goods_receipt_lines'', ' in v_def) = 0 then raise exception 'erase_groups text did not match'; end if;
  v_def := replace(v_def, '''goods_receipt_lines'', ', '''goods_return_lines'', ''goods_returns'', ''goods_receipt_lines'', ');
  execute v_def;
  revoke all on function app.erase_groups() from public, anon, authenticated;
end $$;

-- A receipt that has returns: cancelling it takes back only what is still here.
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.cancel_goods_receipt(uuid,text)'::regprocedure);
  if v_def like '%returned_qty%' then return; end if;
  if position('insert into public.stock_movements' in v_def) = 0
     or position('-l.qty, l.unit_cost' in v_def) = 0
     or position('trim(p_reason), 200), v_user, g.id);' in v_def) = 0 then
    raise exception 'cancel_goods_receipt text did not match';
  end if;
  v_def := replace(v_def, '    insert into public.stock_movements', '    if l.qty > l.returned_qty then insert into public.stock_movements');
  v_def := replace(v_def, '-l.qty, l.unit_cost', '-(l.qty - l.returned_qty), l.unit_cost');
  v_def := replace(v_def, 'trim(p_reason), 200), v_user, g.id);', 'trim(p_reason), 200), v_user, g.id); end if;');
  execute v_def;
end $$;

create or replace function public.return_goods(p_receipt_id uuid, p_lines jsonb, p_reason text, p_client_ref uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  g public.goods_receipts%rowtype; gl public.goods_receipt_lines%rowtype; x record;
  v_id uuid := gen_random_uuid(); v_no text; v_seq int; v_today date; v_val numeric(14,2); v_total numeric(14,2) := 0;
  v_out jsonb; v_seen uuid[] := '{}'; v_qty numeric; v_paid text;
begin
  perform app.require_feature('stock');
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('grt_ref:' || p_client_ref::text));
    select jsonb_build_object('id', r.id, 'number', r.number, 'total', r.total, 'repeat', true) into v_out
      from public.goods_returns r where r.restaurant_id = v_rest and r.client_ref = p_client_ref;
    if v_out is not null then return v_out; end if;
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for the return.'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Choose what is going back.';
  end if;
  select * into g from public.goods_receipts
   where id = p_receipt_id and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'Goods receipt not found.'; end if;
  if g.status = 'cancelled' then raise exception 'Receipt % was cancelled.', g.number; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;

  perform pg_advisory_xact_lock(hashtext('goods_return:' || v_branch::text));
  select count(*) + 1 into v_seq from public.goods_returns where branch_id = v_branch;
  v_no := 'GRT-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');
  insert into public.goods_returns (id, restaurant_id, branch_id, goods_receipt_id, supplier_id, number, returned_on, reason, created_by, client_ref)
  values (v_id, v_rest, v_branch, g.id, g.supplier_id, v_no, v_today, left(trim(p_reason), 300), v_user, p_client_ref);

  for x in select (e->>'ingredient_id')::uuid as ingredient_id, (e->>'qty')::numeric as qty
             from jsonb_array_elements(p_lines) e order by 1 loop
    if x.ingredient_id = any (v_seen) then raise exception 'An ingredient is on the list twice. Put it on one line.'; end if;
    v_seen := v_seen || x.ingredient_id;
    if x.qty is null or x.qty <= 0 then raise exception 'Enter a quantity greater than zero for each line.'; end if;
    select * into gl from public.goods_receipt_lines where goods_receipt_id = g.id and ingredient_id = x.ingredient_id for update;
    if not found then raise exception 'That ingredient is not on receipt %.', g.number; end if;
    v_qty := round(x.qty, 3);
    if v_qty > gl.qty - gl.returned_qty then
      raise exception 'Only % of % can still go back on receipt %.', gl.qty - gl.returned_qty,
        (select name from public.ingredients where id = x.ingredient_id), g.number;
    end if;
    -- Full remaining return gives back exactly what is left of the line; otherwise pro rata.
    v_val := case when v_qty = gl.qty - gl.returned_qty
                  then gl.line_total - coalesce((select sum(rl.line_total) from public.goods_return_lines rl
                         join public.goods_returns rr on rr.id = rl.goods_return_id
                        where rr.goods_receipt_id = g.id and rl.ingredient_id = x.ingredient_id), 0)
                  else round(gl.line_total * v_qty / gl.qty, 2) end;
    perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || x.ingredient_id::text));
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, goods_receipt_id)
    values (v_rest, v_branch, x.ingredient_id, 'adjust', -v_qty, gl.unit_cost, left(v_no || ' returned to supplier: ' || trim(p_reason), 200), v_user, g.id);
    insert into public.goods_return_lines (restaurant_id, goods_return_id, ingredient_id, qty, unit_cost, line_total)
    values (v_rest, v_id, x.ingredient_id, v_qty, gl.unit_cost, v_val);
    update public.goods_receipt_lines set returned_qty = returned_qty + v_qty where id = gl.id;
    v_total := v_total + v_val;
  end loop;

  if v_total > g.total - g.paid_total then
    raise exception 'Receipt % has % paid already, so only % can be returned against it now. Undo the payment first, or agree a refund with the supplier.',
      g.number, g.paid_total, g.total - g.paid_total;
  end if;
  update public.goods_returns set total = v_total where id = v_id;
  v_paid := case when g.total - v_total <= g.paid_total then 'paid' when g.paid_total > 0 then 'partial' else 'unpaid' end;
  update public.goods_receipts set total = total - v_total, returned_total = returned_total + v_total, payment_status = v_paid where id = g.id;
  perform app.audit('goods.return', 'goods_receipts', g.id,
    jsonb_build_object('number', g.number, 'return', v_no, 'value', v_total, 'reason', left(trim(p_reason), 300)));
  return jsonb_build_object('id', v_id, 'number', v_no, 'total', v_total, 'owed', g.total - v_total - g.paid_total);
end $$;
revoke all on function public.return_goods(uuid, jsonb, text, uuid) from public, anon;
grant execute on function public.return_goods(uuid, jsonb, text, uuid) to authenticated;
