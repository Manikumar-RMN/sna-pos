-- Which batch stock was taken from when it is issued, so an expiry or a bad batch
-- can be traced to the department that got it. Batches come from the goods received
-- lines; the newest receipts are taken to be what is still on hand, the same reading
-- the expiry report uses. Nothing changes about how stock is valued.

alter table public.material_issue_lines add column if not exists batch_no text;
alter table public.material_issue_lines add column if not exists expiry_date date;
grant select (batch_no, expiry_date) on public.material_issue_lines to authenticated;

-- The batch stock is being taken from: the one that goes off first.
create or replace function app.pick_batch(p_branch uuid, p_ingredient uuid)
returns table (batch_no text, expiry_date date)
language sql stable security definer set search_path = public, pg_temp as $$
  select b.batch_no, b.expiry_date from (
    select l.batch_no, l.expiry_date, g.received_on, g.created_at, l.id,
           least(l.qty - l.returned_qty,
                 greatest(0, coalesce(oh.on_hand, 0) - coalesce(sum(l.qty - l.returned_qty) over (
                   partition by l.ingredient_id order by g.received_on desc, g.created_at desc, l.id desc
                   rows between unbounded preceding and 1 preceding), 0))) as remaining
      from public.goods_receipt_lines l
      join public.goods_receipts g on g.id = l.goods_receipt_id
      left join lateral (select sum(m.qty) as on_hand from public.stock_movements m
                          where m.branch_id = p_branch and m.ingredient_id = l.ingredient_id) oh on true
     where g.branch_id = p_branch and g.status = 'received' and l.ingredient_id = p_ingredient) b
  where b.remaining > 0.0005 and (nullif(btrim(coalesce(b.batch_no, '')), '') is not null or b.expiry_date is not null)
  order by b.expiry_date nulls last, b.received_on, b.created_at, b.id
  limit 1;
$$;
revoke all on function app.pick_batch(uuid, uuid) from public, anon, authenticated;

do $$
declare d text; n text;
  o1 text := '  v_out jsonb; v_seen uuid[] := ''{}''; v_qty numeric; v_status text; v_name text; v_bd date;';
  r1 text := '  v_out jsonb; v_seen uuid[] := ''{}''; v_qty numeric; v_status text; v_name text; v_bd date;
  v_batch text; v_exp date;';
  o2 text := '    insert into public.material_issue_lines (restaurant_id, issue_id, ingredient_id, qty, unit_cost) values (v_rest, v_id, x.ingredient_id, v_qty, v_cost);';
  r2 text := '    v_batch := null; v_exp := null;
    select pb.batch_no, pb.expiry_date into v_batch, v_exp from app.pick_batch(v_branch, x.ingredient_id) pb;
    insert into public.material_issue_lines (restaurant_id, issue_id, ingredient_id, qty, unit_cost, batch_no, expiry_date)
    values (v_rest, v_id, x.ingredient_id, v_qty, v_cost, v_batch, v_exp);';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'issue_material';
  if position('pick_batch' in d) > 0 then raise notice 'already patched'; return; end if;
  if position(o1 in d) = 0 then raise exception 'issue_material: declare anchor did not match'; end if;
  if position(o2 in d) = 0 then raise exception 'issue_material: insert anchor did not match'; end if;
  n := replace(replace(d, o1, r1), o2, r2);
  execute n;
end $$;
