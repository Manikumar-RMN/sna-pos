-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928143330, name '063_qr_guest_note_to_kitchen'. This is the SQL that actually ran.
-- The text previously in git under this number differed from what ran (see git history before the commit that added this header).

create or replace function public.accept_qr_order(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare q public.qr_orders%rowtype; v_order uuid; v_res jsonb; v_table text;
begin
  perform app.require_permission('order.create');
  perform app.require_feature('qr_ordering');
  select * into q from public.qr_orders where id = p_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That table order does not exist.'; end if;
  if q.status <> 'pending' then raise exception 'This table order was already %.', q.status; end if;
  if q.branch_id <> app.current_branch_id() then raise exception 'This order is for another outlet. Switch outlet first.'; end if;
  if q.guest_note is not null then
    q.items := jsonb_set(q.items, '{0,note}', to_jsonb(left(concat_ws(' · ', nullif(q.items->0->>'note', ''), 'Guest: ' || q.guest_note), 200)));
  end if;
  select o.id into v_order from public.orders o
   where o.dining_table_id = q.dining_table_id and o.restaurant_id = q.restaurant_id
     and o.payment_status in ('unpaid', 'partial') and o.status <> 'voided' and o.merged_into is null
   order by o.created_at desc limit 1;
  if v_order is not null then
    perform public.add_order_items(v_order, q.items);
    select bill_number into v_table from public.orders where id = v_order;
    v_res := jsonb_build_object('order_id', v_order, 'bill_number', v_table, 'added', true);
  else
    v_res := public.create_order(q.items, 'dine_in', q.dining_table_id, null, null, null, 0, null, null, null, null, null);
    v_order := (v_res->>'order_id')::uuid;
  end if;
  update public.qr_orders set status = 'accepted', order_id = v_order, decided_by = app.current_user_id(), decided_at = now() where id = p_id;
  perform app.audit('qr_order.accept', 'qr_orders', p_id, jsonb_build_object('order_id', v_order), null);
  return v_res;
end $$;
revoke all on function public.accept_qr_order(uuid) from public, anon;
grant execute on function public.accept_qr_order(uuid) to authenticated;
