\set ON_ERROR_STOP on
\set owner '11111111-1111-1111-1111-111111111111'
\set cashier '22222222-2222-2222-2222-222222222222'

-- ================================================================ gating
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

select t.must_fail('module off: room board refused', 'select public.fo_room_board()', 'not switched on');
select t.must_fail('module off: availability refused',
  'select public.fo_availability(current_date, current_date + 1)', 'not switched on');

reset role;
insert into public.restaurant_modules (restaurant_id, module_key) values (:'restaurant_id', 'front_office');
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select t.must_pass('module on: room board works', 'select public.fo_room_board()');

-- A Cashier has no front office right at all.
select set_config('request.jwt.claims', '{"sub":"' || :'cashier' || '","role":"authenticated"}', false);
select t.must_fail('cashier cannot see the board', 'select public.fo_room_board()', 'does not allow');
select t.must_fail('cashier cannot take a reservation',
  'select public.fo_create_stay(null, null, current_date, current_date + 1)', 'does not allow');

-- ================================================================ masters
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select public.fo_save_room_type('STD', 'Standard Room', 3000, 2, 1) ->> 'room_type_id' as std \gset
select public.fo_save_room_type('SUI', 'Suite', 9000, 4, 2) ->> 'room_type_id' as sui \gset
select public.fo_save_room('101', :'std', 'Ground') ->> 'room_id' as r101 \gset
select public.fo_save_room('102', :'std', 'Ground') ->> 'room_id' as r102 \gset
select public.fo_save_room('201', :'sui', 'First')  ->> 'room_id' as r201 \gset
select t.ok('masters: three rooms exist',
  (select count(*) = 3 from public.fo_rooms where restaurant_id = :'restaurant_id'));
select t.must_fail('room type needs a code', $$select public.fo_save_room_type('', 'No code')$$, 'short code');

select app.business_today(:'branch_id') as today \gset
select (:'today'::date + 2) as dep2 \gset
select (:'today'::date + 1) as dep1 \gset

-- ================================================================ guests and reservations
select public.fo_save_guest('Ravi Kumar', '9876500011') ->> 'guest_id' as g1 \gset
select public.fo_save_guest('Meena Iyer', '9876500022') ->> 'guest_id' as g2 \gset
select public.fo_save_guest('Ravi Kumar', '9876500011') ->> 'guest_id' as g1again \gset
select t.ok('guest: same phone returns the same guest', :'g1' = :'g1again');
select t.must_fail('guest needs a name', $$select public.fo_save_guest('  ')$$, 'a name');

select t.must_fail('no arrival before the business date',
  format($$select public.fo_create_stay(%L, %L, %L::date, %L::date)$$, :'g1', :'std', :'today'::date - 1, :'dep2'),
  'before the business date');
select t.must_fail('departure must be after arrival',
  format($$select public.fo_create_stay(%L, %L, %L::date, %L::date)$$, :'g1', :'std', :'today', :'today'),
  'later departure');
select t.must_fail('occupancy is capped',
  format($$select public.fo_create_stay(%L, %L, %L::date, %L::date, null, 3, 1)$$, :'g1', :'std', :'today', :'dep2'),
  'holds 2 people');

select public.fo_availability(:'today'::date, :'dep2'::date) as avail \gset
select t.ok('availability: 2 standard rooms free',
  (select (x->>'free')::int = 2 from jsonb_array_elements(:'avail'::jsonb) x where x->>'code' = 'STD'));

select public.fo_create_stay(:'g1', :'std', :'today'::date, :'dep2'::date, null, 2, 0, 'walk_in') as s1j \gset
select (:'s1j'::jsonb ->> 'stay_id') as s1 \gset
select t.ok('stay: rate defaults to the room type base rate',
  (:'s1j'::jsonb ->> 'nightly_rate')::numeric = 3000);
select t.ok('stay: numbered from 1', (:'s1j'::jsonb ->> 'stay_no')::int >= 1);

