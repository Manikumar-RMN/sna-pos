-- t130-133.sql: proves migrations 130 (tax schedule), 131 (open price + business-date tax lookup) and 133 (tips) on a database
-- where t130-133-pre.sql recorded the "before" golden results. Run via docs/tests/run-t130-133.sh. Test databases only.
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
reset role;
-- test helper: move the open business day (the real day only moves at the cutoff; foreign keys are bypassed for the test)
create function t.oi(p text, q numeric, pr text) returns jsonb language sql immutable as $f$
  select jsonb_build_array(jsonb_build_object('product_id', t.id(p), 'qty', q) || case when pr is null then '{}'::jsonb else jsonb_build_object('price', pr::jsonb) end) $f$;
create function t.setday(p date) returns void language plpgsql as $f$
begin
  set local session_replication_role = replica;
  update public.business_days set business_date = p where branch_id = t.ctx('b') and status = 'open';
  set local session_replication_role = origin;
end $f$;

-- ================================================================ 1. golden: ordinary bills are byte-identical
select t.run_golden('after');
select t.eq('golden ' || b.label || ' identical before/after (byte-for-byte jsonb)', a.result, b.result)
  from t.gold b join t.gold a on a.label = b.label and a.phase = 'after' where b.phase = 'before' order by b.label;
select t.is_('golden: 13 scenarios compared', (select count(*) from t.gold where phase = 'after') = 13 and (select count(*) from t.gold where phase = 'before') = 13);
select t.is_('bill_input is still STABLE', (select provolatile = 's' from pg_proc where oid = 'app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb)'::regprocedure));
select t.is_('old 6-argument pay_order is gone, one pay_order remains', (select count(*) from pg_proc where proname = 'pay_order' and pronamespace = 'public'::regnamespace) = 1);
select t.is_('no order_items row is flagged open_price by ordinary bills', not exists (select 1 from public.order_items where open_price));
select t.is_('no open_price audit rows from ordinary bills', not exists (select 1 from public.audit_logs where action = 'order.open_price'));

-- ================================================================ 2. tax schedule (130)
do $$ begin perform set_config('t.today', app.local_today(t.ctx('r'))::text, false); end $$;
select t.as_('cash');
select t.err('cashier cannot schedule a tax change', format('select public.schedule_tax_group(%L, %L::jsonb, %L::date)', t.ctx('gst5'), '[{"name":"GST","rate":12}]', current_setting('t.today')::date + 10), 'tax.manage');
select t.err('cashier cannot cancel', format('select public.cancel_scheduled_tax(%L)', t.ctx('gst5')), 'tax.manage');
select t.as_('owner');
select t.err('start date today is refused', format('select public.schedule_tax_group(%L, %L::jsonb, %L::date)', t.ctx('gst5'), '[{"name":"GST","rate":12}]', current_setting('t.today')::date), 'after today');
select t.err('start date in the past is refused', format('select public.schedule_tax_group(%L, %L::jsonb, %L::date)', t.ctx('gst5'), '[{"name":"GST","rate":12}]', current_setting('t.today')::date - 3), 'after today');
select t.err('more than a year ahead is refused', format('select public.schedule_tax_group(%L, %L::jsonb, %L::date)', t.ctx('gst5'), '[{"name":"GST","rate":12}]', current_setting('t.today')::date + 400), 'one year');
select t.err('rate above 40 refused', format('select public.schedule_tax_group(%L, %L::jsonb, %L::date)', t.ctx('gst5'), '[{"name":"GST","rate":41}]', current_setting('t.today')::date + 10), 'between 0 and 40');
select t.err('unknown group refused', format('select public.schedule_tax_group(%L, %L::jsonb, %L::date)', t.id('nope'), '[{"name":"GST","rate":12}]', current_setting('t.today')::date + 10), 'not found');
select t.err('another restaurant''s group refused', format('select public.schedule_tax_group(%L, %L::jsonb, %L::date)', t.ctx('r2gst5'), '[{"name":"GST","rate":12}]', current_setting('t.today')::date + 10), 'not found');
select t.err('cancel with nothing pending', format('select public.cancel_scheduled_tax(%L)', t.ctx('gst5')), 'No change is scheduled');

