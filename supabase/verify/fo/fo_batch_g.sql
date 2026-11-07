-- ================================================================ batch G: reopen after check-out, cancel and reissue invoice (migration 174)
reset role;
select id as cashm from public.payment_methods where restaurant_id = :'restaurant_id' and kind = 'cash' order by display_order limit 1 \gset
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

select public.fo_save_room_type('RRO', 'Reopen room', 3000, 2, 9) ->> 'room_type_id' as rro \gset
select public.fo_save_room('971', :'rro', 'Ninth') ->> 'room_id' as r971 \gset
select public.fo_save_room('972', :'rro', 'Ninth') ->> 'room_id' as r972 \gset
select public.fo_save_room('973', :'rro', 'Ninth') ->> 'room_id' as r973 \gset
select public.fo_save_room('974', :'rro', 'Ninth') ->> 'room_id' as r974 \gset
select public.fo_save_room('975', :'rro', 'Ninth') ->> 'room_id' as r975 \gset
select public.fo_save_room('976', :'rro', 'Ninth') ->> 'room_id' as r976 \gset
select public.fo_save_guest('Gita Rao', '9876500971') ->> 'guest_id' as ggr \gset
select (:'today'::date + 2) as rodep \gset

-- Seven stays, each checked in, charged, checked out and invoiced to the guest.
select (public.fo_create_stay(:'ggr', :'rro', :'today'::date, :'rodep'::date) ->> 'stay_id') as sa \gset
select (public.fo_create_stay(:'ggr', :'rro', :'today'::date, :'rodep'::date) ->> 'stay_id') as sb \gset
select (public.fo_create_stay(:'ggr', :'rro', :'today'::date, :'rodep'::date) ->> 'stay_id') as sc \gset
select (public.fo_create_stay(:'ggr', :'rro', :'today'::date, :'rodep'::date) ->> 'stay_id') as sd \gset
select (public.fo_create_stay(:'ggr', :'rro', :'today'::date, :'rodep'::date) ->> 'stay_id') as se \gset
select (public.fo_create_stay(:'ggr', :'rro', :'today'::date, :'rodep'::date) ->> 'stay_id') as sf \gset
select public.fo_check_in(:'sa', :'r971') is not null as _a1 \gset
select public.fo_check_in(:'sb', :'r972') is not null as _b1 \gset
select public.fo_check_in(:'sc', :'r973') is not null as _c1 \gset
select public.fo_check_in(:'sd', :'r974') is not null as _d1 \gset
select public.fo_check_in(:'se', :'r975') is not null as _e1 \gset
select public.fo_check_in(:'sf', :'r976') is not null as _f1 \gset
select public.fo_post_charge(:'sa', 'misc', 'Laundry', 1000) is not null as _a2 \gset
select public.fo_post_charge(:'sb', 'misc', 'Laundry', 1000) is not null as _b2 \gset
select public.fo_post_charge(:'sc', 'misc', 'Laundry', 1000) is not null as _c2 \gset
select public.fo_post_charge(:'sd', 'misc', 'Laundry', 1000) is not null as _d2 \gset
select public.fo_post_charge(:'se', 'misc', 'Laundry', 1000) is not null as _e2 \gset
select public.fo_post_charge(:'sf', 'misc', 'Laundry', 1000) is not null as _f2 \gset
select public.fo_check_out(:'sa', :'cashm') is not null as _a3 \gset
select public.fo_check_out(:'sb', :'cashm') is not null as _b3 \gset
select public.fo_check_out(:'sc', :'cashm') is not null as _c3 \gset
select public.fo_check_out(:'sd', :'cashm') is not null as _d3 \gset
select public.fo_check_out(:'se', :'cashm') is not null as _e3 \gset
select public.fo_check_out(:'sf', :'cashm') is not null as _f3 \gset
select public.fo_issue_invoice(:'sa') as ia \gset
select public.fo_issue_invoice(:'sb') as ib \gset
select public.fo_issue_invoice(:'sc') as ic \gset
select public.fo_issue_invoice(:'sd') as id_ \gset
select public.fo_issue_invoice(:'se') as ie \gset
select public.fo_issue_invoice(:'sf') as if_ \gset
select (:'ia'::jsonb ->> 'invoice_id') as ia_id, (:'ia'::jsonb ->> 'invoice_no') as ia_no \gset
select (:'ib'::jsonb ->> 'invoice_id') as ib_id \gset
select (:'ic'::jsonb ->> 'invoice_id') as ic_id \gset
select (:'id_'::jsonb ->> 'invoice_id') as id_id \gset
select (:'ie'::jsonb ->> 'invoice_id') as ie_id, (:'ie'::jsonb ->> 'invoice_no') as ie_no, (:'ie'::jsonb ->> 'total')::numeric as ie_total \gset
select (:'if_'::jsonb ->> 'invoice_id') as if_id \gset

