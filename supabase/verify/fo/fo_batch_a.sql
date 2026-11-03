-- ================================================================ batch A (migration 165)
reset role;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

select public.fo_save_room_type('DLX', 'Deluxe', 4000, 3, 3) ->> 'room_type_id' as dlx \gset
select public.fo_save_room('301', :'dlx', 'Third') ->> 'room_id' as r301 \gset
select public.fo_save_room('302', :'dlx', 'Third') ->> 'room_id' as r302 \gset
select public.fo_save_guest('Latha Rao', '9876500044') ->> 'guest_id' as ga \gset
select public.fo_save_guest('Sunil Bose', '9876500055') ->> 'guest_id' as gb \gset
select (:'today'::date + 10) as d10 \gset
select (:'today'::date + 12) as d12 \gset
select (:'today'::date + 13) as d13 \gset
select (:'today'::date + 15) as d15 \gset

-- ---- guest flags and search
select t.ok('availability: both deluxe rooms free before any booking',
  (select (x->>'free')::int = 2 from jsonb_array_elements(public.fo_availability(:'d10'::date, :'d12'::date)) x where x->>'code' = 'DLX'));
select t.must_fail('blocking needs a reason',
  format($$select public.fo_set_guest_flags(%L, null, null, true)$$, :'gb'), 'reason');
select t.must_pass('mark VIP with a preference',
  format($$select public.fo_set_guest_flags(%L, true, 'High floor, no feather pillows')$$, :'ga'));
select t.ok('search by name finds the VIP',
  (select count(*) = 1 and bool_and((x->>'vip')::boolean) from jsonb_array_elements(public.fo_find_guests('latha')) x));
select t.ok('search by phone works',
  (select count(*) = 1 from jsonb_array_elements(public.fo_find_guests('9876500055')) x));
select t.ok('a one-letter search returns nothing', jsonb_array_length(public.fo_find_guests('l')) = 0);
select t.must_pass('block a guest',
  format($$select public.fo_set_guest_flags(%L, null, null, true, 'Damaged property, 2026')$$, :'gb'));
select t.must_fail('a blocked guest cannot be booked',
  format($$select public.fo_create_stay(%L, %L, %L::date, %L::date)$$, :'gb', :'dlx', :'d10', :'d12'), 'blocked');
select t.must_pass('unblock',
  format($$select public.fo_set_guest_flags(%L, null, null, false)$$, :'gb'));
select t.must_pass('an unblocked guest can be booked',
  format($$select public.fo_create_stay(%L, %L, %L::date, %L::date)$$, :'gb', :'dlx', :'d10', :'d12'));

-- ---- amend: future reservation
select (public.fo_create_stay(:'ga', :'dlx', :'d10', :'d12') ->> 'stay_id') as sa \gset
select t.must_fail('an amendment needs a reason',
  format($$select public.fo_amend_stay(%L, %L::date)$$, :'sa', :'d13'), 'reason');
select t.must_pass('extend a reservation by one night',
  format($$select public.fo_amend_stay(%L, %L::date, null, 'Guest asked')$$, :'sa', :'d13'));
select t.ok('departure moved', (select departure = :'d13'::date from public.fo_stays where id = :'sa'));
select t.must_fail('departure cannot precede arrival',
  format($$select public.fo_amend_stay(%L, %L::date, null, 'x')$$, :'sa', :'d10'), 'after arrival');
select t.must_pass('change the rate',
  format($$select public.fo_amend_stay(%L, null, 3500, 'Corporate rate')$$, :'sa'));
select t.ok('rate changed', (select nightly_rate = 3500 from public.fo_stays where id = :'sa'));