-- the GST 5 group: CGST 2.5 + SGST 2.5. Schedule 6+6 = 12% for today + 10.
reset role; select t.as_su('owner');
select set_config('t.old_comps', (select jsonb_agg(tax_comps)::text from public.order_items where product_name = 'Masala Dosa' and unit_price = 120), false);
select public.schedule_tax_group(t.ctx('gst5'), '[{"name":"CGST","rate":6},{"name":"SGST","rate":6}]'::jsonb, current_setting('t.today')::date + 10);
select t.is_('pending rate row exists from the start date, open-ended', (select count(*) from public.tax_rates where tax_group_id = t.ctx('gst5') and valid_from = current_setting('t.today')::date + 10 and valid_to is null and total_rate = 12) = 1);
select t.is_('current rate was closed the day before', (select count(*) from public.tax_rates where tax_group_id = t.ctx('gst5') and valid_to = current_setting('t.today')::date + 9 and total_rate = 5) = 1);
select t.is_('pending rate has its two components', (select count(*) from public.tax_rate_components c join public.tax_rates r on r.id = c.tax_rate_id where r.tax_group_id = t.ctx('gst5') and r.valid_from > current_setting('t.today')::date) = 2);
select t.is_('audit tax.rate_scheduled written', (select count(*) from public.audit_logs where action = 'tax.rate_scheduled' and entity_id = t.ctx('gst5')) = 1);
select t.err('a second pending change for the same group is refused', format('select public.schedule_tax_group(%L, %L::jsonb, %L::date)', t.ctx('gst5'), '[{"name":"GST","rate":18}]', current_setting('t.today')::date + 20), 'already scheduled');
-- bills before the date use the old rate: identical to golden q1
select t.eq('quote today still at 5% (before the start date)', public.quote_order(t.items('{"dosa":2}'), 0, null, null), (select result from t.gold where phase = 'before' and label = 'q1'));
-- move the open business day to the start date: the new rate applies
select t.setday(current_setting('t.today')::date + 10);
select t.same('quote on the start date uses 12% (6+6 on 240)', (select jsonb_agg(jsonb_build_object('n', x->'name', 'r', x->'rate', 'a', x->'amount') order by x->>'name') from jsonb_array_elements(public.quote_order(t.items('{"dosa":2}'), 0, null, null)->'taxes') x),
  '[{"n":"CGST","r":6,"a":14.40},{"n":"SGST","r":6,"a":14.40}]');
