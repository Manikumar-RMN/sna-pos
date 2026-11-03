-- ================================================================ batch D: requests, messages, wake-up calls and reports (migration 171)
reset role;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

select public.fo_save_room_type('RQT', 'Request Room', 3000, 2, 9) ->> 'room_type_id' as rqt \gset
select public.fo_save_room('903', :'rqt', 'Ninth') ->> 'room_id' as r903 \gset
select public.fo_save_room('904', :'rqt', 'Ninth') ->> 'room_id' as r904 \gset
select public.fo_save_guest('Dev Menon', '9876500410') ->> 'guest_id' as gd \gset
select (:'today'::date + 2) as rdep \gset
select (public.fo_create_stay(:'gd', :'rqt', :'today'::date, :'rdep'::date) ->> 'stay_id') as srq \gset
select (public.fo_create_stay(:'gd', :'rqt', :'today'::date, :'rdep'::date) ->> 'stay_id') as srv \gset

-- ---- a reserved guest can have a request, but not a wake-up call
select public.fo_add_request(:'srv', 'request', 'Extra pillows') ->> 'request_id' as rq_res \gset
select t.ok('a reserved stay can carry a request', :'rq_res' is not null);
select t.must_fail('a wake-up call needs a guest who is checked in',
  format($$select public.fo_add_request(%L, 'wakeup', 'Wake me', %L, '06:30')$$, :'srv', :'today'), 'checked in');

select public.fo_check_in(:'srq', :'r903') is not null as _ci \gset
select t.must_fail('an unknown kind is refused', format($$select public.fo_add_request(%L, 'complaint', 'x')$$, :'srq'), 'request, message or wake-up');
select t.must_fail('empty text is refused', format($$select public.fo_add_request(%L, 'request', '   ')$$, :'srq'), 'Write what');
select t.must_fail('very long text is refused', format($$select public.fo_add_request(%L, 'request', %L)$$, :'srq', repeat('x', 501)), '500');
select t.must_fail('a wake-up needs a time', format($$select public.fo_add_request(%L, 'wakeup', 'Wake', %L)$$, :'srq', :'today'), 'date and time');
select t.must_fail('a wake-up in the past is refused', format($$select public.fo_add_request(%L, 'wakeup', 'Wake', %L, '06:00')$$, :'srq', (:'today'::date - 1)), 'passed');
select t.must_fail('a wake-up outside the stay is refused', format($$select public.fo_add_request(%L, 'wakeup', 'Wake', %L, '06:00')$$, :'srq', (:'today'::date + 30)), 'outside');
select t.must_fail('a checked-out stay takes no requests', format($$select public.fo_add_request(%L, 'request', 'Late bill')$$, :'sa'), 'live stay');
select t.must_fail('another property''s or missing stay is refused', $$select public.fo_add_request('00000000-0000-0000-0000-000000000000', 'request', 'x')$$, 'not found');

select gen_random_uuid() as ref1 \gset
select public.fo_add_request(:'srq', 'request', 'Extra towels', null, null, :'ref1') ->> 'request_id' as rq1 \gset
select t.ok('the same client reference does not add it twice',
  (public.fo_add_request(:'srq', 'request', 'Extra towels', null, null, :'ref1') ->> 'repeat')::boolean
  and (select count(*) from public.fo_requests where client_ref = :'ref1'::uuid) = 1);
select public.fo_add_request(:'srq', 'message', 'Mr Rao called, please ring back') ->> 'request_id' as rq_msg \gset
select (:'today'::date + 1) as wkd \gset
select public.fo_add_request(:'srq', 'wakeup', 'Wake for the 7am train', :'wkd', '06:30') ->> 'request_id' as rq_wk \gset
select t.ok('a wake-up keeps its date and time',
  (select due_date = :'wkd'::date and due_time = '06:30'::time and kind = 'wakeup' from public.fo_requests where id = :'rq_wk'));
select t.ok('a plain request keeps no time',
  (select due_time is null from public.fo_requests where id = :'rq1'));

-- ---- the list
select t.ok('the open list holds all of them, dated wake-up first',
  (select count(*) from jsonb_array_elements(public.fo_requests_list('open')->'rows') x where x->>'stay_no' is not null and x->>'status' = 'open') >= 4
  and (public.fo_requests_list('open')->'rows'->0->>'kind') = 'wakeup');
