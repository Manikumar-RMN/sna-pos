-- ================================================================ batch B: rate plans (migration 167)
reset role;
select (:'today'::date + 30 + ((5 - extract(isodow from :'today'::date + 30)::int + 7) % 7)) as fri \gset
select (:'fri'::date + 1) as sat \gset
select (:'fri'::date + 2) as sun \gset
select (:'fri'::date + 3) as mon \gset
select (:'fri'::date + 4) as tue \gset
select (:'fri'::date + 7) as fri2 \gset
select (:'fri'::date + 9) as sun2 \gset
select (:'fri'::date + 10) as mon2 \gset
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

select public.fo_save_room_type('PLX', 'Plan Room', 3000, 3, 9) ->> 'room_type_id' as plx \gset
select public.fo_save_room('401', :'plx', 'Fourth') ->> 'room_id' as r401 \gset
select public.fo_save_room('402', :'plx', 'Fourth') ->> 'room_id' as r402 \gset
select public.fo_save_guest('Meera Iyer', '9876500166') ->> 'guest_id' as gm \gset
select public.fo_save_guest('Vikram Shah', '9876500177') ->> 'guest_id' as gv \gset

-- ---- the plan and its rules
select t.must_fail('a plan needs a code', $$select public.fo_save_rate_plan('', 'x')$$, 'code');
select t.must_fail('a plan needs a valid meal plan', $$select public.fo_save_rate_plan('X', 'x', 'ZZ')$$, 'Meal plan');
select public.fo_save_rate_plan('bar', 'Best available', 'CP', 'Room with breakfast') ->> 'rate_plan_id' as bar \gset
select t.ok('plan code is upper-cased', (select code = 'BAR' from public.fo_rate_plans where id = :'bar'));
select t.must_fail('a rule cannot have a negative rate',
  format($$select public.fo_save_rate_rule(%L, %L, -1)$$, :'bar', :'plx'), 'rate of zero or more');
select t.must_fail('a season cannot end before it starts',
  format($$select public.fo_save_rate_rule(%L, %L, 5000, null, null, 2, 0, 0, %L::date, %L::date)$$, :'bar', :'plx', :'mon', :'fri'), 'ends before');
select public.fo_save_rate_rule(:'bar', :'plx', 5000, 7000, 4500, 2, 1000, 500) ->> 'rule_id' as rule_open \gset
select public.fo_save_rate_rule(:'bar', :'plx', 9000, null, null, 2, 0, 0, :'sun'::date, :'sun'::date) ->> 'rule_id' as rule_peak \gset

-- ---- quotes
select public.fo_quote(:'plx', :'fri'::date, :'mon'::date, 2, 0) as q2 \gset
select t.ok('quote: the standard rate is always offered',
  (select o->>'code' = 'RACK' and (o->>'total')::numeric = 9000 from jsonb_array_elements(:'q2'::jsonb->'options') o limit 1));
select t.ok('quote: weekend nights and the peak season night are priced separately (7000 + 7000 + 9000)',
  (select (o->>'total')::numeric = 23000 and (o->>'available')::boolean
     from jsonb_array_elements(:'q2'::jsonb->'options') o where o->>'code' = 'BAR'));
select t.ok('quote: three nights listed with the right rates',
  (select array_agg((n->>'rate')::numeric order by n->>'night') = array[7000, 7000, 9000]::numeric[]
     from jsonb_array_elements(:'q2'::jsonb->'options') o, jsonb_array_elements(o->'nights') n where o->>'code' = 'BAR'));
select public.fo_quote(:'plx', :'fri'::date, :'mon'::date, 1, 0) as q1 \gset
select t.ok('quote: one adult takes the single rate (4500, 4500) and the peak night 9000',
  (select (o->>'total')::numeric = 18000 from jsonb_array_elements(:'q1'::jsonb->'options') o where o->>'code' = 'BAR'));
select public.fo_quote(:'plx', :'fri'::date, :'mon'::date, 3, 0) as q3 \gset
select t.ok('quote: a third adult adds 1000 a night on the open rule only (8000 + 8000 + 9000)',
  (select (o->>'total')::numeric = 25000 from jsonb_array_elements(:'q3'::jsonb->'options') o where o->>'code' = 'BAR'));