select t.same('grand total on the start date', (public.quote_order(t.items('{"dosa":2}'), 0, null, null)->>'tax_total')::numeric::text::jsonb, '28.8');
select t.setday(current_setting('t.today')::date + 9);
select t.same('the day before the start date still 5%', (public.quote_order(t.items('{"dosa":2}'), 0, null, null)->>'tax_total')::numeric::text::jsonb, '12');
select t.setday(current_setting('t.today')::date);
-- history safe
select t.same('bills already written keep their tax snapshot', (select jsonb_agg(tax_comps)::text::jsonb from public.order_items where product_name = 'Masala Dosa' and unit_price = 120 and created_at < now() - interval '0 seconds' and tax_comps <> '[]'::jsonb and (tax_comps->0->>'rate')::numeric = 2.5 limit 100), current_setting('t.old_comps'));
select t.is_('no existing order line carries the 12% rate', not exists (select 1 from public.order_items where (tax_comps->0->>'rate')::numeric = 6));
-- cancel
select public.cancel_scheduled_tax(t.ctx('gst5'));
select t.is_('cancel removes the pending row and its components', not exists (select 1 from public.tax_rates where tax_group_id = t.ctx('gst5') and valid_from > current_setting('t.today')::date) and not exists (select 1 from public.tax_rate_components c where not exists (select 1 from public.tax_rates r where r.id = c.tax_rate_id)));
select t.is_('cancel reopens the current rate (valid_to null)', (select count(*) from public.tax_rates where tax_group_id = t.ctx('gst5') and valid_to is null and total_rate = 5) = 1);
select t.is_('audit tax.rate_schedule_cancelled written', (select count(*) from public.audit_logs where action = 'tax.rate_schedule_cancelled' and entity_id = t.ctx('gst5')) = 1);
-- immediate change clears a pending schedule
select public.schedule_tax_group(t.ctx('gst5'), '[{"name":"CGST","rate":9},{"name":"SGST","rate":9}]'::jsonb, current_setting('t.today')::date + 5);
select public.save_tax_group(t.ctx('gst5'), 'GST 5%', '[{"name":"CGST","rate":3},{"name":"SGST","rate":3}]'::jsonb);
select t.is_('immediate change removed the pending schedule', not exists (select 1 from public.tax_rates where tax_group_id = t.ctx('gst5') and valid_from > current_setting('t.today')::date));
select t.is_('immediate change left exactly one open-ended current rate of 6%', (select count(*) from public.tax_rates where tax_group_id = t.ctx('gst5') and valid_to is null) = 1
   and (select total_rate from public.tax_rates where tax_group_id = t.ctx('gst5') and valid_to is null) = 6);
select t.same('immediate change bills at once at 6%', (public.quote_order(t.items('{"dosa":2}'), 0, null, null)->>'tax_total')::numeric::text::jsonb, '14.4');
-- restore 5% so the later sections use the original rate
select public.save_tax_group(t.ctx('gst5'), 'GST 5%', '[{"name":"CGST","rate":2.5},{"name":"SGST","rate":2.5}]'::jsonb);
select t.eq('rate restored: quote equals golden q1 again', public.quote_order(t.items('{"dosa":2}'), 0, null, null), (select result from t.gold where phase = 'before' and label = 'q1'));
-- immediate change during the night: business day still yesterday (between midnight and the cutoff) applies at once
select t.setday(current_setting('t.today')::date - 1);
select public.save_tax_group(t.ctx('gst5'), 'GST 5%', '[{"name":"CGST","rate":4},{"name":"SGST","rate":4}]'::jsonb);
select t.same('immediate change with the business day still yesterday applies to that day', (public.quote_order(t.items('{"dosa":2}'), 0, null, null)->>'tax_total')::numeric::text::jsonb, '19.2');
select public.save_tax_group(t.ctx('gst5'), 'GST 5%', '[{"name":"CGST","rate":2.5},{"name":"SGST","rate":2.5}]'::jsonb);
select t.setday(current_setting('t.today')::date);
select t.eq('rates back to normal', public.quote_order(t.items('{"dosa":2}'), 0, null, null), (select result from t.gold where phase = 'before' and label = 'q1'));
select t.is_('group history rows never overlap', not exists (select 1 from public.tax_rates a join public.tax_rates b on a.tax_group_id = b.tax_group_id and a.id < b.id
   and daterange(a.valid_from, coalesce(a.valid_to + 1, 'infinity')) && daterange(b.valid_from, coalesce(b.valid_to + 1, 'infinity'))));
select t.as_('cash');
select t.is_('authenticated can run schedule_tax_group (grant), the permission check is what refuses', (select has_function_privilege('authenticated', 'public.schedule_tax_group(uuid,jsonb,date)', 'execute') and not has_function_privilege('anon', 'public.schedule_tax_group(uuid,jsonb,date)', 'execute')));
reset role;

