-- Advance (on-account) payments to suppliers.
-- Money can now be given to a supplier before any bill exists, then used against bills later.
-- A payment row is still always tied to a receipt, so applying an advance writes an ordinary
-- supplier_payments row marked with supplier_advance_id. No cash moves at that moment:
-- the cash already left when the advance was paid.

alter table public.supplier_payments add column if not exists supplier_advance_id uuid;

create table if not exists public.supplier_advances (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  branch_id uuid not null references public.branches(id),
  supplier_id uuid not null references public.suppliers(id),
  number text not null,
  amount numeric(14,2) not null check (amount > 0),
  applied_total numeric(14,2) not null default 0 check (applied_total >= 0),
  method text not null check (method in ('cash', 'bank', 'upi', 'cheque', 'card', 'other')),
  reference text,
  paid_on date not null,
  from_till boolean not null default false,
  cash_movement_id uuid,
  notes text,
  status text not null default 'open' check (status in ('open', 'used', 'cancelled')),
  cancelled_reason text,
  cancelled_at timestamptz,
  paid_by uuid not null,
  client_ref uuid,
  created_at timestamptz not null default now(),
  unique (branch_id, number),
  unique (restaurant_id, id),
  check (applied_total <= amount)
);
create index if not exists supplier_advances_supplier on public.supplier_advances (restaurant_id, supplier_id, status);
create unique index if not exists supplier_advances_client_ref on public.supplier_advances (branch_id, client_ref) where client_ref is not null;

alter table public.supplier_advances enable row level security;
revoke all on public.supplier_advances from anon, authenticated;
grant select on public.supplier_advances to authenticated;
drop policy if exists tenant_read on public.supplier_advances;
create policy tenant_read on public.supplier_advances for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()));

grant select (supplier_advance_id) on public.supplier_payments to authenticated;

-- Pay an advance. Cash may come out of the till, like any other supplier payment.
create or replace function public.pay_supplier_advance(
  p_supplier uuid, p_amount numeric, p_method text, p_reference text default null,
  p_paid_on date default null, p_from_till boolean default false, p_notes text default null,
  p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_sup text; v_id uuid := gen_random_uuid(); v_no text; v_seq int; v_today date; v_shift uuid; v_move uuid;
begin
  perform app.require_feature('stock');
  if p_client_ref is not null then
    select id, number into v_id, v_no from public.supplier_advances where branch_id = v_branch and client_ref = p_client_ref;
    if v_no is not null then return jsonb_build_object('id', v_id, 'number', v_no, 'amount', v_amount, 'repeat', true); end if;
    v_id := gen_random_uuid();
  end if;
  select name into v_sup from public.suppliers s
   where s.id = p_supplier and s.restaurant_id = v_rest and s.is_active and not s.blocked;
  if v_sup is null then raise exception 'Choose a supplier.'; end if;
  if coalesce(p_method, '') not in ('cash', 'bank', 'upi', 'cheque', 'card', 'other') then
    raise exception 'Choose how the supplier was paid.';
  end if;
  if v_amount <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;
  if p_paid_on is not null and p_paid_on > v_today then raise exception 'The payment date cannot be in the future.'; end if;

  if coalesce(p_from_till, false) then
    if p_method <> 'cash' then raise exception 'Only a cash payment can come out of the till.'; end if;
    if not app.allowed('cash.movement') then
      raise exception 'Your role does not allow this action (cash.movement).';
    end if;
    select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
    if v_shift is null then raise exception 'Open a shift before paying a supplier from the till.'; end if;
    v_move := gen_random_uuid();
    insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_move, v_rest, v_shift, 'out', v_amount, left('Advance to supplier ' || v_sup, 200), v_user);
  end if;

  perform pg_advisory_xact_lock(hashtext('supplier_advance:' || v_branch::text));
  select count(*) + 1 into v_seq from public.supplier_advances where branch_id = v_branch;
  v_no := 'ADV-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');
  insert into public.supplier_advances (id, restaurant_id, branch_id, supplier_id, number, amount, method, reference,
                                        paid_on, from_till, cash_movement_id, notes, paid_by, client_ref)
  values (v_id, v_rest, v_branch, p_supplier, v_no, v_amount, p_method,
          nullif(left(trim(coalesce(p_reference, '')), 60), ''), coalesce(p_paid_on, v_today),
          coalesce(p_from_till, false), v_move, nullif(left(trim(coalesce(p_notes, '')), 300), ''), v_user, p_client_ref);
  perform app.audit('supplier.advance', 'supplier_advances', v_id,
    jsonb_build_object('number', v_no, 'supplier', v_sup, 'amount', v_amount, 'method', p_method, 'from_till', coalesce(p_from_till, false)));
  return jsonb_build_object('id', v_id, 'number', v_no, 'amount', v_amount);