select t.ok('the today list leaves out a wake-up for tomorrow',
  not exists (select 1 from jsonb_array_elements(public.fo_requests_list('today')->'rows') x where x->>'id' = :'rq_wk'));
select t.ok('the list shows the room and guest name',
  exists (select 1 from jsonb_array_elements(public.fo_requests_list('open')->'rows') x
           where x->>'id' = :'rq1' and x->>'room' = '903' and x->>'guest' = 'Dev Menon'));
select t.must_fail('an unknown list is refused', $$select public.fo_requests_list('everything')$$, 'Unknown list');

-- ---- closing
select t.must_fail('an unknown status is refused', format($$select public.fo_close_request(%L, 'maybe')$$, :'rq1'), 'done or cancelled');
select t.must_fail('cancelling needs a reason', format($$select public.fo_close_request(%L, 'cancelled')$$, :'rq1'), 'why');
select public.fo_close_request(:'rq1', 'done', 'Sent up with housekeeping') ->> 'status' as st1 \gset
select t.ok('a request can be marked done',
  :'st1' = 'done' and (select status = 'done' and closed_at is not null and closed_by is not null and note = 'Sent up with housekeeping' from public.fo_requests where id = :'rq1'));
select t.ok('closing again is a harmless repeat',
  (public.fo_close_request(:'rq1', 'cancelled', 'changed my mind') ->> 'repeat')::boolean and (select status = 'done' from public.fo_requests where id = :'rq1'));
select public.fo_close_request(:'rq_msg', 'cancelled', 'Guest took the call') is not null as _c \gset
select t.ok('a cancelled one drops off the open list',
  not exists (select 1 from jsonb_array_elements(public.fo_requests_list('open')->'rows') x where x->>'id' in (:'rq1', :'rq_msg')));
select t.ok('the recent list still shows closed ones',
  exists (select 1 from jsonb_array_elements(public.fo_requests_list('recent')->'rows') x where x->>'id' = :'rq1'));
select t.ok('adding and closing is written to the audit log',
  (select count(*) from public.audit_logs where action in ('fo_request_added', 'fo_request_done', 'fo_request_cancelled')) >= 4);

-- ---- rights: a cashier has no front office rights
select set_config('request.jwt.claims', '{"sub":"' || :'cashier' || '","role":"authenticated"}', false);
select t.must_fail('cashier cannot add a request', format($$select public.fo_add_request(%L, 'request', 'x')$$, :'srq'), 'does not allow');
select t.must_fail('cashier cannot list requests', $$select public.fo_requests_list('open')$$, 'does not allow');
select t.must_fail('cashier cannot close a request', format($$select public.fo_close_request(%L, 'done')$$, :'rq_wk'), 'does not allow');
select t.must_fail('cashier cannot run the performance report', format($$select public.fo_report_performance(%L, %L)$$, :'today', :'today'), 'does not allow');
select t.must_fail('cashier cannot see who owes what', $$select public.fo_report_outstanding()$$, 'does not allow');
select t.must_fail('cashier cannot run the GST report', format($$select public.fo_report_gst(%L, %L)$$, :'today', :'today'), 'does not allow');
select t.ok('cashier sees no requests through the table either', (select count(*) from public.fo_requests) = 0);
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

-- ---- performance report on a quiet stretch of calendar (so earlier tests do not leak in)
reset role;
select (:'today'::date + 400) as p1 \gset
select (:'today'::date + 409) as p10 \gset
insert into public.fo_charges (restaurant_id, branch_id, stay_id, business_date, kind, description, quantity, unit_amount, net_amount, tax_pct, tax_amount, total_amount)
values (:'restaurant_id', :'branch_id', :'srq', :'p1'::date, 'room', 'Room charge', 1, 3000, 3000, 5, 150, 3150),
       (:'restaurant_id', :'branch_id', :'srq', (:'p1'::date + 1), 'room', 'Room charge', 1, 3000, 3000, 5, 150, 3150),
       (:'restaurant_id', :'branch_id', :'srq', (:'p1'::date + 1), 'food', 'Dinner', 1, 1000, 1000, 5, 50, 1050);
