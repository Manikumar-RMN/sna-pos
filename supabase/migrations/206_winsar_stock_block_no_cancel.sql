-- Winsar rules: stock can never go out beyond what is on hand (issue, return, wastage, transfer, adjust),
-- and received goods cannot be cancelled (reverse them with "Return goods"). Sales are never blocked.
create or replace function app.stock_no_negative() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_now numeric; v_name text;
begin
  if new.qty >= 0 or new.kind not in ('returned', 'wastage', 'adjust', 'transfer_out') then return new; end if;
  perform pg_advisory_xact_lock(hashtext('stock:' || new.branch_id::text || ':' || new.ingredient_id::text));
  select coalesce(sum(m.qty), 0) into v_now from public.stock_movements m where m.branch_id = new.branch_id and m.ingredient_id = new.ingredient_id;
  if v_now + new.qty < -0.0005 then
    select name into v_name from public.ingredients where id = new.ingredient_id;
    raise exception '% - Issue Qty(%) should be <= available Qty(%)', v_name, to_char(-new.qty, 'FM999999990.00'), to_char(greatest(v_now, 0), 'FM999999990.00');
  end if;
  return new;
end $$;
revoke all on function app.stock_no_negative() from public, anon, authenticated;
drop trigger if exists stock_no_negative on public.stock_movements;
create trigger stock_no_negative before insert on public.stock_movements for each row execute function app.stock_no_negative();

drop function if exists public.cancel_goods_receipt(uuid, text);
create function public.cancel_goods_receipt(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  raise exception 'Received goods cannot be cancelled. Use Return goods.';
end $$;
revoke all on function public.cancel_goods_receipt(uuid, text) from public, anon;
grant execute on function public.cancel_goods_receipt(uuid, text) to authenticated;
