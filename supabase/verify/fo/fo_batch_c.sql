-- ================================================================ batch C part 1: group bookings (migration 169)
reset role;
-- TEST HARNESS ONLY: lets the tests read availability directly.
grant execute on function app.fo_type_free(uuid, uuid, date, date, uuid) to authenticated;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

select (:'today'::date + 90) as ga \gset
select (:'today'::date + 93) as gd \gset
select public.fo_save_room_type('GRP', 'Group Room', 2500, 3, 7) ->> 'room_type_id' as grp \gset
select public.fo_save_room('701', :'grp', 'Seventh') ->> 'room_id' as g701 \gset
select public.fo_save_room('702', :'grp', 'Seventh') ->> 'room_id' as g702 \gset
select public.fo_save_room('703', :'grp', 'Seventh') ->> 'room_id' as g703 \gset
select public.fo_save_guest('Group Contact', '9876500188') ->> 'guest_id' as gc \gset
select public.fo_save_guest('Group Member One', '9876500199') ->> 'guest_id' as gm1 \gset

select t.must_fail('a group needs a name', format($$select public.fo_create_group('  ', %L, %L, %L, %L::jsonb)$$, :'gc', :'ga', :'gd', '[{"room_type_id":"x","qty":1}]'), 'name');
select t.must_fail('a group needs at least one room', format($$select public.fo_create_group('Tour', %L, %L, %L, '[]'::jsonb)$$, :'gc', :'ga', :'gd'), 'at least one room');
select t.must_fail('departure must be after arrival', format($$select public.fo_create_group('Tour', %L, %L, %L, %L::jsonb)$$, :'gc', :'gd', :'ga', '[{"room_type_id":"' || :'grp' || '","qty":1}]'), 'later departure');

-- ---- more rooms than exist: nothing is booked
select count(*) as groups_before from public.fo_groups \gset
select count(*) as stays_before from public.fo_stays \gset
select t.must_fail('four rooms cannot be had when only three exist',
  format($$select public.fo_create_group('Too Big', %L, %L, %L, %L::jsonb)$$, :'gc', :'ga', :'gd', '[{"room_type_id":"' || :'grp' || '","qty":4}]'), 'No Group Room is free');
select t.ok('a failed group books nothing at all',
  (select count(*) from public.fo_groups) = :'groups_before' and (select count(*) from public.fo_stays) = :'stays_before');

-- ---- a real group of two (with a client reference, so a repeated tap is harmless)
select public.fo_create_group('Sharma Wedding', :'gc', :'ga', :'gd',
  ('[{"room_type_id":"' || :'grp' || '","qty":2,"adults":2,"rate":2400}]')::jsonb, 'Bride side', 'corporate',
  'aaaaaaaa-0000-0000-0000-000000000001') as cg \gset
select (:'cg'::jsonb->>'group_id') as gid \gset
select t.ok('the group gets number 1 and two stays', (:'cg'::jsonb->>'group_no')::int = 1 and jsonb_array_length(:'cg'::jsonb->'stays') = 2);
select t.ok('both stays carry the group and the agreed rate',
  (select count(*) from public.fo_stays where group_id = :'gid' and nightly_rate = 2400 and status = 'reserved') = 2);
select t.ok('both stays are under the contact guest until named',
  (select count(*) from public.fo_stays where group_id = :'gid' and guest_id = :'gc') = 2);
select t.ok('the group holds inventory like any booking', app.fo_type_free(:'branch_id', :'grp', :'ga', :'gd') = 1);
select t.ok('a repeated request returns the same group and books nothing more',
  (public.fo_create_group('Sharma Wedding', :'gc', :'ga', :'gd', ('[{"room_type_id":"' || :'grp' || '","qty":2}]')::jsonb, null, 'corporate',
     'aaaaaaaa-0000-0000-0000-000000000001')->>'group_id') = :'gid'
  and (select count(*) from public.fo_stays where group_id = :'gid') = 2);

-- ---- add the last room, then one too many
select public.fo_group_add_rooms(:'gid', ('[{"room_type_id":"' || :'grp' || '","qty":1}]')::jsonb) as ar \gset
select t.ok('adding a room gives the group a third stay', (select count(*) from public.fo_stays where group_id = :'gid') = 3);
select t.must_fail('no room is left to add',
  format($$select public.fo_group_add_rooms(%L, %L::jsonb)$$, :'gid', '[{"room_type_id":"' || :'grp' || '","qty":1}]'), 'No Group Room is free');