end $$;

-- Use an advance against a bill. Writes an ordinary payment row; no cash moves now.
create or replace function public.apply_supplier_advance(p_advance uuid, p_receipt uuid, p_amount numeric default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  a public.supplier_advances%rowtype; g public.goods_receipts%rowtype;
  v_left numeric(14,2); v_owed numeric(14,2); v_amount numeric(14,2); v_id uuid := gen_random_uuid(); v_today date;
begin
  perform app.require_feature('stock');
  select * into a from public.supplier_advances
   where id = p_advance and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'Advance not found.'; end if;
  if a.status = 'cancelled' then raise exception 'Advance % was cancelled.', a.number; end if;
  select * into g from public.goods_receipts where id = p_receipt and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'Goods receipt not found.'; end if;
  if g.status = 'cancelled' then raise exception 'Receipt % was cancelled.', g.number; end if;
  if g.supplier_id <> a.supplier_id then
    raise exception 'Advance % is for another supplier, so it cannot be used on receipt %.', a.number, g.number;
  end if;
  v_left := a.amount - a.applied_total;
  if v_left <= 0 then raise exception 'Advance % has already been used in full.', a.number; end if;
  v_owed := g.total - g.paid_total;
  if v_owed <= 0 then raise exception 'Receipt % is already fully paid.', g.number; end if;
  v_amount := round(coalesce(p_amount, least(v_left, v_owed)), 2);
  if v_amount <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  if v_amount > v_left then raise exception 'Only % is left on advance %.', v_left, a.number; end if;
  if v_amount > v_owed then raise exception 'Only % is still owed on receipt %.', v_owed, g.number; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;

  insert into public.supplier_payments (id, restaurant_id, branch_id, supplier_id, goods_receipt_id, amount, method, reference,
                                        paid_on, from_till, paid_by, supplier_advance_id)
  values (v_id, v_rest, v_branch, g.supplier_id, g.id, v_amount, a.method,
          left('Advance ' || a.number, 60), v_today, false, v_user, a.id);
  update public.goods_receipts set paid_total = paid_total + v_amount,
         payment_status = case when paid_total + v_amount >= total then 'paid' else 'partial' end
   where id = g.id;
  update public.supplier_advances set applied_total = applied_total + v_amount,
         status = case when applied_total + v_amount >= amount then 'used' else 'open' end
   where id = a.id;
  perform app.audit('supplier.advance_apply', 'supplier_advances', a.id,
    jsonb_build_object('number', a.number, 'receipt', g.number, 'amount', v_amount));
  return jsonb_build_object('payment_id', v_id, 'amount', v_amount,
    'advance_left', v_left - v_amount, 'receipt_balance', v_owed - v_amount, 'number', a.number);
end $$;

-- Take an advance back off a bill. The money goes back onto the advance, not into the till.
create or replace function public.unapply_supplier_advance(p_payment_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  sp public.supplier_payments%rowtype; g public.goods_receipts%rowtype; a public.supplier_advances%rowtype;
  v_id uuid := gen_random_uuid(); v_today date; v_paid numeric(14,2);
begin
  perform app.require_feature('stock');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for taking the advance back off the bill.'; end if;
  select * into sp from public.supplier_payments
   where id = p_payment_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id();
  if not found then raise exception 'Payment not found.'; end if;
  if sp.supplier_advance_id is null then raise exception 'That payment did not come from an advance. Undo it from the payment list instead.'; end if;
  if sp.reverses_id is not null then raise exception 'That entry is itself an undo; it cannot be undone.'; end if;
  if exists (select 1 from public.supplier_payments x where x.reverses_id = sp.id) then
    raise exception 'That advance has already been taken back off the bill.';
  end if;
  select * into g from public.goods_receipts where id = sp.goods_receipt_id for update;
  select * into a from public.supplier_advances where id = sp.supplier_advance_id for update;
  if exists (select 1 from public.supplier_refunds r where r.goods_receipt_id = g.id) then
    raise exception 'A refund from the supplier was already recorded on receipt %, so its payments cannot be undone.', g.number;
  end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = g.restaurant_id))::date;

  insert into public.supplier_payments (id, restaurant_id, branch_id, supplier_id, goods_receipt_id, amount, method, reference,
                                        paid_on, from_till, paid_by, reverses_id, reason, supplier_advance_id)
  values (v_id, sp.restaurant_id, sp.branch_id, sp.supplier_id, sp.goods_receipt_id, -sp.amount, sp.method, sp.reference,
          v_today, false, v_user, sp.id, left(trim(p_reason), 300), a.id);
  v_paid := greatest(0, g.paid_total - sp.amount);
  update public.goods_receipts set paid_total = v_paid,
         payment_status = case when v_paid <= 0 then (case when total = 0 then 'paid' else 'unpaid' end)
                               when v_paid >= total then 'paid' else 'partial' end
   where id = g.id;
  update public.supplier_advances set applied_total = greatest(0, applied_total - sp.amount),
         status = case when status = 'cancelled' then 'cancelled'
                       when greatest(0, applied_total - sp.amount) >= amount then 'used' else 'open' end
   where id = a.id;
  perform app.audit('supplier.advance_unapply', 'supplier_advances', a.id,
    jsonb_build_object('number', a.number, 'receipt', g.number, 'amount', sp.amount, 'reason', left(trim(p_reason), 300)));
  return jsonb_build_object('payment_id', v_id, 'amount', sp.amount, 'number', a.number, 'receipt', g.number);