-- two Deluxe rooms, two bookings on those dates (gb's and sa): a third has nothing to take
select t.must_fail('no third deluxe room, though no room is assigned yet',
  format($$select public.fo_create_stay(%L, %L, %L::date, %L::date)$$, :'ga', :'dlx', :'d10', :'d13'), 'No Deluxe');
select t.ok('availability: no deluxe room left on those nights',
  (select (x->>'free')::int = 0 from jsonb_array_elements(public.fo_availability(:'d10'::date, :'d12'::date)) x where x->>'code' = 'DLX'));
select t.must_pass('extension into nights that are free is allowed',
  format($$select public.fo_amend_stay(%L, %L::date, null, 'Stays on')$$, :'sa', :'d15'));

-- ---- amend: in-house stay, extension blocked by the next booking
reset role;
update public.fo_rooms set housekeeping_status = 'clean' where id in (:'r301', :'r302');
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select (public.fo_create_stay(:'ga', :'dlx', :'today'::date, :'dep1'::date) ->> 'stay_id') as sc \gset
select public.fo_check_in(:'sc', :'r301') ->> 'room_number' as rn \gset
select t.ok('in-house in 301', :'rn' = '301');
select t.must_pass('extend an in-house stay by a night',
  format($$select public.fo_amend_stay(%L, %L::date, null, 'Late flight')$$, :'sc', :'dep2'));
select t.must_pass('shorten back to tomorrow',
  format($$select public.fo_amend_stay(%L, %L::date, null, 'Flight on time')$$, :'sc', :'dep1'));
reset role;
update public.fo_stays set arrival = :'today'::date - 2 where id = :'sc';
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select t.must_fail('cannot leave before today',
  format($$select public.fo_amend_stay(%L, %L::date, null, 'x')$$, :'sc', :'today'::date - 1), 'before today');

-- ---- housekeeping list and assignment
select t.ok('hk list: 301 is a departure-or-stayover with a guest',
  (select (x->>'occupied')::boolean and x->>'task' in ('departure', 'stayover')
     from jsonb_array_elements(public.fo_hk_list()) x where x->>'room_number' = '301'));
select t.ok('hk list: 302 is clean but not yet inspected',
  (select x->>'task' = 'to_inspect' from jsonb_array_elements(public.fo_hk_list()) x where x->>'room_number' = '302'));
select t.must_pass('inspect 302', format($$select public.fo_set_room_status(%L, 'inspected')$$, :'r302'));
select t.ok('hk list: 302 is ready',
  (select x->>'task' = 'ready' and (x->>'inspected')::boolean
     from jsonb_array_elements(public.fo_hk_list()) x where x->>'room_number' = '302'));
select t.must_pass('mark 302 dirty', format($$select public.fo_set_room_status(%L, 'dirty')$$, :'r302'));
select t.ok('dirty removes the inspected mark',
  (select not hk_inspected and housekeeping_status = 'dirty' from public.fo_rooms where id = :'r302'));
select t.ok('hk list: 302 is vacant dirty',
  (select x->>'task' = 'vacant_dirty' from jsonb_array_elements(public.fo_hk_list()) x where x->>'room_number' = '302'));
select id as staff_id from public.users where restaurant_id = :'restaurant_id' and employee_code = 'EMP002' \gset
select t.must_pass('assign 302 to an attendant',
  format($$select public.fo_hk_assign(array[%L]::uuid[], %L, 'Deep clean')$$, :'r302', :'staff_id'));
select t.ok('attendant shows on the list',
  (select x->>'attendant' = 'Cashier FO' and x->>'note' = 'Deep clean'
     from jsonb_array_elements(public.fo_hk_list()) x where x->>'room_number' = '302'));
select t.must_fail('cannot assign to a stranger',
  format($$select public.fo_hk_assign(array[%L]::uuid[], gen_random_uuid())$$, :'r302'), 'not found');
select t.must_fail('a status other than clean, dirty, inspected is refused',
  format($$select public.fo_set_room_status(%L, 'sparkling')$$, :'r302'), 'clean, dirty or inspected');

-- ---- move a charge between folios
select (public.fo_create_stay(:'gb', :'std', :'today'::date, :'dep1'::date) ->> 'stay_id') as sd \gset
select public.fo_post_charge(:'sc', 'food', 'Shared dinner', 1000) ->> 'charge_id' as chg \gset
select t.must_fail('a transfer needs a reason',
  format($$select public.fo_move_charge(%L, %L, '')$$, :'chg', :'sd'), 'reason');
select t.must_pass('move the dinner to the other guest',
  format($$select public.fo_move_charge(%L, %L, 'Host pays')$$, :'chg', :'sd'));
select t.ok('moved: balances follow', app.fo_balance(:'sd') = 1050 and app.fo_balance(:'sc') = 0);
select t.must_fail('moving to the same folio is refused',
  format($$select public.fo_move_charge(%L, %L, 'x')$$, :'chg', :'sd'), 'already on this folio');

-- ---- chart
select t.ok('chart: 2 deluxe rooms and our stays on them',
  (select jsonb_array_length(c->'rooms') >= 5 from (select public.fo_chart(:'today'::date, 14) c) q));
select t.ok('chart: room 301 shows the in-house stay',
  (select jsonb_array_length(r->'stays') >= 1
     from jsonb_array_elements(public.fo_chart(:'today'::date, 14)->'rooms') r where r->>'room_number' = '301'));
select t.ok('chart: day span is capped at 62',
  (public.fo_chart(:'today'::date, 500) ->> 'days')::int = 62);

-- ---- rights: the cashier has no front office right
select set_config('request.jwt.claims', '{"sub":"' || :'cashier' || '","role":"authenticated"}', false);
select t.must_fail('cashier cannot amend', format($$select public.fo_amend_stay(%L, null, 1, 'x')$$, :'sc'), 'does not allow');
select t.must_fail('cashier cannot see the hk list', 'select public.fo_hk_list()', 'does not allow');
select t.must_fail('cashier cannot search guests', $$select public.fo_find_guests('latha')$$, 'does not allow');
select t.must_fail('cashier cannot see the chart', 'select public.fo_chart()', 'does not allow');