-- ================================================================ check-in
reset role;
update public.fo_rooms set housekeeping_status = 'dirty' where id = :'r101';
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select t.must_fail('check-in refuses a dirty room',
  format($$select public.fo_check_in(%L, %L)$$, :'s1', :'r101'), 'not clean');

select t.must_pass('housekeeping: room marked clean',
  format($$select public.fo_set_room_status(%L, 'clean')$$, :'r101'));
select t.must_pass('check-in into room 101', format($$select public.fo_check_in(%L, %L)$$, :'s1', :'r101'));
select t.ok('check-in: stay is in-house in room 101',
  (select status = 'inhouse' and room_id = :'r101' from public.fo_stays where id = :'s1'));
select t.ok('check-in: the room is now dirty',
  (select housekeeping_status = 'dirty' from public.fo_rooms where id = :'r101'));
select t.ok('check-in twice is harmless',
  (public.fo_check_in(:'s1') ->> 'repeat')::boolean);

-- The occupied room is no longer offered.
select public.fo_availability(:'today'::date, :'dep2'::date) as avail2 \gset
select t.ok('availability: 1 standard room left',
  (select (x->>'free')::int = 1 from jsonb_array_elements(:'avail2'::jsonb) x where x->>'code' = 'STD'));

-- ================================================================ charges
select t.must_fail('a room charge cannot be posted by hand',
  format($$select public.fo_post_charge(%L, 'room', 'Room', 3000)$$, :'s1'), 'night audit');
select t.must_fail('a charge needs a description',
  format($$select public.fo_post_charge(%L, 'food', '', 100)$$, :'s1'), 'Describe');

select public.fo_post_charge(:'s1', 'food', 'Room service dinner', 500) as c1j \gset
select t.ok('charge: 5 per cent tax on 500 = 525 total',
  (:'c1j'::jsonb ->> 'tax')::numeric = 25 and (:'c1j'::jsonb ->> 'total')::numeric = 525);
select t.ok('folio balance is 525', app.fo_balance(:'s1') = 525);

-- Idempotency: the same client_ref posts once.
select public.fo_post_charge(:'s1', 'minibar', 'Water', 50, 1, '33333333-3333-3333-3333-333333333333') as cr1 \gset
select public.fo_post_charge(:'s1', 'minibar', 'Water', 50, 1, '33333333-3333-3333-3333-333333333333') as cr2 \gset
select t.ok('charge: a retry does not double-post',
  (:'cr2'::jsonb ->> 'repeat')::boolean
  and (:'cr1'::jsonb ->> 'charge_id') = (:'cr2'::jsonb ->> 'charge_id')
  and app.fo_balance(:'s1') = 577.50);

select (:'cr1'::jsonb ->> 'charge_id') as minibar \gset
select t.must_fail('a void needs a reason',
  format($$select public.fo_void_charge(%L, '  ')$$, :'minibar'), 'a reason');
select t.must_pass('void the minibar charge',
  format($$select public.fo_void_charge(%L, 'Guest says not taken')$$, :'minibar'));
select t.ok('balance back to 525 after the void', app.fo_balance(:'s1') = 525);

-- ================================================================ check-out
select id as cash_method from public.payment_methods
 where restaurant_id = :'restaurant_id' and kind = 'cash' limit 1 \gset
select t.must_fail('check-out refuses while money is owed',
  format($$select public.fo_check_out(%L)$$, :'s1'), 'owes 525');

select public.fo_take_payment(:'s1', 600, :'cash_method') as pay1 \gset
select t.ok('overpayment leaves the folio in credit', app.fo_balance(:'s1') = -75);
select t.must_fail('check-out refuses a folio in credit',
  format($$select public.fo_check_out(%L)$$, :'s1'), 'in credit by 75');
select t.must_fail('a refund cannot exceed the credit',
  format($$select public.fo_take_payment(%L, 100, %L, null, true)$$, :'s1', :'cash_method'), 'cannot be refunded');
