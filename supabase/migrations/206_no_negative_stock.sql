-- No negative stock. One guard on every stock write that takes stock out (not sales: billing must never be blocked).
alter table public.purchase_settings add column if not exists allow_negative_stock boolean not null default false;

create or replace function app.stock_no_negative() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_now numeric; v_name text; v_unit text; v_allow boolean;
begin
  if new.qty >= 0 or new.kind not in ('returned', 'wastage', 'adjust', 'transfer_out') then return new; end if;
  select coalesce((select ps.allow_negative_stock from public.purchase_settings ps where ps.restaurant_id = new.restaurant_id), false) into v_allow;
  if v_allow then return new; end if;
  perform pg_advisory_xact_lock(hashtext('stock:' || new.branch_id::text || ':' || new.ingredient_id::text));
  select coalesce(sum(m.qty), 0) into v_now from public.stock_movements m where m.branch_id = new.branch_id and m.ingredient_id = new.ingredient_id;
  if v_now + new.qty < -0.0005 then
    select name, unit into v_name, v_unit from public.ingredients where id = new.ingredient_id;
    raise exception 'Only % % of % is in stock here, so % % cannot go out. Stock cannot go below zero.', trim(trailing '.' from trim(trailing '0' from v_now::text)), v_unit, v_name, trim(trailing '.' from trim(trailing '0' from (-new.qty)::text)), v_unit;
  end if;
  return new;
end $$;
revoke all on function app.stock_no_negative() from public, anon, authenticated;
drop trigger if exists stock_no_negative on public.stock_movements;
create trigger stock_no_negative before insert on public.stock_movements for each row execute function app.stock_no_negative();

create or replace function public.set_purchase_rules(p_direct boolean, p_rate_check text, p_excess boolean, p_needs_req boolean, p_backdate_days int, p_allow_negative boolean default false) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id();
begin
  if p_rate_check not in ('off', 'warn', 'block') then raise exception 'Choose off, warn or block for the rate check.'; end if;
  if p_backdate_days is null or p_backdate_days < 0 or p_backdate_days > 366 then raise exception 'Back-dating days must be between 0 and 366.'; end if;
  insert into public.purchase_settings (restaurant_id, direct_receiving, rate_check, allow_excess_qty, po_needs_requisition, max_backdate_days, allow_negative_stock, updated_by)
  values (v_rest, coalesce(p_direct, true), p_rate_check, coalesce(p_excess, true), coalesce(p_needs_req, false), p_backdate_days, coalesce(p_allow_negative, false), v_user)
  on conflict (restaurant_id) do update set direct_receiving = excluded.direct_receiving, rate_check = excluded.rate_check, allow_excess_qty = excluded.allow_excess_qty,
    po_needs_requisition = excluded.po_needs_requisition, max_backdate_days = excluded.max_backdate_days, allow_negative_stock = excluded.allow_negative_stock, updated_at = now(), updated_by = v_user;
  perform app.audit('purchase.rules', 'purchase_settings', v_rest, jsonb_build_object('direct', p_direct, 'rate_check', p_rate_check, 'excess', p_excess, 'needs_requisition', p_needs_req, 'backdate_days', p_backdate_days, 'allow_negative', coalesce(p_allow_negative, false)));
  return true;
end $$;
drop function if exists public.set_purchase_rules(boolean, text, boolean, boolean, int);
revoke all on function public.set_purchase_rules(boolean, text, boolean, boolean, int, boolean) from public, anon;
grant execute on function public.set_purchase_rules(boolean, text, boolean, boolean, int, boolean) to authenticated;
