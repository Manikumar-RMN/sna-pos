-- Money a supplier gives back after goods on a paid receipt were returned.
create table if not exists public.supplier_refunds (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  supplier_id uuid not null,
  goods_receipt_id uuid not null,
  amount numeric(14,2) not null check (amount > 0),
  method text not null check (method in ('cash', 'bank', 'upi', 'cheque', 'card', 'other')),
  reference text,
  received_on date not null,
  into_till boolean not null default false,
  cash_movement_id uuid,
  received_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  client_ref uuid,
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, goods_receipt_id) references public.goods_receipts(restaurant_id, id),
  foreign key (restaurant_id, supplier_id) references public.suppliers(restaurant_id, id)
);
create unique index if not exists supplier_refunds_client_ref on public.supplier_refunds (restaurant_id, client_ref) where client_ref is not null;
create index if not exists supplier_refunds_receipt on public.supplier_refunds (goods_receipt_id);
alter table public.supplier_refunds enable row level security;
drop policy if exists tenant_read on public.supplier_refunds;
create policy tenant_read on public.supplier_refunds for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()) and (select app.has_permission('stock.manage')) and branch_id = (select app.current_branch_id()));
revoke all on public.supplier_refunds from anon, authenticated;
grant select on public.supplier_refunds to authenticated;

create or replace function public.receive_supplier_refund(p_receipt_id uuid, p_amount numeric, p_method text, p_reference text default null,
  p_received_on date default null, p_into_till boolean default false, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  g public.goods_receipts%rowtype; v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_shift uuid; v_move uuid; v_sup text; v_id uuid := gen_random_uuid(); v_today date; v_seen jsonb;
begin
  perform app.require_feature('stock');
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('supplier_refund_ref:' || p_client_ref::text));
    select jsonb_build_object('refund_id', r.id, 'amount', r.amount, 'left', gr.refund_due, 'repeat', true) into v_seen
      from public.supplier_refunds r join public.goods_receipts gr on gr.id = r.goods_receipt_id
     where r.restaurant_id = v_rest and r.client_ref = p_client_ref;
    if v_seen is not null then return v_seen; end if;
  end if;
  select * into g from public.goods_receipts where id = p_receipt_id and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'Goods receipt not found.'; end if;
  if coalesce(p_method, '') not in ('cash', 'bank', 'upi', 'cheque', 'card', 'other') then raise exception 'Choose how the refund was received.'; end if;
  if g.refund_due <= 0 then raise exception 'The supplier owes nothing on receipt %.', g.number; end if;
  if v_amount <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  if v_amount > g.refund_due then raise exception 'The supplier owes only % on receipt %.', g.refund_due, g.number; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;
  if p_received_on is not null and p_received_on > v_today then raise exception 'The refund date cannot be in the future.'; end if;
  select name into v_sup from public.suppliers where id = g.supplier_id;

  if coalesce(p_into_till, false) then
    if p_method <> 'cash' then raise exception 'Only a cash refund can go into the till.'; end if;
    if not app.allowed('cash.movement') then raise exception 'Your role does not allow this action (cash.movement).'; end if;
    select id into v_shift from public.shifts where branch_id = g.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(g.branch_id); end if;
    if v_shift is null then raise exception 'Open a shift before putting a supplier refund into the till.'; end if;
    v_move := gen_random_uuid();
    insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_move, g.restaurant_id, v_shift, 'in', v_amount, left('Refund from supplier ' || v_sup || ' (' || g.number || ')', 200), v_user);
  end if;

  insert into public.supplier_refunds (id, restaurant_id, branch_id, supplier_id, goods_receipt_id, amount, method, reference, received_on, into_till, cash_movement_id, received_by, client_ref)
  values (v_id, g.restaurant_id, g.branch_id, g.supplier_id, g.id, v_amount, p_method, nullif(left(trim(coalesce(p_reference, '')), 60), ''),
          coalesce(p_received_on, v_today), coalesce(p_into_till, false), v_move, v_user, p_client_ref);
  update public.goods_receipts set refund_due = refund_due - v_amount where id = g.id;
  perform app.audit('supplier.refund', 'goods_receipts', g.id,
    jsonb_build_object('number', g.number, 'supplier', v_sup, 'amount', v_amount, 'method', p_method, 'into_till', coalesce(p_into_till, false)));
  return jsonb_build_object('refund_id', v_id, 'amount', v_amount, 'left', g.refund_due - v_amount);
