-- ================================================================ batch C part 2: bill to company (migration 170)
reset role;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

-- ---- the company master
select t.must_fail('a company needs a name', $$select public.fo_save_company('  ')$$, 'name');
select t.must_fail('a bad company GSTIN is refused', $$select public.fo_save_company('Acme', '29BAD')$$, 'GSTIN');
select t.must_fail('GSTIN and state must agree', $$select public.fo_save_company('Acme', '29AAACA0000A1Z5', '33')$$, 'starts with');
select t.must_fail('credit days are limited', $$select public.fo_save_company('Acme', null, null, null, null, null, null, 999)$$, 'Credit days');
select public.fo_save_company('Acme Industries Pvt Ltd', '29AAACA0000A1Z5', null, '5 MG Road, Bengaluru 560001', 'Ravi', '9876500300', 'ap@acme.test', 30, 100000) ->> 'company_id' as acme \gset
select t.ok('the company state follows its GSTIN',
  (select state_code = '29' from public.fo_companies where id = :'acme'));
select t.must_fail('the same company name cannot be added twice', $$select public.fo_save_company('  ACME industries pvt ltd ')$$, 'already exists');

-- ---- stays: A pays for the room only; B has everything on the company
select public.fo_save_room_type('CMP', 'Company Room', 4000, 2, 8) ->> 'room_type_id' as cmp \gset
select public.fo_save_room('801', :'cmp', 'Eighth') ->> 'room_id' as r801 \gset
select public.fo_save_room('802', :'cmp', 'Eighth') ->> 'room_id' as r802 \gset
select public.fo_save_guest('Anita Rao', '9876500210') ->> 'guest_id' as ga1 \gset
select public.fo_save_guest('Bharat Nair', '9876500211') ->> 'guest_id' as gb1 \gset
select (:'today'::date + 2) as cdep \gset
select (public.fo_create_stay(:'ga1', :'cmp', :'today'::date, :'cdep'::date) ->> 'stay_id') as sa \gset
select (public.fo_create_stay(:'gb1', :'cmp', :'today'::date, :'cdep'::date) ->> 'stay_id') as sb \gset

select t.must_fail('an unknown company is refused', format($$select public.fo_set_stay_company(%L, gen_random_uuid(), 'room')$$, :'sa'), 'not found');
select t.must_fail('the scope must be room or all', format($$select public.fo_set_stay_company(%L, %L, 'half')$$, :'sa', :'acme'), 'room, or everything');
select t.must_pass('stay A: the company pays the room', format($$select public.fo_set_stay_company(%L, %L, 'room')$$, :'sa', :'acme'));
select t.must_pass('stay B: the company pays everything', format($$select public.fo_set_stay_company(%L, %L, 'all')$$, :'sb', :'acme'));

select public.fo_set_room_status(:'r801', 'clean') is not null as _c1 \gset
select public.fo_set_room_status(:'r802', 'clean') is not null as _c2 \gset
select public.fo_check_in(:'sa', :'r801') is not null as _i1 \gset
select public.fo_check_in(:'sb', :'r802') is not null as _i2 \gset
-- Room charges are posted by the night audit; the test books one directly (4000 + 5% tax).
reset role;
insert into public.fo_charges (restaurant_id, branch_id, stay_id, business_date, kind, description, quantity, unit_amount, net_amount, tax_pct, tax_amount, total_amount)
select :'restaurant_id', :'branch_id', x, :'today'::date, 'room', 'Room charge', 1, 4000, 4000, 5, 200, 4200 from (values (:'sa'::uuid), (:'sb'::uuid)) v(x);
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select public.fo_post_charge(:'sa', 'food', 'Dinner', 500) is not null as _f1 \gset
select public.fo_post_charge(:'sb', 'food', 'Dinner', 500) is not null as _f2 \gset

-- ---- the split
select public.fo_folio(:'sa') as fa \gset
select t.ok('stay A: guest side is the 525 dinner, company side is the 4,200 room',
  (:'fa'::jsonb->'totals'->>'charged')::numeric = 525 and (:'fa'::jsonb->'totals'->>'company_charged')::numeric = 4200
  and (:'fa'::jsonb->'totals'->>'balance')::numeric = 525);
select t.ok('each charge says which side it is on',
  (select count(*) from jsonb_array_elements(:'fa'::jsonb->'charges') c where (c->>'to_company')::boolean and c->>'kind' = 'room') = 1
  and (select count(*) from jsonb_array_elements(:'fa'::jsonb->'charges') c where not (c->>'to_company')::boolean and c->>'kind' = 'food') = 1);
select t.ok('the folio names the company and scope',
  (:'fa'::jsonb->'stay'->'company'->>'name') = 'Acme Industries Pvt Ltd' and (:'fa'::jsonb->'stay'->'company'->>'scope') = 'room');
