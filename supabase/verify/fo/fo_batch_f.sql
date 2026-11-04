-- ================================================================ batch F: POS "Charge to room" (migration 173)
reset role;
-- POS setup for the test hotel: a product to sell, a shift to sell in.
select tg.id as tgid from public.tax_groups tg where tg.restaurant_id = :'restaurant_id' order by tg.name limit 1 \gset
insert into public.categories (restaurant_id, name, display_order) values (:'restaurant_id', 'Room dining', 1);
insert into public.products (restaurant_id, category_id, tax_group_id, name, price)
select :'restaurant_id', c.id, :'tgid', 'Club sandwich', 400 from public.categories c where c.restaurant_id = :'restaurant_id' and c.name = 'Room dining';
select p.id as prod from public.products p where p.restaurant_id = :'restaurant_id' and p.name = 'Club sandwich' \gset

set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select public.fo_save_room_type('RMC', 'Room charge room', 3000, 2, 9) ->> 'room_type_id' as rmc \gset
select public.fo_save_room('951', :'rmc', 'Ninth') ->> 'room_id' as r951 \gset
select public.fo_save_room('952', :'rmc', 'Ninth') ->> 'room_id' as r952 \gset
select public.fo_save_guest('Rhea Kapoor', '9876500951') ->> 'guest_id' as grh \gset
select (:'today'::date + 3) as rcdep \gset
select (public.fo_create_stay(:'grh', :'rmc', :'today'::date, :'rcdep'::date) ->> 'stay_id') as src \gset
select (public.fo_create_stay(:'grh', :'rmc', :'today'::date, :'rcdep'::date) ->> 'stay_id') as src_res \gset
select public.fo_check_in(:'src', :'r951') is not null as _ci \gset
do $$ begin perform public.open_shift(0); exception when others then null; end $$;

-- ---- who is in the hotel
select t.ok('the POS list shows the in-house guest with the room, and not the one only booked',
  exists (select 1 from jsonb_array_elements(public.fo_inhouse_for_pos()) x where x ->> 'stay_id' = :'src' and x ->> 'room_number' = '951' and x ->> 'guest' = 'Rhea Kapoor')
  and not exists (select 1 from jsonb_array_elements(public.fo_inhouse_for_pos()) x where x ->> 'stay_id' = :'src_res'));

-- ---- a bill, charged to the room
select (public.create_order(jsonb_build_array(jsonb_build_object('product_id', :'prod', 'qty', 2)), 'takeaway') ->> 'order_id') as ord1 \gset
select grand_total as gt1, bill_number as bn1 from public.orders where id = :'ord1' \gset
reset role;
select app.fo_balance(:'src') as bal0 \gset
set role authenticated;
select t.must_fail('a guest who is only booked cannot be charged', format($$select public.fo_charge_bill_to_room(%L, %L)$$, :'ord1', :'src_res'), 'in the hotel now');
select public.fo_charge_bill_to_room(:'ord1', :'src', 'Room service') as rc1 \gset
select t.ok('the bill is paid in full by a room payment',
  (select payment_status = 'paid' and paid_total = :'gt1'::numeric from public.orders where id = :'ord1')
  and (select count(*) = 1 and bool_and(pm.kind = 'room' and p.amount = :'gt1'::numeric and p.status = 'captured')
         from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id where p.order_id = :'ord1'));
select t.ok('the folio has one line for the whole bill, tax included, with no second GST',
  (select count(*) = 1 and bool_and(order_id = :'ord1' and total_amount = :'gt1'::numeric and net_amount = :'gt1'::numeric
                                      and tax_amount = 0 and tax_pct = 0 and kind = 'food'
                                      and description like 'Restaurant bill #' || :'bn1' || ' (tax included)%')
     from public.fo_charges where stay_id = :'src' and order_id = :'ord1'));
reset role;
select t.ok('the folio balance went up by the bill total', app.fo_balance(:'src') = :'bal0'::numeric + :'gt1'::numeric);
set role authenticated;
select t.must_fail('the same bill cannot be charged twice', format($$select public.fo_charge_bill_to_room(%L, %L)$$, :'ord1', :'src'), 'already paid');
select t.ok('the room method is hidden from the payment pickers',
  not exists (select 1 from public.payment_methods where restaurant_id = :'restaurant_id' and kind = 'room' and is_active));
reset role;
select t.must_fail('a room payment cannot be written any other way',
  format($$insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, status, received_by, client_created_at)
           select gen_random_uuid(), restaurant_id, id, app.room_method(restaurant_id), 1, currency_code, 'captured', (select u.id from public.users u where u.restaurant_id = orders.restaurant_id limit 1), now() from public.orders where id = %L$$, :'ord1'),
  'Charge to room');
set role authenticated;

-- ---- voiding the bill takes it off the folio
select t.must_pass('the bill can be voided while the guest is in the hotel', format($$select public.void_order(%L, 'Guest changed their mind')$$, :'ord1'));
select t.ok('the folio line is voided with the reason',
  (select voided_at is not null and void_reason like '%voided%' from public.fo_charges where order_id = :'ord1'));
reset role;
select t.ok('the folio balance is back where it was', app.fo_balance(:'src') = :'bal0'::numeric);
set role authenticated;

-- ---- a second bill: no refund of cash for it, and no void after check-out
select (public.create_order(jsonb_build_array(jsonb_build_object('product_id', :'prod', 'qty', 1)), 'takeaway') ->> 'order_id') as ord2 \gset
select grand_total as gt2 from public.orders where id = :'ord2' \gset
select public.fo_charge_bill_to_room(:'ord2', :'src') is not null as _rc2 \gset
reset role;
select id as cashm from public.payment_methods where restaurant_id = :'restaurant_id' and kind = 'cash' order by display_order limit 1 \gset
set role authenticated;
select t.must_fail('a credit note with cash is refused for a room-charged bill',
  format($$select public.issue_credit_note(%L, 10, %L, 'Guest complaint')$$, :'ord2', :'cashm'), 'charged to a room');

-- the guest settles and leaves
select t.must_pass('the guest settles the folio, bill included, and checks out', format($$select public.fo_check_out(%L, %L)$$, :'src', :'cashm'));
select t.must_fail('after check-out the bill cannot be voided', format($$select public.void_order(%L, 'Too late')$$, :'ord2'), 'credit note on the hotel invoice');
select t.ok('the folio line is still there after the refused void',
  (select voided_at is null from public.fo_charges where order_id = :'ord2'));
