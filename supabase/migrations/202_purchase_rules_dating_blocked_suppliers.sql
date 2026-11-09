-- Purchase rules (Winsar: Settings > Receiving, Privilege): receive without an order or not, rate check, over-delivery,
-- orders only from requisitions, who may back-date / future-date, and blocked suppliers.

alter table public.purchase_settings add column if not exists direct_receiving boolean not null default true;
alter table public.purchase_settings add column if not exists rate_check text not null default 'off' check (rate_check in ('off', 'warn', 'block'));
alter table public.purchase_settings add column if not exists allow_excess_qty boolean not null default true;
alter table public.purchase_settings add column if not exists po_needs_requisition boolean not null default false;
alter table public.purchase_settings add column if not exists max_backdate_days int not null default 31 check (max_backdate_days between 0 and 366);

alter table public.suppliers add column if not exists blocked boolean not null default false;
alter table public.suppliers add column if not exists blocked_reason text;

insert into public.permissions (key, description, is_sensitive) values
  ('stock.backdate', 'Enter stock receipts, issues and counts with an earlier date', true),
  ('stock.futuredate', 'Date stock requests and orders in the future', true)
on conflict (key) do nothing;
insert into public.role_permissions (role_id, permission_key)
select r.id, k.key from public.roles r cross join (values ('stock.backdate'), ('stock.futuredate')) k(key)
 where r.is_system and r.name in ('Owner', 'Manager') on conflict do nothing;

create or replace function public.set_purchase_rules(p_direct boolean, p_rate_check text, p_excess boolean, p_needs_req boolean, p_backdate_days int) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id();
begin
  if p_rate_check not in ('off', 'warn', 'block') then raise exception 'Choose off, warn or block for the rate check.'; end if;
  if p_backdate_days is null or p_backdate_days < 0 or p_backdate_days > 366 then raise exception 'Back-dating days must be between 0 and 366.'; end if;
  insert into public.purchase_settings (restaurant_id, direct_receiving, rate_check, allow_excess_qty, po_needs_requisition, max_backdate_days, updated_by)
  values (v_rest, coalesce(p_direct, true), p_rate_check, coalesce(p_excess, true), coalesce(p_needs_req, false), p_backdate_days, v_user)
  on conflict (restaurant_id) do update set direct_receiving = excluded.direct_receiving, rate_check = excluded.rate_check, allow_excess_qty = excluded.allow_excess_qty,
    po_needs_requisition = excluded.po_needs_requisition, max_backdate_days = excluded.max_backdate_days, updated_at = now(), updated_by = v_user;
  perform app.audit('purchase.rules', 'purchase_settings', v_rest, jsonb_build_object('direct', p_direct, 'rate_check', p_rate_check, 'excess', p_excess, 'needs_requisition', p_needs_req, 'backdate_days', p_backdate_days));
  return true;
end $$;
revoke all on function public.set_purchase_rules(boolean, text, boolean, boolean, int) from public, anon;
grant execute on function public.set_purchase_rules(boolean, text, boolean, boolean, int) to authenticated;

create or replace function public.set_supplier_blocked(p_id uuid, p_blocked boolean, p_reason text default null) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_name text;
begin
  select name into v_name from public.suppliers where id = p_id and restaurant_id = v_rest;
  if v_name is null then raise exception 'Supplier not found.'; end if;
  if coalesce(p_blocked, false) and length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for blocking the supplier.'; end if;
  update public.suppliers set blocked = coalesce(p_blocked, false), blocked_reason = case when coalesce(p_blocked, false) then left(btrim(p_reason), 200) else null end where id = p_id;
  perform app.audit(case when p_blocked then 'supplier.block' else 'supplier.unblock' end, 'suppliers', p_id, jsonb_build_object('name', v_name, 'reason', left(btrim(coalesce(p_reason, '')), 200)));
  return true;
end $$;
revoke all on function public.set_supplier_blocked(uuid, boolean, text) from public, anon;
grant execute on function public.set_supplier_blocked(uuid, boolean, text) to authenticated;

