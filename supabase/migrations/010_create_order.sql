-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260923125459, name 'sna_pos_10_create_order'. This is the SQL that actually ran.

-- SNA POS — server-authoritative order creation.
--
-- The browser sends only WHAT was ordered (product ids + quantities). Every
-- rupee is computed here, from the menu price and tax rules stored in the
-- database, so a tampered client cannot change a total. The tax breakdown is
-- frozen into order_item_taxes at the moment of sale, and item names/prices are
-- copied onto the bill, so a later price or rate change never alters this bill.
--
-- SECURITY INVOKER: it runs with the caller's own rights, so Row Level Security
-- applies and it can only ever touch the caller's own restaurant. It checks the
-- caller holds 'order.create', and 'order.discount' before allowing a discount.

create or replace function public.create_order(
    p_items             jsonb,                 -- [{"product_id":"uuid","qty":number,"note":text}]
    p_order_type        text default 'dine_in',
    p_table_id          uuid default null,
    p_customer_id       uuid default null,
    p_payment_method_id uuid default null,
    p_tendered          numeric default null,
    p_discount_amount   numeric default 0,
    p_discount_reason   text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
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
    v_order_id   uuid := gen_random_uuid();

    v_item        jsonb;
    v_product     public.products%rowtype;
    v_line_id     uuid;
    v_qty         numeric(10,3);
    v_line_sub    numeric(14,2);
    v_subtotal    numeric(14,2) := 0;
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
begin
    if v_restaurant is null then
        raise exception 'Not signed in to a restaurant.';
    end if;
    if not app.has_permission('order.create') then
        raise exception 'You do not have permission to take orders.';
    end if;
    if p_items is null or jsonb_array_length(p_items) = 0 then
        raise exception 'The order is empty.';
    end if;
    if coalesce(p_discount_amount,0) > 0 and not app.has_permission('order.discount') then
        raise exception 'A manager must approve a discount.';
    end if;

    select id into v_user from public.users
      where auth_user_id = auth.uid() and deleted_at is null and is_active limit 1;

    -- Resolve the caller's branch and a billing device, locking the device row
    -- so two concurrent bills cannot take the same number.
    select b.id, b.code, b.currency_or_null, br.cash_rounding_mode
      into v_branch, v_prefix, v_currency, v_rounding
    from (
      select b.id, b.code,
             (select currency_code from public.restaurants r where r.id = b.restaurant_id) as currency_or_null
      from public.branches b
      where b.restaurant_id = v_restaurant and b.deleted_at is null
      order by b.created_at limit 1
    ) b
    left join public.branch_settings br on br.branch_id = b.id;

    if v_branch is null then
      raise exception 'No branch is set up for this restaurant.';
    end if;
    v_rounding := coalesce(v_rounding, 'none');

    select id, bill_prefix, next_bill_seq
      into v_device, v_prefix, v_seq
    from public.devices
    where branch_id = v_branch and is_active
    order by created_at limit 1
    for update;

    if v_device is null then
      raise exception 'No billing device is set up for this branch.';
    end if;

    v_bill_no := (select code from public.branches where id = v_branch)
                 || '-' || coalesce(v_prefix,'C1')
                 || '-' || lpad(v_seq::text, 4, '0');
    update public.devices set next_bill_seq = next_bill_seq + 1 where id = v_device;

    -- First pass: create the order shell and the line items, accumulating the
    -- pre-discount subtotal.
    insert into public.orders
      (id, restaurant_id, branch_id, device_id, bill_number, order_type,
       dining_table_id, customer_id, cashier_id, currency_code,
       status, payment_status, client_created_at)
    values
      (v_order_id, v_restaurant, v_branch, v_device, v_bill_no, p_order_type,
       p_table_id, p_customer_id, v_user, v_currency,
       'open', 'unpaid', now());

    for v_item in select * from jsonb_array_elements(p_items)
    loop
      select * into v_product from public.products
        where id = (v_item->>'product_id')::uuid
          and restaurant_id = v_restaurant and deleted_at is null;
      if not found then
        raise exception 'A menu item on the order no longer exists.';
      end if;
      v_qty := coalesce((v_item->>'qty')::numeric, 1);
      if v_qty <= 0 then continue; end if;

      v_line_sub := round(v_product.price * v_qty, 2);
      v_subtotal := v_subtotal + v_line_sub;
      v_line_id  := gen_random_uuid();

      insert into public.order_items
        (id, restaurant_id, order_id, product_id, product_name, unit_price,
         quantity, line_subtotal, line_total, is_price_inclusive, kitchen_note)
      values
        (v_line_id, v_restaurant, v_order_id, v_product.id, v_product.name,
         v_product.price, v_qty, v_line_sub, v_line_sub, false,
         nullif(v_item->>'note',''));
    end loop;

    v_discount := least(coalesce(p_discount_amount,0), v_subtotal);

    -- Second pass: allocate the discount across lines by value share, then
    -- compute and FREEZE each tax component on the discounted line value.
    for v_line_id, v_line_sub in
      select id, line_subtotal from public.order_items where order_id = v_order_id
    loop
      v_line_disc := case when v_subtotal > 0
                          then round(v_discount * (v_line_sub / v_subtotal), 2)
                          else 0 end;
      v_line_net  := v_line_sub - v_line_disc;
      v_line_tax  := 0;

      -- The current in-force tax rate for this line's product.
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
        -- Same-state sale for V1: components that apply 'always' or intra-region.
        for v_comp in
          select name, rate from public.tax_rate_components
          where tax_rate_id = v_rate_id and applies_when in ('always','intra_region')
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
         p_discount_reason, v_user);
    end if;

    -- Grand total, rounded once per the branch's rule.
    v_before_round := v_subtotal - v_discount + v_tax_total;
    v_grand := case v_rounding
                 when 'nearest_1'    then round(v_before_round, 0)
                 when 'nearest_0_05' then round(v_before_round / 0.05) * 0.05
                 when 'nearest_0_10' then round(v_before_round / 0.10) * 0.10
                 else v_before_round end;
    v_rounding_adj := v_grand - v_before_round;

    -- Record payment, if one was given, and close the bill.
    if p_payment_method_id is not null then
      if p_tendered is not null and p_tendered > v_grand then
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
        payment_status = case when p_payment_method_id is not null then 'paid' else 'unpaid' end,
        synced_at = now()
    where id = v_order_id;

    insert into public.audit_logs
      (restaurant_id, branch_id, user_id, action, entity_type, entity_id,
       actor_type, new_value)
    values
      (v_restaurant, v_branch, v_user, 'order.create', 'orders', v_order_id,
       'user', jsonb_build_object('bill_number', v_bill_no, 'grand_total', v_grand));

    return jsonb_build_object(
      'order_id', v_order_id, 'bill_number', v_bill_no,
      'subtotal', v_subtotal, 'discount', v_discount, 'tax_total', v_tax_total,
      'rounding', v_rounding_adj, 'grand_total', v_grand, 'change', v_change);
end
$$;

revoke all on function public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text) from public;
grant execute on function public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text) to authenticated;