select public.fo_folio(:'sb') as fb \gset
select t.ok('stay B: nothing falls on the guest', (:'fb'::jsonb->'totals'->>'balance')::numeric = 0
  and (:'fb'::jsonb->'totals'->>'company_charged')::numeric = 4725);
select t.ok('the company owes both stays', (select (x->>'outstanding')::numeric = 8925 from jsonb_array_elements(public.fo_companies_list()) x where x->>'company_id' = :'acme'));

-- ---- check-out follows the guest side only
select t.must_fail('stay A: the guest still owes the dinner', format($$select public.fo_check_out(%L)$$, :'sa'), 'owes');
select public.fo_check_out(:'sa', :'cash_method') as coa \gset
select t.ok('stay A checks out after the guest pays 525', (:'coa'::jsonb->>'collected')::numeric = 525);
select public.fo_check_out(:'sb') as cob \gset
select t.ok('stay B checks out with no payment at all', (:'cob'::jsonb->>'collected')::numeric = 0
  and (select status = 'checked_out' from public.fo_stays where id = :'sb'));

-- ---- two invoices for stay A
select t.must_fail('no company invoice for a stay without a company',
  format($$select public.fo_issue_invoice(%L, null, null, null, null, 'company')$$, :'s1'), 'no company');
select public.fo_issue_invoice(:'sa') as iag \gset
select public.fo_issue_invoice(:'sa', null, null, null, null, 'company') as iac \gset
select t.ok('guest invoice 525, company invoice 4,200, different numbers',
  (:'iag'::jsonb->>'total')::numeric = 525 and (:'iac'::jsonb->>'total')::numeric = 4200
  and (:'iag'::jsonb->>'invoice_no') <> (:'iac'::jsonb->>'invoice_no'));
select public.fo_invoice_for_stay(:'sa', 'company') as vac \gset
select public.fo_invoice_for_stay(:'sa', 'guest') as vag \gset
select t.ok('the company invoice is made out to the company with its GSTIN',
  (:'vac'::jsonb->'snapshot'->'bill_to'->>'name') = 'Acme Industries Pvt Ltd'
  and (:'vac'::jsonb->'snapshot'->'bill_to'->>'gstin') = '29AAACA0000A1Z5' and (:'vac'::jsonb->'snapshot'->>'party') = 'company');
select t.ok('the room is on the company invoice and the dinner on the guest invoice',
  (:'vac'::jsonb->'snapshot'->'lines'->0->>'kind') = 'room' and jsonb_array_length(:'vac'::jsonb->'snapshot'->'lines') = 1
  and (:'vag'::jsonb->'snapshot'->'lines'->0->>'kind') = 'food' and jsonb_array_length(:'vag'::jsonb->'snapshot'->'lines') = 1);
select t.ok('the guest payment is on the guest invoice only',
  jsonb_array_length(:'vag'::jsonb->'snapshot'->'payments') = 1 and jsonb_array_length(:'vac'::jsonb->'snapshot'->'payments') = 0);
select t.ok('issuing again returns the same invoice',
  (public.fo_issue_invoice(:'sa', null, null, null, null, 'company')->>'invoice_no') = (:'iac'::jsonb->>'invoice_no'));
select t.must_fail('the company cannot be changed once invoiced', format($$select public.fo_set_stay_company(%L, null)$$, :'sa'), 'can no longer be changed');

-- ---- stay B: company only
select t.must_fail('stay B has nothing to invoice to the guest', format($$select public.fo_issue_invoice(%L)$$, :'sb'), 'nothing on the guest');
select public.fo_invoice_for_stay(:'sb', 'guest') as vbg \gset
select t.ok('the read says the guest side has no lines', not (:'vbg'::jsonb->>'has_lines')::boolean);
select public.fo_issue_invoice(:'sb', null, null, null, null, 'company') as ibc \gset
select t.ok('stay B company invoice is 4,725', (:'ibc'::jsonb->>'total')::numeric = 4725);

-- ---- the company account
select public.fo_company_ledger(:'acme') as led \gset
select t.ok('ledger: two stays, 8,925 charged, nothing paid, nothing overdue yet',
  jsonb_array_length(:'led'::jsonb->'stays') = 2 and (:'led'::jsonb->'summary'->>'charged')::numeric = 8925
  and (:'led'::jsonb->'summary'->>'outstanding')::numeric = 8925 and (:'led'::jsonb->'summary'->>'overdue')::numeric = 0);
select t.ok('ledger shows the invoice number against the stay',
  exists (select 1 from jsonb_array_elements(:'led'::jsonb->'stays') x where (x->>'invoice_no') = (:'iac'::jsonb->>'invoice_no')));
select t.ok('the credit limit of 100,000 is not exceeded', not (:'led'::jsonb->'summary'->>'over_limit')::boolean);