-- stale open business day (QA M1): a day left open past the cutoff must not price bills at its old date
reset role; select t.as_su('owner');
do $$ begin perform set_config('t.bt', app.business_today(t.ctx('b'))::text, false); end $$;
select t.setday(current_setting('t.bt')::date);
select public.save_tax_group(t.ctx('gst5'), 'GST 5%', '[{"name":"CGST","rate":6},{"name":"SGST","rate":6}]'::jsonb);   -- 12% from the business today
select t.setday(current_setting('t.bt')::date - 5);                                                                       -- the open day is 5 days stale
select t.same('stale open day: bill_input prices by the current business day (12%), not by the stale date (5%)',
  (public.quote_order(t.items('{"dosa":2}'), 0, null, null)->>'tax_total')::numeric::text::jsonb, '28.8');
select t.is_('stale open day: app.tax_today is the current business day', app.tax_today(t.ctx('r')) = current_setting('t.bt')::date);
select t.is_('bill_input and tax_today are still STABLE', (select bool_and(provolatile = 's') from pg_proc where oid in ('app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb)'::regprocedure, 'app.tax_today(uuid)'::regprocedure)));
select t.setday(current_setting('t.bt')::date + 1);
select t.same('an open day AHEAD of the business day is still honoured (12% on the later date)',
  (public.quote_order(t.items('{"dosa":2}'), 0, null, null)->>'tax_total')::numeric::text::jsonb, '28.8');
select t.setday(current_setting('t.bt')::date);
select public.save_tax_group(t.ctx('gst5'), 'GST 5%', '[{"name":"CGST","rate":2.5},{"name":"SGST","rate":2.5}]'::jsonb);
select t.setday(current_setting('t.today')::date);
select t.eq('rates back to normal after the stale-day test', public.quote_order(t.items('{"dosa":2}'), 0, null, null), (select result from t.gold where phase = 'before' and label = 'q1'));

-- ================================================================ 3. open price (131)
insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price, is_open_price)
  select t.id('openp'), t.ctx('r'), category_id, t.ctx('gst5'), 'Open Item', 0, true from public.products where id = t.id('dosa');
select t.is_('Owner and Manager were granted order.open_price, Cashier was not',
  (select array_agg(r.name order by r.name) from public.role_permissions rp join public.roles r on r.id = rp.role_id where rp.permission_key = 'order.open_price' and r.restaurant_id = t.ctx('r')) = array['Manager','Owner']);
select t.as_su('mgr');
select t.same('manager: open price 200 x 2 gets tax on the typed price (5% of 400 = 20)',
  (select jsonb_build_object('sub', q->'subtotal', 'tax', q->'tax_total', 'grand', q->'grand_total') from (select public.quote_order(t.oi('openp', 2, '200'), 0, false, null) q) z),
  '{"sub":400,"tax":20,"grand":420}');
select t.same('fractional typed price is rounded to 2 places', (public.quote_order(t.oi('openp', 1, '10.456'), 0, false, null)->>'subtotal')::numeric::text::jsonb, '10.46');
select t.err('missing price refused', format('select public.quote_order(%L::jsonb, 0, false, null)', '[{"product_id":"' || t.id('openp') || '","qty":1}]'), 'Enter a price');
select t.err('zero price refused', format('select public.quote_order(%L::jsonb, 0, false, null)', '[{"product_id":"' || t.id('openp') || '","qty":1,"price":0}]'), 'above zero');
select t.err('negative price refused', format('select public.quote_order(%L::jsonb, 0, false, null)', '[{"product_id":"' || t.id('openp') || '","qty":1,"price":-5}]'), 'above zero');
select t.err('text price refused', format('select public.quote_order(%L::jsonb, 0, false, null)', '[{"product_id":"' || t.id('openp') || '","qty":1,"price":"abc"}]'), 'Enter a price');
select t.err('huge price refused', format('select public.quote_order(%L::jsonb, 0, false, null)', '[{"product_id":"' || t.id('openp') || '","qty":1,"price":1000000000}]'), 'too large');
select t.as_su('cash');
select t.err('cashier without the right is refused', format('select public.quote_order(%L::jsonb, 0, false, null)', '[{"product_id":"' || t.id('openp') || '","qty":1,"price":200}]'), 'Only a manager or owner');
select t.err('cashier cannot create a bill with an open price either', format('select public.create_order(%L::jsonb, %L, %L)', '[{"product_id":"' || t.id('openp') || '","qty":1,"price":200}]', 'takeaway', null), 'Only a manager or owner');
select t.eq('a stray price on an ordinary item is ignored (quote equals golden q1)',
  public.quote_order(t.oi('dosa', 2, '1'), 0, null, null), (select result from t.gold where phase = 'before' and label = 'q1'));
