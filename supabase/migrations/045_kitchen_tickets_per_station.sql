-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928092352, name '45_kitchen_tickets_per_station'. This is the SQL that actually ran.

-- One kitchen ticket per station (Kitchen, Bar, Tandoor…) so each station prints / sees only its own items.
create or replace function app.create_kitchen_ticket(p_order uuid, p_items uuid[]) returns uuid
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare o public.orders%rowtype; v_n int; v_id uuid; v_first uuid; st record;
begin
  select * into o from public.orders where id = p_order;
  for st in
    select coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen') as station
      from public.order_items oi left join public.products p on p.id = oi.product_id
     where oi.id = any(p_items)
     group by 1 order by 1
  loop
    v_id := gen_random_uuid();
    select count(*) + 1 into v_n from public.kitchen_tickets where order_id = p_order;
    insert into public.kitchen_tickets (id, restaurant_id, branch_id, order_id, ticket_number, station, status, client_created_at)
    values (v_id, o.restaurant_id, o.branch_id, o.id,
            'K-' || o.bill_number || case when v_n > 1 then '-' || v_n else '' end, st.station, 'new', now());
    insert into public.kitchen_ticket_items (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note)
    select o.restaurant_id, v_id, oi.id,
           oi.product_name || coalesce(' (' || oi.options_text || ')', ''), oi.quantity, oi.kitchen_note
      from public.order_items oi left join public.products p on p.id = oi.product_id
     where oi.id = any(p_items) and coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen') = st.station
     order by oi.created_at, oi.id;
    v_first := coalesce(v_first, v_id);
  end loop;
  return v_first;
end $$;

-- A kitchen printer marks the tickets it printed, so another device does not print them again.
create or replace function public.mark_tickets_printed(p_ids uuid[]) returns int
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare n int;
begin
  if app.current_user_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  update public.kitchen_tickets set printed_at = coalesce(printed_at, now())
   where id = any(p_ids) and restaurant_id = app.current_restaurant_id();
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.mark_tickets_printed(uuid[]) from public, anon;
grant execute on function public.mark_tickets_printed(uuid[]) to authenticated;

alter table public.products add constraint products_station_len check (kitchen_station is null or length(kitchen_station) <= 30);
