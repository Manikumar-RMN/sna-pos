-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260924095728, name 'sna_pos_13_billing_v2_shifts_void_refund'. This is the SQL that actually ran.

-- SNA POS migration 13: billing v2, shifts / day close, cash movements,
-- void and refund. All are SECURITY DEFINER functions: the tables they write
-- are read-only to signed-in users since migration 12, so these functions are
-- the only way money records change. Each one checks the caller's permission,
-- scopes every read and write to the caller's restaurant, and writes the audit
-- log.

-- ===========================================================================
-- create_order v2
--   * runs as definer (orders tables are no longer directly writable)
--   * refuses payment methods / tables / customers from another restaurant
--   * requires an open shift and links the bill to it
--   * refuses under-tendered cash
--   * raises a kitchen ticket (KOT) for the order
-- ===========================================================================
create or replace function public.create_order(
    p_items jsonb,
    p_order_type text default 'dine_in',
    p_table_id uuid default null,
    p_customer_id uuid default null,
    p_payment_method_id uuid default null,
    p_tendered numeric default null,
    p_discount_amount numeric default 0,
    p_discount_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_restaurant uuid := app.current_restaurant_id();
    v_user       uuid;
    v_branch     uuid;
    v_device     uuid;
    v_prefix     text;
    v_seq        bigint;
    v_bill_no    text;
    v_currency   char(3);
    v_rounding   text;
    v_auto_kot   boolean;
    v_shift      uuid;
    v_order_id   uuid := gen_random_uuid();
    v_kot_id     uuid;

    v_item        jsonb;
    v_product     public.products%rowtype;
    v_line_id     uuid;
    v_qty         numeric(10,3);
    v_line_sub    numeric(14,2);
    v_subtotal    numeric(14,2) := 0;
    v_lines       int := 0;
    v_discount    numeric(14,2);
    v_tax_total   numeric(14,2) := 0;
    v_line_disc   numeric(14,2);
    v_line_net    numeric(14,2);
    v_line_tax    numeric(14,2);
    v_rate_id     uuid;
    v_comp        record;
    v_before_round numeric(14,2);
    v_grand       numeric(14,2);
    v_rounding_adj numeric(14,2);
    v_change      numeric(14,2) := 0;
    v_method_kind text;
begin
    v_user := app.require_permission('order.create');

    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
        raise exception 'The order is empty.';
    end if;
    if coalesce(p_discount_amount,0) < 0 then
        raise exception 'A discount cannot be negative.';
    end if;
    if coalesce(p_discount_amount,0) > 0 and not app.has_permission('order.discount') then
        raise exception 'A manager must approve a discount.';
    end if;

    v_branch := app.current_branch_id();
    if v_branch is null then
        raise exception 'No branch is set up for this restaurant.';
    end if;

    select r.currency_code into v_currency from public.restaurants r where r.id = v_restaurant;
    select coalesce(bs.cash_rounding_mode,'none'), coalesce(bs.auto_print_kot, true)
      into v_rounding, v_auto_kot
      from public.branch_settings bs where bs.branch_id = v_branch;
    v_rounding := coalesce(v_rounding, 'none');
    v_auto_kot := coalesce(v_auto_kot, true);

    -- Every bill belongs to an open shift, so the day can be closed and the
    -- drawer counted against it.
    select s.id into v_shift from public.shifts s
      where s.branch_id = v_branch and s.status = 'open'
      order by s.opened_at desc limit 1;
    if v_shift is null then
        raise exception 'Open a shift before taking bills.';
    end if;

    -- Anything referenced by id must belong to this restaurant.
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

    -- Take the next bill number, locking the device row so two concurrent
    -- bills can never share a number.
    select d.id, d.bill_prefix, d.next_bill_seq into v_device, v_prefix, v_seq
      from public.devices d
      where d.branch_id = v_branch and d.is_active
      order by d.created_at limit 1
      for update;
    if v_device is null then
        raise exception 'No billing device is set up for this branch.';
    end if;
    v_bill_no := (select b.code from public.branches b where b.id = v_branch)
                 || '-' || coalesce(v_prefix,'C1') || '-' || lpad(v_seq::text, 4, '0');
    update public.devices set next_bill_seq = next_bill_seq + 1 where id = v_device;

    insert into public.orders
      (id, restaurant_id, branch_id, device_id, bill_number, order_type,
       dining_table_id, customer_id, cashier_id, shift_id, currency_code,
       status, payment_status, client_created_at)
    values
      (v_order_id, v_restaurant, v_branch, v_device, v_bill_no, p_order_type,
       p_table_id, p_customer_id, v_user, v_shift, v_currency,
       'open', 'unpaid', now());

    -- Line items. Prices come from the database, never from the caller.
    for v_item in select * from jsonb_array_elements(p_items)
    loop
      select * into v_product from public.products
        where id = (v_item->>'product_id')::uuid
          and restaurant_id = v_restaurant and deleted_at is null;
      if not found then
        raise exception 'A menu item on the order no longer exists.';
      end if;
      if not v_product.is_available then
        raise exception '% is marked sold out.', v_product.name;
      end if;
      v_qty := coalesce((v_item->>'qty')::numeric, 1);
      if v_qty <= 0 then continue; end if;
      if v_qty > 999 then raise exception 'Quantity for % is too large.', v_product.name; end if;

      v_line_sub := round(v_product.price * v_qty, 2);
      v_subtotal := v_subtotal + v_line_sub;
      v_lines    := v_lines + 1;
      v_line_id  := gen_random_uuid();

      insert into public.order_items
        (id, restaurant_id, order_id, product_id, product_name, unit_price,
         quantity, line_subtotal, line_total, is_price_inclusive, kitchen_note)
      values
        (v_line_id, v_restaurant, v_order_id, v_product.id, v_product.name,
         v_product.price, v_qty, v_line_sub, v_line_sub, false,
         nullif(left(v_item->>'note', 200),''));
    end loop;

    if v_lines = 0 then
      raise exception 'The order is empty.';
    end if;

    v_discount := least(coalesce(p_discount_amount,0), v_subtotal);

    -- Allocate the discount across lines by value, then compute and freeze
    -- each tax component on the discounted line value.
    for v_line_id, v_line_sub in
      select id, line_subtotal from public.order_items where order_id = v_order_id
    loop
      v_line_disc := case when v_subtotal > 0
                          then round(v_discount * (v_line_sub / v_subtotal), 2)
                          else 0 end;
      v_line_net  := v_line_sub - v_line_disc;
      v_line_tax  := 0;

      select tr.id into v_rate_id
      from public.order_items oi
      join public.products p on p.id = oi.product_id
      join public.tax_rates tr on tr.tax_group_id = p.tax_group_id
      where oi.id = v_line_id
        and tr.valid_from <= current_date
        and (tr.valid_to is null or tr.valid_to >= current_date)
      order by tr.valid_from desc
      limit 1;

      if v_rate_id is not null then
        for v_comp in
          select name, rate from public.tax_rate_components
          where tax_rate_id = v_rate_id and applies_when in ('always','intra_region')
          order by display_order
        loop
          declare v_amt numeric(14,2) := round(v_line_net * v_comp.rate / 100, 2);
          begin
            insert into public.order_item_taxes
              (restaurant_id, order_id, order_item_id, component_name, rate,
               taxable_amount, tax_amount)
            values
              (v_restaurant, v_order_id, v_line_id, v_comp.name, v_comp.rate,
               v_line_net, v_amt);
            v_line_tax := v_line_tax + v_amt;
          end;
        end loop;
      end if;

      update public.order_items
        set line_discount = v_line_disc, line_tax = v_line_tax,
            line_total = v_line_net + v_line_tax
      where id = v_line_id;

      v_tax_total := v_tax_total + v_line_tax;
    end loop;

    if v_discount > 0 then
      insert into public.order_discounts
        (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
      values
        (v_restaurant, v_order_id, 'fixed_amount', v_discount, v_discount,
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

    -- Kitchen order ticket.
    if v_auto_kot then
      v_kot_id := gen_random_uuid();
      insert into public.kitchen_tickets
        (id, restaurant_id, branch_id, order_id, ticket_number, status, client_created_at)
      values
        (v_kot_id, v_restaurant, v_branch, v_order_id, 'K-' || v_bill_no, 'new', now());
      insert into public.kitchen_ticket_items
        (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note)
      select v_restaurant, v_kot_id, oi.id, oi.product_name, oi.quantity, oi.kitchen_note
        from public.order_items oi where oi.order_id = v_order_id
        order by oi.created_at;
    end if;

    perform app.audit('order.create', 'orders', v_order_id,
      jsonb_build_object('bill_number', v_bill_no, 'grand_total', v_grand,
                         'discount', v_discount));

    return jsonb_build_object(
      'order_id', v_order_id, 'bill_number', v_bill_no,
      'subtotal', v_subtotal, 'discount', v_discount, 'tax_total', v_tax_total,
      'rounding', v_rounding_adj, 'grand_total', v_grand, 'change', v_change);
end
$function$;

-- ===========================================================================
-- Shift figures (internal). Expected cash in the drawer =
--   opening float + cash taken on live bills - cash refunded + cash in - cash out
-- ===========================================================================
create or replace function app.shift_figures(p_shift uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  s public.shifts%rowtype;
  v_cash_sales numeric(14,2);
  v_cash_refunds numeric(14,2);
  v_in numeric(14,2);
  v_out numeric(14,2);
  v_bills int;
  v_sales numeric(14,2);
  v_voided int;
  v_methods jsonb;
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
    into v_in, v_out
    from public.cash_movements where shift_id = s.id;

  select count(*) filter (where status <> 'voided'),
         coalesce(sum(grand_total) filter (where status <> 'voided'),0),
         count(*) filter (where status = 'voided')
    into v_bills, v_sales, v_voided
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
    'bills', v_bills, 'sales', v_sales, 'voided', v_voided,
    'cash_sales', v_cash_sales, 'cash_refunds', v_cash_refunds,
    'cash_in', v_in, 'cash_out', v_out,
    'expected_cash', s.opening_float + v_cash_sales - v_cash_refunds + v_in - v_out,
    'counted_cash', s.counted_cash, 'variance', s.cash_variance, 'notes', s.notes,
    'by_method', v_methods);
end $$;

-- The open shift for this branch (or null). Money figures are only returned
-- to roles allowed to see the drawer.
create or replace function public.current_shift()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_shift uuid;
  v jsonb;
begin
  if app.current_restaurant_id() is null then
    raise exception 'You are not signed in to a restaurant.';
  end if;
  select id into v_shift from public.shifts
   where branch_id = app.current_branch_id() and status = 'open'
   order by opened_at desc limit 1;
  if v_shift is null then return null; end if;
  v := app.shift_figures(v_shift);
  if not (app.has_permission('shift.close') or app.has_permission('report.view_financial')) then
    v := jsonb_build_object('shift_id', v->'shift_id', 'status', v->'status',
           'opened_at', v->'opened_at', 'opened_by', v->'opened_by', 'bills', v->'bills');
  end if;
  return v;
end $$;

create or replace function public.open_shift(p_opening_float numeric default 0)
returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('shift.open');
  v_branch uuid := app.current_branch_id();
  v_id uuid := gen_random_uuid();
begin
  if coalesce(p_opening_float,0) < 0 then
    raise exception 'The opening cash cannot be negative.';
  end if;
  perform 1 from public.shifts where branch_id = v_branch and status = 'open' for update;
  if found then
    raise exception 'A shift is already open. Close it before opening a new one.';
  end if;
  insert into public.shifts
    (id, restaurant_id, branch_id, device_id, opened_by, opening_float, opened_at, status)
  values
    (v_id, app.current_restaurant_id(), v_branch,
     (select id from public.devices where branch_id = v_branch and is_active order by created_at limit 1),
     v_user, coalesce(p_opening_float,0), now(), 'open');
  perform app.audit('shift.open', 'shifts', v_id,
    jsonb_build_object('opening_float', coalesce(p_opening_float,0)));
  return v_id;
end $$;

create or replace function public.record_cash_movement(
  p_direction text, p_amount numeric, p_reason text)
returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('cash.movement');
  v_shift uuid;
  v_id uuid := gen_random_uuid();
begin
  if p_direction not in ('in','out') then raise exception 'Choose cash in or cash out.'; end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'Enter a reason.'; end if;
  select id into v_shift from public.shifts
   where branch_id = app.current_branch_id() and status = 'open' limit 1;
  if v_shift is null then raise exception 'There is no open shift.'; end if;
  insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
  values (v_id, app.current_restaurant_id(), v_shift, p_direction, round(p_amount,2), left(trim(p_reason),200), v_user);
  perform app.audit('cash.' || p_direction, 'cash_movements', v_id,
    jsonb_build_object('amount', round(p_amount,2), 'reason', left(trim(p_reason),200)));
  return v_id;
end $$;

create or replace function public.close_shift(p_counted_cash numeric, p_notes text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('shift.close');
  v_shift uuid;
  v_fig jsonb;
  v_expected numeric(14,2);
begin
  if p_counted_cash is null or p_counted_cash < 0 then
    raise exception 'Enter the cash you counted in the drawer.';
  end if;
  select id into v_shift from public.shifts
   where branch_id = app.current_branch_id() and status = 'open'
   limit 1 for update;
  if v_shift is null then raise exception 'There is no open shift to close.'; end if;

  v_fig := app.shift_figures(v_shift);
  v_expected := (v_fig->>'expected_cash')::numeric;

  update public.shifts set
    closed_by = v_user, closed_at = now(), status = 'closed',
    expected_cash = v_expected, counted_cash = round(p_counted_cash,2),
    cash_variance = round(p_counted_cash,2) - v_expected,
    notes = nullif(left(trim(p_notes),500),'')
  where id = v_shift;

  perform app.audit('shift.close', 'shifts', v_shift,
    jsonb_build_object('expected_cash', v_expected, 'counted_cash', round(p_counted_cash,2),
                       'variance', round(p_counted_cash,2) - v_expected));
  return app.shift_figures(v_shift);
end $$;

-- Figures for any shift (open or closed) - for the day-close report.
create or replace function public.shift_report(p_shift_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  perform app.require_permission('report.view_financial');
  if not exists (select 1 from public.shifts where id = p_shift_id
                 and restaurant_id = app.current_restaurant_id()) then
    raise exception 'Shift not found.';
  end if;
  return app.shift_figures(p_shift_id);
end $$;

-- ===========================================================================
-- Void: the whole bill is cancelled. The record stays, marked Voided.
-- ===========================================================================
create or replace function public.void_order(p_order_id uuid, p_reason text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('order.void');
  o public.orders%rowtype;
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

-- ===========================================================================
-- Refund: part or all of the money goes back; the bill stays completed.
-- ===========================================================================
create or replace function public.refund_order(p_order_id uuid, p_amount numeric, p_reason text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('order.refund');
  o public.orders%rowtype;
  v_done numeric(14,2);
  v_left numeric(14,2);
  v_payment uuid;
  v_id uuid := gen_random_uuid();
  v_amount numeric(14,2) := round(coalesce(p_amount,0), 2);
begin
  if coalesce(trim(p_reason),'') = '' then raise exception 'A reason is required for a refund.'; end if;
  if v_amount <= 0 then raise exception 'Enter a refund amount greater than zero.'; end if;
  select * into o from public.orders
   where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status <> 'completed' then raise exception 'Only a completed bill can be refunded.'; end if;
  select coalesce(sum(amount),0) into v_done from public.refunds where order_id = o.id;
  v_left := o.paid_total - v_done;
  if v_left <= 0 then raise exception 'Bill % has already been fully refunded.', o.bill_number; end if;
  if v_amount > v_left then
    raise exception 'The most that can be refunded on bill % is %.', o.bill_number, v_left;
  end if;
  select id into v_payment from public.payments
   where order_id = o.id order by created_at limit 1;

  insert into public.refunds (id, restaurant_id, order_id, payment_id, amount, reason, approved_by, client_created_at)
  values (v_id, o.restaurant_id, o.id, v_payment, v_amount, left(trim(p_reason),300), v_user, now());

  update public.orders set payment_status =
         case when v_done + v_amount >= o.paid_total then 'refunded' else 'partially_refunded' end
   where id = o.id;

  perform app.audit('order.refund', 'refunds', v_id,
    jsonb_build_object('bill_number', o.bill_number, 'amount', v_amount, 'reason', left(trim(p_reason),300)));
  return jsonb_build_object('refund_id', v_id, 'bill_number', o.bill_number,
                            'amount', v_amount, 'remaining', v_left - v_amount);
end $$;

-- ===========================================================================
-- Kitchen ticket status: any staff member of the restaurant can move a ticket
-- along new -> preparing -> ready -> served.
-- ===========================================================================
create or replace function public.set_kitchen_status(p_ticket_id uuid, p_status text)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare t public.kitchen_tickets%rowtype;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_status not in ('preparing','ready','served') then raise exception 'Unknown kitchen status.'; end if;
  select * into t from public.kitchen_tickets
   where id = p_ticket_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Kitchen ticket not found.'; end if;
  if t.status = 'cancelled' then raise exception 'This ticket was cancelled.'; end if;
  update public.kitchen_tickets set status = p_status,
         started_at = case when p_status = 'preparing' then coalesce(started_at, now()) else started_at end,
         ready_at   = case when p_status in ('ready','served') then coalesce(ready_at, now()) else ready_at end
   where id = t.id;
  update public.kitchen_ticket_items set status = p_status
   where kitchen_ticket_id = t.id and status <> 'cancelled';
end $$;

-- ---------------------------------------------------------------------------
-- Grants: signed-in users only. Never anonymous.
-- ---------------------------------------------------------------------------
revoke all on function public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text) from public, anon;
revoke all on function public.current_shift() from public, anon;
revoke all on function public.open_shift(numeric) from public, anon;
revoke all on function public.record_cash_movement(text,numeric,text) from public, anon;
revoke all on function public.close_shift(numeric,text) from public, anon;
revoke all on function public.shift_report(uuid) from public, anon;
revoke all on function public.void_order(uuid,text) from public, anon;
revoke all on function public.refund_order(uuid,numeric,text) from public, anon;
revoke all on function public.set_kitchen_status(uuid,text) from public, anon;
revoke all on function app.shift_figures(uuid) from public;

grant execute on function public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text),
  public.current_shift(), public.open_shift(numeric), public.record_cash_movement(text,numeric,text),
  public.close_shift(numeric,text), public.shift_report(uuid), public.void_order(uuid,text),
  public.refund_order(uuid,numeric,text), public.set_kitchen_status(uuid,text)
  to authenticated;
