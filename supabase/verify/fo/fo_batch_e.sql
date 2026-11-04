-- ================================================================ batch E: credit notes and early/late fees (migration 172)
reset role;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

-- ---- what can be credited on stay A's guest invoice
select (:'iag'::jsonb ->> 'invoice_id') as inv_g \gset
select (:'iac'::jsonb ->> 'invoice_id') as inv_c \gset
select public.fo_credit_note_options(:'inv_g') as opt \gset
select t.ok('the options list the invoice rows with nothing credited yet',
  jsonb_array_length(:'opt'::jsonb -> 'rows') >= 1 and (select bool_and((x ->> 'credited_taxable')::numeric = 0 and x ->> 'remaining_taxable' = x ->> 'taxable') from jsonb_array_elements(:'opt'::jsonb -> 'rows') x));
select t.ok('the deadline is 30 November after the end of the financial year',
  (:'opt'::jsonb ->> 'deadline')::date = make_date((select substr(fy, 1, 2)::int + 2001 from public.fo_invoices where id = :'inv_g'), 11, 30));
select (:'opt'::jsonb -> 'rows' -> 0 ->> 'sac') as sac0, (:'opt'::jsonb -> 'rows' -> 0 ->> 'tax_pct')::numeric as pct0,
       (:'opt'::jsonb -> 'rows' -> 0 ->> 'taxable')::numeric as tx0, (:'opt'::jsonb -> 'rows' -> 0 ->> 'tax')::numeric as tax0 \gset
select (:'tx0'::numeric / 2) as half \gset

-- ---- refusals
select t.must_fail('a reason is needed', format($$select public.fo_issue_credit_note(%L, ' ', %L::jsonb)$$, :'inv_g', format('[{"sac":"%s","tax_pct":%s,"taxable":10}]', :'sac0', :'pct0')), 'reason');
select t.must_fail('something to credit is needed', format($$select public.fo_issue_credit_note(%L, 'Rate error', '[]'::jsonb)$$, :'inv_g'), 'Choose what');
select t.must_fail('a row that is not on the invoice is refused', format($$select public.fo_issue_credit_note(%L, 'x', '[{"sac":"000000","tax_pct":5,"taxable":10}]'::jsonb)$$, :'inv_g'), 'no 000000 line');
select t.must_fail('zero is refused', format($$select public.fo_issue_credit_note(%L, 'x', %L::jsonb)$$, :'inv_g', format('[{"sac":"%s","tax_pct":%s,"taxable":0}]', :'sac0', :'pct0')), 'more than zero');
select t.must_fail('three decimals are refused', format($$select public.fo_issue_credit_note(%L, 'x', %L::jsonb)$$, :'inv_g', format('[{"sac":"%s","tax_pct":%s,"taxable":10.005}]', :'sac0', :'pct0')), 'two decimals');
select t.must_fail('more than was invoiced is refused', format($$select public.fo_issue_credit_note(%L, 'x', %L::jsonb)$$, :'inv_g', format('[{"sac":"%s","tax_pct":%s,"taxable":%s}]', :'sac0', :'pct0', :'tx0'::numeric + 1)), 'at most');
select t.must_fail('a company invoice cannot be credited yet', format($$select public.fo_issue_credit_note(%L, 'x', %L::jsonb)$$, :'inv_c', format('[{"sac":"%s","tax_pct":%s,"taxable":10}]', :'sac0', :'pct0')), 'company invoice');

-- ---- a partial credit, then the rest of that row
select gen_random_uuid() as cnref \gset
select public.fo_issue_credit_note(:'inv_g', 'Room rate was wrong', format('[{"sac":"%s","tax_pct":%s,"taxable":%s}]', :'sac0', :'pct0', :'half')::jsonb, :'cnref') as cn1 \gset
select t.ok('the first note has its own number in the credit note series',
  (:'cn1'::jsonb ->> 'note_no') ~ '/CN/[0-9]{4}/000001$');