-- The date a stock document is entered for. Blank means today. Earlier needs stock.backdate (and not older than the limit);
-- later needs stock.futuredate and is only allowed where p_future is true (requests and orders, never stock movements).
create or replace function app.check_doc_date(p_date date, p_future boolean default false) returns date
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_today date; v_max int;
begin
  v_today := (now() at time zone coalesce((select timezone from public.restaurants where id = v_rest), 'UTC'))::date;
  if p_date is null or p_date = v_today then return v_today; end if;
  if p_date < v_today then
    if not app.has_permission('stock.backdate') then raise exception 'Your role cannot enter an earlier date. Ask a manager or the owner.'; end if;
    select coalesce(max_backdate_days, 31) into v_max from public.purchase_settings where restaurant_id = v_rest;
    if v_today - p_date > coalesce(v_max, 31) then raise exception 'That date is more than % days back.', coalesce(v_max, 31); end if;
    return p_date;
  end if;
  if not p_future then raise exception 'The date cannot be in the future.'; end if;
  if not app.has_permission('stock.futuredate') then raise exception 'Your role cannot enter a future date.'; end if;
  return p_date;
end $$;
revoke all on function app.check_doc_date(date, boolean) from public, anon, authenticated;

-- receive_goods: new optional p_received_on, blocked suppliers, receive-without-order rule, rate check (block), over-delivery rule.
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid)'::regprocedure);
  o := d;
  d := replace(d, 'p_client_ref uuid DEFAULT NULL::uuid)', 'p_client_ref uuid DEFAULT NULL::uuid, p_received_on date DEFAULT NULL::date)');
  d := replace(d, 'v_claim boolean; v_ok boolean;', 'v_claim boolean; v_ok boolean; v_rc text := ''off''; v_dr boolean := true; v_xs boolean := true; v_ref numeric; v_pq numeric; v_bd date;');
  d := replace(d, E'  if not found then raise exception ''Choose a supplier.''; end if;',
    E'  if not found then raise exception ''Choose a supplier.''; end if;\n  if sup.blocked then raise exception ''% is blocked: %'', sup.name, coalesce(sup.blocked_reason, ''see the supplier''''s page''); end if;\n  select coalesce(ps.rate_check, ''off''), coalesce(ps.direct_receiving, true), coalesce(ps.allow_excess_qty, true) into v_rc, v_dr, v_xs from public.purchase_settings ps where ps.restaurant_id = v_rest;\n  if p_purchase_order_id is null and not v_dr then raise exception ''Goods can only be received against a purchase order. Choose the order.''; end if;');
  d := replace(d, E'  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;',
    E'  v_today := app.check_doc_date(p_received_on, false);\n  if v_today <> (now() at time zone (select timezone from public.restaurants where id = v_rest))::date then perform app.assert_month_open(v_branch, v_today); end if;\n  v_bd := case when v_today < (now() at time zone (select timezone from public.restaurants where id = v_rest))::date then v_today else null end;');
  d := replace(d, E'    v_amt := coalesce(l.line_total, round(l.qty * l.unit_cost, 2));',
    E'    v_amt := coalesce(l.line_total, round(l.qty * l.unit_cost, 2));\n    v_ref := null; v_pq := null;\n    if po.id is not null then select pol.unit_cost, pol.qty - pol.received_qty into v_ref, v_pq from public.purchase_order_lines pol where pol.purchase_order_id = po.id and pol.ingredient_id = l.ingredient_id; end if;\n    if v_ref is null then v_ref := app.agreed_rate(v_rest, sup.id, l.ingredient_id, v_today); end if;\n    if v_rc = ''block'' and v_ref is not null and abs(round(v_amt / nullif(l.qty, 0), 4) - v_ref) > 0.0001 then\n      raise exception ''The rate for % is % but the agreed or ordered rate is %. Change the rate, or ask the owner to relax the rate check.'', (select name from public.ingredients where id = l.ingredient_id), round(v_amt / nullif(l.qty, 0), 4), v_ref;\n    end if;\n    if not v_xs and v_pq is not null and l.qty > v_pq then\n      raise exception ''Only % of % is still due on order %.'', v_pq, (select name from public.ingredients where id = l.ingredient_id), po.number;\n    end if;');
  d := replace(d, E'    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, goods_receipt_id)\n    values (v_rest, v_branch, l.ingredient_id, ''purchase'', l.qty, v_eff, left(v_no || '' · '' || sup.name, 200), v_user, v_id);',
    E'    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, goods_receipt_id, business_date)\n    values (v_rest, v_branch, l.ingredient_id, ''purchase'', l.qty, v_eff, left(v_no || '' · '' || sup.name, 200), v_user, v_id, v_bd);');
  if d = o or position('app.check_doc_date' in d) = 0 or position('v_xs' in d) = 0 or position('sup.blocked' in d) = 0 or position('p_received_on' in d) = 0 or position('v_bd)' in d) = 0 then raise exception 'receive_goods anchors not found'; end if;
  execute d;
  drop function public.receive_goods(uuid, jsonb, uuid, text, date, numeric, numeric, date, text, jsonb, uuid);
end $$;

-- issue_material: new optional p_issue_date.
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.issue_material(uuid,text,jsonb,text,uuid)'::regprocedure);
  o := d;
  d := replace(d, 'p_client_ref uuid DEFAULT NULL::uuid)', 'p_client_ref uuid DEFAULT NULL::uuid, p_issue_date date DEFAULT NULL::date)');
  d := replace(d, 'v_name text;', 'v_name text; v_bd date;');
  d := replace(d, E'  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;',
    E'  v_today := app.check_doc_date(p_issue_date, false);\n  if v_today <> (now() at time zone (select timezone from public.restaurants where id = v_rest))::date then perform app.assert_month_open(v_branch, v_today); end if;\n  v_bd := case when v_today < (now() at time zone (select timezone from public.restaurants where id = v_rest))::date then v_today else null end;');
  d := replace(d, E'insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, reason, note, created_by)\n    values (v_rest, v_branch, x.ingredient_id, ''adjust'', -v_qty, v_cost, ''issued'', left(v_no || '' issued to '' || v_dept, 200), v_user);',
    E'insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, reason, note, created_by, business_date)\n    values (v_rest, v_branch, x.ingredient_id, ''adjust'', -v_qty, v_cost, ''issued'', left(v_no || '' issued to '' || v_dept, 200), v_user, v_bd);');
  if d = o or position('v_bd)' in d) = 0 or position('check_doc_date' in d) = 0 or position('p_issue_date' in d) = 0 then raise exception 'issue_material anchors not found'; end if;
  execute d;
  drop function public.issue_material(uuid, text, jsonb, text, uuid);
end $$;

-- save_purchase_order: blocked suppliers, and "orders only from requisitions".
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.save_purchase_order(uuid,uuid,jsonb,date,text,boolean)'::regprocedure);
  o := d;
  d := replace(d, 's.restaurant_id = v_rest and s.is_active) then', 's.restaurant_id = v_rest and s.is_active and not s.blocked) then');
  d := replace(d, E'  if v_id is null then\n    perform pg_advisory_xact_lock(hashtext(''purchase_order:'' || v_branch::text));',
    E'  if v_id is null and coalesce((select ps.po_needs_requisition from public.purchase_settings ps where ps.restaurant_id = v_rest), false) then\n    raise exception ''Orders can only be made from an approved requisition. Raise a requisition first.'';\n  end if;\n  if v_id is null then\n    perform pg_advisory_xact_lock(hashtext(''purchase_order:'' || v_branch::text));');
  if d = o or position('po_needs_requisition' in d) = 0 or position('not s.blocked' in d) = 0 then raise exception 'save_purchase_order anchors not found'; end if;
  execute d;
end $$;