select public.fo_quote(:'plx', :'mon'::date, :'tue'::date, 2, 1) as qc \gset
select t.ok('quote: a child adds 500 on a weekday (5000 + 500)',
  (select (o->>'total')::numeric = 5500 from jsonb_array_elements(:'qc'::jsonb->'options') o where o->>'code' = 'BAR'));
select t.must_fail('a quote needs a later departure',
  format($$select public.fo_quote(%L, %L::date, %L::date)$$, :'plx', :'mon', :'fri'), 'later departure');

-- a plan that prices only some nights is shown as unavailable, with the reason
select public.fo_save_rate_plan('SUM', 'Summer special', 'EP') ->> 'rate_plan_id' as summ \gset
select public.fo_save_rate_rule(:'summ', :'plx', 3500, null, null, 2, 0, 0, :'fri'::date, :'sat'::date) ->> 'rule_id' as rule_sum \gset
select public.fo_quote(:'plx', :'fri'::date, :'mon'::date, 2, 0) as qs \gset
select t.ok('quote: a plan with a gap is listed as unavailable with a reason',
  (select not (o->>'available')::boolean and o->>'reason' like 'No rate for%'
     from jsonb_array_elements(:'qs'::jsonb->'options') o where o->>'code' = 'SUM'));
select t.must_fail('a stay cannot be booked on a plan that has a gap',
  format($$select public.fo_create_stay(%L, %L, %L::date, %L::date, null, 2, 0, 'phone', null, null, %L)$$,
         :'gm', :'plx', :'fri', :'mon', :'summ'), 'has no rate');

-- ---- booking on a plan stores every night
select (public.fo_create_stay(:'gm', :'plx', :'fri'::date, :'mon'::date, null, 2, 0, 'phone', null, null, :'bar') ->> 'stay_id') as sp \gset
select t.ok('stay on a plan: the three nightly rates are stored',
  (select count(*) = 3 and sum(rate) = 23000 from public.fo_stay_rates where stay_id = :'sp'));
select t.ok('stay on a plan: the headline nightly rate is the first night',
  (select nightly_rate = 7000 and rate_plan_id = :'bar' from public.fo_stays where id = :'sp'));
select public.fo_folio(:'sp') as fp \gset
select t.ok('folio shows the plan, its meal plan and the rate schedule',
  (:'fp'::jsonb->'stay'->>'rate_plan_code') = 'BAR' and (:'fp'::jsonb->'stay'->>'meal_plan') = 'CP'
  and jsonb_array_length(:'fp'::jsonb->'stay'->'rate_schedule') = 3);

-- a manual rate overrides the plan and is flat
select (public.fo_create_stay(:'gv', :'plx', :'fri'::date, :'mon'::date, 6000, 2, 0, 'phone', null, null, :'bar') ->> 'stay_id') as so \gset
select t.ok('manual rate on a plan: flat, no per-night rows, the plan is still recorded',
  (select nightly_rate = 6000 and rate_plan_id = :'bar' from public.fo_stays where id = :'so')
  and not exists (select 1 from public.fo_stay_rates where stay_id = :'so'));

-- both rooms of the type are now held on those nights
select t.must_fail('no third room of the type on the same nights',
  format($$select public.fo_create_stay(%L, %L, %L::date, %L::date)$$, :'gm', :'plx', :'fri', :'sat'), 'No Plan Room');

-- ---- amending a plan stay keeps the nights true
select t.must_pass('extend the plan stay by one weekday night',
  format($$select public.fo_amend_stay(%L, %L::date, null, 'Stays on')$$, :'sp', :'tue'));
select t.ok('the new night takes the plan weekday rate (5000), the others are untouched',
  (select count(*) = 4 and (select rate from public.fo_stay_rates where stay_id = :'sp' and night = :'mon'::date) = 5000
          and sum(rate) = 28000 from public.fo_stay_rates where stay_id = :'sp'));