end $$;

-- Cancel an advance that was never used (money came back from the supplier).
create or replace function public.cancel_supplier_advance(p_advance uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  a public.supplier_advances%rowtype; v_sup text; v_shift uuid; v_move uuid;
begin
  perform app.require_feature('stock');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for cancelling the advance.'; end if;
  select * into a from public.supplier_advances
   where id = p_advance and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Advance not found.'; end if;
  if a.status = 'cancelled' then raise exception 'Advance % is already cancelled.', a.number; end if;
  if a.applied_total > 0 then
    raise exception 'Advance % has already been used on a bill. Take it off the bill first.', a.number;
  end if;
  select name into v_sup from public.suppliers where id = a.supplier_id;

  if a.from_till then
    if not app.allowed('cash.movement') then
      raise exception 'Your role does not allow this action (cash.movement).';
    end if;
    select id into v_shift from public.shifts where branch_id = a.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(a.branch_id); end if;
    if v_shift is null then raise exception 'Open a shift before cancelling an advance that was paid from the till.'; end if;
    v_move := gen_random_uuid();
    insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_move, a.restaurant_id, v_shift, 'in', a.amount,
            left('Advance cancelled: ' || v_sup || ' (' || a.number || ')', 200), v_user);
  end if;

  update public.supplier_advances set status = 'cancelled', cancelled_reason = left(trim(p_reason), 300), cancelled_at = now()
   where id = a.id;
  perform app.audit('supplier.advance_cancel', 'supplier_advances', a.id,
    jsonb_build_object('number', a.number, 'supplier', v_sup, 'amount', a.amount, 'reason', left(trim(p_reason), 300)));
  return jsonb_build_object('id', a.id, 'number', a.number, 'amount', a.amount, 'to_till', a.from_till);
end $$;

do $$ declare f text; begin
  foreach f in array array['pay_supplier_advance(uuid,numeric,text,text,date,boolean,text,uuid)',
                           'apply_supplier_advance(uuid,uuid,numeric)',
                           'unapply_supplier_advance(uuid,text)',
                           'cancel_supplier_advance(uuid,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

-- Advances an outlet is holding with each supplier, for the purchases screen.
create or replace function public.report_supplier_advances(p_supplier uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  return (
    with a as (
      select ad.id, ad.number, s.name as supplier, ad.supplier_id, ad.amount, ad.applied_total,
             ad.amount - ad.applied_total as left_over, ad.method, ad.reference, ad.paid_on, ad.from_till,
             ad.status, ad.notes
        from public.supplier_advances ad join public.suppliers s on s.id = ad.supplier_id
       where ad.restaurant_id = v_rest and (v_rb is null or ad.branch_id = v_rb)
         and (p_supplier is null or ad.supplier_id = p_supplier))
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'number', number, 'supplier', supplier,
                'amount', round(amount, 2), 'used', round(applied_total, 2), 'left', round(left_over, 2),
                'method', method, 'reference', reference, 'paid_on', paid_on, 'from_till', from_till,
                'status', status, 'notes', notes)
                order by case when status = 'open' then 0 when status = 'used' then 1 else 2 end, paid_on desc, number desc) from a), '[]'::jsonb),
      'open_total', coalesce((select round(sum(left_over), 2) from a where status = 'open'), 0),
      'by_supplier', coalesce((select jsonb_agg(x order by nm) from (
                select supplier as nm, jsonb_build_object('supplier', supplier, 'left', round(sum(left_over), 2)) as x
                  from a where status = 'open' group by supplier) y), '[]'::jsonb))
  );
end $$;
revoke all on function public.report_supplier_advances(uuid) from public, anon;
grant execute on function public.report_supplier_advances(uuid) to authenticated;