-- ---- the night audit for today has already been run (batch B): reopening is refused
reset role;
select t.ok('a night audit exists for the check-out date (set-up check)',
  exists (select 1 from public.fo_night_audits where branch_id = :'branch_id' and business_date = app.business_today(:'branch_id')));
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select t.must_fail('no reopen once the night audit for that day has been run',
  format($$select public.fo_reopen_stay(%L, 'Wrong room posted')$$, :'sa'), 'night audit');
select public.fo_fix_options(:'sa') as fo_blocked \gset
select t.ok('the options say so, and still offer cancel and reissue',
  not (:'fo_blocked'::jsonb ->> 'can_reopen')::boolean and (:'fo_blocked'::jsonb ->> 'reopen_blocked') like '%night audit%'
  and (:'fo_blocked'::jsonb ->> 'can_reissue')::boolean);

-- ---- the audit is not yet run: clear it for the tests that follow
reset role;
delete from public.fo_night_audits where branch_id = :'branch_id' and business_date = app.business_today(:'branch_id');
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

-- ---- rights and reason
select set_config('request.jwt.claims', '{"sub":"' || :'cashier' || '","role":"authenticated"}', false);
select t.must_fail('a cashier cannot reopen a stay', format($$select public.fo_reopen_stay(%L, 'x')$$, :'sa'), 'does not allow');
select t.must_fail('a cashier cannot reissue an invoice', format($$select public.fo_reissue_invoice(%L, 'x')$$, :'ie_id'), 'does not allow');
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select t.must_fail('a reason is needed to reopen', format($$select public.fo_reopen_stay(%L, '  ')$$, :'sa'), 'reason');
select t.must_fail('an unknown stay is refused',
  $$select public.fo_reopen_stay('00000000-0000-0000-0000-000000000000', 'x')$$, 'not found');

-- ---- reopen: the main case
select public.fo_fix_options(:'sa') as fo_ok \gset
select t.ok('the options offer the reopen', (:'fo_ok'::jsonb ->> 'can_reopen')::boolean and (:'fo_ok'::jsonb ->> 'reopen_blocked') is null);
select public.fo_reopen_stay(:'sa', 'Laundry was posted to the wrong room') as ro \gset
select t.ok('the stay is back in the hotel with no check-out time',
  (select status = 'inhouse' and checked_out_at is null from public.fo_stays where id = :'sa')
  and not (:'ro'::jsonb ->> 'repeat')::boolean);
select t.ok('the invoice is cancelled, kept on record, with the reason and kind',
  (select cancelled_at is not null and cancel_kind = 'reopen' and cancel_reason = 'Laundry was posted to the wrong room'
     from public.fo_invoices where id = :'ia_id'));
select t.ok('reopening again is a no-op', (public.fo_reopen_stay(:'sa', 'again') ->> 'repeat')::boolean);
select t.ok('the invoice view shows no active invoice now',
  not (public.fo_invoice_for_stay(:'sa') ->> 'issued')::boolean);
select t.ok('a cancelled invoice is listed in the register, flagged, and left out of its totals',
  exists (select 1 from jsonb_array_elements(public.fo_invoice_register(:'today'::date, :'today'::date) -> 'rows') x
           where x ->> 'invoice_no' = :'ia_no' and (x ->> 'cancelled')::boolean and x ->> 'cancel_kind' = 'reopen')
  and (public.fo_invoice_register(:'today'::date, :'today'::date) -> 'totals' ->> 'count')::int
      = (select count(*) from jsonb_array_elements(public.fo_invoice_register(:'today'::date, :'today'::date) -> 'rows') x
          where not (x ->> 'cancelled')::boolean));

