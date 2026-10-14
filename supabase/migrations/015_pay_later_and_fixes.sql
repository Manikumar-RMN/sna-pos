-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260924165305, name 'sna_pos_15_pay_later_and_fixes'. This is the SQL that actually ran.

-- SNA POS migration 15: fixes found reviewing migrations 13-14.
--   1. pay_order: settle a bill that was saved unpaid (pay later / open tab).
--   2. create_order: discount allocation gives the rounding remainder to the
--      last line so line discounts always add up to the bill discount.
--   3. sales_report: marked VOLATILE (it creates a temp table, which a STABLE
--      plpgsql function is not allowed to do).
--   4. shift_figures: a closed shift reports the expected cash it was closed
--      against, not a figure recomputed after later voids.
--   5. void_order: voiding a cash bill from an already-closed shift records the
--      cash handed back as a cash-out in the currently open shift.

-- 1. pay_order ---------------------------------------------------------------
create or replace function public.pay_order(
  p_order_id uuid, p_payment_method_id uuid, p_tendered numeric default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user   uuid := app.require_permission('order.create');
  o        public.orders%rowtype;
  v_kind   text;
  v_change numeric(14,2) := 0;
  v_shift  uuid;
begin
  select * into o from public.orders
   where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' then raise exception 'Bill % is already paid.', o.bill_number; end if;

  select pm.kind into v_kind from public.payment_methods pm
   where pm.id = p_payment_method_id and pm.restaurant_id = o.restaurant_id and pm.is_active;
  if not found then raise exception 'That payment method is not available.'; end if;

  select id into v_shift from public.shifts
   where branch_id = o.branch_id and status = 'open' limit 1;
  if v_shift is null then raise exception 'Open a shift before taking payments.'; end if;

  if p_tendered is not null then
    if p_tendered < o.grand_total then
      raise exception 'Cash received (%) is less than the bill total (%).', p_tendered, o.grand_total;
    end if;
    v_change := p_tendered - o.grand_total;
  end if;

  insert into public.payments
    (id, restaurant_id, order_id, payment_method_id, amount, currency_code,
     tendered_amount, change_amount, status, received_by, client_created_at)
  values
    (gen_random_uuid(), o.restaurant_id, o.id, p_payment_method_id, o.grand_total,
     o.currency_code, p_tendered, v_change, 'captured', v_user, now());

  -- Money is counted in the shift that received it: if the bill's own shift
  -- has already been closed, the bill moves to the open one.
  update public.orders set
      paid_total = o.grand_total, payment_status = 'paid',
      shift_id = case when exists (select 1 from public.shifts s
                                   where s.id = o.shift_id and s.status = 'open')
                      then o.shift_id else v_shift end
   where id = o.id;

  perform app.audit('order.pay', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'amount', o.grand_total, 'method_kind', v_kind));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'change', v_change);
end $$;

revoke all on function public.pay_order(uuid, uuid, numeric) from public, anon;
grant execute on function public.pay_order(uuid, uuid, numeric) to authenticated;