select t.as_su('mgr');
select set_config('t.openbill', (public.create_order((t.oi('openp', 2, '200') || t.oi('dosa', 1, null)), 'dine_in', t.id('T1'), null, null, null, 0, null, false, null, null, null, null))->>'order_id', false);
select t.same('bill stores the typed price and flags only that line',
  (select jsonb_agg(jsonb_build_object('n', product_name, 'p', unit_price, 'open', open_price, 'tax', line_tax) order by product_name) from public.order_items where order_id = current_setting('t.openbill')::uuid),
  '[{"n":"Masala Dosa","p":120,"open":false,"tax":6},{"n":"Open Item","p":200,"open":true,"tax":20}]');
select t.same('one audit row per open-priced line, with product, price, qty, who',
  (select jsonb_agg(jsonb_build_object('a', action, 'p', new_value->>'product', 'price', new_value->>'price', 'qty', new_value->>'qty', 'by_manager', user_id = (select id from public.users where auth_user_id = t.id('auth:mgr')))) from public.audit_logs where action = 'order.open_price'),
  '[{"a":"order.open_price","p":"Open Item","price":"200.00","qty":"2.000","by_manager":true}]');
select public.add_order_items(current_setting('t.openbill')::uuid, t.oi('openp', 1, '55'));
select t.is_('add_order_items with an open item is audited too (2 rows total)', (select count(*) from public.audit_logs where action = 'order.open_price') = 2);
select t.is_('open-priced lines add into the bill: subtotal 575, tax 28.76 (2.5% + 2.5% rounded per tax)', (select subtotal = 575 and tax_total = 28.76 from public.orders where id = current_setting('t.openbill')::uuid));
select t.as_su('cash');
select t.err('cashier adding an open item to a bill is refused', format('select public.add_order_items(%L, %L::jsonb)', current_setting('t.openbill'), '[{"product_id":"' || t.id('openp') || '","qty":1,"price":55}]'), 'Only a manager or owner');
reset role;
do $$ declare m text; begin
  perform t.as_su('cash');
  begin perform public.quote_order(t.oi('openp', 1, '200'), 0, false, null); m := 'NO ERROR'; exception when others then m := sqlerrm; end;
  perform t.is_('the cashier refusal does not name the right in brackets (the app would offer a PIN prompt that cannot work)', m like 'Only a manager or owner%' and m not like '%(order.%', m);
end $$;
-- turning the flag off returns the product to its list price path
update public.products set is_open_price = false where id = t.id('openp');
select t.is_('flag change audited as menu.open_price_flag', (select count(*) from public.audit_logs where action = 'menu.open_price_flag' and entity_id = t.id('openp')) = 1);
select t.as_su('cash');
select t.same('open flag off: product is an ordinary 0-priced item (price key ignored)', (public.quote_order(t.oi('openp', 1, '500'), 0, false, null)->>'subtotal')::numeric::text::jsonb, '0');
reset role;