select t.must_pass('refund the 75',
  format($$select public.fo_take_payment(%L, 75, %L, null, true)$$, :'s1', :'cash_method'));
select t.ok('folio settled at zero', app.fo_balance(:'s1') = 0);
select t.must_pass('check-out now succeeds', format($$select public.fo_check_out(%L)$$, :'s1'));
select t.ok('check-out: stay is closed',
  (select status = 'checked_out' from public.fo_stays where id = :'s1'));
select t.must_fail('a closed folio cannot be changed',
  format($$select public.fo_post_charge(%L, 'misc', 'Late', 10)$$, :'s1'), 'checked_out');

-- Collect-and-close in one call.
select public.fo_save_guest('Arun Das', '9876500033') ->> 'guest_id' as g3 \gset
select (public.fo_create_stay(:'g3', :'std', :'today'::date, :'dep1'::date) ->> 'stay_id') as s2 \gset
select public.fo_check_in(:'s2', :'r102') as ci2 \gset
select public.fo_post_charge(:'s2', 'laundry', 'Shirts', 200) as c2 \gset
select public.fo_check_out(:'s2', :'cash_method') as co2 \gset
select t.ok('check-out collects the balance in one call',
  (:'co2'::jsonb ->> 'collected')::numeric = 210 and app.fo_balance(:'s2') = 0);

-- ================================================================ cancel and no-show
select (public.fo_create_stay(:'g2', :'sui', :'dep1'::date, :'dep2'::date) ->> 'stay_id') as s3 \gset
select t.must_fail('cancelling needs a reason',
  format($$select public.fo_cancel_stay(%L, '')$$, :'s3'), 'a reason');
select public.fo_take_payment(:'s3', 1000, :'cash_method') as adv \gset
select t.must_fail('a stay with an advance cannot be cancelled',
  format($$select public.fo_cancel_stay(%L, 'Guest changed plans')$$, :'s3'), 'advance of 1000');
select t.must_pass('refund the advance',
  format($$select public.fo_take_payment(%L, 1000, %L, null, true)$$, :'s3', :'cash_method'));
select t.must_pass('a refunded advance no longer blocks the cancel',
  format($$select public.fo_cancel_stay(%L, 'Guest changed plans')$$, :'s3'));
select t.ok('cancel: the stay is cancelled',
  (select status = 'cancelled' from public.fo_stays where id = :'s3'));
select public.fo_save_guest('Future F', '9876500077') ->> 'guest_id' as g7 \gset
select (public.fo_create_stay(:'g7', :'std', :'dep1'::date, :'dep2'::date) ->> 'stay_id') as s4 \gset
select t.must_fail('a future reservation is not a no-show yet',
  format($$select public.fo_mark_no_show(%L)$$, :'s4'), 'not a no-show yet');

-- ================================================================ out of service
select t.must_fail('out of service needs a reason',
  format($$select public.fo_set_room_status(%L, null, true, '')$$, :'r201'), 'a reason');
select t.must_pass('take the suite out of service',
  format($$select public.fo_set_room_status(%L, null, true, 'Air conditioner failed')$$, :'r201'));
select public.fo_availability(:'dep1'::date, :'dep2'::date) as avail3 \gset
select t.ok('availability: an out-of-service room is not offered',
  (select (x->>'rooms')::int = 0 from jsonb_array_elements(:'avail3'::jsonb) x where x->>'code' = 'SUI'));
select t.must_pass('bring the suite back',
  format($$select public.fo_set_room_status(%L, 'clean', false)$$, :'r201'));

