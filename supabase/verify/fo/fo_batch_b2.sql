-- ================================================================ batch B part 2: GST invoice and registration card (migration 168)
reset role;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

-- ---- business details are required before an invoice
select t.must_fail('no invoice before the hotel details are filled in',
  format($$select public.fo_issue_invoice(%L)$$, :'s1'), 'legal name and address');
select t.must_fail('a bad GSTIN is refused', $$select public.fo_save_business('Sunrise Residency', '33BADGSTIN')$$, 'GSTIN');
select t.must_fail('GSTIN and state code must agree',
  $$select public.fo_save_business('Sunrise Residency', '33AAACA0000A1Z5', '29')$$, 'must match');
select t.must_fail('prefix is at most four letters or digits',
  $$select public.fo_save_business('Sunrise Residency', null, null, null, null, null, 'TOOLONG')$$, 'prefix');
select t.must_pass('save the hotel details without a GSTIN first',
  $$select public.fo_save_business('Sunrise Hotels Pvt Ltd', null, '33', '12 Beach Road, Chennai 600001', '044-5550100', 'desk@sunrise.test', 'SR', 'Thank you for staying with us')$$);
select t.must_fail('a folio with GST cannot be invoiced without the hotel GSTIN',
  format($$select public.fo_issue_invoice(%L)$$, :'s1'), 'GSTIN is needed');
select t.must_pass('now add the GSTIN (state code follows from it)',
  $$select public.fo_save_business(null, '33AAACA0000A1Z5')$$);
select t.ok('the saved settings carry the details',
  (select gstin = '33AAACA0000A1Z5' and state_code = '33' and invoice_prefix = 'SR' from public.fo_branch_settings where branch_id = :'branch_id'));
select t.ok('fo_setup returns the business details',
  (public.fo_setup()->'settings'->>'legal_name') = 'Sunrise Hotels Pvt Ltd');

-- ---- an in-house stay cannot be invoiced
select t.must_fail('an in-house stay has no invoice yet',
  format($$select public.fo_issue_invoice(%L)$$, :'sn'), 'after check-out');
select public.fo_invoice_for_stay(:'sn') as pre \gset
select t.ok('before issue the read says not issued, with a prefill',
  not (:'pre'::jsonb->>'issued')::boolean and (:'pre'::jsonb->'prefill'->>'name') = 'Vikram Shah');

-- ---- a consumer invoice (B2C) on a checked-out stay
select public.fo_folio(:'s1') as f1 \gset
select public.fo_issue_invoice(:'s1') as i1 \gset
select t.ok('invoice number: prefix / financial year / six digits',
  (:'i1'::jsonb->>'invoice_no') ~ '^SR/[0-9]{4}/000001$' and length(:'i1'::jsonb->>'invoice_no') <= 16);
select t.ok('invoice total equals the folio total charged',
  (:'i1'::jsonb->>'total')::numeric = (:'f1'::jsonb->'totals'->>'charged')::numeric);
select t.ok('issuing again returns the same invoice',
  (public.fo_issue_invoice(:'s1')->>'invoice_no') = (:'i1'::jsonb->>'invoice_no')
  and (public.fo_issue_invoice(:'s1')->>'repeat')::boolean);
select public.fo_invoice_for_stay(:'s1') as v1 \gset
select t.ok('the issued invoice lists every live charge and a tax summary that adds up',
  jsonb_array_length(:'v1'::jsonb->'snapshot'->'lines') = (select count(*) from public.fo_charges where stay_id = :'s1' and voided_at is null)
  and (select sum((x->>'cgst')::numeric + (x->>'sgst')::numeric) = (:'v1'::jsonb->'snapshot'->'totals'->>'tax')::numeric
         from jsonb_array_elements(:'v1'::jsonb->'snapshot'->'tax_summary') x));
select t.ok('supply is intra-state, so tax is CGST + SGST',
  (:'v1'::jsonb->'snapshot'->'supply'->>'type') = 'intra');
select t.ok('the invoice carries the hotel GSTIN and legal name',
  (:'v1'::jsonb->'snapshot'->'property'->>'gstin') = '33AAACA0000A1Z5'
  and (:'v1'::jsonb->'snapshot'->'property'->>'legal_name') = 'Sunrise Hotels Pvt Ltd');

-- ---- a business invoice (B2B)
select t.must_fail('a GSTIN needs a business name',
  format($$select public.fo_issue_invoice(%L, null, '29AAACA0000A1Z5')$$, :'s2'), 'business name');
select t.must_fail('a malformed buyer GSTIN is refused',
  format($$select public.fo_issue_invoice(%L, 'Acme Pvt Ltd', '29BAD')$$, :'s2'), 'GSTIN');
