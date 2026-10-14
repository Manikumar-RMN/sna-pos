-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928094110, name '53_fire_held_items_fix'. This is the SQL that actually ran.

create or replace function public.fire_held_items(p_order_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_user uuid := app.require_permission('order.create'); o public.orders%rowtype; v_ids uuid[];
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  with upd as (
    update public.order_items set held = false
     where order_id = o.id and held and cancelled_at is null
    returning id)
  select array_agg(id) into v_ids from upd;
  if v_ids is null then raise exception 'Nothing is waiting to be sent to the kitchen.'; end if;
  perform app.create_kitchen_ticket(o.id, v_ids);
  perform app.audit('order.fire', 'orders', o.id, jsonb_build_object('bill_number', o.bill_number, 'items', array_length(v_ids, 1)));
  return jsonb_build_object('bill_number', o.bill_number, 'sent', array_length(v_ids, 1));
end $$;
