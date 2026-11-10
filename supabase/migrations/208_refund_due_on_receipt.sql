-- Money paid beyond a receipt's reduced total is tracked as refund due from the supplier
-- (a receipt can never have paid_total above its total).
alter table public.goods_receipts add column if not exists refund_due numeric(14,2) not null default 0 check (refund_due >= 0);
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.return_goods(uuid,jsonb,text,uuid)'::regprocedure); o := d;
  d := replace(d, 'update public.goods_receipts set total = total - v_total, returned_total',
    'update public.goods_receipts set refund_due = refund_due + greatest(0, paid_total - (total - v_total)), paid_total = least(paid_total, total - v_total), total = total - v_total, returned_total');
  if d = o then raise exception 'return_goods patch anchor changed'; end if;
  execute d;
end $$;
revoke all on function public.return_goods(uuid, jsonb, text, uuid) from public, anon;
grant execute on function public.return_goods(uuid, jsonb, text, uuid) to authenticated;