-- ---- the invoice stays untouchable
reset role;
select t.must_fail('a cancelled invoice cannot be edited', format($$update public.fo_invoices set total = total + 1 where id = %L$$, :'ia_id'), 'cannot be changed');
select t.must_fail('its cancel reason cannot be rewritten', format($$update public.fo_invoices set cancel_reason = 'something else' where id = %L$$, :'ia_id'), 'cannot be changed');
select t.must_fail('it cannot be un-cancelled', format($$update public.fo_invoices set cancelled_at = null, cancelled_by = null, cancel_reason = null, cancel_kind = null where id = %L$$, :'ia_id'), 'cannot be changed');
select t.must_fail('it cannot be deleted', format($$delete from public.fo_invoices where id = %L$$, :'ia_id'), 'cannot be changed');
select t.must_fail('an active invoice cannot be edited either', format($$update public.fo_invoices set total = total + 1 where id = %L$$, :'ib_id'), 'cannot be changed');
select t.must_fail('two active guest invoices for one stay are impossible',
  format($$insert into public.fo_invoices (restaurant_id, branch_id, stay_id, invoice_no, fy, seq, invoice_date, bill_to_name, taxable, tax, total, snapshot)
           select restaurant_id, branch_id, stay_id, 'DUP/1', fy, 99999, invoice_date, bill_to_name, taxable, tax, total, snapshot from public.fo_invoices where id = %L$$, :'ib_id'),
  'duplicate key');
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

-- ---- a credit note cannot be raised on a cancelled invoice
select public.fo_credit_note_options(:'ia_id') as cno \gset
select t.must_fail('no credit note on a cancelled invoice',
  format($$select public.fo_issue_credit_note(%L, 'x', %L::jsonb)$$, :'ia_id',
         format('[{"sac":"%s","tax_pct":%s,"taxable":10}]', (:'cno'::jsonb -> 'rows' -> 0 ->> 'sac'), (:'cno'::jsonb -> 'rows' -> 0 ->> 'tax_pct'))), 'was cancelled');

-- ---- correct the folio, check out again, and the new invoice gets a NEW number
select public.fo_post_charge(:'sa', 'misc', 'Laundry (correct room)', 400) is not null as _a4 \gset
select public.fo_check_out(:'sa', :'cashm') is not null as _a5 \gset
select public.fo_issue_invoice(:'sa') as ia2 \gset
select t.ok('a new invoice, with a different number, is issued after the second check-out',
  (:'ia2'::jsonb ->> 'invoice_no') <> :'ia_no' and (:'ia2'::jsonb ->> 'invoice_id') <> :'ia_id' and not (:'ia2'::jsonb ->> 'repeat')::boolean);
select t.ok('the stay now has the cancelled invoice and one active one',
  (select count(*) = 2 and count(*) filter (where cancelled_at is null) = 1 from public.fo_invoices where stay_id = :'sa'));
select t.ok('the invoice view returns the new, active invoice',
  (public.fo_invoice_for_stay(:'sa') ->> 'invoice_no') = (:'ia2'::jsonb ->> 'invoice_no'));

-- ---- reopen refused: room cleaned, credit note raised, other country
reset role;
update public.fo_rooms set housekeeping_status = 'clean' where id = :'r972';
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select t.must_fail('no reopen once the room has been cleaned', format($$select public.fo_reopen_stay(%L, 'x')$$, :'sb'), 'already been cleaned');

select public.fo_credit_note_options(:'ic_id') as cnc \gset
select public.fo_issue_credit_note(:'ic_id', 'Goodwill', format('[{"sac":"%s","tax_pct":%s,"taxable":10}]', (:'cnc'::jsonb -> 'rows' -> 0 ->> 'sac'), (:'cnc'::jsonb -> 'rows' -> 0 ->> 'tax_pct'))::jsonb) is not null as _cn1 \gset
select t.must_fail('no reopen once a credit note exists on the invoice', format($$select public.fo_reopen_stay(%L, 'x')$$, :'sc'), 'credit note');