end $$;
revoke all on function public.receive_supplier_refund(uuid, numeric, text, text, date, boolean, uuid) from public, anon;
grant execute on function public.receive_supplier_refund(uuid, numeric, text, text, date, boolean, uuid) to authenticated;

-- Undoing a payment: the part of it that had become "refund due" is cleared first.
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.undo_supplier_payment(uuid,text)'::regprocedure); o := d;
  d := replace(d, E'  select name into v_sup from public.suppliers where id = g.supplier_id;',
    E'  if exists (select 1 from public.supplier_refunds r where r.goods_receipt_id = g.id) then\n    raise exception ''A refund from the supplier was already recorded on receipt %, so its payments cannot be undone.'', g.number;\n  end if;\n  select name into v_sup from public.suppliers where id = g.supplier_id;');
  d := replace(d, 'v_paid := greatest(0, g.paid_total - sp.amount);', 'v_paid := greatest(0, g.paid_total - greatest(0, sp.amount - g.refund_due));');
  d := replace(d, 'update public.goods_receipts set paid_total = v_paid,', 'update public.goods_receipts set paid_total = v_paid, refund_due = greatest(0, refund_due - sp.amount),');
  if d = o or position('refund_due - sp.amount' in d) = 0 or position('supplier_refunds' in d) = 0 or position('sp.amount - g.refund_due' in d) = 0 then raise exception 'undo patch anchors changed'; end if;
  execute d;

  -- Purchase report: show what suppliers owe back.
  d := pg_get_functiondef('public.purchase_report(date,date)'::regprocedure); o := d;
  d := replace(d, '''owed'', sum(g.total - g.paid_total)) x', '''owed'', sum(g.total - g.paid_total), ''refund_due'', sum(g.refund_due)) x');
  d := replace(d, E'''owed'', coalesce(sum(g.total - g.paid_total), 0),\n', E'''owed'', coalesce(sum(g.total - g.paid_total), 0),\n      ''refund_due'', coalesce(sum(g.refund_due), 0),\n');
  d := replace(d, E'  select coalesce(jsonb_agg(x order by (x->>''amount'')::numeric desc), ''[]''::jsonb) into v_items from (',
    E'  select coalesce(jsonb_agg(x order by (x->>''received_on'')), ''[]''::jsonb) into v_ref from (\n    select jsonb_build_object(''id'', g.id, ''number'', g.number, ''supplier_id'', s.id, ''supplier'', s.name, ''received_on'', g.received_on, ''refund_due'', g.refund_due) x\n      from public.goods_receipts g join public.suppliers s on s.id = g.supplier_id\n     where g.restaurant_id = v_rest and g.branch_id = v_branch and g.status = ''received'' and g.refund_due > 0) z;\n\n  select coalesce(jsonb_agg(x order by (x->>''amount'')::numeric desc), ''[]''::jsonb) into v_items from (');
  d := replace(d, 'v_items jsonb; v_tot jsonb;', 'v_items jsonb; v_tot jsonb; v_ref jsonb;');
  d := replace(d, '''owed'', v_owed, ''by_ingredient'', v_items);', '''owed'', v_owed, ''refunds'', v_ref, ''by_ingredient'', v_items);');
  if d = o or position('''refunds'', v_ref' in d) = 0 or position('v_ref jsonb' in d) = 0 or position('into v_ref' in d) = 0 or position('sum(g.refund_due)) x' in d) = 0 or position('coalesce(sum(g.refund_due), 0)' in d) = 0 then raise exception 'report patch anchors changed'; end if;
  execute d;
end $$;