insert into public.fo_charges (restaurant_id, branch_id, stay_id, business_date, kind, description, quantity, unit_amount, net_amount, tax_pct, tax_amount, total_amount, voided_at, void_reason)
values (:'restaurant_id', :'branch_id', :'srq', (:'p1'::date + 2), 'room', 'Voided night', 1, 3000, 3000, 5, 150, 3150, now(), 'test');
select count(*) as nrooms from public.fo_rooms where restaurant_id = :'restaurant_id' and branch_id = :'branch_id' and active and not out_of_service \gset
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select public.fo_report_performance(:'p1', :'p10') as perf \gset
select t.ok('rooms sold counts posted room nights and skips voided ones',
  (:'perf'::jsonb->'totals'->>'rooms_sold')::int = 2 and (:'perf'::jsonb->'totals'->>'days_with_sales')::int = 2);
select t.ok('room revenue is net of tax, other revenue is kept apart',
  (:'perf'::jsonb->'totals'->>'room_revenue')::numeric = 6000 and (:'perf'::jsonb->'totals'->>'other_revenue')::numeric = 1000
  and (:'perf'::jsonb->'totals'->>'tax')::numeric = 350);
select t.ok('ADR is room revenue over rooms sold', (:'perf'::jsonb->'totals'->>'adr')::numeric = 3000);
select t.ok('occupancy and RevPAR use the number of rooms and days in the range',
  (:'perf'::jsonb->>'rooms_available')::int = :'nrooms'::int
  and (:'perf'::jsonb->'totals'->>'occupancy_pct')::numeric = round(100.0 * 2 / (:'nrooms'::int * 10), 2)
  and (:'perf'::jsonb->'totals'->>'revpar')::numeric = round(6000.0 / (:'nrooms'::int * 10), 2));
select t.ok('each day carries its own occupancy',
  (select count(*) from jsonb_array_elements(:'perf'::jsonb->'days') d where (d->>'rooms_sold')::int = 1 and (d->>'room_revenue')::numeric = 3000) = 2);
select t.ok('the room type table shows the request room type',
  (select (x->>'rooms_sold')::int = 2 and (x->>'room_revenue')::numeric = 6000 and (x->>'adr')::numeric = 3000
     from jsonb_array_elements(:'perf'::jsonb->'room_types') x where x->>'code' = 'RQT'));
select t.must_fail('a range over a year is refused', format($$select public.fo_report_performance(%L, %L)$$, :'p1', (:'p1'::date + 400)), 'one year');
select t.must_fail('a backwards range is refused', format($$select public.fo_report_performance(%L, %L)$$, :'p10', :'p1'), 'one year');

-- ---- lost bookings and source mix
select (:'today'::date + 410) as lost_a \gset
select (:'today'::date + 412) as lost_d \gset
select (public.fo_create_stay(:'gd', :'rqt', :'lost_a'::date, :'lost_d'::date, 3000, 1, 0, 'ota') ->> 'stay_id') as slost \gset
select (public.fo_create_stay(:'gd', :'rqt', :'lost_a'::date, :'lost_d'::date, 3000, 1, 0, 'phone') ->> 'stay_id') as skeep \gset
select public.fo_cancel_stay(:'slost', 'Found a cheaper hotel') is not null as _cx \gset
select public.fo_report_performance(:'lost_a', :'lost_d') as perf2 \gset
select t.ok('a cancelled booking is listed with its reason and value',
  (select x->>'reason' = 'Found a cheaper hotel' and (x->>'nights')::int = 2 and (x->>'value')::numeric = 6000 and x->>'source' = 'ota'
     from jsonb_array_elements(:'perf2'::jsonb->'lost') x where x->>'stay_no' = (select stay_no::text from public.fo_stays where id = :'slost')));
select t.ok('the live booking is not in the lost list',
  not exists (select 1 from jsonb_array_elements(:'perf2'::jsonb->'lost') x where x->>'stay_no' = (select stay_no::text from public.fo_stays where id = :'skeep')));