reset role;
update public.restaurants set country_code = 'AE' where id = :'restaurant_id';
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);
select t.must_fail('outside India there is no reopen', format($$select public.fo_reopen_stay(%L, 'x')$$, :'sd'), 'India only');
select t.ok('outside India the options offer only cancel and reissue',
  (select not (o ->> 'can_reopen')::boolean and (o ->> 'reopen_blocked') like '%India only%' and (o ->> 'can_reissue')::boolean
     from (select public.fo_fix_options(:'sd') as o) x));
reset role;
update public.restaurants set country_code = 'IN' where id = :'restaurant_id';
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"' || :'owner' || '","role":"authenticated"}', false);

-- ---- cancel and reissue
select public.fo_report_gst(:'today'::date, :'today'::date) as gst0 \gset
select count(*) as cn0 from public.fo_credit_notes where restaurant_id = :'restaurant_id' \gset
select t.must_fail('an invalid GSTIN stops the reissue',
  format($$select public.fo_reissue_invoice(%L, 'Wrong bill-to', 'Acme Pvt Ltd', '29BAD')$$, :'ie_id'), 'GSTIN');
select t.ok('and nothing was done: no credit note, invoice still active',
  (select count(*) from public.fo_credit_notes where restaurant_id = :'restaurant_id') = :'cn0'::bigint
  and (select cancelled_at is null from public.fo_invoices where id = :'ie_id'));
select t.must_fail('a reason is needed to reissue', format($$select public.fo_reissue_invoice(%L, ' ')$$, :'ie_id'), 'reason');
select public.fo_reissue_invoice(:'ie_id', 'Guest asked for the invoice in the company name', 'Acme Pvt Ltd', '29AAACA0000A1Z5', 'Bengaluru') as rs \gset
select t.ok('the reissue returns the credit note and the new invoice',
  (:'rs'::jsonb ->> 'old_invoice_no') = :'ie_no' and (:'rs'::jsonb ->> 'credit_note_no') like '%/CN/%'
  and (:'rs'::jsonb ->> 'invoice_no') <> :'ie_no');
select t.ok('the old invoice is cancelled as credit-and-reissue and points to the new one',
  (select cancelled_at is not null and cancel_kind = 'credit_reissue' and replaced_by = (:'rs'::jsonb ->> 'invoice_id')::uuid
     from public.fo_invoices where id = :'ie_id'));
select t.ok('the credit note takes back the whole old invoice',
  (select n.total = :'ie_total'::numeric from public.fo_credit_notes n where n.note_no = (:'rs'::jsonb ->> 'credit_note_no')));
select t.ok('the new invoice is for the same amount, made out to the business with its GSTIN',
  (select total = :'ie_total'::numeric and bill_to_name = 'Acme Pvt Ltd' and bill_to_gstin = '29AAACA0000A1Z5' and cancelled_at is null
     from public.fo_invoices where id = (:'rs'::jsonb ->> 'invoice_id')::uuid));
select public.fo_report_gst(:'today'::date, :'today'::date) as gst1 \gset
select t.ok('the GST report nets to the same tax and taxable value as before the reissue',
  (:'gst1'::jsonb -> 'net' ->> 'tax')::numeric = (:'gst0'::jsonb -> 'net' ->> 'tax')::numeric
  and (:'gst1'::jsonb -> 'net' ->> 'taxable')::numeric = (:'gst0'::jsonb -> 'net' ->> 'taxable')::numeric);
select t.must_fail('the cancelled invoice cannot be reissued again', format($$select public.fo_reissue_invoice(%L, 'x')$$, :'ie_id'), 'already cancelled');
select t.must_fail('an invoice with a credit note cannot be cancelled as a whole', format($$select public.fo_reissue_invoice(%L, 'x')$$, :'ic_id'), 'credit note has already');
select t.ok('the reissued stay shows the new invoice',
  (public.fo_invoice_for_stay(:'se') ->> 'invoice_no') = (:'rs'::jsonb ->> 'invoice_no'));
select public.fo_fix_options(:'se') as fo_after \gset
select t.ok('the options now point at the new invoice, which can itself be cancelled and reissued',
  (:'fo_after'::jsonb ->> 'invoice_no') = (:'rs'::jsonb ->> 'invoice_no') and (:'fo_after'::jsonb ->> 'can_reissue')::boolean);
