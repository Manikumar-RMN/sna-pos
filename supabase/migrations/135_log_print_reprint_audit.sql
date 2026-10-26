-- 135: bill and KOT print log; a reprint needs the "Reprint bills and KOTs" right (order.reprint) or a manager PIN
--
-- Before this, `order.reprint` existed but was enforced nowhere, and printing left no trace. Now the app calls
-- public.log_print() just before it prints:
--   * kind 'bill': the FIRST print of a bill is logged as `bill.print` and needs no special right.
--     Any later print of the same bill is a reprint: it needs order.reprint (or a manager PIN approval, the same
--     "right or approval" check as discounts - app.require_permission -> app.allowed) and is logged as `bill.reprint`.
--   * kind 'kot': the app only calls this for a REPRINT of a kitchen ticket (the normal first print goes through
--     claim_tickets_for_print and is not a reprint). It needs order.reprint (or a PIN) and logs `kot.reprint`
--     with the ticket numbers.
-- Nothing about money is touched: no order, payment or ticket row is changed. One audit row per call.
-- Stewards do NOT get order.reprint by default (founder decision): they ask a manager for a PIN.
-- Limits (by design): Ctrl+P / browser print and offline receipts cannot be logged.
--
-- p_is_reprint (optional, default null = the rule above): the app passes TRUE when it knows this bill was already printed
-- (for example a second press of Print on the same screen, or a print that the log never saw). TRUE always makes the call a
-- reprint, even when the log shows no earlier print, so a first copy that was never logged cannot make a real reprint look
-- original. FALSE or null never lets a call skip the reprint check when earlier prints exist.
--
-- Additive: one new function. Roll back:  drop function if exists public.log_print(text, uuid, uuid[], boolean);

-- the earlier 3-argument form (same batch, never released) is replaced by the 4-argument one
drop function if exists public.log_print(text, uuid, uuid[]);

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