select t.must_fail('a company payment must be more than zero', format($$select public.fo_take_company_payment(%L, 0)$$, :'acme'), 'more than zero');
select t.must_fail('an unknown company cannot pay', $$select public.fo_take_company_payment(gen_random_uuid(), 100)$$, 'not found');
select public.fo_take_company_payment(:'acme', 1000, :'cash_method', 'NEFT 4411', 'bbbbbbbb-0000-0000-0000-000000000001') as cp1 \gset
select t.ok('a payment of 1,000 leaves 7,925', (:'cp1'::jsonb->>'outstanding')::numeric = 7925);
select t.ok('the same request again changes nothing',
  (public.fo_take_company_payment(:'acme', 1000, :'cash_method', 'NEFT 4411', 'bbbbbbbb-0000-0000-0000-000000000001')->>'repeat')::boolean
  and (select count(*) from public.fo_company_payments where company_id = :'acme') = 1);

-- ---- overdue: make stay A old and the terms strict (due on departure)
reset role;
update public.fo_stays set arrival = :'today'::date - 3, departure = :'today'::date - 1 where id = :'sa';
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select public.fo_save_company('Acme Industries Pvt Ltd', '29AAACA0000A1Z5', null, '5 MG Road, Bengaluru 560001', 'Ravi', '9876500300', 'ap@acme.test', 0, 100000, true, :'acme') is not null as _upd \gset
select public.fo_company_ledger(:'acme') as led2 \gset
select t.ok('overdue is the old stay less the payments: 4,200 - 1,000', (:'led2'::jsonb->'summary'->>'overdue')::numeric = 3200);

select (:'cp1'::jsonb->>'payment_id') as cp1id \gset
select t.must_fail('voiding a company payment needs a reason', format($$select public.fo_void_company_payment(%L, ' ')$$, :'cp1id'), 'reason');
select public.fo_void_company_payment(:'cp1id', 'Bounced') as vp \gset
select t.ok('after the void the full 8,925 is outstanding again and it is all overdue-able',
  (:'vp'::jsonb->>'outstanding')::numeric = 8925 and (public.fo_company_ledger(:'acme')->'summary'->>'overdue')::numeric = 4200);

-- ---- the credit limit warning
select public.fo_save_company('Acme Industries Pvt Ltd', '29AAACA0000A1Z5', null, '5 MG Road, Bengaluru 560001', 'Ravi', '9876500300', 'ap@acme.test', 0, 5000, true, :'acme') is not null as _lim \gset
select t.ok('over the credit limit is flagged', (public.fo_company_ledger(:'acme')->'summary'->>'over_limit')::boolean);

-- ---- a whole group on the company
select (:'today'::date + 100) as ca \gset
select (:'today'::date + 102) as cd \gset
select public.fo_create_group('Acme Offsite', :'ga1', :'ca', :'cd', ('[{"room_type_id":"' || :'cmp' || '","qty":2,"rate":3800}]')::jsonb) ->> 'group_id' as cgid \gset
select (public.fo_set_group_company(:'cgid', :'acme', 'room')->>'rooms')::int as grp_rooms \gset
select t.ok('the group rooms are linked to the company for the room',
  :'grp_rooms'::int = 2
  and (select count(*) from public.fo_stays where group_id = :'cgid' and company_id = :'acme' and company_scope = 'room') = 2);
select t.ok('the group view shows the company on each room',
  (select count(*) from jsonb_array_elements(public.fo_group_view(:'cgid')->'stays') x where x->>'company' = 'Acme Industries Pvt Ltd') = 2);
select s.id as one_g from public.fo_stays s where s.group_id = :'cgid' order by s.stay_no limit 1 \gset
select (public.fo_set_stay_company(:'one_g', null)->>'scope') as off_scope \gset
select t.ok('one room can be taken off the company again',
  :'off_scope' = 'none' and (select company_id is null from public.fo_stays where id = :'one_g'));
select public.fo_save_company('Acme Industries Pvt Ltd', '29AAACA0000A1Z5', null, '5 MG Road, Bengaluru 560001', 'Ravi', '9876500300', 'ap@acme.test', 0, 5000, false, :'acme') is not null as _off \gset
select t.must_fail('a switched-off company cannot be chosen', format($$select public.fo_set_stay_company(%L, %L, 'room')$$, :'one_g', :'acme'), 'switched off');

-- ---- rights
select set_config('request.jwt.claims', '{"sub":"' || :'cashier' || '","role":"authenticated"}', false);
select t.must_fail('cashier cannot add a company', $$select public.fo_save_company('Nope Ltd')$$, 'does not allow');
select t.must_fail('cashier cannot list companies', $$select public.fo_companies_list()$$, 'does not allow');
select t.must_fail('cashier cannot take a company payment', format($$select public.fo_take_company_payment(%L, 10)$$, :'acme'), 'does not allow');
select t.must_fail('cashier cannot read the company account', format($$select public.fo_company_ledger(%L)$$, :'acme'), 'does not allow');
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