select t.must_fail('buyer GSTIN and state code must agree',
  format($$select public.fo_issue_invoice(%L, 'Acme Pvt Ltd', '29AAACA0000A1Z5', 'Bengaluru', '33')$$, :'s2'), 'starts with');
select t.must_pass('issue to a company',
  format($$select public.fo_issue_invoice(%L, 'Acme Pvt Ltd', '29AAACA0000A1Z5', 'Bengaluru')$$, :'s2'));
select t.ok('the company is on the invoice and the second number follows the first',
  (select bill_to_name = 'Acme Pvt Ltd' and bill_to_gstin = '29AAACA0000A1Z5' and bill_to_state_code = '29' and seq = 2
     and invoice_no = 'SR/' || fy || '/000002' from public.fo_invoices where stay_id = :'s2'));
select t.ok('the guest remembers the company for next time',
  (select bill_gstin = '29AAACA0000A1Z5' from public.fo_guests where id = (select guest_id from public.fo_stays where id = :'s2')));

-- ---- a large bill to a guest without GSTIN needs an address and a state
select (public.fo_create_stay(:'gm', :'plx', :'today'::date, :'dep1'::date) ->> 'stay_id') as sbig \gset
select public.fo_check_in(:'sbig', :'r402') ->> 'room_number' as rbig \gset
select public.fo_post_charge(:'sbig', 'misc', 'Banquet hall hire', 60000) ->> 'total' as bigtot \gset
select t.ok('the big charge is 63,000 with 5% tax', :'bigtot'::numeric = 63000);
select t.must_pass('check out with cash', format($$select public.fo_check_out(%L, %L)$$, :'sbig', :'cash_method'));
select t.must_fail('50,000 or more with no GSTIN: address and state are required',
  format($$select public.fo_issue_invoice(%L)$$, :'sbig'), 'address and state');
select t.must_pass('with address and state it goes through',
  format($$select public.fo_issue_invoice(%L, null, null, '4 Lake View, Madurai', '33')$$, :'sbig'));
select t.ok('the guest''s own name is on a consumer invoice',
  (select bill_to_name = 'Meera Iyer' from public.fo_invoices where stay_id = :'sbig'));

-- ---- an issued invoice can never be changed
reset role;
select t.must_fail('an invoice cannot be updated, even by a superuser',
  format($$update public.fo_invoices set total = 1 where stay_id = %L$$, :'s1'), 'cannot be changed');
select t.must_fail('an invoice cannot be deleted',
  format($$delete from public.fo_invoices where stay_id = %L$$, :'s1'), 'cannot be changed');
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select t.must_fail('and a charge on an invoiced folio cannot be voided',
  format($$select public.fo_void_charge((select id from public.fo_charges where stay_id = %L and voided_at is null limit 1), 'oops')$$, :'s1'), 'closed');

-- ---- register
select public.fo_invoice_register(:'today'::date - 1, :'today'::date + 1) as reg \gset
select t.ok('register lists the three invoices and their totals add up',
  (:'reg'::jsonb->'totals'->>'count')::int = 3
  and (:'reg'::jsonb->'totals'->>'total')::numeric = (select sum(total) from public.fo_invoices where branch_id = :'branch_id'));
select t.must_fail('register range is limited to a year',
  $$select public.fo_invoice_register('2020-01-01', '2026-12-31')$$, 'one year');

-- ---- registration card
select public.fo_reg_card(:'sn') as rc \gset
select t.ok('registration card: guest, room and property are on it',
  (:'rc'::jsonb->'guest'->>'full_name') = 'Vikram Shah' and (:'rc'::jsonb->'stay'->>'room_number') = '401'
  and (:'rc'::jsonb->'property'->>'gstin') = '33AAACA0000A1Z5' and (:'rc'::jsonb->'stay'->>'rate_plan') = 'Best available');
select t.ok('registration card for an unknown stay is null', public.fo_reg_card(gen_random_uuid()) is null);

-- ---- rights
select set_config('request.jwt.claims', '{"sub":"' || :'cashier' || '","role":"authenticated"}', false);
select t.must_fail('cashier cannot issue an invoice', format($$select public.fo_issue_invoice(%L)$$, :'s2'), 'does not allow');
select t.must_fail('cashier cannot save business details', $$select public.fo_save_business('x')$$, 'does not allow');
select t.must_fail('cashier cannot read the register', $$select public.fo_invoice_register(current_date, current_date)$$, 'does not allow');
select t.must_fail('cashier cannot open a registration card', format($$select public.fo_reg_card(%L)$$, :'sn'), 'does not allow');
