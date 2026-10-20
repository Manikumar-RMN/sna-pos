-- 120: Critical money fixes from QA round 1 (rebased on top of live migrations 112-118 made by another session).
--
-- 1. Voiding a bill now also gives back: the customer-account charge, the pre-order (open again, still holding its advance) and the batch stock. Gift-card money and loyalty points are already given back by live
--    migration 116 (trigger trg_return_on_void), so they are NOT done here a second time.
-- 2. A batch-tracked dish chosen inside a combo is taken from its batch.
-- 3. Brand settlement, chain report and credit notes (including a credit note onto a customer account) are corrected.

CREATE OR REPLACE FUNCTION public.void_order(p_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.void');
  o public.orders%rowtype;
  v_cash numeric(14,2);
  v_open uuid; v_acc record; v_gift record; v_po public.pre_orders; 
begin
  if coalesce(trim(p_reason),'') = '' then raise exception 'A reason is required to void a bill.'; end if;
  select * into o from public.orders
   where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is already voided.', o.bill_number; end if;
  if o.status <> 'completed' then raise exception 'Only a completed bill can be voided.'; end if;
  if exists (select 1 from public.refunds where order_id = o.id) then
    raise exception 'Bill % already has a refund, so it cannot also be voided.', o.bill_number;
  end if;

  -- If the bill's shift is already closed, its cash is no longer in that
  -- drawer's count: the money goes back out of today's drawer instead.
  -- Cash that was counted into a shift which has since closed is given back
  -- from the drawer that is open now, so it must be written down there. With
  -- no drawer open there is nowhere to record it, so the void waits.
  select coalesce(sum(p.amount),0) into v_cash
    from public.payments p
    join public.payment_methods pm on pm.id = p.payment_method_id
    join public.shifts s on s.id = coalesce(p.shift_id, o.shift_id)
   where p.order_id = o.id and p.status = 'captured' and pm.affects_cash_drawer and s.status = 'closed';
  if v_cash > 0 then
    select id into v_open from public.shifts
     where branch_id = o.branch_id and status = 'open' limit 1;
    if v_open is null then v_open := app.auto_shift(o.branch_id); end if;
    if v_open is null then
      raise exception 'Open a shift before voiding bill %. Its cash (%) has to come out of a drawer that is being counted.', o.bill_number, v_cash;
    end if;
    insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (gen_random_uuid(), o.restaurant_id, v_open, 'out', v_cash,
            left('Cash returned for voided bill ' || o.bill_number, 200), v_user);
  end if;

  update public.orders set status = 'voided', voided_by = v_user, voided_at = now(),
         void_reason = left(trim(p_reason),300),
         payment_status = case when o.paid_total > 0 then 'refunded' else o.payment_status end
   where id = o.id;
  update public.payments set status = 'refunded' where order_id = o.id and status = 'captured';

  -- Money that did not go through the drawer is given back where it came from.
  -- 1. A bill put on a customer account: the charge comes off the account.
  for v_acc in select customer_id, sum(amount) as net from public.customer_ledger
                where order_id = o.id and kind in ('charge', 'adjustment') group by customer_id having sum(amount) > 0 loop
    insert into public.customer_ledger (restaurant_id, customer_id, kind, amount, order_id, note, created_by)
    values (o.restaurant_id, v_acc.customer_id, 'adjustment', -v_acc.net, o.id, left('Bill ' || o.bill_number || ' voided', 200), v_user);
  end loop;
  -- 2. (Gift-card money and loyalty points go back through the trigger trg_return_on_void, live migration 116.)
  -- 3. A bill made from a pre-order: the pre-order is open again, its advance still held.
  select * into v_po from public.pre_orders where order_id = o.id and status = 'billed' for update;
  if found then
    -- (The advance the bill used was never taken off the pre-order's ledger, so it is held again by itself.)
    update public.pre_orders set status = 'booked', order_id = null, updated_at = now() where id = v_po.id;
  end if;
  -- 4. Batch-tracked dishes on the bill go back into their batches.
  for v_gift in select bm.batch_id, bm.order_item_id, -sum(bm.qty) as taken from public.batch_movements bm
                  join public.order_items oi on oi.id = bm.order_item_id
                 where oi.order_id = o.id group by bm.batch_id, bm.order_item_id having sum(bm.qty) < 0 loop
    update public.product_batches set qty_left = qty_left + v_gift.taken where id = v_gift.batch_id;
    insert into public.batch_movements (restaurant_id, batch_id, order_item_id, qty) values (o.restaurant_id, v_gift.batch_id, v_gift.order_item_id, v_gift.taken);
  end loop;
  -- Cancel only this bill's own lines in the kitchen. After a split, a kitchen
  -- ticket can carry lines that now belong to another bill; those stay.
  update public.kitchen_ticket_items k set status = 'cancelled'
   where k.order_item_id in (select oi.id from public.order_items oi where oi.order_id = o.id)
     and k.status in ('new','preparing');
  update public.kitchen_tickets kt set status = 'cancelled'
   where kt.restaurant_id = o.restaurant_id and kt.status in ('new','preparing')
     and (kt.order_id = o.id
          or exists (select 1 from public.kitchen_ticket_items k join public.order_items oi on oi.id = k.order_item_id
                      where k.kitchen_ticket_id = kt.id and oi.order_id = o.id))
     and not exists (select 1 from public.kitchen_ticket_items k2
                      where k2.kitchen_ticket_id = kt.id and k2.status <> 'cancelled');

  perform app.audit('order.void', 'orders', o.id,
    jsonb_build_object('status','voided','reason', left(trim(p_reason),300)),
    jsonb_build_object('status', o.status, 'grand_total', o.grand_total));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'status', 'voided');
end $function$;

-- A batch-tracked dish chosen inside a combo comes out of its batches (oldest first), like a dish sold on its own.
create or replace function app.batch_on_item_option()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare it public.order_items; v_pid uuid; v_branch uuid; v_need numeric; b record; v_take numeric;
begin
  if new.modifier_item_id is null then return new; end if;
  select product_id into v_pid from public.modifier_items where id = new.modifier_item_id;
  if v_pid is null or not exists (select 1 from public.products where id = v_pid and track_batches) then return new; end if;
  select * into it from public.order_items where id = new.order_item_id;
  if it.cancelled_at is not null then return new; end if;
  v_need := it.quantity - coalesce(it.cancelled_qty, 0);
  select branch_id into v_branch from public.orders where id = it.order_id;
  for b in select id, qty_left from public.product_batches
            where branch_id = v_branch and product_id = v_pid and qty_left > 0 and expires_on >= app.local_today(it.restaurant_id)
            order by expires_on, made_on, created_at for update loop
    exit when v_need <= 0;
    v_take := least(v_need, b.qty_left);
    update public.product_batches set qty_left = qty_left - v_take where id = b.id;
    insert into public.batch_movements (restaurant_id, batch_id, order_item_id, qty) values (it.restaurant_id, b.id, it.id, -v_take);
    v_need := v_need - v_take;
  end loop;
  return new;
end $function$;
drop trigger if exists trg_batch_on_item_option on public.order_item_modifiers;
create trigger trg_batch_on_item_option after insert on public.order_item_modifiers
  for each row execute function app.batch_on_item_option();

-- Liquor cannot be a choice inside a food combo.
CREATE OR REPLACE FUNCTION app.trg_modifier_item_dish()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare p public.products;
begin
  if new.product_id is null then return new; end if;
  select * into p from public.products where id = new.product_id;
  if p.is_combo then raise exception 'A combo cannot be a choice inside another combo.'; end if;
  if p.is_charge then raise exception 'The packing charge cannot be a choice.'; end if;
  -- Liquor goes on its own liquor bill, so it cannot ride along inside a food combo on a GST bill.
  if exists (select 1 from public.tax_groups tg where tg.id = p.tax_group_id and tg.separate_bill) then
    raise exception '% is liquor and goes on a separate liquor bill, so it cannot be a choice inside a combo.', p.name;
  end if;
  if exists (select 1 from public.products s where s.parent_id = p.id and s.deleted_at is null) then
    raise exception '% is sold in sizes. Choose one of its sizes instead.', p.name;
  end if;
  return new;
end $function$;

-- Brand settlement: tax of price-inclusive dishes counted once; credit notes come off.
CREATE OR REPLACE FUNCTION public.brand_settlement(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end := (p_to + 1)::timestamp at time zone v_tz;
  return jsonb_build_object('from', p_from, 'to', p_to, 'brands', coalesce((
    select jsonb_agg(jsonb_build_object('brand_id', x.brand_id, 'brand', coalesce(b.name, 'No brand'), 'gstin', b.gstin,
             'bills', x.bills, 'qty', x.qty, 'sales', x.sales, 'tax', x.tax, 'billed', x.sales + x.tax,
             'commission_percent', coalesce(b.commission_percent, 0),
             'commission', round(x.sales * coalesce(b.commission_percent, 0) / 100, 2),
             'payable', x.sales + x.tax - round(x.sales * coalesce(b.commission_percent, 0) / 100, 2))
           order by b.display_order nulls last, b.name)
      from (select z.brand_id, count(distinct z.order_id) filter (where z.qty is not null) bills, sum(z.qty) qty,
                   round(sum(z.net), 2) sales, round(sum(z.tax), 2) tax
              from (
                -- every sold line: sales without tax, and its tax (line_tax already holds the tax of price-inclusive lines)
                select oi.brand_id, o.id order_id, oi.quantity qty, oi.net_amount net, oi.line_tax tax
                  from public.order_items oi join public.orders o on o.id = oi.order_id
                 where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.created_at >= v_start and o.created_at < v_end
                   and o.status = 'completed' and o.merged_into is null and o.comp_kind is null and oi.cancelled_at is null
                   and not exists (select 1 from public.products p where p.id = oi.product_id and p.is_charge)
                union all
                -- credit notes in the period come off, shared between the brands of the bill by their sales
                select oi.brand_id, o.id, null, -(cn.amount - cn.tax_amount) * oi.net_amount / nullif(t.net, 0),
                       -cn.tax_amount * oi.net_amount / nullif(t.net, 0)
                  from public.credit_notes cn
                  join public.orders o on o.id = cn.order_id
                  join public.order_items oi on oi.order_id = o.id and oi.cancelled_at is null
                  join (select oi2.order_id, sum(oi2.net_amount) net from public.order_items oi2
                         where oi2.cancelled_at is null
                           and not exists (select 1 from public.products p2 where p2.id = oi2.product_id and p2.is_charge)
                         group by oi2.order_id) t on t.order_id = o.id
                 where cn.restaurant_id = v_rest and app.in_scope(o.branch_id) and cn.created_at >= v_start and cn.created_at < v_end
                   and not exists (select 1 from public.products p where p.id = oi.product_id and p.is_charge)
              ) z
             group by z.brand_id) x
      left join public.brands b on b.id = x.brand_id), '[]'::jsonb));
end $function$;

-- Chain report: royalty is on sales without tax; credit notes come off.
CREATE OR REPLACE FUNCTION public.chain_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_rows jsonb;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end := (p_to + 1)::timestamp at time zone v_tz;
  select coalesce(jsonb_agg(jsonb_build_object('branch_id', b.id, 'outlet', b.name, 'code', b.code, 'region', coalesce(b.region, 'No region'),
           'royalty_percent', b.royalty_percent, 'bills', coalesce(x.bills, 0), 'sales', coalesce(x.sales, 0), 'tax', coalesce(x.tax, 0),
           'total', coalesce(x.total, 0), 'average_bill', case when coalesce(x.bills, 0) > 0 then round(x.total / x.bills, 2) else 0 end,
           'royalty', round(coalesce(x.sales, 0) * b.royalty_percent / 100, 2))
         order by coalesce(b.region, 'zzz'), b.name), '[]'::jsonb) into v_rows
    from public.branches b
    left join (select y.branch_id, count(*) filter (where y.is_bill) bills, round(sum(y.sales), 2) sales, round(sum(y.tax), 2) tax, round(sum(y.total), 2) total
                 from (
                   -- sales without tax (a price-inclusive dish carries its tax inside the subtotal)
                   select o.branch_id, true is_bill, o.subtotal - o.discount_total - o.tax_included sales, o.tax_total tax, o.grand_total total
                     from public.orders o
                    where o.restaurant_id = v_rest and o.created_at >= v_start and o.created_at < v_end
                      and o.status = 'completed' and o.merged_into is null and o.comp_kind is null
                   union all
                   -- credit notes in the period come off
                   select cn.branch_id, false, -(cn.amount - cn.tax_amount), -cn.tax_amount, -cn.amount
                     from public.credit_notes cn
                    where cn.restaurant_id = v_rest and cn.created_at >= v_start and cn.created_at < v_end
                 ) y
                group by y.branch_id) x on x.branch_id = b.id
   where b.restaurant_id = v_rest and b.deleted_at is null and app.in_scope(b.id);
  return jsonb_build_object('from', p_from, 'to', p_to, 'outlets', v_rows,
    'regions', coalesce((select jsonb_agg(jsonb_build_object('region', g.region, 'outlets', g.n, 'bills', g.bills, 'sales', g.sales, 'total', g.total, 'royalty', g.royalty) order by g.region)
                           from (select r->>'region' region, count(*) n, sum((r->>'bills')::int) bills, sum((r->>'sales')::numeric) sales,
                                        sum((r->>'total')::numeric) total, sum((r->>'royalty')::numeric) royalty
                                   from jsonb_array_elements(v_rows) r group by r->>'region') g), '[]'::jsonb));
end $function$;

-- Credit note: a full refund reverses all of the GST, even when cash rounding made the payment a few paise less.
-- A bill charged to a customer account can be credited back to the account.
CREATE OR REPLACE FUNCTION public.issue_credit_note(p_order_id uuid, p_amount numeric, p_method_id uuid, p_reason text, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid;
  o public.orders%rowtype; v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_done numeric(14,2); v_left numeric(14,2); v_country text; v_day public.business_days; v_shift uuid;
  v_kind text; v_ratio numeric; v_tax numeric(14,2); v_taxes jsonb; v_no text; v_seq int; v_fy text; v_code text;
  v_id uuid := gen_random_uuid(); v_deadline date;
  v_seen record; v_out jsonb; v_acc_cust uuid; v_acc_net numeric;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen
      from public.request_refs rr where rr.restaurant_id = app.current_restaurant_id() and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'credit_note' or v_seen.order_id is distinct from p_order_id then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  v_user := app.require_permission('order.refund');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for the credit note.'; end if;
  if v_amount <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status <> 'completed' or o.merged_into is not null then raise exception 'Only a completed bill can get a credit note.'; end if;
  if o.payment_status in ('unpaid', 'partial') then
    raise exception 'Bill % is not fully paid. Cancel items or void it instead.', o.bill_number;
  end if;
  select coalesce(sum(amount), 0) into v_done from public.refunds where order_id = o.id;
  v_left := o.paid_total - v_done;
  if v_left <= 0 then raise exception 'Bill % has already been fully refunded.', o.bill_number; end if;
  if v_amount > v_left then raise exception 'The most that can be refunded on bill % is %.', o.bill_number, v_left; end if;

  select country_code into v_country from public.restaurants where id = o.restaurant_id;
  v_day := app.open_business_day(o.branch_id);
  if v_country = 'IN' then
    v_deadline := make_date(case when extract(month from o.business_date) >= 4 then extract(year from o.business_date)::int + 1
                                 else extract(year from o.business_date)::int end, 11, 30);
    if v_day.business_date > v_deadline then
      raise exception 'Under GST rules a credit note for bill % could only be issued until %.', o.bill_number, to_char(v_deadline, 'DD Mon YYYY');
    end if;
  end if;

  -- The hidden "Customer account" method is allowed: the credit note then reduces what the customer owes.
  select pm.kind into v_kind from public.payment_methods pm where pm.id = p_method_id and pm.restaurant_id = o.restaurant_id and (pm.is_active or pm.kind = 'account');
  if not found then raise exception 'Choose how the money is given back.'; end if;
  if v_kind in ('gift_card', 'loyalty', 'advance') then raise exception 'Money cannot be given back to a gift card, points or an advance. Choose cash, UPI, card or another payment mode.'; end if;
  if v_kind = 'account' then
    select customer_id, sum(amount) into v_acc_cust, v_acc_net from public.customer_ledger
     where order_id = o.id and kind in ('charge', 'adjustment') group by customer_id having sum(amount) > 0 limit 1;
    if v_acc_cust is null then raise exception 'Bill % was not charged to a customer account.', o.bill_number; end if;
    if v_amount > v_acc_net then raise exception 'Only % of bill % is still on the customer account.', v_acc_net, o.bill_number; end if;
  end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_kind = 'cash' and v_shift is null then raise exception 'Open a shift before giving cash back.'; end if;

  -- Share of the bill being refunded. It is worked out on what was actually paid (cash rounding can make that a few
  -- paise less than the bill total). Giving back everything that is left reverses exactly the GST that is left.
  v_ratio := case when o.paid_total > 0 then v_amount / o.paid_total else 0 end;
  select coalesce(jsonb_agg(jsonb_build_object('name', c, 'rate', r, 'amount', t) order by r, c), '[]'::jsonb),
         coalesce(sum(t), 0)
    into v_taxes, v_tax
    from (select x.c, x.r,
                 case when v_amount >= v_left then greatest(x.a - coalesce(pv.done, 0), 0) else round(x.a * v_ratio, 2) end t
            from (select component_name c, rate r, sum(tax_amount) a from public.order_item_taxes where order_id = o.id group by 1, 2) x
            left join (select e->>'name' c, (e->>'rate')::numeric r, sum((e->>'amount')::numeric) done
                         from public.credit_notes cn2, jsonb_array_elements(cn2.taxes) e
                        where cn2.order_id = o.id group by 1, 2) pv on pv.c = x.c and pv.r = x.r) y;

  perform pg_advisory_xact_lock(hashtext('credit_note:' || o.branch_id::text));
  v_fy := app.fy_label(v_country, v_day.business_date);
  if v_country = 'IN' then v_fy := substr(v_fy, 3, 2) || substr(v_fy, 6, 2); end if;  -- 2026-27 -> 2627 (GST: max 16 characters)
  select code into v_code from public.branches where id = o.branch_id;
  select count(*) + 1 into v_seq from public.credit_notes
   where branch_id = o.branch_id and number like 'CN-' || v_code || '-' || v_fy || '-%';
  v_no := 'CN-' || v_code || '-' || v_fy || '-' || lpad(v_seq::text, 4, '0');

  insert into public.credit_notes (id, restaurant_id, branch_id, order_id, number, business_date, shift_id, amount,
                                   tax_amount, taxes, reason, payment_method_id, created_by)
  values (v_id, o.restaurant_id, o.branch_id, o.id, v_no, v_day.business_date, v_shift, v_amount, v_tax, v_taxes,
          left(trim(p_reason), 300), p_method_id, v_user);
  insert into public.refunds (id, restaurant_id, order_id, payment_id, amount, reason, approved_by, client_created_at,
                              shift_id, payment_method_id, credit_note_id)
  values (gen_random_uuid(), o.restaurant_id, o.id, null, v_amount, left(trim(p_reason), 300), v_user, now(),
          v_shift, p_method_id, v_id);

  if v_kind = 'account' then
    insert into public.customer_ledger (restaurant_id, customer_id, kind, amount, order_id, shift_id, note, created_by)
    values (o.restaurant_id, v_acc_cust, 'adjustment', -v_amount, o.id, v_shift, left('Credit note ' || v_no, 200), v_user);
  end if;
  perform set_config('app.day_ok', 'on', true);
  update public.orders set payment_status = case when v_done + v_amount >= o.paid_total then 'refunded' else 'partially_refunded' end
   where id = o.id;
  perform set_config('app.day_ok', 'off', true);

  perform app.audit('credit_note.issue', 'credit_notes', v_id,
    jsonb_build_object('number', v_no, 'bill_number', o.bill_number, 'amount', v_amount, 'tax', v_tax,
                       'method_kind', v_kind, 'reason', left(trim(p_reason), 300)));
  v_out := jsonb_build_object('credit_note_id', v_id, 'number', v_no, 'amount', v_amount, 'tax', v_tax,
                            'remaining', v_left - v_amount);
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result)
    values (app.current_restaurant_id(), p_client_ref, 'credit_note', p_order_id, v_out);
    -- Request ids only matter for a retry within minutes; old ones are cleared as new ones arrive.
    delete from public.request_refs
     where restaurant_id = app.current_restaurant_id() and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $function$;