-- ================================================================ night audit and tax slabs
select public.fo_save_guest('Latha R', '9876500044') ->> 'guest_id' as g4 \gset
select public.fo_save_guest('Suresh P', '9876500055') ->> 'guest_id' as g5 \gset
select (public.fo_create_stay(:'g4', :'std', :'today'::date, :'dep2'::date) ->> 'stay_id') as a1 \gset
select (public.fo_create_stay(:'g5', :'sui', :'today'::date, :'dep2'::date) ->> 'stay_id') as a2 \gset
select public.fo_set_room_status(:'r101', 'clean') as hk1 \gset
select public.fo_check_in(:'a1', :'r101') as x1 \gset
select public.fo_check_in(:'a2', :'r201') as x2 \gset
select t.ok('night audit setup: both guests are in-house',
  (select count(*) = 2 from public.fo_stays where id in (:'a1', :'a2') and status = 'inhouse'));

select public.fo_save_guest('Noshow N', '9876500066') ->> 'guest_id' as g6 \gset
select (public.fo_create_stay(:'g6', :'std', :'today'::date, :'dep1'::date) ->> 'stay_id') as ns1 \gset
select public.fo_night_audit_run() as na1 \gset
select t.ok('night audit posted two room charges',
  (:'na1'::jsonb ->> 'charges_posted')::int = 2);
select t.ok('room tax 5 per cent below the threshold: 3000 + 150',
  (select tax_pct = 5 and tax_amount = 150 and total_amount = 3150
     from public.fo_charges where stay_id = :'a1' and kind = 'room'));
select t.ok('room tax 18 per cent above the threshold: 9000 + 1620',
  (select tax_pct = 18 and tax_amount = 1620 and total_amount = 10620
     from public.fo_charges where stay_id = :'a2' and kind = 'room'));
select t.ok('night audit: room revenue is net of tax (3000 + 9000)',
  (:'na1'::jsonb ->> 'room_revenue')::numeric = 12000);
select t.ok('night audit: ADR = 12000 / 2 rooms sold',
  (:'na1'::jsonb ->> 'adr')::numeric = 6000);
select t.ok('night audit: RevPAR = 12000 / 3 rooms available',
  (:'na1'::jsonb ->> 'revpar')::numeric = 4000);
select t.ok('night audit: occupancy = 2 of 3',
  (:'na1'::jsonb ->> 'occupancy_pct')::numeric = 66.67);
select t.ok('night audit: a reservation due today that never arrived is a no-show',
  (select status = 'no_show' from public.fo_stays where id = :'ns1'));

select public.fo_night_audit_run() as na2 \gset
select t.ok('night audit cannot run twice for one date',
  (:'na2'::jsonb ->> 'repeat')::boolean);
select t.ok('night audit: no second room charge',
  (select count(*) = 2 from public.fo_charges where kind = 'room' and voided_at is null));
select t.must_fail('night audit refuses a future date',
  format($$select public.fo_night_audit_run(%L::date)$$, :'dep2'), 'future date');

-- ================================================================ tenant isolation
reset role;
insert into auth.users (id, email, encrypted_password)
values ('44444444-4444-4444-4444-444444444444', 'other@fo.test',
        extensions.crypt('Test-Passw0rd!', extensions.gen_salt('bf')));
-- The console creates a tenant with the service role, as in fo_world.sql, so this runs unprivileged-role-free.
select set_config('request.jwt.claims',
  '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', false);
select public.create_restaurant_with_owner('Rival Hotels', 'Rival Inn', 'IN', 'Other Owner', 'Main', 'MN') as other \gset
insert into public.restaurant_modules (restaurant_id, module_key) values (:'other', 'front_office');
set role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', false);
select t.ok('another hotel cannot read our folio', public.fo_folio(:'s1') is null);
select t.ok('another hotel sees no rooms of ours',
  (select count(*) = 0 from jsonb_array_elements(public.fo_room_board()) x));
select t.must_fail('another hotel cannot check our guest in',
  format($$select public.fo_check_in(%L)$$, :'a1'), 'not found');
select t.ok('our stays are invisible under RLS',
  (select count(*) = 0 from public.fo_stays));