-- ================================================================ 4. tips (133)
select t.as_su('cash');
select set_config('t.b1', (public.create_order(t.items('{"dosa":2,"cola":1}'), 'dine_in', t.id('T2'), null, null, null, 0, null, false, null, null, null, null))->>'order_id', false);
select set_config('t.grand1', (select grand_total::text from public.orders where id = current_setting('t.b1')::uuid), false);
select t.err('negative tip refused', format('select public.pay_order(%L, %L, null, null, null, null, -5)', current_setting('t.b1'), t.ctx('pmCash')), 'cannot be negative');
select t.is_('a refused tip leaves the bill unpaid with no payment', (select payment_status from public.orders where id = current_setting('t.b1')::uuid) = 'unpaid' and not exists (select 1 from public.payments where order_id = current_setting('t.b1')::uuid));
select set_config('t.pay1', (public.pay_order(current_setting('t.b1')::uuid, t.ctx('pmUpi'), null, null, null, 'a0000000-0000-0000-0000-000000000001', 25.456))::text, false);
select t.same('pay_order result carries the tip, balance stays zero', (current_setting('t.pay1')::jsonb - 'order_id' - 'bill_number'), '{"amount":' || current_setting('t.grand1') || ',"cash_rounding":0,"change":0,"paid":true,"balance":0,"tip":25.46}');
select t.is_('payment amount is exactly the bill (tip not in payments.amount)', (select sum(amount) from public.payments where order_id = current_setting('t.b1')::uuid) = current_setting('t.grand1')::numeric);
select t.is_('bill paid_total / covered exclude the tip', (select paid_total = grand_total and app.order_covered(id) = grand_total and payment_status = 'paid' from public.orders where id = current_setting('t.b1')::uuid));
select t.same('tip row stored with method, waiter/cashier, shift, business date, payment link',
  (select jsonb_build_object('amount', tp.amount, 'method_ok', tp.method_id = t.ctx('pmUpi'), 'by_cashier', tp.received_by = (select id from public.users where auth_user_id = t.id('auth:cash')),
          'shift_ok', tp.shift_id is not null and tp.shift_id = py.shift_id, 'date_ok', tp.business_date = o.business_date, 'pay_ok', tp.payment_id = py.id, 'branch_ok', tp.branch_id = o.branch_id)
     from public.order_tips tp join public.payments py on py.id = tp.payment_id join public.orders o on o.id = tp.order_id where tp.order_id = current_setting('t.b1')::uuid),
  '{"amount":25.46,"method_ok":true,"by_cashier":true,"shift_ok":true,"date_ok":true,"pay_ok":true,"branch_ok":true}');
select t.is_('audit order.tip written', (select count(*) from public.audit_logs where action = 'order.tip' and entity_id = current_setting('t.b1')::uuid) = 1);
-- idempotent replay with the same client_ref does not tip twice
select public.pay_order(current_setting('t.b1')::uuid, t.ctx('pmUpi'), null, null, null, 'a0000000-0000-0000-0000-000000000001', 25.456);
select t.is_('replay with the same client_ref writes no second tip', (select count(*) from public.order_tips where order_id = current_setting('t.b1')::uuid) = 1);
-- zero / null tip writes nothing and returns the old shape
select set_config('t.b2', (public.create_order(t.items('{"thali":1}'), 'takeaway', null, null, null, null, 0, null, false, null, null, null, null))->>'order_id', false);
select t.is_('zero tip: result has no tip key', not ((public.pay_order(current_setting('t.b2')::uuid, t.ctx('pmCash'), null, null, null, null, 0) - 'order_id' - 'bill_number') ? 'tip'));
select set_config('t.b3', (public.create_order(t.items('{"thali":1}'), 'takeaway', null, null, null, null, 0, null, false, null, null, null, null))->>'order_id', false);
select public.pay_order(current_setting('t.b3')::uuid, t.ctx('pmCash'), null, null, null, null, null);
select t.is_('zero and null tips write no order_tips row', (select count(*) from public.order_tips where order_id in (current_setting('t.b2')::uuid, current_setting('t.b3')::uuid)) = 0);
-- part payments: a tip on each part
select set_config('t.b4', (public.create_order(t.items('{"biryani":2}'), 'dine_in', t.id('T1'), null, null, null, 0, null, false, null, null, null, null))->>'order_id', false);
select public.pay_order(current_setting('t.b4')::uuid, t.ctx('pmCash'), null, 100, null, null, 5);
select public.pay_order(current_setting('t.b4')::uuid, t.ctx('pmCash'), 1000, null, null, null, 10);
select t.same('part payments: one tip row per payment', (select jsonb_agg(amount order by amount) from public.order_tips where order_id = current_setting('t.b4')::uuid), '[5,10]');
select t.is_('part payments: paid_total is the bill only', (select paid_total = grand_total from public.orders where id = current_setting('t.b4')::uuid));
-- shift cash / day close unchanged by tips
reset role; select t.as_su('owner');
select t.is_('shift expected cash = cash payments (tips excluded)',
  (select (s->>'expected_cash')::numeric = (select sum(py.amount) from public.payments py join public.payment_methods pm on pm.id = py.payment_method_id where pm.kind = 'cash' and py.shift_id = (s->>'shift_id')::uuid)
     from jsonb_array_elements(app.z_report((select id from public.business_days where branch_id = t.ctx('b') and status = 'open'))->'shifts') s limit 1));
