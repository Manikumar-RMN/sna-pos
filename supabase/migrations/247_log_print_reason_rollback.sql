drop function if exists public.log_print(text, uuid, uuid[], boolean, text);

create or replace function public.log_print(p_kind text, p_order uuid, p_ticket_ids uuid[] default null, p_is_reprint boolean default null)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  o public.orders%rowtype;
  v_prior int;
  v_nums text[];
  v_found int;
  v_ids uuid[];
begin
  if app.current_restaurant_id() is null or app.current_user_id() is null then
    raise exception 'You are not signed in to a restaurant.';
  end if;
  if p_kind is null or p_kind not in ('bill', 'kot') then raise exception 'Print kind must be bill or kot.'; end if;
  -- the row lock makes two devices printing the same bill at the same moment count one after the other
  select * into o from public.orders
   where id = p_order and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Bill not found.'; end if;

  if p_kind = 'bill' then
    -- copies so far: the number of logged prints, or the highest copy number written (a declared reprint writes #2 on its own)
    select greatest(count(*), coalesce(max((new_value ->> 'print_no')::int), 0)) into v_prior from public.audit_logs
     where restaurant_id = o.restaurant_id and entity_type = 'orders' and entity_id = o.id and action in ('bill.print', 'bill.reprint');
    if v_prior = 0 and coalesce(p_is_reprint, false) = false then
      perform app.audit('bill.print', 'orders', o.id, jsonb_build_object('bill_number', o.bill_number, 'print_no', 1));
      return jsonb_build_object('kind', 'bill', 'action', 'bill.print', 'reprint', false, 'print_no', 1);
    end if;
    perform app.require_permission('order.reprint');
    -- a declared reprint with no logged print: the original copy was never logged, so this is at least copy number 2
    v_prior := greatest(v_prior, 1);
    perform app.audit('bill.reprint', 'orders', o.id,
      jsonb_build_object('bill_number', o.bill_number, 'print_no', v_prior + 1), jsonb_build_object('prints_before', v_prior, 'declared_reprint', coalesce(p_is_reprint, false)));
    return jsonb_build_object('kind', 'bill', 'action', 'bill.reprint', 'reprint', true, 'print_no', v_prior + 1);
  end if;

  -- kot: always a reprint
  if p_ticket_ids is not null and coalesce(array_length(p_ticket_ids, 1), 0) > 0 then
    select count(*), array_agg(kt.ticket_number order by kt.created_at), array_agg(kt.id order by kt.created_at)
      into v_found, v_nums, v_ids
      from public.kitchen_tickets kt where kt.order_id = o.id and kt.id = any(p_ticket_ids);
    if v_found <> (select count(distinct x) from unnest(p_ticket_ids) x) then
      raise exception 'A kitchen ticket in the list does not belong to this bill.';
    end if;
  else
    select array_agg(kt.ticket_number order by kt.created_at), array_agg(kt.id order by kt.created_at)
      into v_nums, v_ids from public.kitchen_tickets kt where kt.order_id = o.id;
  end if;
  if v_ids is null then raise exception 'This bill has no kitchen ticket to reprint.'; end if;
  perform app.require_permission('order.reprint');
  perform app.audit('kot.reprint', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'tickets', to_jsonb(v_nums), 'ticket_ids', to_jsonb(v_ids)));
  return jsonb_build_object('kind', 'kot', 'action', 'kot.reprint', 'reprint', true, 'tickets', to_jsonb(v_nums));
end $$;
revoke all on function public.log_print(text, uuid, uuid[], boolean) from public, anon;
grant execute on function public.log_print(text, uuid, uuid[], boolean) to authenticated;
