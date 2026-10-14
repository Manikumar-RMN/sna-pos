-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928094100, name '52_hold_and_fire_courses'. This is the SQL that actually ran.

alter table public.order_items add column held boolean not null default false;

do $$
declare d text;
begin
  -- Each line can be held ("next course"); held lines are not sent to the kitchen yet.
  d := pg_get_functiondef('app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb)'::regprocedure);
  d := replace(d, E'''qty'', v_qty, ''note'', nullif(left(coalesce(v_item->>''note'', ''''), 200), ''''),',
                  E'''qty'', v_qty, ''note'', nullif(left(coalesce(v_item->>''note'', ''''), 200), ''''), ''held'', coalesce((v_item->>''hold'')::boolean, false),');
  if position('''held''' in d) = 0 then raise exception 'patch bill_input failed'; end if;
  execute d;

  d := pg_get_functiondef('app.insert_order_lines(uuid,uuid,jsonb)'::regprocedure);
  d := replace(d, 'net_amount, service_charge, tax_included, tax_comps, options_text, created_at)', 'net_amount, service_charge, tax_included, tax_comps, options_text, created_at, held)');
  d := replace(d, 'nullif(s->>''options_text'', ''''), clock_timestamp());', 'nullif(s->>''options_text'', ''''), clock_timestamp(), coalesce((s->>''held'')::boolean, false));');
  if position('clock_timestamp(), coalesce' in d) = 0 then raise exception 'patch insert_order_lines failed'; end if;
  execute d;

  d := pg_get_functiondef('app.create_kitchen_ticket(uuid,uuid[])'::regprocedure);
  d := replace(d, E'     where oi.id = any(p_items)\n     group by 1 order by 1', E'     where oi.id = any(p_items) and not oi.held\n     group by 1 order by 1');
  d := replace(d, E'     where oi.id = any(p_items) and coalesce(nullif(trim(p.kitchen_station), ''''), ''Kitchen'') = st.station',
                  E'     where oi.id = any(p_items) and not oi.held and coalesce(nullif(trim(p.kitchen_station), ''''), ''Kitchen'') = st.station');
  if position('not oi.held and coalesce' in d) = 0 or position('any(p_items) and not oi.held' in d) = 0 then raise exception 'patch create_kitchen_ticket failed'; end if;
  execute d;
end $$;

create or replace function public.fire_held_items(p_order_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_user uuid := app.require_permission('order.create'); o public.orders%rowtype; v_ids uuid[];
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  update public.order_items set held = false where order_id = o.id and held and cancelled_at is null returning id into v_ids;
  select array_agg(id) into v_ids from public.order_items where order_id = o.id and id = any(
    select id from public.order_items where order_id = o.id) and not held and id not in (
    select order_item_id from public.kitchen_ticket_items kti join public.kitchen_tickets kt on kt.id = kti.kitchen_ticket_id where kt.order_id = o.id)
    and cancelled_at is null;
  if v_ids is null then raise exception 'Nothing is waiting to be sent to the kitchen.'; end if;
  perform app.create_kitchen_ticket(o.id, v_ids);
  perform app.audit('order.fire', 'orders', o.id, jsonb_build_object('bill_number', o.bill_number, 'items', coalesce(array_length(v_ids, 1), 0)));
  return jsonb_build_object('bill_number', o.bill_number, 'sent', coalesce(array_length(v_ids, 1), 0));
end $$;
revoke all on function public.fire_held_items(uuid) from public, anon;
grant execute on function public.fire_held_items(uuid) to authenticated;