select t.must_pass('shorten the plan stay back to Monday',
  format($$select public.fo_amend_stay(%L, %L::date, null, 'Changed mind')$$, :'sp', :'mon'));
select t.ok('the dropped night loses its rate row',
  (select count(*) = 3 from public.fo_stay_rates where stay_id = :'sp'));
select t.must_pass('change to a flat rate',
  format($$select public.fo_amend_stay(%L, null, 6500, 'Negotiated')$$, :'sp'));
select t.ok('a flat rate replaces the stored nights for the stay still to come',
  (select nightly_rate = 6500 from public.fo_stays where id = :'sp')
  and not exists (select 1 from public.fo_stay_rates where stay_id = :'sp'));

-- ---- deleting a rule never rewrites a booked stay
select (public.fo_create_stay(:'gm', :'plx', :'fri2'::date, :'mon2'::date, null, 2, 0, 'phone', null, null, :'bar') ->> 'stay_id') as sq \gset
select t.must_pass('delete the peak rule', format($$select public.fo_delete_rate_rule(%L)$$, :'rule_peak'));
select t.ok('the booked stay keeps its stored rates (7000 + 7000 + 5000: the peak season was one Sunday only)',
  (select count(*) = 3 and sum(rate) = 19000 from public.fo_stay_rates where stay_id = :'sq'));
select t.must_fail('deleting a rule twice says so', format($$select public.fo_delete_rate_rule(%L)$$, :'rule_peak'), 'not found');
select t.ok('setup lists the plans with their rules',
  (select jsonb_array_length(p->'rules') = 1 from jsonb_array_elements(public.fo_rate_setup()->'plans') p where p->>'code' = 'BAR'));

-- ---- the night audit posts the stored rate of that night, and the slab follows the rate
reset role;
select t.ok('slab: below 1000 a night carries no GST', app.fo_room_tax_pct(:'branch_id', 999) = 0);
select t.ok('slab: 1000 is taxed at 5%', app.fo_room_tax_pct(:'branch_id', 1000) = 5);
select t.ok('slab: 7500 is still 5%', app.fo_room_tax_pct(:'branch_id', 7500) = 5);
select t.ok('slab: above 7500 is 18%', app.fo_room_tax_pct(:'branch_id', 7501) = 18);
select (public.fo_save_settings(null, null, null, null, null, null) is not null) as _s \gset
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select (public.fo_create_stay(:'gv', :'plx', :'today'::date, :'dep1'::date, null, 2, 0, 'walk_in', null, null, :'bar') ->> 'stay_id') as sn \gset
select public.fo_check_in(:'sn', :'r401') ->> 'room_number' as rnn \gset
reset role;
delete from public.fo_night_audits where branch_id = :'branch_id' and business_date = :'today'::date;
select case when extract(isodow from :'today'::date) in (5, 6) then 7000 else 5000 end as expect_rate \gset
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select public.fo_night_audit_run() ->> 'repeat' as rpt \gset
select t.ok('night audit ran again for the date after its row was cleared', :'rpt' = 'false');
select t.ok('night audit posted tonight''s plan rate and its 5% slab',
  (select unit_amount = :'expect_rate'::numeric and tax_pct = 5 from public.fo_charges
    where stay_id = :'sn' and kind = 'room' and business_date = :'today'::date and voided_at is null));
select t.ok('and no stay was charged twice for the night',
  not exists (select 1 from public.fo_charges where kind = 'room' and business_date = :'today'::date and voided_at is null
              group by stay_id having count(*) > 1));

-- ---- rights
select set_config('request.jwt.claims', '{"sub":"' || :'cashier' || '","role":"authenticated"}', false);
select t.must_fail('cashier cannot save a plan', $$select public.fo_save_rate_plan('Z', 'Z')$$, 'does not allow');
select t.must_fail('cashier cannot quote', format($$select public.fo_quote(%L, %L::date, %L::date)$$, :'plx', :'fri', :'mon'), 'does not allow');
select t.must_fail('cashier cannot read the rate setup', 'select public.fo_rate_setup()', 'does not allow');