select t.ok('its tax is the rate on the credited value',
  (select taxable = :'half'::numeric and tax = round(:'half'::numeric * :'pct0'::numeric / 100, 2) and total = taxable + tax from public.fo_credit_notes where id = (:'cn1'::jsonb ->> 'note_id')::uuid));
select t.ok('the same client reference does not raise a second note',
  (public.fo_issue_credit_note(:'inv_g', 'Room rate was wrong', format('[{"sac":"%s","tax_pct":%s,"taxable":%s}]', :'sac0', :'pct0', :'half')::jsonb, :'cnref') ->> 'repeat')::boolean
  and (select count(*) from public.fo_credit_notes where invoice_id = :'inv_g') = 1);
select t.must_fail('more than what is left is refused', format($$select public.fo_issue_credit_note(%L, 'x', %L::jsonb)$$, :'inv_g', format('[{"sac":"%s","tax_pct":%s,"taxable":%s}]', :'sac0', :'pct0', :'half'::numeric + 1)), 'at most');
select public.fo_issue_credit_note(:'inv_g', 'The rest of the rate error', format('[{"sac":"%s","tax_pct":%s,"taxable":%s}]', :'sac0', :'pct0', :'tx0'::numeric - :'half'::numeric)::jsonb) as cn2 \gset
select t.ok('crediting the whole row takes back exactly the invoiced tax, no paisa left',
  (select sum(tax) from public.fo_credit_notes where invoice_id = :'inv_g') = :'tax0'::numeric
  and (select sum(taxable) from public.fo_credit_notes where invoice_id = :'inv_g') = :'tx0'::numeric);
select t.ok('the second note is number 2', (:'cn2'::jsonb ->> 'note_no') ~ '/CN/[0-9]{4}/000002$');
select t.must_fail('nothing is left on that row', format($$select public.fo_issue_credit_note(%L, 'x', %L::jsonb)$$, :'inv_g', format('[{"sac":"%s","tax_pct":%s,"taxable":1}]', :'sac0', :'pct0')), 'at most');
select public.fo_credit_note_options(:'inv_g') as opt2 \gset
select t.ok('the options now show it fully credited and list both notes',
  (:'opt2'::jsonb -> 'rows' -> 0 ->> 'remaining_taxable')::numeric = 0 and jsonb_array_length(:'opt2'::jsonb -> 'notes') = 2);
select t.ok('the printed note carries the invoice it is against and the reason',
  (public.fo_credit_note_get((:'cn1'::jsonb ->> 'note_id')::uuid) -> 'snapshot' -> 'against' ->> 'invoice_no') = (select invoice_no from public.fo_invoices where id = :'inv_g')
  and (public.fo_credit_note_get((:'cn1'::jsonb ->> 'note_id')::uuid) -> 'snapshot' ->> 'reason') = 'Room rate was wrong');

-- ---- the register and the GST report
select public.fo_credit_note_register((:'today'::date - 100), (:'today'::date + 100)) as cnreg \gset
select t.ok('the credit note register lists both notes with totals',
  (:'cnreg'::jsonb -> 'totals' ->> 'count')::int = 2 and (:'cnreg'::jsonb -> 'totals' ->> 'tax')::numeric = :'tax0'::numeric);
select public.fo_report_gst((:'today'::date - 100), (:'today'::date + 100)) as gst2 \gset
select t.ok('the GST report shows credit notes and the net after them',
  (:'gst2'::jsonb -> 'credit_totals' ->> 'count')::int = 2
  and (:'gst2'::jsonb -> 'net' ->> 'tax')::numeric = (:'gst2'::jsonb -> 'totals' ->> 'tax')::numeric - (:'gst2'::jsonb -> 'credit_totals' ->> 'tax')::numeric
  and (:'gst2'::jsonb -> 'net' ->> 'taxable')::numeric = (:'gst2'::jsonb -> 'totals' ->> 'taxable')::numeric - (:'gst2'::jsonb -> 'credit_totals' ->> 'taxable')::numeric);

