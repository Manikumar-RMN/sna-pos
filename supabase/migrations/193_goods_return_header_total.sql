-- return_goods fills in the header total once the lines are known, so the header may be updated exactly once
-- (from 0), and nothing else on it may ever change. Nobody has write access to the table anyway; deletes stay blocked.
drop trigger if exists trg_no_update_goods_returns on public.goods_returns;
create or replace function app.goods_returns_guard() returns trigger language plpgsql as $$
begin
  if old.total <> 0 then raise exception 'Goods Returns records cannot be changed.'; end if;
  if (new.id, new.restaurant_id, new.branch_id, new.goods_receipt_id, new.supplier_id, new.number, new.returned_on, new.reason, new.created_by)
     is distinct from (old.id, old.restaurant_id, old.branch_id, old.goods_receipt_id, old.supplier_id, old.number, old.returned_on, old.reason, old.created_by) then
    raise exception 'Goods Returns records cannot be changed.';
  end if;
  return new;
end $$;
drop trigger if exists trg_guard_goods_returns on public.goods_returns;
create trigger trg_guard_goods_returns before update on public.goods_returns for each row execute function app.goods_returns_guard();