select t.ok('source mix counts bookings and cancellations by source',
  (select (x->>'bookings')::int = 1 and (x->>'cancelled')::int = 1 and (x->>'nights')::int = 0 from jsonb_array_elements(:'perf2'::jsonb->'sources') x where x->>'source' = 'ota')
  and (select (x->>'bookings')::int = 1 and (x->>'cancelled')::int = 0 and (x->>'nights')::int = 2 from jsonb_array_elements(:'perf2'::jsonb->'sources') x where x->>'source' = 'phone'));

-- ---- who owes what
select public.fo_take_payment(:'srq', 1000, null, 'advance') is not null as _pay \gset
select public.fo_report_outstanding() as os \gset
select (public.fo_folio(:'srq')->'totals'->>'balance')::numeric as fbal \gset
select t.ok('the guest ledger shows the in-house guest with the same balance as the folio',
  (select (x->>'balance')::numeric = :'fbal'::numeric and x->>'room' = '903' from jsonb_array_elements(:'os'::jsonb->'guests') x where x->>'stay_id' = :'srq'));
select t.ok('a guest who owes nothing is not listed',
  not exists (select 1 from jsonb_array_elements(:'os'::jsonb->'guests') x where x->>'stay_id' = :'sa'));
select t.ok('the company side matches the company account',
  (select (x->>'outstanding')::numeric = (public.fo_company_ledger(:'acme')->'summary'->>'outstanding')::numeric
     from jsonb_array_elements(:'os'::jsonb->'companies') x where x->>'company_id' = :'acme'));
select t.ok('guest owed and deposits held add up from the rows',
  (:'os'::jsonb->>'guest_owed')::numeric = (select coalesce(sum((x->>'balance')::numeric), 0) from jsonb_array_elements(:'os'::jsonb->'guests') x where (x->>'balance')::numeric > 0)
  and (:'os'::jsonb->>'deposits_held')::numeric = (select coalesce(-sum((x->>'balance')::numeric), 0) from jsonb_array_elements(:'os'::jsonb->'guests') x where (x->>'balance')::numeric < 0));

-- ---- GST summary agrees with the register
select (:'today'::date - 100) as g1 \gset
select (:'today'::date + 100) as g2 \gset
select public.fo_report_gst(:'g1', :'g2') as gst \gset
select public.fo_invoice_register(:'g1', :'g2') as reg \gset
select t.ok('the GST report counts the same invoices as the register',
  (:'gst'::jsonb->'totals'->>'invoices')::int = (:'reg'::jsonb->'totals'->>'count')::int and (:'reg'::jsonb->'totals'->>'count')::int >= 3);
select t.ok('the GST report has the same taxable value, tax and total as the register',
  (:'gst'::jsonb->'totals'->>'taxable')::numeric = (:'reg'::jsonb->'totals'->>'taxable')::numeric
  and (:'gst'::jsonb->'totals'->>'tax')::numeric = (:'reg'::jsonb->'totals'->>'tax')::numeric
  and (:'gst'::jsonb->'totals'->>'total')::numeric = (:'reg'::jsonb->'totals'->>'total')::numeric);
select t.ok('the rate lines add up to the invoice tax',
  (select coalesce(sum((x->>'tax')::numeric), 0) from jsonb_array_elements(:'gst'::jsonb->'rows') x) = (:'gst'::jsonb->'totals'->>'tax')::numeric
  and (select coalesce(sum((x->>'taxable')::numeric), 0) from jsonb_array_elements(:'gst'::jsonb->'rows') x) = (:'gst'::jsonb->'totals'->>'taxable')::numeric);
select t.ok('CGST and SGST add up to the tax on every line',
  (select bool_and((x->>'cgst')::numeric + (x->>'sgst')::numeric = (x->>'tax')::numeric) from jsonb_array_elements(:'gst'::jsonb->'rows') x));
select t.ok('B2B plus B2C is every invoice',
  (:'gst'::jsonb->'totals'->>'b2b_count')::int + (:'gst'::jsonb->'totals'->>'b2c_count')::int = (:'gst'::jsonb->'totals'->>'invoices')::int);
select t.must_fail('a GST range over a year is refused', format($$select public.fo_report_gst(%L, %L)$$, :'g1', (:'g1'::date + 400)), 'one year');
