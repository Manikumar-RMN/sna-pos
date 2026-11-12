-- Follow-up to 240: the bill-level discount is also recorded in order_discounts. That record is shared between the two bills like the amount
-- (source keeps its part, the new bill gets a record for its part). Bills with item or category discounts are still refused.
do $mig$
declare
  d text := pg_get_functiondef('public.split_order(uuid,jsonb,uuid)'::regprocedure);
  d2 text;
begin
  d2 := regexp_replace(d, 'or exists \(select 1 from public\.order_discounts where order_id = o\.id\)', 'or exists (select 1 from public.order_items where order_id = o.id and cancelled_at is null and disc_kind is not null)');
  if d2 = d then raise exception 'split_order discount guard not found'; end if;
  d := d2;
  d2 := regexp_replace(d, 'to_jsonb\(v_d2\)\) where id = v_new;', $r$to_jsonb(v_d2)) where id = v_new;
      update public.order_discounts set amount = v_disc - v_d2, value = v_disc - v_d2 where order_id = o.id;
      if v_d2 > 0 then
        insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
        select restaurant_id, v_new, discount_type, v_d2, v_d2, reason, approved_by from public.order_discounts where order_id = o.id order by created_at limit 1;
      end if;$r$);
  if d2 = d then raise exception 'split_order discount update not found'; end if;
  execute d2;
end
$mig$;