-- ---- rights and immutability
select set_config('request.jwt.claims', '{"sub":"' || :'cashier' || '","role":"authenticated"}', false);
select t.must_fail('cashier cannot raise a credit note', format($$select public.fo_issue_credit_note(%L, 'x', '[{"sac":"1","tax_pct":5,"taxable":1}]'::jsonb)$$, :'inv_g'), 'does not allow');
select t.must_fail('cashier cannot read credit note options', format($$select public.fo_credit_note_options(%L)$$, :'inv_g'), 'does not allow');
select t.must_fail('cashier cannot read the register', format($$select public.fo_credit_note_register(%L, %L)$$, :'today', :'today'), 'does not allow');
select t.ok('cashier sees no credit notes through the table', (select count(*) from public.fo_credit_notes) = 0);
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
reset role;
select t.must_fail('an issued note cannot be edited', format($$update public.fo_credit_notes set reason = 'changed' where id = %L$$, (:'cn1'::jsonb ->> 'note_id')), 'cannot be changed');
select t.must_fail('an issued note cannot be deleted', format($$delete from public.fo_credit_notes where id = %L$$, (:'cn1'::jsonb ->> 'note_id')), 'cannot be changed');
select t.ok('the credit deadline for FY 2026-27 is 30 Nov 2027', app.fo_credit_deadline('2627') = date '2027-11-30');
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

-- ---- early check-in / late check-out fees
select nightly_rate as rrate from public.fo_stays where id = :'srq' \gset
select public.fo_post_stay_fee(:'srq', 'late_checkout', 50) as fee1 \gset
select t.ok('a late check-out fee is half the nightly rate, taxed like other charges',
  (select net_amount = round(:'rrate'::numeric / 2, 2) and kind = 'misc' and description like 'Late check-out fee (50% of room rate)'
     and tax_amount = round(net_amount * tax_pct / 100, 2) from public.fo_charges where id = (:'fee1'::jsonb ->> 'charge_id')::uuid));
select public.fo_post_stay_fee(:'srq', 'early_checkin', null, 750) as fee2 \gset
select t.ok('a fixed fee is posted as given',
  (select net_amount = 750 and description = 'Early check-in fee' from public.fo_charges where id = (:'fee2'::jsonb ->> 'charge_id')::uuid));
select gen_random_uuid() as feeref \gset
select public.fo_post_stay_fee(:'srq', 'late_checkout', 25, null, :'feeref') is not null as _f3 \gset
select t.ok('a fee with the same client reference is not posted twice',
  (public.fo_post_stay_fee(:'srq', 'late_checkout', 25, null, :'feeref') ->> 'repeat')::boolean
  and (select count(*) from public.fo_charges where client_ref = :'feeref'::uuid) = 1);
select t.must_fail('an unknown fee is refused', format($$select public.fo_post_stay_fee(%L, 'parking', 50)$$, :'srq'), 'early check-in or late');
select t.must_fail('zero percent is refused', format($$select public.fo_post_stay_fee(%L, 'late_checkout', 0)$$, :'srq'), '1 to 100');
select t.must_fail('over 100 percent is refused', format($$select public.fo_post_stay_fee(%L, 'late_checkout', 101)$$, :'srq'), '1 to 100');
select t.must_fail('a negative fixed fee is refused', format($$select public.fo_post_stay_fee(%L, 'early_checkin', 50, -5)$$, :'srq'), 'more than zero');
select t.must_fail('a late check-out fee needs a guest who is in the house', format($$select public.fo_post_stay_fee(%L, 'late_checkout', 50)$$, :'srv'), 'checked in');
select t.ok('an early check-in fee can be posted for a reserved stay',
  (public.fo_post_stay_fee(:'srv', 'early_checkin', 50) ->> 'charge_id') is not null);
select t.must_fail('a checked-out stay takes no fee', format($$select public.fo_post_stay_fee(%L, 'early_checkin', 50)$$, :'sa'), 'nothing can be posted');
select set_config('request.jwt.claims', '{"sub":"' || :'cashier' || '","role":"authenticated"}', false);
select t.must_fail('cashier cannot post a fee', format($$select public.fo_post_stay_fee(%L, 'late_checkout', 50)$$, :'srq'), 'does not allow');
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