select t.is_('Z report payments equal payments.amount (tips excluded)',
  (select coalesce(sum((p->>'amount')::numeric), 0) from jsonb_array_elements(app.z_report((select id from public.business_days where branch_id = t.ctx('b') and status = 'open'))->'payments') p)
  = (select sum(amount) from public.payments where restaurant_id = t.ctx('r')));
select t.is_('tax is untouched by tips: orders.tax_total = sum of line tax', (select bool_and(o.tax_total = (select sum(line_tax) from public.order_items i where i.order_id = o.id)) from public.orders o where o.id = current_setting('t.b1')::uuid));
-- voided bill: tips stay as rows but any report joining orders.status excludes them; the void itself works
select t.as_su('owner');
select set_config('t.b5', (public.create_order(t.items('{"dosa":1}'), 'takeaway', null, null, null, null, 0, null, false, null, null, null, null))->>'order_id', false);
select public.pay_order(current_setting('t.b5')::uuid, t.ctx('pmCash'), null, null, null, null, 7);
select public.void_order(current_setting('t.b5')::uuid, 'test void');
select t.is_('tip on a voided bill is excluded by the reporting join (status <> voided)',
  (select coalesce(sum(tp.amount), 0) from public.order_tips tp join public.orders o on o.id = tp.order_id where o.status <> 'voided' and tp.restaurant_id = t.ctx('r')) = 25.46 + 5 + 10
  and exists (select 1 from public.order_tips where order_id = current_setting('t.b5')::uuid));
-- credit note refunds the bill, not the tip
select t.is_('credit notes do not touch order_tips (no code path)', not exists (select 1 from pg_proc where proname = 'issue_credit_note' and prosrc ilike '%order_tips%'));
-- RLS
select t.as_('cash');
select t.is_('cashier can read this restaurant''s tips', (select count(*) from public.order_tips) >= 3);
select t.err('direct insert refused', format('insert into public.order_tips (restaurant_id, order_id, amount) values (%L, %L, 1)', t.ctx('r'), current_setting('t.b1')), 'permission denied');
select t.err('direct update refused', 'update public.order_tips set amount = 1', 'permission denied');
select t.err('direct delete refused', 'delete from public.order_tips', 'permission denied');
reset role; select t.as_('other');
select t.is_('another restaurant sees none of these tips', (select count(*) from public.order_tips) = 0);
reset role;
select t.is_('amount > 0 is a table check', exists (select 1 from pg_constraint where conrelid = 'public.order_tips'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%amount > (0)%'));
select t.is_('anon has no access to order_tips', not has_table_privilege('anon', 'public.order_tips', 'select'));

\o
select (case when ok then 'PASS ' else 'FAIL ' end) || label || coalesce(E'\n   ' || detail, '') from t.res order by n;
select 'TOTAL ' || count(*) || ' checks, ' || count(*) filter (where not ok) || ' failed' from t.res;
