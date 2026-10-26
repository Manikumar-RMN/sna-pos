-- t140.sql: proves migration 140 (bulk price range check, offline bills with open-priced items, daily summary guests and tips).
-- Runs AFTER t140-pre.sql (same database, fixtures and "before" results) and after 140 has been applied. Test databases only.
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
create function t.rm(j jsonb, k text[]) returns jsonb language sql immutable as $$ select j - k $$;

-- ================================================================ 1 bulk price: flag in preview, refuse in apply
select t.as_('carl');
select t.err('1.1 a Cashier still cannot preview', $q$ select public.bulk_price_preview('amount', -25, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea')))) $q$, '(menu.price_change)');
select t.err('1.2 a Cashier still cannot apply', $q$ select public.bulk_price_apply('amount', -25, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea'))), true, 'x reason') $q$, '(menu.price_change)');
reset role;

select t.as_('mgr');
select public.bulk_price_preview('amount', -25, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea')))) as neg \gset
select public.bulk_price_preview('amount', -50, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea'), t.id('burger')))) as mix \gset
select public.bulk_price_preview('amount', -5, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('free')))) as zero \gset
select public.bulk_price_preview('percent', 10, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('lux')))) as hi \gset
select public.bulk_price_preview('amount', -20, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea')))) as exact0 \gset
select public.bulk_price_preview('percent', 10, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea'), t.id('burger')))) as ok10 \gset
reset role;
select t.same('1.3 preview: Tea -25 shows the real result -5, flagged below_zero (not cut to 0)', t.rm(:'neg'::jsonb #> '{lines,0}', array['product_id','branch_id']),
  '{"name":"Tea","category":"Drinks","scope":"base","branch":null,"old_price":20,"new_price":-5,"problem":"below_zero"}');
select t.same('1.4 preview counts and can_apply = false', t.rm(:'neg'::jsonb, array['lines']), '{"total_lines":1,"base_lines":1,"branch_lines":0,"truncated":false,"include_branch":true,"below_zero_lines":1,"too_high_lines":0,"invalid_lines":1,"invalid_items":1,"can_apply":false}');
select t.same('1.5 mixed batch: the flagged line comes first, the good line follows with problem null',
  jsonb_build_array(:'mix'::jsonb #> '{lines,0,name}', :'mix'::jsonb #> '{lines,0,problem}', :'mix'::jsonb #> '{lines,1,name}', :'mix'::jsonb #> '{lines,1,new_price}', :'mix'::jsonb #> '{lines,1,problem}'),
  '["Tea","below_zero","Burger",50,null]');
select t.same('1.6 mixed batch counts', t.rm(:'mix'::jsonb, array['lines']), '{"total_lines":2,"base_lines":2,"branch_lines":0,"truncated":false,"include_branch":true,"below_zero_lines":1,"too_high_lines":0,"invalid_lines":1,"invalid_items":1,"can_apply":false}');
select t.q('1.7 a free item (price 0) lowered by 5 used to vanish from the preview (cut to 0 = unchanged); now it is listed and flagged',
  jsonb_build_array(:'zero'::jsonb #> '{lines,0,name}', :'zero'::jsonb #> '{lines,0,new_price}', :'zero'::jsonb #> '{lines,0,problem}', :'zero'::jsonb -> 'can_apply'), '["Water",-5,"below_zero",false]');
select t.same('1.8 above the largest price (10000000) is flagged too_high with the real figure', t.rm(:'hi'::jsonb, array['lines']) || jsonb_build_object('l', t.rm(:'hi'::jsonb #> '{lines,0}', array['product_id','branch_id','category'])),
  '{"total_lines":1,"base_lines":1,"branch_lines":0,"truncated":false,"include_branch":true,"below_zero_lines":0,"too_high_lines":1,"invalid_lines":1,"invalid_items":1,"can_apply":false,"l":{"name":"Caviar","scope":"base","branch":null,"old_price":9999999,"new_price":10999999,"problem":"too_high"}}');
select t.same('1.9 landing exactly on 0 is allowed (not flagged)', t.rm(:'exact0'::jsonb #> '{lines,0}', array['product_id','branch_id']) || jsonb_build_object('can', :'exact0'::jsonb -> 'can_apply', 'inv', :'exact0'::jsonb -> 'invalid_lines'),
  '{"name":"Tea","category":"Drinks","scope":"base","branch":null,"old_price":20,"new_price":0,"problem":null,"can":true,"inv":0}');
select t.same('1.10 a normal +10% preview: unchanged shape and numbers, no problems, can_apply',
  jsonb_build_object('names', (select jsonb_agg(e ->> 'name' order by e ->> 'name') from jsonb_array_elements(:'ok10'::jsonb -> 'lines') e),
                     'new', (select jsonb_agg(e -> 'new_price' order by e ->> 'name') from jsonb_array_elements(:'ok10'::jsonb -> 'lines') e),
                     'keys', (select jsonb_agg(k order by k) from jsonb_object_keys(:'ok10'::jsonb) k), 'can', :'ok10'::jsonb -> 'can_apply'),
  '{"names":["Burger","Tea"],"new":[110,22],"can":true,"keys":["base_lines","below_zero_lines","branch_lines","can_apply","include_branch","invalid_items","invalid_lines","lines","too_high_lines","total_lines","truncated"]}');

select t.as_('mgr');
select t.err('1.11 apply refuses Tea -25 (would be -5) and names the count', $q$ select public.bulk_price_apply('amount', -25, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea'))), true, 'Cost cut') $q$, 'Nothing was changed: 1 of the 1 new prices (1 dishes) would be out of range (1 below zero, 0 above 10000000)');
select t.err('1.12 apply refuses the WHOLE mixed batch (one bad line stops the good one too)', $q$ select public.bulk_price_apply('amount', -50, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea'), t.id('burger'))), true, 'Cost cut') $q$, '1 of the 2 new prices (1 dishes) would be out of range (1 below zero, 0 above 10000000)');
select t.err('1.13 apply refuses a price above the maximum', $q$ select public.bulk_price_apply('percent', 10, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('lux'))), true, 'Raise') $q$, '(0 below zero, 1 above 10000000)');
select t.err('1.14 apply refuses the free item going below zero', $q$ select public.bulk_price_apply('amount', -5, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('free'))), true, 'Cut') $q$, '1 below zero');
select t.err('1.15 the refusal comes even with a matching expect_lines', $q$ select public.bulk_price_apply('amount', -25, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea'))), true, 'Cost cut', t.id('refA'), 1) $q$, 'would be out of range');
reset role;
select t.q('1.16 nothing was written by the refusals: prices, batches, lines, audit, owner alerts',
  (select jsonb_build_object('tea', (select price from public.products where id = t.id('tea')), 'burger', (select price from public.products where id = t.id('burger')),
     'free', (select price from public.products where id = t.id('free')), 'lux', (select price from public.products where id = t.id('lux')),
     'batches', (select count(*) from public.price_change_batches), 'lines', (select count(*) from public.price_change_lines),
     'audit', (select count(*) from public.audit_logs where action like 'menu.bulk%'), 'ref_used', (select count(*) from public.price_change_batches where client_ref = t.id('refA')))),
  '{"tea":20,"burger":100,"free":0,"lux":9999999,"batches":0,"lines":0,"audit":0,"ref_used":0}');

select t.as_('mgr');
select t.err('1.17 the expect_lines check still works (stale preview is refused)', $q$ select public.bulk_price_apply('percent', 10, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea'), t.id('burger'))), true, 'Rise', null, 5) $q$, 'Preview again');
select public.bulk_price_apply('percent', 10, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea'), t.id('burger'))), true, 'Rise', t.id('ref1'), 2) as ap \gset
select public.bulk_price_apply('percent', 10, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea'), t.id('burger'))), true, 'Rise', t.id('ref1'), 2) as ap2 \gset
reset role;
select t.same('1.18 a good batch applies', t.rm(:'ap'::jsonb, array['batch_id']), '{"total_lines":2,"base_lines":2,"branch_lines":0,"already_applied":false}');
select t.q('1.19 the same client ref returns the same batch (idempotent)', to_jsonb((:'ap'::jsonb ->> 'batch_id') = (:'ap2'::jsonb ->> 'batch_id') and (:'ap2'::jsonb ->> 'already_applied')::boolean), 'true');
select t.q('1.20 preview and apply used the same prices: what the preview showed is what was written (and recorded)',
  (select jsonb_build_object('preview_eq_products',
        (select bool_and(p.price = (e ->> 'new_price')::numeric) from jsonb_array_elements(:'ok10'::jsonb -> 'lines') e join public.products p on p.id = (e ->> 'product_id')::uuid),
        'preview_eq_lines',
        (select bool_and(l.new_price = (e ->> 'new_price')::numeric) from jsonb_array_elements(:'ok10'::jsonb -> 'lines') e join public.price_change_lines l on l.product_id = (e ->> 'product_id')::uuid and l.batch_id = (:'ap'::jsonb ->> 'batch_id')::uuid),
        'one_batch', (select count(*) from public.price_change_batches), 'one_audit', (select count(*) from public.audit_logs where action = 'menu.bulk_price_change'))),
  '{"preview_eq_products":true,"preview_eq_lines":true,"one_batch":1,"one_audit":1}');
select t.as_('mgr');
select public.bulk_price_undo((:'ap'::jsonb ->> 'batch_id')::uuid, 'oops') as un \gset
reset role;
select t.same('1.21 undo is untouched: restores both prices', t.rm(:'un'::jsonb, array['batch_id']), '{"restored":2,"skipped":0}');
select t.q('1.22 prices are back', (select jsonb_build_object('tea', (select price from public.products where id = t.id('tea')), 'burger', (select price from public.products where id = t.id('burger')))), '{"tea":20,"burger":100}');
select t.as_('mgr');
select public.bulk_price_apply('amount', -20, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea'))), true, 'Free tea day', t.id('ref2'), 1) as z0 \gset
reset role;
select t.q('1.23 a result of exactly 0 can still be applied', (select jsonb_build_object('lines', :'z0'::jsonb -> 'total_lines', 'tea', (select price from public.products where id = t.id('tea')))), '{"lines":1,"tea":0}');
select t.as_('mgr');
select public.bulk_price_undo((:'z0'::jsonb ->> 'batch_id')::uuid) as un2 \gset
reset role;
select t.q('1.24 and be undone', (select price from public.products where id = t.id('tea')), '20');
select t.same('1.25 the pricing function: rounding and signs (no more cutting)',
  jsonb_build_array(app.bulk_price_new('percent', 2.5, 1, 20), app.bulk_price_new('percent', 2.5, 0.5, 20), app.bulk_price_new('amount', 0.4, 0.5, 80), app.bulk_price_new('amount', -25, 1, 20), app.bulk_price_new('percent', 10, 0.01, 9999999)),
  '[21, 20.5, 80.5, -5, 10999998.90]');
select t.same('1.26 app.bulk_price_problem boundaries', jsonb_build_array(app.bulk_price_problem(0), app.bulk_price_problem(10000000), app.bulk_price_problem(-0.01), app.bulk_price_problem(10000000.01), app.bulk_price_problem(55)),
  '[null, null, "below_zero", "too_high", null]');
select t.q('1.27 the helpers are not callable by the app roles', (select to_jsonb(count(*)) from information_schema.routine_privileges where routine_schema = 'app' and routine_name in ('bulk_price_new', 'bulk_price_problem') and grantee in ('anon', 'authenticated', 'PUBLIC')), '0');

-- ================================================================ 2 daily summary (before the offline bills: those open today's business day and close older open ones): every old key unchanged, new keys added
select t.same('2.1 day D: all old keys and numbers identical to before 140',
  t.rm(app.report_summary(t.id('outA'), '2026-10-20'), array['covers','bills_with_covers','sales_per_cover','tips','tip_count']), (select v::text from t.before where k = 'sum_D'));
select t.same('2.2 empty day E: old keys identical',
  t.rm(app.report_summary(t.id('outA'), '2026-10-21'), array['covers','bills_with_covers','sales_per_cover','tips','tip_count']), (select v::text from t.before where k = 'sum_E'));
select t.same('2.3 a date with no business day: old keys identical',
  t.rm(app.report_summary(t.id('outA'), '2026-10-25'), array['covers','bills_with_covers','sales_per_cover','tips','tip_count']), (select v::text from t.before where k = 'sum_none'));
select t.q('2.4 an unknown outlet still gives null', (select to_jsonb(app.report_summary(t.id('nowhere'), '2026-10-20') is null)), 'true');
select t.same('2.5 only the five new keys were added',
  (select jsonb_agg(k order by k) from jsonb_object_keys(app.report_summary(t.id('outA'), '2026-10-20')) k where k not in (select jsonb_object_keys(v) from t.before where k = 'sum_D')),
  '["bills_with_covers","covers","sales_per_cover","tip_count","tips"]');
select t.same('2.6 day D new values: 9 guests on 3 dine-in bills (voided and merged bills left out), 790 / 9 = 87.78 per guest, tips 30 + 20 (the voided bill and the other-day tip left out)',
  (select jsonb_build_object('covers', s -> 'covers', 'bills_with_covers', s -> 'bills_with_covers', 'sales_per_cover', s -> 'sales_per_cover', 'tips', s -> 'tips', 'tip_count', s -> 'tip_count') from (select app.report_summary(t.id('outA'), '2026-10-20') s) z),
  '{"covers":9,"bills_with_covers":3,"sales_per_cover":87.78,"tips":50,"tip_count":2}');
select t.same('2.7 day E: no guests (0 and sales per guest 0, not null) and the one tip dated that day',
  (select jsonb_build_object('covers', s -> 'covers', 'bills_with_covers', s -> 'bills_with_covers', 'sales_per_cover', s -> 'sales_per_cover', 'tips', s -> 'tips', 'tip_count', s -> 'tip_count') from (select app.report_summary(t.id('outA'), '2026-10-21') s) z),
  '{"covers":0,"bills_with_covers":0,"sales_per_cover":0,"tips":10,"tip_count":1}');
select t.same('2.8 a day with nothing at all: zeros',
  (select jsonb_build_object('covers', s -> 'covers', 'sales_per_cover', s -> 'sales_per_cover', 'tips', s -> 'tips', 'tip_count', s -> 'tip_count') from (select app.report_summary(t.id('outA'), '2026-10-25') s) z),
  '{"covers":0,"sales_per_cover":0,"tips":0,"tip_count":0}');
select t.as_('owner');
select public.report_covers('2026-10-20', '2026-10-20') as rc, public.report_tips('2026-10-20', '2026-10-20') as rt \gset
reset role;
select t.same('2.9 the summary agrees with the reports (report_covers / report_tips) for day D',
  (select jsonb_build_object('covers', s -> 'covers', 'per', s -> 'sales_per_cover', 'tips', s -> 'tips', 'tip_count', s -> 'tip_count') from (select app.report_summary(t.id('outA'), '2026-10-20') s) z),
  jsonb_build_object('covers', (:'rc'::jsonb #> '{totals,covers}'), 'per', (:'rc'::jsonb #> '{totals,sales_per_cover}'), 'tips', (:'rt'::jsonb #> '{totals,amount}'), 'tip_count', (:'rt'::jsonb #> '{totals,tips}'))::text);
select t.q('2.10 report_summary is still locked down (internal)', (select to_jsonb(count(*)) from information_schema.routine_privileges where routine_schema = 'app' and routine_name = 'report_summary' and grantee in ('anon', 'authenticated', 'PUBLIC')), '0');
select t.q('2.11 report_summary is still STABLE and security definer', (select jsonb_build_object('volatile', provolatile, 'definer', prosecdef) from pg_proc where oid = 'app.report_summary(uuid,date)'::regprocedure), '{"volatile":"s","definer":true}');

-- ================================================================ 3 offline bills with open-priced items
select t.q('3.0 fixture: Chef Special is open-priced with a stored price of 10', (select to_jsonb(is_open_price) from public.products where id = t.id('special')), 'true');
select t.as_('carl');
select public.sync_offline_bill(t.bill(1, 1, jsonb_build_array(t.item('special', 1, 75)), 'ob1')) as o1 \gset
reset role;
select t.q('3.1 Cashier without order.open_price: bill ACCEPTED, recorded at the till price 75 (not the stored 10)',
  (select jsonb_build_object('ok', :'o1'::jsonb -> 'ok', 'total', o.grand_total, 'status', o.status, 'paid', o.paid_total, 'price', (select oi.unit_price from public.order_items oi where oi.order_id = o.id), 'open_line', (select oi.open_price from public.order_items oi where oi.order_id = o.id))
     from public.orders o where o.client_ref = t.id('ob1')), '{"ok":true,"total":75,"status":"completed","paid":75,"price":75,"open_line":true}');
select t.same('3.2 it is flagged on the order (open_price_no_right) and nothing else',
  (select o.offline_flags from public.orders o where o.client_ref = t.id('ob1')), '[{"flag":"open_price_no_right","item":"Chef Special","price":75}]');
select t.same('3.3 the answer to the till carries the same flag', :'o1'::jsonb -> 'flags', '[{"flag":"open_price_no_right","item":"Chef Special","price":75}]');
select t.q('3.4 audit order.open_price_offline written for review, naming the cashier and the bill',
  (select jsonb_build_object('n', count(*), 'review', bool_and((a.new_value ->> 'review')::boolean), 'user', bool_and(a.new_value ->> 'user_id' = t.id('carl')::text), 'bill', bool_and(a.new_value ->> 'bill_number' = 'T-X1-0001'),
          'items', bool_and(a.new_value #>> '{items,0,item}' = 'Chef Special'))
     from public.audit_logs a join public.orders o on o.id = a.entity_id where o.client_ref = t.id('ob1') and a.action = 'order.open_price_offline'),
  '{"n":1,"review":true,"user":true,"bill":true,"items":true}');
select t.q('3.5 the usual audits are there too: order.offline_flagged (with a plain summary), order.offline_sync, and the per-line order.open_price (131 trigger)',
  (select jsonb_build_object('flagged_summary', (select a.new_value ->> 'summary' from public.audit_logs a where a.entity_id = o.id and a.action = 'order.offline_flagged'),
          'sync', (select count(*) from public.audit_logs a where a.entity_id = o.id and a.action = 'order.offline_sync'),
          'line', (select count(*) from public.audit_logs a where a.action = 'order.open_price' and a.new_value ->> 'bill_number' = 'T-X1-0001'))
     from public.orders o where o.client_ref = t.id('ob1')),
  '{"flagged_summary":"open-price item Chef Special at 75.00 sold without the open-price right","sync":1,"line":1}');
select t.as_('carl');
select public.sync_offline_bill(t.bill(1, 1, jsonb_build_array(t.item('special', 1, 75)), 'ob1')) as o1r \gset
reset role;
select t.q('3.6 sending the same bill again is a repeat: no second order, no second audit',
  jsonb_build_object('repeat', :'o1r'::jsonb -> 'repeat', 'orders', (select count(*) from public.orders where client_ref = t.id('ob1')),
     'audits', (select count(*) from public.audit_logs where action = 'order.open_price_offline')), '{"repeat":true,"orders":1,"audits":1}');

select t.as_('mgr');
select public.sync_offline_bill(t.bill(1, 2, jsonb_build_array(t.item('special', 1, 120), t.item('burger', 1, 100)), 'ob2')) as o2 \gset
reset role;
select t.q('3.7 Manager (has the right): accepted at 120 + 100, NO review flag, no order.open_price_offline audit, line marked open_price',
  (select jsonb_build_object('total', o.grand_total, 'flags', o.offline_flags, 'ok', :'o2'::jsonb -> 'ok',
        'open', (select jsonb_agg(oi.open_price order by oi.product_name) from public.order_items oi where oi.order_id = o.id),
        'review_audits', (select count(*) from public.audit_logs a where a.entity_id = o.id and a.action = 'order.open_price_offline'),
        'line_audits', (select count(*) from public.audit_logs a where a.action = 'order.open_price' and a.new_value ->> 'bill_number' = 'T-X1-0002'))
     from public.orders o where o.client_ref = t.id('ob2')), '{"total":220,"flags":null,"ok":true,"open":[false,true],"review_audits":0,"line_audits":1}');

select t.as_('carl');
select t.err('3.8 price 0 on an open-priced item: bill REFUSED with a clear message', $q$ select public.sync_offline_bill(t.bill(1, 3, jsonb_build_array(t.item('special', 1, 0)), 'ob3')) $q$, 'Offline bill T-X1-0003: the price of Chef Special (open price) is not above zero');
select t.err('3.9 a negative price is refused the same way', $q$ select public.sync_offline_bill(t.bill(1, 3, jsonb_build_array(t.item('burger', 1, 100), t.item('special', 1, -5)), 'ob4')) $q$, 'not above zero');
select t.err('3.10 an absurd price is refused', $q$ select public.sync_offline_bill(t.bill(1, 3, jsonb_build_array(t.item('special', 1, 100000000)), 'ob5')) $q$, 'is too large');
reset role;
select t.q('3.11 refusals left nothing behind: no order, series number not used up',
  (select jsonb_build_object('orders', (select count(*) from public.orders where client_ref in (t.id('ob3'), t.id('ob4'), t.id('ob5'))), 'next_seq', (select next_seq from public.offline_series where device_key = t.id('dev1')::text))), '{"orders":0,"next_seq":3}');
select t.err('3.12 the refusal is a P0001 database message (the app treats it as "refused": the bill moves to the device Stuck list with this text, never lost)',
  $q$ do $d$ begin perform set_config('request.jwt.claim.sub', t.id('auth:carl')::text, false); perform public.sync_offline_bill(t.bill(1, 3, jsonb_build_array(t.item('special', 1, 0)), 'ob3')); exception when sqlstate 'P0001' then raise exception 'got P0001'; end $d$ $q$, 'got P0001');

select t.as_('carl');
select public.sync_offline_bill(t.bill(1, 3, jsonb_build_array(t.item('special', 1, 10)), 'ob6')) as o6 \gset
reset role;
select t.q('3.13 an item that was fixed-price on the till but is open-priced now, billed at the old stored price 10 by a Cashier: accepted at 10 and flagged for review',
  (select jsonb_build_object('total', o.grand_total, 'flags', o.offline_flags) from public.orders o where o.client_ref = t.id('ob6')), '{"total":10,"flags":[{"flag":"open_price_no_right","item":"Chef Special","price":10}]}');

-- unchanged behaviour of ordinary bills
select t.as_('carl');
select public.sync_offline_bill(t.bill(3, 1, jsonb_build_array(t.item('burger', 2, 100), t.item('tea', 1, 5)), 'post1')) as r \gset
reset role;
select t.same('3.14 an ordinary offline bill (right price + a price the menu never had) gives exactly what it gave before 140',
  jsonb_build_object('res', t.rm(:'r'::jsonb, array['order_id','bill_number']),
    'flags', (select o.offline_flags from public.orders o where o.client_ref = t.id('post1')),
    'total', (select o.grand_total from public.orders o where o.client_ref = t.id('post1')),
    'prices', (select jsonb_agg(oi.unit_price order by oi.product_name) from public.order_items oi join public.orders o on o.id = oi.order_id where o.client_ref = t.id('post1')),
    'open_flags', (select jsonb_agg(oi.open_price) from public.order_items oi join public.orders o on o.id = oi.order_id where o.client_ref = t.id('post1')),
    'audits', (select jsonb_agg(a.action order by a.action) from public.audit_logs a join public.orders o on o.id = a.entity_id where o.client_ref = t.id('post1'))),
  (select v::text from t.before where k = 'sync_normal'));
select t.q('3.15 an ordinary bill creates no open-price audit and no review flag', (select jsonb_build_object('n', count(*)) from public.audit_logs a join public.orders o on o.id = a.entity_id where o.client_ref = t.id('post1') and a.action in ('order.open_price_offline', 'order.open_price')), '{"n":0}');
select t.q('3.16 sync_offline_bill is still callable by signed-in users only (grants kept by create or replace)',
  (select jsonb_build_object('auth', has_function_privilege('authenticated', 'public.sync_offline_bill(jsonb)', 'execute'), 'anon', has_function_privilege('anon', 'public.sync_offline_bill(jsonb)', 'execute'))), '{"auth":true,"anon":false}');

-- ================================================================ result
\o
select case when ok then 'PASS' else 'FAIL' end as result, label, detail from t.res order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.res \gset
\echo
\echo RESULT: :passed passed, :failed failed
select case when :failed > 0 then 1/0 end as stop_if_failed;