-- 2. create_order: exact discount allocation ---------------------------------
create or replace function public.create_order(
    p_items jsonb, p_order_type text default 'dine_in', p_table_id uuid default null,
    p_customer_id uuid default null, p_payment_method_id uuid default null,
    p_tendered numeric default null, p_discount_amount numeric default 0,
    p_discount_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $function$
declare
    v_restaurant uuid := app.current_restaurant_id();
    v_user uuid; v_branch uuid; v_device uuid; v_prefix text; v_seq bigint; v_bill_no text;
    v_currency char(3); v_rounding text; v_auto_kot boolean; v_shift uuid;
    v_order_id uuid := gen_random_uuid(); v_kot_id uuid;
    v_item jsonb; v_product public.products%rowtype; v_line_id uuid; v_qty numeric(10,3);
    v_line_sub numeric(14,2); v_subtotal numeric(14,2) := 0; v_lines int := 0;
    v_discount numeric(14,2); v_tax_total numeric(14,2) := 0; v_line_disc numeric(14,2);
    v_line_net numeric(14,2); v_line_tax numeric(14,2); v_rate_id uuid; v_comp record;
    v_amt numeric(14,2); v_i int := 0; v_alloc numeric(14,2) := 0;
    v_before_round numeric(14,2); v_grand numeric(14,2); v_rounding_adj numeric(14,2);
    v_change numeric(14,2) := 0; v_method_kind text;
begin
    v_user := app.require_permission('order.create');

    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
        raise exception 'The order is empty.';
    end if;
    if jsonb_array_length(p_items) > 200 then raise exception 'Too many lines on one bill.'; end if;
    if coalesce(p_discount_amount,0) < 0 then raise exception 'A discount cannot be negative.'; end if;
    if coalesce(p_discount_amount,0) > 0 and not app.has_permission('order.discount') then
        raise exception 'A manager must approve a discount.';
    end if;

    v_branch := app.current_branch_id();
    if v_branch is null then raise exception 'No branch is set up for this restaurant.'; end if;

    select r.currency_code into v_currency from public.restaurants r where r.id = v_restaurant;
    select coalesce(bs.cash_rounding_mode,'none'), coalesce(bs.auto_print_kot, true)
      into v_rounding, v_auto_kot from public.branch_settings bs where bs.branch_id = v_branch;
    v_rounding := coalesce(v_rounding, 'none');
    v_auto_kot := coalesce(v_auto_kot, true);

    select s.id into v_shift from public.shifts s
      where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1;
    if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

    if p_payment_method_id is not null then
        select pm.kind into v_method_kind from public.payment_methods pm
          where pm.id = p_payment_method_id and pm.restaurant_id = v_restaurant and pm.is_active;
        if not found then raise exception 'That payment method is not available.'; end if;
    end if;
    if p_table_id is not null and not exists (
        select 1 from public.dining_tables t
        where t.id = p_table_id and t.restaurant_id = v_restaurant and t.is_active) then
        raise exception 'That table does not exist.';
    end if;
    if p_customer_id is not null and not exists (
        select 1 from public.customers c
        where c.id = p_customer_id and c.restaurant_id = v_restaurant and c.deleted_at is null) then
        raise exception 'That customer does not exist.';
    end if;

    select d.id, d.bill_prefix, d.next_bill_seq into v_device, v_prefix, v_seq
      from public.devices d where d.branch_id = v_branch and d.is_active
      order by d.created_at limit 1 for update;
    if v_device is null then raise exception 'No billing device is set up for this branch.'; end if;
    v_bill_no := (select b.code from public.branches b where b.id = v_branch)
                 || '-' || coalesce(v_prefix,'C1') || '-' || lpad(v_seq::text, 4, '0');
    update public.devices set next_bill_seq = next_bill_seq + 1 where id = v_device;

    insert into public.orders
      (id, restaurant_id, branch_id, device_id, bill_number, order_type, dining_table_id,
       customer_id, cashier_id, shift_id, currency_code, status, payment_status, client_created_at)
    values
      (v_order_id, v_restaurant, v_branch, v_device, v_bill_no, p_order_type, p_table_id,
       p_customer_id, v_user, v_shift, v_currency, 'open', 'unpaid', now());

    for v_item in select * from jsonb_array_elements(p_items) loop
      select * into v_product from public.products
        where id = (v_item->>'product_id')::uuid and restaurant_id = v_restaurant and deleted_at is null;
      if not found then raise exception 'A menu item on the order no longer exists.'; end if;
      if not v_product.is_available then raise exception '% is marked sold out.', v_product.name; end if;
      v_qty := coalesce((v_item->>'qty')::numeric, 1);
      if v_qty <= 0 then continue; end if;
      if v_qty > 999 then raise exception 'Quantity for % is too large.', v_product.name; end if;
      v_line_sub := round(v_product.price * v_qty, 2);
      v_subtotal := v_subtotal + v_line_sub;
      v_lines := v_lines + 1;
      insert into public.order_items
        (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity,
         line_subtotal, line_total, is_price_inclusive, kitchen_note)
      values
        (gen_random_uuid(), v_restaurant, v_order_id, v_product.id, v_product.name,
         v_product.price, v_qty, v_line_sub, v_line_sub, false, nullif(left(v_item->>'note', 200),''));
    end loop;
    if v_lines = 0 then raise exception 'The order is empty.'; end if;

    v_discount := least(coalesce(p_discount_amount,0), v_subtotal);

    -- Discount by value share; the last (largest) line takes the rounding
    -- remainder so the line discounts always add up to the bill discount.
    for v_line_id, v_line_sub in
      select id, line_subtotal from public.order_items where order_id = v_order_id
      order by line_subtotal, id
    loop
      v_i := v_i + 1;
      if v_i = v_lines then
        v_line_disc := v_discount - v_alloc;
      elsif v_subtotal > 0 then
        v_line_disc := round(v_discount * (v_line_sub / v_subtotal), 2);
      else
        v_line_disc := 0;
      end if;
      v_line_disc := greatest(0, least(v_line_disc, v_line_sub));
      v_alloc := v_alloc + v_line_disc;
      v_line_net := v_line_sub - v_line_disc;
      v_line_tax := 0;

      select tr.id into v_rate_id
      from public.order_items oi
      join public.products p on p.id = oi.product_id
      join public.tax_rates tr on tr.tax_group_id = p.tax_group_id
      where oi.id = v_line_id and tr.valid_from <= current_date
        and (tr.valid_to is null or tr.valid_to >= current_date)
      order by tr.valid_from desc limit 1;

      if v_rate_id is not null then
        for v_comp in
          select name, rate from public.tax_rate_components
          where tax_rate_id = v_rate_id and applies_when in ('always','intra_region')
          order by display_order
        loop
          v_amt := round(v_line_net * v_comp.rate / 100, 2);
          insert into public.order_item_taxes
            (restaurant_id, order_id, order_item_id, component_name, rate, taxable_amount, tax_amount)
          values (v_restaurant, v_order_id, v_line_id, v_comp.name, v_comp.rate, v_line_net, v_amt);
          v_line_tax := v_line_tax + v_amt;
        end loop;
      end if;

      update public.order_items
        set line_discount = v_line_disc, line_tax = v_line_tax, line_total = v_line_net + v_line_tax
      where id = v_line_id;
      v_tax_total := v_tax_total + v_line_tax;
    end loop;

    if v_discount > 0 then
      insert into public.order_discounts
        (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
      values (v_restaurant, v_order_id, 'fixed_amount', v_discount, v_discount,
              nullif(left(p_discount_reason, 200),''), v_user);
    end if;

    v_before_round := v_subtotal - v_discount + v_tax_total;
    v_grand := case v_rounding
                 when 'nearest_1'    then round(v_before_round, 0)
                 when 'nearest_0_05' then round(v_before_round / 0.05) * 0.05
                 when 'nearest_0_10' then round(v_before_round / 0.10) * 0.10
                 else v_before_round end;
    v_rounding_adj := v_grand - v_before_round;

    if p_payment_method_id is not null and v_grand > 0 then
      if p_tendered is not null then
        if p_tendered < v_grand then
          raise exception 'Cash received (%) is less than the bill total (%).', p_tendered, v_grand;
        end if;
        v_change := p_tendered - v_grand;
      end if;
      insert into public.payments
        (id, restaurant_id, order_id, payment_method_id, amount, currency_code,
         tendered_amount, change_amount, status, received_by, client_created_at)
      values
        (gen_random_uuid(), v_restaurant, v_order_id, p_payment_method_id, v_grand,
         v_currency, p_tendered, v_change, 'captured', v_user, now());
    end if;

    update public.orders set
        subtotal = v_subtotal, discount_total = v_discount, tax_total = v_tax_total,
        rounding_adjustment = v_rounding_adj, grand_total = v_grand,
        paid_total = case when p_payment_method_id is not null then v_grand else 0 end,
        status = 'completed',
        payment_status = case when p_payment_method_id is not null or v_grand = 0
                              then 'paid' else 'unpaid' end,
        synced_at = now()
    where id = v_order_id;

    if v_auto_kot then
      v_kot_id := gen_random_uuid();
      insert into public.kitchen_tickets
        (id, restaurant_id, branch_id, order_id, ticket_number, status, client_created_at)
      values (v_kot_id, v_restaurant, v_branch, v_order_id, 'K-' || v_bill_no, 'new', now());
      insert into public.kitchen_ticket_items
        (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note)
      select v_restaurant, v_kot_id, oi.id, oi.product_name, oi.quantity, oi.kitchen_note
        from public.order_items oi where oi.order_id = v_order_id order by oi.created_at;
    end if;

    perform app.audit('order.create', 'orders', v_order_id,
      jsonb_build_object('bill_number', v_bill_no, 'grand_total', v_grand, 'discount', v_discount));

    return jsonb_build_object(
      'order_id', v_order_id, 'bill_number', v_bill_no, 'subtotal', v_subtotal,
      'discount', v_discount, 'tax_total', v_tax_total, 'rounding', v_rounding_adj,
      'grand_total', v_grand, 'change', v_change,
      'paid', p_payment_method_id is not null or v_grand = 0);
end
$function$;

-- 3. sales_report writes a temp table, so it cannot be STABLE -----------------
alter function public.sales_report(date, date) volatile;

-- 4. shift_figures: closed shifts report the figure they were closed against --
create or replace function app.shift_figures(p_shift uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s public.shifts%rowtype;
  v_cash_sales numeric(14,2); v_cash_refunds numeric(14,2);
  v_in numeric(14,2); v_out numeric(14,2);
  v_bills int; v_sales numeric(14,2); v_voided int; v_unpaid int; v_methods jsonb;
begin
  select * into s from public.shifts where id = p_shift;
  if not found then return null; end if;

  select coalesce(sum(p.amount),0) into v_cash_sales
    from public.payments p
    join public.orders o on o.id = p.order_id
    join public.payment_methods pm on pm.id = p.payment_method_id
   where o.shift_id = s.id and o.status <> 'voided'
     and pm.affects_cash_drawer and p.status = 'captured';

  select coalesce(sum(r.amount),0) into v_cash_refunds
    from public.refunds r
    join public.payments p on p.id = r.payment_id
    join public.payment_methods pm on pm.id = p.payment_method_id
   where r.restaurant_id = s.restaurant_id and pm.affects_cash_drawer
     and r.created_at >= s.opened_at
     and (s.closed_at is null or r.created_at <= s.closed_at);

  select coalesce(sum(amount) filter (where direction='in'),0),
         coalesce(sum(amount) filter (where direction='out'),0)
    into v_in, v_out from public.cash_movements where shift_id = s.id;

  select count(*) filter (where status <> 'voided'),
         coalesce(sum(grand_total) filter (where status <> 'voided'),0),
         count(*) filter (where status = 'voided'),
         count(*) filter (where status <> 'voided' and payment_status = 'unpaid')
    into v_bills, v_sales, v_voided, v_unpaid
    from public.orders where shift_id = s.id;

  select coalesce(jsonb_agg(jsonb_build_object('method', m.name, 'bills', m.n, 'amount', m.amt)
                            order by m.amt desc), '[]'::jsonb)
    into v_methods
    from (select pm.name, count(*) n, sum(p.amount) amt
            from public.payments p
            join public.orders o on o.id = p.order_id
            join public.payment_methods pm on pm.id = p.payment_method_id
           where o.shift_id = s.id and o.status <> 'voided' and p.status = 'captured'
           group by pm.name) m;

  return jsonb_build_object(
    'shift_id', s.id, 'status', s.status, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
    'opened_by', (select full_name from public.users where id = s.opened_by),
    'closed_by', (select full_name from public.users where id = s.closed_by),
    'opening_float', s.opening_float,
    'bills', v_bills, 'sales', v_sales, 'voided', v_voided, 'unpaid', v_unpaid,
    'cash_sales', v_cash_sales, 'cash_refunds', v_cash_refunds,
    'cash_in', v_in, 'cash_out', v_out,
    'expected_cash', case when s.status = 'closed' and s.expected_cash is not null
                          then s.expected_cash
                          else s.opening_float + v_cash_sales - v_cash_refunds + v_in - v_out end,
    'counted_cash', s.counted_cash, 'variance', s.cash_variance, 'notes', s.notes,
    'by_method', v_methods);
end $$;
revoke all on function app.shift_figures(uuid) from public;

-- 5. void_order: cash handed back for a bill from a closed shift --------------
create or replace function public.void_order(p_order_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('order.void');
  o public.orders%rowtype;
  v_cash numeric(14,2);
  v_open uuid;
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
  if exists (select 1 from public.shifts where id = o.shift_id and status = 'closed') then
    select coalesce(sum(p.amount),0) into v_cash
      from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
     where p.order_id = o.id and p.status = 'captured' and pm.affects_cash_drawer;
    if v_cash > 0 then
      select id into v_open from public.shifts
       where branch_id = o.branch_id and status = 'open' limit 1;
      if v_open is not null then
        insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
        values (gen_random_uuid(), o.restaurant_id, v_open, 'out', v_cash,
                left('Cash returned for voided bill ' || o.bill_number, 200), v_user);
      end if;
    end if;
  end if;

  update public.orders set status = 'voided', voided_by = v_user, voided_at = now(),
         void_reason = left(trim(p_reason),300),
         payment_status = case when o.paid_total > 0 then 'refunded' else o.payment_status end
   where id = o.id;
  update public.payments set status = 'refunded' where order_id = o.id and status = 'captured';
  update public.kitchen_tickets set status = 'cancelled'
   where order_id = o.id and status in ('new','preparing');
  update public.kitchen_ticket_items set status = 'cancelled'
   where kitchen_ticket_id in (select id from public.kitchen_tickets where order_id = o.id)
     and status in ('new','preparing');

  perform app.audit('order.void', 'orders', o.id,
    jsonb_build_object('status','voided','reason', left(trim(p_reason),300)),
    jsonb_build_object('status', o.status, 'grand_total', o.grand_total));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'status', 'voided');
end $$;
revoke all on function public.void_order(uuid, text) from public, anon;
grant execute on function public.void_order(uuid, text) to authenticated;