select t.ok('the failed add changed nothing', (select count(*) from public.fo_stays where group_id = :'gid') = 3);

-- ---- name a real guest on one room
select s.id as one_stay from public.fo_stays s where s.group_id = :'gid' order by s.stay_no limit 1 \gset
select t.must_fail('an unknown guest is refused', format($$select public.fo_set_stay_guest(%L, gen_random_uuid())$$, :'one_stay'), 'not found');
select t.must_pass('put a real guest on the first room', format($$select public.fo_set_stay_guest(%L, %L)$$, :'one_stay', :'gm1'));
select t.ok('that stay now belongs to the new guest and stays in the group',
  (select guest_id = :'gm1' and group_id = :'gid' from public.fo_stays where id = :'one_stay'));

-- ---- reading it back
select public.fo_group_view(:'gid') as gv \gset
select t.ok('the group view lists three rooms with names, and totals', jsonb_array_length(:'gv'::jsonb->'stays') = 3
  and (:'gv'::jsonb->'totals'->>'rooms')::int = 3 and (:'gv'::jsonb->'group'->>'name') = 'Sharma Wedding'
  and (:'gv'::jsonb->'group'->>'contact_name') = 'Group Contact');
select t.ok('the group view shows the named guest on that room',
  exists (select 1 from jsonb_array_elements(:'gv'::jsonb->'stays') x where x->>'guest_name' = 'Group Member One'));
select t.ok('the active list includes this group with 3 rooms',
  exists (select 1 from jsonb_array_elements(public.fo_groups_list()) x where (x->>'group_id') = :'gid' and (x->>'rooms')::int = 3));
select t.ok('a stay can tell which group it is in',
  (public.fo_stay_group(:'one_stay')->>'group_no')::int = 1);
select t.ok('a single booking has no group', public.fo_stay_group(:'s1') is null);

-- ---- rights
reset role;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', false);
select t.must_fail('a user without front office rights cannot book a group',
  format($$select public.fo_create_group('Nope', %L, %L, %L, %L::jsonb)$$, :'gc', :'ga', :'gd', '[{"room_type_id":"' || :'grp' || '","qty":1}]'), 'does not allow');
select t.must_fail('nor read one', format($$select public.fo_group_view(%L)$$, :'gid'), 'does not allow');
reset role;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

-- ---- cancel the group: an advance holds it up, then it goes through
select public.fo_take_payment(:'one_stay', 500, :'cash_method') is not null as _paid \gset
select t.must_fail('a room with an advance stops the group cancellation',
  format($$select public.fo_cancel_group(%L, 'Event off')$$, :'gid'), 'Refund it');
select t.ok('nothing was half cancelled', (select count(*) from public.fo_stays where group_id = :'gid' and status = 'reserved') = 3);
select t.must_fail('a reason is required', format($$select public.fo_cancel_group(%L, ' ')$$, :'gid'), 'reason');
select public.fo_take_payment(:'one_stay', 500, :'cash_method', null, true) is not null as _refunded \gset
select public.fo_cancel_group(:'gid', 'Event off') as cx \gset
select t.ok('after the refund the whole group cancels', (:'cx'::jsonb->>'cancelled')::int = 3
  and (select count(*) from public.fo_stays where group_id = :'gid' and status = 'cancelled') = 3
  and (select status from public.fo_groups where id = :'gid') = 'cancelled');
select t.ok('the rooms are free again', app.fo_type_free(:'branch_id', :'grp', :'ga', :'gd') = 3);
select t.ok('cancelling twice is harmless', (public.fo_cancel_group(:'gid', 'again')->>'repeat')::boolean);
select t.must_fail('a cancelled group takes no more rooms',
  format($$select public.fo_group_add_rooms(%L, %L::jsonb)$$, :'gid', '[{"room_type_id":"' || :'grp' || '","qty":1}]'), 'cancelled');
select t.ok('the cancelled group leaves the active list',
  not exists (select 1 from jsonb_array_elements(public.fo_groups_list()) x where (x->>'group_id') = :'gid'));
select t.ok('but shows when past groups are included',
  exists (select 1 from jsonb_array_elements(public.fo_groups_list(true)) x where (x->>'group_id') = :'gid'));
