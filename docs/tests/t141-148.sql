-- t141-148.sql: proves migrations 141 (billing core: discount block, prep time, loyalty slot), 142 (floor_status prep), 145 (customers + loyalty),
-- 146 (customer reports), 147 (offline sync: guest + block) and 148 (erase lists, grants). Runs AFTER t141-148-pre.sql (same database, fixtures and the "before"
-- results) and after 141..148 were applied (run-t141-148.sh). 143 / 144 (inventory) are tested by their own builder; here only what 148 needs from them.
-- Test databases only.
\set ON_ERROR_STOP off
\pset pager off
\o /dev/null
reset role;
create function t.pid(p text) returns uuid language sql immutable as $$ select t.id('p:' || p) $$;
create function t.prod(p_key text, p_name text, p_price numeric, p_group text default 'gst18', p_restricted boolean default false, p_prep int default null) returns void language plpgsql as $$
begin
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price, discount_restricted, prep_minutes)
  values (t.id(p_key), t.ctx('r'), t.ctx('cat'), t.ctx(p_group), p_name, p_price, p_restricted, p_prep);
end $$;
create function t.one(p_items jsonb) returns jsonb language sql immutable as $$ select p_items $$;
-- a bill with the given product -> qty map (qty only)
create function t.new_bill(p_who text, p_items jsonb, p_disc numeric default 0, p_table text default null, p_extra jsonb default null) returns uuid language plpgsql as $$
declare v jsonb;
begin
  perform t.as_su(p_who);
  v := public.create_order(t.items(p_items), case when p_table is null then 'takeaway' else 'dine_in' end, case when p_table is null then null else t.id(p_table) end,
                           null, null, null, p_disc, 'test', false, null, null, null, p_extra);
  perform set_config('role', 'postgres', false);
  return (v->>'order_id')::uuid;
end $$;
create function t.pay(p_who text, p_order uuid) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform t.as_su(p_who);
  v := public.pay_order(p_order, t.ctx('pmCash'), 100000, null);
  perform set_config('role', 'postgres', false);
  return v;
end $$;

-- ================================================================ 1. the money core did not change for ordinary bills
select t.run_golden('after', 'T3', 'T4');
select t.eq('1.' || row_number() over (order by b.label) || ' golden ' || b.label || ' identical before/after 141..148 (byte-for-byte jsonb)', a.result, b.result)
  from t.gold b join t.gold a on a.label = b.label and a.phase = 'after' where b.phase = 'before' order by b.label;
select t.is_('1.0 golden: 14 scenarios compared', (select count(*) from t.gold where phase = 'after') = 14 and (select count(*) from t.gold where phase = 'before') = 14);

-- random bills: the new app.calc_bill equals the OLD one (kept as t.calc_old) for every bill without restricted lines or points, errors included
do $$
declare i int; k int; n int; j jsonb; lines jsonb; a jsonb; b jsonb; ea text; eb text; bad int := 0; errs int := 0; sub numeric; share numeric; p numeric; q numeric; first_bad text;
  modes text[] := array['none', 'nearest_1', 'nearest_0_05', 'nearest_0_10'];
begin
  perform setseed(0.314159);
  for i in 1 .. 3000 loop
    n := case when random() < 0.15 then 8 + floor(random() * 6)::int else 1 + floor(random() * 5)::int end; lines := '[]'::jsonb; sub := 0;
    for k in 1 .. n loop
      p := case when random() < 0.15 then 0.01 else round((random() * 900)::numeric + 0.01, 2) end;
      q := case when random() < 0.2 then round((random() * 4 + 0.1)::numeric, 3) else (1 + floor(random() * 9))::numeric end;
      sub := sub + round(p * q, 2);
      lines := lines || jsonb_build_object('key', k, 'price', p, 'qty', q, 'inclusive', random() < 0.4,
        'comps', (case floor(random() * 4)::int when 0 then '[]' when 1 then '[{"name":"GST","rate":5,"compound":false}]'
                  when 2 then '[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]'
                  else '[{"name":"A","rate":5,"compound":true},{"name":"B","rate":9,"compound":false}]' end)::jsonb);
    end loop;
    share := case when random() < 0.1 then round((random() * 0.8)::numeric, 6) else 0 end;
    j := jsonb_build_object('lines', lines,
      'discount', case when share > 0 or random() < 0.35 then 0 when random() < 0.2 then round((random() * 0.5)::numeric, 2) else round((random() * sub * 1.2)::numeric, 2) end,
      'sc_percent', case when random() < 0.3 then round((random() * 12)::numeric, 1) else 0 end, 'sc_taxable', random() < 0.5,
      'senior', case when share > 0 then jsonb_build_object('share', share, 'rate', 20) else null end, 'rounding', modes[1 + floor(random() * 4)::int]);
    a := null; b := null; ea := null; eb := null;
    begin a := app.calc_bill(j); exception when others then ea := sqlerrm; end;
    begin b := t.calc_old(j); exception when others then eb := sqlerrm; end;
    if ea is not null then errs := errs + 1; end if;
    if a is distinct from b or ea is distinct from eb then bad := bad + 1; first_bad := coalesce(first_bad, j::text); end if;
  end loop;
  perform t.is_('1.20 random bills: new calc_bill = old calc_bill for 3000 bills (' || errs || ' of them are refusals, both sides refuse alike)', bad = 0, 'first difference: ' || coalesce(first_bad, ''));
end $$;

-- random bills WITH restricted lines: per line the answer is what the old function says for that line alone (restricted: no discount) or for the unrestricted lines together
do $$
declare i int; k int; n int; j jsonb; lines jsonb; a jsonb; o jsonb; el jsonb; d numeric; pool numeric; sub numeric; bad int := 0; first_bad text; p numeric; q numeric; nd boolean; l jsonb; xl jsonb; any_r boolean;
  modes text[] := array['none', 'nearest_1', 'nearest_0_05', 'nearest_0_10']; sc numeric; sct boolean; ld numeric; chk int := 0;
begin
  perform setseed(0.271828);
  for i in 1 .. 2000 loop
    n := case when random() < 0.15 then 8 + floor(random() * 6)::int else 2 + floor(random() * 5)::int end; lines := '[]'::jsonb; el := '[]'::jsonb; sub := 0; pool := 0; any_r := false;
    for k in 1 .. n loop
      p := case when random() < 0.15 then 0.01 else round((random() * 900)::numeric + 0.01, 2) end;
      q := case when random() < 0.2 then round((random() * 4 + 0.1)::numeric, 3) else (1 + floor(random() * 9))::numeric end;
      nd := random() < 0.4; if nd then any_r := true; end if;
      l := jsonb_build_object('key', k, 'price', p, 'qty', q, 'inclusive', random() < 0.4,
        'comps', (case floor(random() * 4)::int when 0 then '[]' when 1 then '[{"name":"GST","rate":5,"compound":false}]'
                  when 2 then '[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]'
                  else '[{"name":"A","rate":5,"compound":true},{"name":"B","rate":9,"compound":false}]' end)::jsonb);
      sub := sub + round(p * q, 2);
      if nd then lines := lines || (l || '{"no_disc":true}'::jsonb); else lines := lines || l; pool := pool + round(p * q, 2); el := el || l; end if;
    end loop;
    d := case when random() < 0.2 then 0 when random() < 0.2 then round((random() * 0.5)::numeric, 2) else round((random() * sub * 1.2)::numeric, 2) end;
    sc := case when random() < 0.3 then round((random() * 12)::numeric, 1) else 0 end; sct := random() < 0.5;
    ld := case when random() < 0.3 then round((random() * sub * 0.5)::numeric, 2) else 0 end;
    j := jsonb_build_object('lines', lines, 'discount', d, 'loyalty_discount', ld, 'sc_percent', sc, 'sc_taxable', sct, 'rounding', 'none');
    begin a := app.calc_bill(j); exception when others then a := jsonb_build_object('err', sqlerrm); end;
    if a ? 'err' then bad := bad + 1; first_bad := coalesce(first_bad, a::text || ' ' || j::text); continue; end if;
    -- the unrestricted lines alone, with the typed + points discount, in the old function
    o := case when jsonb_array_length(el) = 0 then null
              else t.calc_old(jsonb_build_object('lines', el, 'discount', least(d, pool) + least(ld, pool - least(d, pool)), 'sc_percent', sc, 'sc_taxable', sct, 'rounding', 'none')) end;
    for k in 0 .. n - 1 loop
      xl := a->'lines'->k;
      if (lines->k) ? 'no_disc' then
        if (xl->>'discount')::numeric <> 0 then bad := bad + 1; first_bad := coalesce(first_bad, 'restricted line got a discount ' || j::text); end if;
        if xl - 'key' is distinct from (t.calc_old(jsonb_build_object('lines', jsonb_build_array(lines->k), 'discount', 0, 'sc_percent', sc, 'sc_taxable', sct, 'rounding', 'none'))->'lines'->0) - 'key' then
          bad := bad + 1; first_bad := coalesce(first_bad, 'restricted line differs ' || j::text);
        end if;
      end if;
    end loop;
    if o is not null then
      -- every unrestricted line equals the same line in the old result (matched by key)
      if exists (select 1 from jsonb_array_elements(a->'lines') x join jsonb_array_elements(o->'lines') y on y->'key' = x->'key' where x is distinct from y)
         or (select count(*) from jsonb_array_elements(o->'lines')) <> (select count(*) from jsonb_array_elements(a->'lines') x where not ((lines->((x->>'key')::int - 1)) ? 'no_disc')) then
        bad := bad + 1; first_bad := coalesce(first_bad, 'unrestricted lines differ ' || j::text);
      end if;
    end if;
    -- totals: discount = typed part capped at the pool, loyalty part capped at what is left of the pool
    if (a->>'discount')::numeric <> least(d, pool) or coalesce((a->>'loyalty_discount')::numeric, 0) <> (case when ld > 0 then least(ld, pool - least(d, pool)) else 0 end)
       or (any_r and (a->>'discountable_subtotal')::numeric <> pool) or (not any_r and a ? 'discountable_subtotal') then
      bad := bad + 1; first_bad := coalesce(first_bad, 'discount totals ' || a::text || ' ' || j::text);
    end if;
    chk := chk + 1;
  end loop;
  perform t.is_('1.21 random bills with restricted lines and points (' || chk || '): restricted lines get 0, every other line equals the old function on the discountable lines, totals cap at the pool', bad = 0, 'first problem: ' || coalesce(first_bad, ''));
end $$;

-- ================================================================ 2. discount block (141)
select t.as_su('owner');
select t.prod('pizza', 'Pizza', 100, 'gst18', true);
select t.prod('pasta', 'Pasta', 100, 'gst18');
select t.prod('wine', 'Wine', 250, 'gst18', true);
select t.prod('soup', 'Soup', 60, 'gst5');
select t.prod('snack7', 'Inclusive Restricted', 107, 'ginc', true);
reset role;

select t.same('2.1 quote: restricted A 100 + B 100, 18% exclusive, discount 20 -> A tax 18.00, B base 80 tax 14.40, total 212.40 (the plan says 232.40: 100+80+32.40 is 212.40)',
  (select public.quote_order(t.items('{"pizza":1,"pasta":1}'), 20, false, null) from (select t.as_su('owner')) s) - 'lines' - 'service_charge_available' - 'service_charge_on' - 'service_charge_percent' - 'service_charge_label' - 'cash_rounding' - 'taxes',
  '{"subtotal":200,"discount":20,"senior_discount":0,"tax_exempt_amount":0,"exempt_sales":0,"service_charge":0,"tax_total":32.4,"tax_included":0,"net_sales":180,"before_round":212.4,"rounding":-0.4,"grand_total":212,"discountable_subtotal":100}');
select t.same('2.2 quote: per-line totals (restricted 118.00, other 94.40)', (select jsonb_agg(l->'total' order by (l->>'key')::int) from jsonb_array_elements((select public.quote_order(t.items('{"pizza":1,"pasta":1}'), 20, false, null) from (select t.as_su('owner')) s)->'lines') l), '[94.4, 118]');  -- key 0 = pasta (jsonb sorts the product map by name)
select t.same('2.3 a quote with no restricted lines has no new keys', (select jsonb_agg(k order by k collate "C") from jsonb_object_keys((select public.quote_order(t.items('{"pasta":1}'), 20, false, null) from (select t.as_su('owner')) s)) k),
  '["before_round","cash_rounding","discount","exempt_sales","grand_total","lines","net_sales","rounding","senior_discount","service_charge","service_charge_available","service_charge_label","service_charge_on","service_charge_percent","subtotal","tax_exempt_amount","tax_included","tax_total","taxes"]');
reset role;

select t.new_bill('owner', '{"pizza":1,"pasta":1}', 20, 'T5') as "bA" \gset
select t.same('2.4 create_order: same numbers as the quote; pizza keeps full tax, pasta carries the discount; order_discounts = one fixed_amount of 20',
  t.snap(:'bA'::uuid) #- '{payments}', '{"order":{"subtotal":200,"discount":20,"tax":32.4,"sc":0,"rounding":-0.4,"grand":212,"paid":0,"pstatus":"unpaid","tax_included":0,"exempt":0,"covered":0},
   "items":[{"name":"Pasta","unit":100,"qty":1,"mod":0,"sub":100,"disc":20,"tax":14.4,"total":94.4,"incl":false,"net":80,"sc":0,"taxinc":0,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]},
            {"name":"Pizza","unit":100,"qty":1,"mod":0,"sub":100,"disc":0,"tax":18,"total":118,"incl":false,"net":100,"sc":0,"taxinc":0,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]}],
   "discounts":[{"type":"fixed_amount","value":20,"amount":20}]}');
select t.q('2.5 order_items.discount_blocked is a snapshot: pizza true, pasta false', (select jsonb_agg(discount_blocked order by product_name) from public.order_items where order_id = :'bA'::uuid), '[false, true]');

-- more than the discountable part: cut silently by create_order / quote; more than the whole bill still refused
select t.new_bill('owner', '{"pizza":1,"pasta":1}', 150, 'T6') as "bB" \gset
select t.same('2.6 create_order with a discount of 150 (pool is 100): cut to 100, total 118 (pizza) + 0 (pasta)', t.snap(:'bB'::uuid) #- '{items}' #- '{payments}',
  '{"order":{"subtotal":200,"discount":100,"tax":18,"sc":0,"rounding":0,"grand":118,"paid":0,"pstatus":"unpaid","tax_included":0,"exempt":0,"covered":0},"discounts":[{"type":"fixed_amount","value":100,"amount":100}]}');
select t.q('2.7 the quote for the same input gives the same grand total', (select public.quote_order(t.items('{"pizza":1,"pasta":1}'), 150, false, null)->'grand_total' from (select t.as_su('owner')) s), '118');
reset role;
select t.as_su('owner');
select t.err('2.8 a discount above the whole bill (250 of 200) is still refused with the old message', $q$ select public.create_order(t.items('{"pizza":1,"pasta":1}'), 'takeaway', null, null, null, null, 250, 'x', false, null, null, null, null) $q$, 'The discount (250.00) is more than the bill (200.00)');
reset role;
select t.q('2.9 the refusal left no bill behind', (select count(*) from public.orders where subtotal = 200 and discount_total = 250), '0');

-- all restricted
select t.new_bill('owner', '{"pizza":2,"wine":1}', 50, 'T1') as "bC" \gset
select t.same('2.10 all lines restricted: a typed discount of 50 gives 0, tax on the full price, no order_discounts row', t.snap(:'bC'::uuid) #- '{items}' #- '{payments}',
  '{"order":{"subtotal":450,"discount":0,"tax":81,"sc":0,"rounding":0,"grand":531,"paid":0,"pstatus":"unpaid","tax_included":0,"exempt":0,"covered":0},"discounts":[]}');
select t.as_su('owner');
select t.err('2.11 adjust_order on an all-restricted bill refuses with the pool message', format('select public.adjust_order(%L, 10, %L)', :'bC', 'test'), 'The discount can be at most 0.00 (some items on this bill cannot be discounted).');
select t.err('2.12 adjust_order on the mixed bill: 150 of a pool of 100 refused with the pool', format('select public.adjust_order(%L, 150, %L)', :'bA', 'test'), 'The discount can be at most 100.00 (some items on this bill cannot be discounted).');
select public.adjust_order(:'bA'::uuid, 40, 'regular guest') as adj \gset
reset role;
select t.same('2.13 adjust_order to 40: pasta base 60 tax 10.80, pizza untouched, total 188.80; the fixed_amount row follows', t.snap(:'bA'::uuid) #- '{payments}' #- '{items}',
  '{"order":{"subtotal":200,"discount":40,"tax":28.8,"sc":0,"rounding":0.2,"grand":189,"paid":0,"pstatus":"unpaid","tax_included":0,"exempt":0,"covered":0},"discounts":[{"type":"fixed_amount","value":40,"amount":40}]}');
select t.as_su('owner');
select public.adjust_order(:'bA'::uuid, 100, 'whole pool') as adj2 \gset
reset role;
select t.q('2.14 a discount exactly equal to the pool is accepted: pasta free, total = pizza 118', (select grand_total from public.orders where id = :'bA'::uuid), '118');

-- tax-inclusive restricted line with an unrestricted one (ginc 7% inclusive): the restricted one keeps its 107, tax inside it 7
select t.same('2.15 inclusive: restricted 107 (7% inside) + 107 unrestricted, discount 20 -> 107 + 87 = 194, tax inside 7 + 5.69',
  (select jsonb_build_object('g', q->'grand_total', 't', q->'tax_included', 'd', q->'discount', 'p', q->'discountable_subtotal')
     from (select public.quote_order(jsonb_build_array(jsonb_build_object('product_id', t.id('snack7'), 'qty', 1), jsonb_build_object('product_id', t.id('inc'), 'qty', 1)), 20, false, null) q from (select t.as_su('owner')) s) z),
  '{"g":194,"t":12.69,"d":20,"p":107}');
reset role;

-- calc_bill directly: rounding remainder goes to the largest ELIGIBLE line; all restricted; bigger than the pool; senior ignores the flag
select t.same('2.16 remainder on the largest eligible line (the restricted line is the largest of all): 10 over 33.33 / 33.33 / 33.34 -> 3.33, 3.33, 3.34',
  (select jsonb_agg((l->>'discount')::numeric order by (l->>'key')::int) from jsonb_array_elements(app.calc_bill('{"lines":[{"key":1,"price":500,"qty":1,"comps":[],"no_disc":true},{"key":2,"price":33.33,"qty":1,"comps":[]},{"key":3,"price":33.33,"qty":1,"comps":[]},{"key":4,"price":33.34,"qty":1,"comps":[]}],"discount":10}')->'lines') l),
  '[0, 3.33, 3.33, 3.34]');
select t.same('2.17 all lines restricted: pool 0, discount 0, discountable_subtotal 0',
  (select jsonb_build_object('d', c->'discount', 'p', c->'discountable_subtotal', 'g', c->'grand_total') from (select app.calc_bill('{"lines":[{"key":1,"price":80,"qty":2,"comps":[],"no_disc":true}],"discount":30,"loyalty_discount":10}') c) z), '{"d":0,"p":0,"g":160}');
select t.same('2.18 discount larger than the pool is capped, points take what is left of the pool',
  (select jsonb_build_object('d', c->'discount', 'l', c->'loyalty_discount', 'p', c->'discountable_subtotal', 'g', c->'grand_total') from (select app.calc_bill('{"lines":[{"key":1,"price":100,"qty":1,"comps":[],"no_disc":true},{"key":2,"price":50,"qty":1,"comps":[]},{"key":3,"price":30,"qty":1,"comps":[]}],"discount":60,"loyalty_discount":40}') c) z), '{"d":60,"l":20,"p":80,"g":100}');
select t.same('2.19 a small discount over many lines still adds up exactly on the eligible lines (fallback spread)',
  (select jsonb_build_object('sum', (select sum((l->>'discount')::numeric) from jsonb_array_elements(c->'lines') l), 'restricted', (c->'lines'->0->>'discount')::numeric, 'min', (select min((l->>'discount')::numeric) from jsonb_array_elements(c->'lines') l))
     from (select app.calc_bill((select jsonb_build_object('discount', 0.07, 'lines', jsonb_build_array(jsonb_build_object('key', 1, 'price', 400, 'qty', 1, 'comps', '[]'::jsonb, 'no_disc', true)) || jsonb_agg(jsonb_build_object('key', g + 1, 'price', 0.01, 'qty', 1, 'comps', '[]'::jsonb) || case when g = 5 then '{"price":9.99}'::jsonb else '{}'::jsonb end)) from generate_series(1, 9) g)) c) z),
  '{"sum":0.07,"restricted":0,"min":0}');
select t.same('2.20 senior/PWD share ignores the flag (statutory): a restricted line still gets the senior discount',
  (select jsonb_build_object('s', (c->'lines'->0->>'senior_discount')::numeric, 'd', c->'discount') from (select app.calc_bill('{"lines":[{"key":1,"price":100,"qty":1,"comps":[],"no_disc":true}],"discount":0,"senior":{"share":1,"rate":20}}') c) z), '{"s":20,"d":0}');
select t.err('2.21 senior/PWD still cannot be combined with another discount', $q$ select app.calc_bill('{"lines":[{"key":1,"price":100,"qty":1,"comps":[]}],"discount":5,"senior":{"share":1,"rate":20}}') $q$, 'cannot be combined with another discount');
select t.err('2.22 ... nor with a points discount', $q$ select app.calc_bill('{"lines":[{"key":1,"price":100,"qty":1,"comps":[]}],"loyalty_discount":5,"senior":{"share":1,"rate":20}}') $q$, 'cannot be combined with loyalty points');

-- cancel an item: the pool shrinks and the typed discount is cut to it
select t.new_bill('owner', '{"pizza":1,"pasta":1,"cola":1}', 130, 'T2') as "bD" \gset
select t.q('2.23 before: discount 130 of a pool of 160 (pasta 100 + cola 60)', (select discount_total from public.orders where id = :'bD'::uuid), '130');
select t.as_su('owner');
select public.cancel_order_item((select id from public.order_items where order_id = :'bD'::uuid and product_name = 'Cola'), 1, 'wrong item') as cx \gset
reset role;
select t.same('2.24 after cancelling the cola the pool is 100: discount cut to 100, order_discounts follows, total 118', t.snap(:'bD'::uuid) #- '{items}' #- '{payments}',
  '{"order":{"subtotal":200,"discount":100,"tax":18,"sc":0,"rounding":0,"grand":118,"paid":0,"pstatus":"unpaid","tax_included":0,"exempt":0,"covered":0},"discounts":[{"type":"fixed_amount","value":100,"amount":100}]}');

-- add_order_items goes through the same recalculation (a restricted dish added to a bill with a discount)
select t.new_bill('owner', '{"pasta":2}', 50, 'T3') as "bE" \gset
select t.as_su('owner');
select public.add_order_items(:'bE'::uuid, t.items('{"pizza":1}')) as ai \gset
reset role;
select t.same('2.25 add a restricted pizza to a bill with discount 50: the discount stays 50 on the pasta, pizza full tax', t.snap(:'bE'::uuid) #- '{payments}' #- '{items}',
  '{"order":{"subtotal":300,"discount":50,"tax":45,"sc":0,"rounding":0,"grand":295,"paid":0,"pstatus":"unpaid","tax_included":0,"exempt":0,"covered":0},"discounts":[{"type":"fixed_amount","value":50,"amount":50}]}');

-- ================================================================ 2b. the other bill functions keep the flag; menu flag audit; sizes follow; prep range
reset role;
insert into public.dining_tables (id, restaurant_id, branch_id, table_number, seats) values
  (t.id('T7'), t.ctx('r'), t.ctx('b'), 'T7', 4), (t.id('T8'), t.ctx('r'), t.ctx('b'), 'T8', 4), (t.id('T9'), t.ctx('r'), t.ctx('b'), 'T9', 4),
  (t.id('T10'), t.ctx('r'), t.ctx('b'), 'T10', 4), (t.id('T11'), t.ctx('r'), t.ctx('b'), 'T11', 4), (t.id('T12'), t.ctx('r'), t.ctx('b'), 'T12', 4);
select t.new_bill('owner', '{"pizza":2,"pasta":1}', 0, 'T7') as "bF" \gset
select t.as_su('owner');
select public.split_order(:'bF'::uuid, jsonb_build_array(jsonb_build_object('order_item_id', (select id from public.order_items where order_id = :'bF'::uuid and product_name = 'Pizza'), 'qty', 1))) as "sp" \gset
reset role;
select t.q('2.26 split_order: the cloned pizza line is still restricted, and so is the original (one pizza on each bill)',
  (select jsonb_agg(discount_blocked) from public.order_items where product_name = 'Pizza' and order_id in (select id from public.orders where id = :'bF'::uuid or id = (:'sp'::jsonb->>'order_id')::uuid)), '[true, true]');

select t.new_bill('owner', '{"pizza":1,"pasta":1}', 0, 'T8') as "bG" \gset
select t.new_bill('owner', '{"cola":1}', 0, 'T9') as "bH" \gset
select t.as_su('owner');
select public.move_order_items(:'bG'::uuid, jsonb_build_array(jsonb_build_object('order_item_id', (select id from public.order_items where order_id = :'bG'::uuid and product_name = 'Pizza'), 'qty', 1)), t.id('T9')) as "mv" \gset
reset role;
select t.q('2.27 move_order_items: the moved pizza keeps the restriction on the target bill',
  (select discount_blocked from public.order_items where order_id = :'bH'::uuid and product_name = 'Pizza'), 'true');
select t.new_bill('owner', '{"pizza":1}', 0, 'T10') as "bI" \gset
select t.new_bill('owner', '{"pasta":1}', 0, 'T11') as "bJ" \gset
select t.as_su('owner');
select public.merge_orders(:'bJ'::uuid, :'bI'::uuid) as "mg" \gset
reset role;
select t.q('2.28 merge_orders: the restricted line moved onto the other bill is still restricted',
  (select jsonb_agg(discount_blocked order by product_name) from public.order_items where order_id = :'bJ'::uuid), '[false, true]');
select t.as_su('owner');
select public.adjust_order(:'bJ'::uuid, 30, 'merged bill') as "adj3" \gset
reset role;
select t.q('2.29 ... and a discount on the merged bill goes to the pasta only (pizza line discount 0, pasta 30)',
  (select jsonb_agg(line_discount order by product_name) from public.order_items where order_id = :'bJ'::uuid), '[30, 0]');

-- the flag on a dish: audited once (dish only), sizes follow silently; prep time the same
insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values (t.id('burger'), t.ctx('r'), t.ctx('cat'), t.ctx('gst18'), 'Burger', 150);
insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price, parent_id, variant_name) values
  (t.id('burger_l'), t.ctx('r'), t.ctx('cat'), t.ctx('gst18'), 'Burger (Large)', 220, t.id('burger'), 'Large');
update public.products set discount_restricted = true where id = t.id('burger');
select t.q('2.30 the dish flag is copied to its sizes', (select discount_restricted from public.products where id = t.id('burger_l')), 'true');
select t.q('2.31 one audit row for the dish flag, none for the size', (select count(*) from public.audit_logs where action = 'menu.discount_flag' and entity_id in (t.id('burger'), t.id('burger_l'))), '1');
select t.q('2.32 the audit row says which way it went', (select new_value->>'discount_restricted' from public.audit_logs where action = 'menu.discount_flag' and entity_id = t.id('burger')), '"true"');
update public.products set discount_restricted = true where id = t.id('burger');   -- no change: no new row
select t.q('2.33 saving the same flag again adds no audit row', (select count(*) from public.audit_logs where action = 'menu.discount_flag' and entity_id = t.id('burger')), '1');
update public.products set prep_minutes = 12 where id = t.id('burger');
select t.same('2.34 prep time follows to the size; one audit row for the dish', jsonb_build_object('size', (select prep_minutes from public.products where id = t.id('burger_l')),
  'audit', (select count(*) from public.audit_logs where action = 'menu.prep_time' and entity_id in (t.id('burger'), t.id('burger_l')))), '{"size":12,"audit":1}');
select t.err('2.35 prep time 0 is refused', $q$ update public.products set prep_minutes = 0 where id = t.id('burger') $q$, 'products_prep_minutes_range');
select t.err('2.36 prep time 241 is refused', $q$ update public.products set prep_minutes = 241 where id = t.id('burger') $q$, 'products_prep_minutes_range');
update public.products set prep_minutes = 240 where id = t.id('burger');
select t.q('2.37 prep time 240 and then null are accepted', (select prep_minutes from public.products where id = t.id('burger')), '240');
update public.products set prep_minutes = null where id = t.id('burger');
-- a size of a restricted dish is restricted on the bill (the flag of the size row is what a bill reads)
select t.new_bill('owner', jsonb_build_object('burger_l', 1, 'pasta', 1), 40) as "bK" \gset
select t.same('2.38 a restricted SIZE is restricted on the bill: 40 goes to the pasta only (pool 100)',
  (select jsonb_agg(jsonb_build_object('n', product_name, 'd', line_discount, 'b', discount_blocked) order by product_name) from public.order_items where order_id = :'bK'::uuid),
  '[{"n":"Burger (Large)","d":0,"b":true},{"n":"Pasta","d":40,"b":false}]');
-- complimentary: the whole bill comes off even when lines are restricted
select t.new_bill('owner', '{"pizza":1,"pasta":1}', 0) as "bL" \gset
select t.as_su('owner');
select public.make_complimentary(:'bL'::uuid, 'complimentary', 'owner guest') as "mc" \gset
reset role;
select t.same('2.39 complimentary bill with a restricted line: total 0, both lines free', (select jsonb_build_object('g', grand_total, 'd', jsonb_agg((select line_total from public.order_items i where i.order_id = o.id and i.product_name = 'Pizza')))
   from public.orders o where o.id = :'bL'::uuid group by o.grand_total), '{"g":0,"d":[0]}');
select t.q('2.40 ... and the flag stays on the line for the record', (select discount_blocked from public.order_items where order_id = :'bL'::uuid and product_name = 'Pizza'), 'true');

-- ================================================================ 3. floor_status with prep time (142)
reset role;
select t.prod('stew', 'Stew', 90, 'gst5', false, 90);
select t.prod('bread', 'Bread', 20, 'gst5', false, 10);
update public.products set prep_minutes = 20 where id = t.id('pasta');
select t.q('3.1 constants: grace 5, default 15', (select jsonb_build_array(app.kot_grace_min(), app.kot_default_min())), '[5, 15]');
insert into public.dining_tables (id, restaurant_id, branch_id, table_number, seats) values
  (t.id('F1'), t.ctx('r'), t.ctx('b'), 'F1', 4), (t.id('F2'), t.ctx('r'), t.ctx('b'), 'F2', 4), (t.id('F3'), t.ctx('r'), t.ctx('b'), 'F3', 4),
  (t.id('F4'), t.ctx('r'), t.ctx('b'), 'F4', 4), (t.id('F5'), t.ctx('r'), t.ctx('b'), 'F5', 4);
select t.new_bill('owner', '{"pasta":1,"soup":1}', 0, 'F1') as "fA" \gset
select t.new_bill('owner', '{"soup":1}', 0, 'F2') as "fB" \gset
select t.new_bill('owner', '{"soup":1}', 0, 'F3') as "fC1" \gset
select t.new_bill('owner', '{"stew":1}', 0, 'F3') as "fC2" \gset
select t.new_bill('owner', '{"pasta":1,"stew":1}', 0, 'F4') as "fD" \gset
select t.new_bill('owner', '{"bread":1}', 0, 'F5') as "fE" \gset
-- the clock is moved by editing the tickets (client_created_at is when the ticket was keyed)
update public.kitchen_tickets set client_created_at = now() - interval '10 minutes' where order_id = :'fA'::uuid;
update public.kitchen_tickets set client_created_at = now() - interval '20 minutes' where order_id = :'fB'::uuid;
update public.kitchen_tickets set client_created_at = now() - interval '30 minutes' where order_id = :'fC1'::uuid;
update public.kitchen_tickets set client_created_at = now() - interval '1 minutes' where order_id = :'fC2'::uuid;
update public.kitchen_tickets set client_created_at = now() - interval '40 minutes' where order_id = :'fD'::uuid;
update public.kitchen_ticket_items set status = 'cancelled' where order_item_id in (select id from public.order_items where order_id = :'fD'::uuid and product_name = 'Stew');
select t.as_su('owner');
create temp table fs as select * from public.floor_status();
reset role;
select t.same('3.2 columns: 13 old ones first, then kot_due_at, kot_prep_min, kot_ticket_at (migration 149 may add billed_bills, billed_at after them: only the first 16 are checked)',
  (select jsonb_agg(c order by o) from unnest((select proargnames from pg_proc where oid = 'public.floor_status()'::regprocedure)) with ordinality x(c, o) where o <= 16),
  '["table_id","table_number","seats","open_bills","open_total","oldest_open_at","kot_waiting","oldest_kot_at","reservation_id","reservation_at","reservation_name","reservation_party","db_now","kot_due_at","kot_prep_min","kot_ticket_at"]');
select t.same('3.3 F1: pasta (20 min) + soup (none) -> longest prep 20, due = ticket + 25 min',
  (select jsonb_build_object('prep', kot_prep_min, 'mins', round(extract(epoch from (kot_due_at - kot_ticket_at)) / 60), 'waiting', kot_waiting) from fs where table_number = 'F1'), '{"prep":20,"mins":25,"waiting":1}');
select t.same('3.4 F2: soup only (no prep time) -> no prep, due = ticket + 15 min (no grace)',
  (select jsonb_build_object('prep', kot_prep_min, 'mins', round(extract(epoch from (kot_due_at - kot_ticket_at)) / 60)) from fs where table_number = 'F2'), '{"prep":null,"mins":15}');
select t.same('3.5 F3: two tickets - the one due first is reported (the 30-minute-old soup, due 15 min after its start; the stew is due in 66 min)',
  (select jsonb_build_object('prep', kot_prep_min, 'waiting', kot_waiting, 'ticket_old', kot_ticket_at < now() - interval '25 minutes') from fs where table_number = 'F3'), '{"prep":null,"waiting":2,"ticket_old":true}');
select t.same('3.6 F4: the 90-minute stew line was cancelled -> only the pasta counts (prep 20)',
  (select jsonb_build_object('prep', kot_prep_min, 'mins', round(extract(epoch from (kot_due_at - kot_ticket_at)) / 60)) from fs where table_number = 'F4'), '{"prep":20,"mins":25}');
select t.same('3.7 F5: bread (10 min) -> prep 10, due ticket + 15 min',
  (select jsonb_build_object('prep', kot_prep_min, 'mins', round(extract(epoch from (kot_due_at - kot_ticket_at)) / 60)) from fs where table_number = 'F5'), '{"prep":10,"mins":15}');
select t.same('3.8 a table with no waiting ticket has null kot columns', (select jsonb_build_object('due', kot_due_at, 'prep', kot_prep_min, 'at', kot_ticket_at, 'n', kot_waiting) from fs where table_number = 'T12'), '{"due":null,"prep":null,"at":null,"n":0}');
select t.q('3.9 oldest_kot_at is still the oldest waiting ticket (F3: the soup)', (select oldest_kot_at = kot_ticket_at from fs where table_number = 'F3'), 'true');
select t.as_su('wait');
select count(*) as n_fs from public.floor_status() \gset
reset role;
select t.is_('3.10 a Steward can read the floor', :n_fs > 0);
select t.as_su('chef');
select t.err('3.11 a role without order.create cannot', 'select * from public.floor_status()', 'order.create');
reset role;
-- a size follows its dish in the prep lookup: a ticket for the Large burger uses the burger's time
update public.products set prep_minutes = 33 where id = t.id('burger');
select t.new_bill('owner', jsonb_build_object('burger_l', 1), 0, 'T12') as "fF" \gset
update public.kitchen_tickets set client_created_at = now() - interval '2 minutes' where order_id = :'fF'::uuid;
select t.as_su('owner');
select kot_prep_min as burger_prep from public.floor_status() where table_number = 'T12' \gset
reset role;
select t.q('3.12 a ticket for a size uses the size''s time, which the dish saved', :burger_prep::int, '33');
update public.products set prep_minutes = 44 where id = t.id('burger_l');
select t.as_su('owner');
select kot_prep_min as burger_prep2 from public.floor_status() where table_number = 'T12' \gset
reset role;
select t.q('3.13 a time set on the size itself wins over the dish''s', :burger_prep2::int, '44');

-- ================================================================ 4. customers (145): rights, privacy, list, detail, lookup, edit, forget
reset role;
create function t.cbill(p_items jsonb, p_phone text, p_name text, p_pay boolean, p_disc numeric default 0) returns uuid language plpgsql as $$
declare o uuid;
begin
  o := t.new_bill('owner', p_items, p_disc);
  perform t.as_su('owner');
  perform public.attach_customer(o, p_phone, p_name);
  if p_pay then perform public.pay_order(o, t.ctx('pmCash'), 100000, null); end if;
  perform set_config('role', 'postgres', false);
  return o;
end $$;
select t.same('4.1 customer.view: exactly Owner, Manager, Cashier and every role with customer.manage',
  (select jsonb_agg(r.name order by r.name) from public.roles r where r.restaurant_id = t.ctx('r') and exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = 'customer.view')),
  (select jsonb_agg(r.name order by r.name)::text from public.roles r where r.restaurant_id = t.ctx('r')
     and ((r.is_system and r.name in ('Owner', 'Manager', 'Cashier')) or exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = 'customer.manage'))));
select t.same('4.2 loyalty.redeem: exactly Owner, Manager, Cashier (the custom Front desk role does not get it)',
  (select jsonb_agg(r.name order by r.name) from public.roles r where r.restaurant_id = t.ctx('r') and exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = 'loyalty.redeem')),
  '["Cashier","Manager","Owner"]');
select t.q('4.3 Chef has neither right', (select count(*) from public.role_permissions where role_id = t.ctx('roleChef') and permission_key in ('customer.view', 'customer.manage', 'loyalty.redeem')), '0');
select t.q('4.4 Front desk (custom role with customer.manage) received customer.view', (select count(*) from public.role_permissions where role_id = t.ctx('roleCust') and permission_key = 'customer.view'), '1');
select t.q('4.5 the new rights are marked sensitive', (select jsonb_agg(is_sensitive order by key) from public.permissions where key in ('customer.view', 'loyalty.redeem')), '[true, true]');

-- people: Rita (2 paid bills), Sam (1), Tara (open bill only), Uma (1 paid, 90 days ago)
insert into t.ctx select 'rita1', t.cbill('{"pasta":1}', '99000 11111', 'Rita Regular', true)::text;
insert into t.ctx select 'rita2', t.cbill('{"pasta":1,"soup":1}', '+91 99000 11111', null, true)::text;
insert into t.ctx select 'sam1',  t.cbill('{"soup":2}', '99000 22222', 'Sam Single', true)::text;
insert into t.ctx select 'tara1', t.cbill('{"soup":1}', '99000 33333', 'Tara Tab', false)::text;
insert into t.ctx select 'uma1',  t.cbill('{"soup":1}', '99000 44444', 'Uma Lapsed', true)::text;
set session_replication_role = replica;
insert into public.business_days (restaurant_id, branch_id, business_date, status, closed_at) values (t.ctx('r'), t.ctx('b'), app.local_today(t.ctx('r')) - 90, 'closed', now()) on conflict do nothing;
update public.orders set business_date = app.local_today(t.ctx('r')) - 90 where id = t.ctx('uma1');
set session_replication_role = origin;
select t.q('4.6 a phone with +91 and spaces finds the same guest as the plain number: one customer for Rita, 2 bills', (select count(*) from public.orders where customer_id = (select id from public.customers where name = 'Rita Regular')), '2');
select t.q('4.7 earn: Rita got floor(total / 10) points on each paid bill (ledger = earn rows only so far)',
  (select sum(l.points) = (select sum(floor(o.grand_total / 10)) from public.orders o where o.id in (t.ctx('rita1'), t.ctx('rita2'))) from public.loyalty_ledger l where l.customer_id = (select id from public.customers where name = 'Rita Regular')), 'true');
select t.q('4.8 an open bill earns nothing (Tara)', (select count(*) from public.loyalty_ledger where customer_id = (select id from public.customers where name = 'Tara Tab')), '0');
select t.q('4.9 the legacy customer (made before 145) kept the points she had', (select coalesce(sum(points), 0) from public.loyalty_ledger l join public.customers c on c.id = l.customer_id where c.phone like '%9876543210')::numeric, (select v->>'pts' from t.before where k = 'legacy_points'));

-- privacy: who can read the tables directly
select t.as_('chef');
select (select count(*) from public.customers) as c_chef, (select count(*) from public.loyalty_ledger) as l_chef \gset
reset role;
select t.as_('cash');
select (select count(*) from public.customers) as c_cash, (select count(*) from public.loyalty_ledger) as l_cash \gset
reset role;
select t.as_('cust');
select (select count(*) from public.customers) as c_cust \gset
reset role;
select t.as_('wait');
select (select count(*) from public.customers) as c_wait \gset
reset role;
select t.as_('other');
select (select count(*) from public.customers) as c_oth \gset
reset role;
select t.same('4.10 Chef reads no customers and no ledger rows; Cashier and Front desk read them; Steward (customer.manage) too; another restaurant sees none',
  jsonb_build_object('chef', :c_chef::int + :l_chef::int, 'cash', :c_cash::int > 0 and :l_cash::int > 0, 'cust', :c_cust::int > 0, 'wait', :c_wait::int > 0, 'other', :c_oth::int),
  '{"chef":0,"cash":true,"cust":true,"wait":true,"other":0}');

-- the list
select t.as_su('owner');
select public.customer_list() as cl_all \gset
select public.customer_list(null, 'repeat') as cl_rep \gset
select public.customer_list(null, 'new') as cl_new \gset
select public.customer_list(null, 'lapsed') as cl_lap \gset
select public.customer_list(null, 'never') as cl_nev \gset
select public.customer_list('rit') as cl_s1 \gset
select public.customer_list('2222') as cl_s2 \gset
select public.customer_list('ri') as cl_s3 \gset
select public.customer_list('+91 99000 3333') as cl_s4 \gset
select public.customer_list(null, 'all', 'spend') as cl_sp \gset
select public.customer_list(null, 'all', 'name') as cl_nm \gset
select public.customer_list(null, 'all', 'last_visit', 2, 1) as cl_pg \gset
reset role;
create function t.names(j jsonb) returns jsonb language sql immutable as $$ select coalesce(jsonb_agg(r->>'name' order by ord), '[]'::jsonb) from jsonb_array_elements(j->'rows') with ordinality x(r, ord) $$;
select t.same('4.11 list keys: total and rows with id, name, phone, visits, spend, avg_bill, first/last visit, points, consent',
  jsonb_build_object('total', :'cl_all'::jsonb->'total', 'keys', (select jsonb_agg(k order by k) from jsonb_object_keys((:'cl_all'::jsonb->'rows')->0) k)),
  (jsonb_build_object('total', (select count(*) from public.customers where deleted_at is null), 'keys', '["avg_bill","first_visit_on","id","last_visit_on","marketing_consent","name","phone","points","spend","visits"]'::jsonb))::text);
select t.same('4.12 filter repeat = 2 or more visits', t.names(:'cl_rep'::jsonb), '["Rita Regular"]');
select t.same('4.13 filter new = exactly one visit (and not lapsed is NOT required: Uma is a first-and-only visit too)', (select jsonb_agg(n order by n) from jsonb_array_elements_text(t.names(:'cl_new'::jsonb)) n), '["Asha Legacy","Sam Single","Uma Lapsed"]');
select t.same('4.14 filter lapsed = visited, but not in the last 60 days', t.names(:'cl_lap'::jsonb), '["Uma Lapsed"]');
select t.same('4.15 filter never = no paid bill yet', t.names(:'cl_nev'::jsonb), '["Tara Tab"]');
select t.same('4.16 search by name part', t.names(:'cl_s1'::jsonb), '["Rita Regular"]');
select t.same('4.17 search by phone digits (3 or more)', t.names(:'cl_s2'::jsonb), '["Sam Single"]');
select t.q('4.18 a search of fewer than 3 characters is ignored (the whole list)', (:'cl_s3'::jsonb->>'total')::int, (:'cl_all'::jsonb->>'total'));
select t.same('4.19 search by phone with +91 and spaces', t.names(:'cl_s4'::jsonb), '["Tara Tab"]');
select t.q('4.20 sort by spend: biggest first', (select jsonb_agg((r->>'spend')::numeric order by ord) = jsonb_agg((r->>'spend')::numeric order by (r->>'spend')::numeric desc) from jsonb_array_elements(:'cl_sp'::jsonb->'rows') with ordinality x(r, ord)), 'true');
select t.q('4.21 sort by name: alphabetical', (select jsonb_agg(n order by ord) = jsonb_agg(n order by lower(n)) from jsonb_array_elements_text(t.names(:'cl_nm'::jsonb)) with ordinality x(n, ord)), 'true');
select t.q('4.22 paging: limit 2 offset 1 gives 2 rows and the same total', jsonb_build_array(jsonb_array_length(:'cl_pg'::jsonb->'rows'), (:'cl_pg'::jsonb->>'total')::int = (:'cl_all'::jsonb->>'total')::int), '[2, true]');
select t.same('4.23 Rita: 2 visits, spend = the two bills, 1 decimal-free average, points = what she earned',
  (select jsonb_build_object('v', r->>'visits', 's', (r->>'spend')::numeric - (select sum(grand_total) from public.orders where id in (t.ctx('rita1'), t.ctx('rita2'))),
         'a', (r->>'avg_bill')::numeric - round((select sum(grand_total) / 2 from public.orders where id in (t.ctx('rita1'), t.ctx('rita2'))), 2),
         'p', (r->>'points')::numeric - (select sum(floor(grand_total / 10)) from public.orders where id in (t.ctx('rita1'), t.ctx('rita2'))))
     from jsonb_array_elements(:'cl_all'::jsonb->'rows') r where r->>'name' = 'Rita Regular'), '{"v":"2","s":0,"a":0,"p":0}');
select t.as_su('chef');
select t.err('4.24 the list needs customer.view', 'select public.customer_list()', '(customer.view)');
select t.err('4.25 the detail too', format('select public.customer_detail(%L)', t.ctx('rita1')), '(customer.view)');
reset role;
select t.as_su('other');
select t.q('4.26 another restaurant''s list is empty', (public.customer_list()->>'total')::int, '0');
select t.err('4.27 and cannot open our customer', format('select public.customer_detail((select id from public.customers where name = %L))', 'Rita Regular'), 'Customer not found');
reset role;

-- scope: one of Rita's bills belongs to Outlet B
set session_replication_role = replica;
insert into public.business_days (restaurant_id, branch_id, business_date, status, closed_at) values (t.ctx('r'), t.id('outB'), app.local_today(t.ctx('r')), 'closed', now()) on conflict do nothing;
update public.orders set branch_id = t.id('outB') where id = t.ctx('rita2');
set session_replication_role = origin;
select t.as_su('owner');
select (public.customer_list('rit')->'rows'->0->>'visits')::int as v_all \gset
reset role;
select t.as_su('mgr');
select (public.customer_list('rit')->'rows'->0->>'visits')::int as v_a \gset
reset role;
select t.same('4.28 visits follow the outlet scope: All outlets 2, a Manager limited to Outlet A 1', jsonb_build_array(:v_all, :v_a), '[2, 1]');
-- ... and back
set session_replication_role = replica;
update public.orders set branch_id = t.ctx('b') where id = t.ctx('rita2');
set session_replication_role = origin;

-- the detail
select t.as_su('owner');
select public.customer_detail((select id from public.customers where name = 'Rita Regular')) as cd \gset
reset role;
select t.same('4.29 detail: profile, stats, points, 2 bills (both visits), ledger rows',
  jsonb_build_object('name', :'cd'::jsonb #>> '{profile,name}', 'visits', :'cd'::jsonb #>> '{stats,visits}', 'bills', jsonb_array_length(:'cd'::jsonb->'bills'),
    'visit_flags', (select jsonb_agg(b->'is_visit') from jsonb_array_elements(:'cd'::jsonb->'bills') b), 'ledger', jsonb_array_length(:'cd'::jsonb->'ledger'),
    'note', :'cd'::jsonb->>'points_note', 'expire', :'cd'::jsonb->'points_expire'),
  '{"name":"Rita Regular","visits":"2","bills":2,"visit_flags":[true,true],"ledger":2,"note":"Points do not expire.","expire":false}');

-- the regular-guest lookup (needs only order.create, returns no spend and no phone)
select t.as_su('wait');
select public.find_customer('+91 99000 11111') as fc1 \gset
select public.find_customer('099000 11111') as fc2 \gset
select coalesce(public.find_customer('12345')::text, 'null') as fc3 \gset
select coalesce(public.find_customer('99000 55555')::text, 'null') as fc4 \gset
reset role;
select t.same('4.30 find_customer matches the last 10 digits: +91 and a leading 0 both find Rita; shows name, visits, last visit and points only',
  jsonb_build_object('a', :'fc1'::jsonb->>'name', 'b', :'fc2'::jsonb->>'name', 'keys', (select jsonb_agg(k order by k) from jsonb_object_keys(:'fc1'::jsonb) k)),
  '{"a":"Rita Regular","b":"Rita Regular","keys":["id","last_visit_on","name","points","visits"]}');
select t.same('4.31 a short number or an unknown number gives null', jsonb_build_array(:'fc3'::text, :'fc4'::text), '["null", "null"]');

-- editing a guest
select t.as_su('cash');
select t.err('4.32 an email that is not an email is refused', format('select public.update_customer(%L, %L, %L, %L, null, false)', (select id from public.customers where name = 'Sam Single'), 'Sam Single', 'not-an-email', null), 'does not look right');
select public.update_customer((select id from public.customers where name = 'Sam Single'), 'Sam S.', 'sam@example.com', 'likes soup', date '1990-05-04', true);
reset role;
select t.same('4.33 update_customer: saved, consent time stamped', (select jsonb_build_object('n', name, 'e', email, 'c', marketing_consent, 'stamp', consent_given_at is not null, 'dob', date_of_birth) from public.customers where phone like '%9900022222'),
  '{"n":"Sam S.","e":"sam@example.com","c":true,"stamp":true,"dob":"1990-05-04"}');
select t.as_su('chef');
select t.err('4.34 Chef cannot edit a guest', format('select public.update_customer(%L, %L, null, null, null, false)', (select id from public.customers where name = 'Sam S.'), 'X'), 'customer.manage');
reset role;
select t.q('4.35 the edit is in the audit trail', (select count(*) from public.audit_logs where action = 'customer.updated'), '1');

-- credit note takes back points; a void returns what was spent and takes back what was earned
select t.as_su('owner');
select public.issue_credit_note(t.ctx('rita2'), 20, t.ctx('pmCash'), 'plate returned') as "cn" \gset
reset role;
select t.as_su('owner');
select (public.customer_list('rit')->'rows'->0->>'spend')::numeric - (select sum(grand_total) from public.orders where id in (t.ctx('rita1'), t.ctx('rita2'))) as spend_diff \gset
reset role;
select t.same('4.36 a credit note of 20 takes back ceil(20/10) = 2 points ("reverse" row); the visit spend drops by 20',
  jsonb_build_object('rev', (select sum(points) from public.loyalty_ledger where order_id = t.ctx('rita2') and kind = 'reverse'), 'spend', :spend_diff::numeric), '{"rev":-2,"spend":-20}');

-- ================================================================ 5. loyalty settings and points redeemed as a discount (145 + 141)
reset role;
create function t.seed(p_name text, p_phone text, p_pts numeric) returns uuid language plpgsql as $$
declare o uuid; c uuid;
begin
  o := t.cbill('{"soup":1}', p_phone, p_name, false);
  select id into c from public.customers where name = p_name and restaurant_id = t.ctx('r');
  insert into public.loyalty_ledger (restaurant_id, customer_id, points, kind, note) values (t.ctx('r'), c, p_pts, 'adjust', 'test seed');
  return c;
end $$;
create function t.bal(p_name text) returns numeric language sql stable as $$
  select app.points_balance((select id from public.customers where name = p_name and restaurant_id = t.ctx('r'))) $$;
create function t.red(p_who text, p_order uuid, p_pts numeric, p_ref uuid default null) returns jsonb language plpgsql as $$
declare v jsonb;
begin perform t.as_su(p_who); v := public.redeem_points_discount(p_order, p_pts, p_ref); perform set_config('role', 'postgres', false); return v; end $$;
create function t.part(p_order uuid) returns jsonb language sql stable as $$
  select jsonb_build_object('order', t.snap(p_order)->'order', 'discounts', t.snap(p_order)->'discounts') $$;

-- settings: the 3-argument function still works and leaves the mode alone; the 5-argument one sets mode and cap
select t.q('5.1 before 145-style settings: mode is "tender" and the cap 100 (nobody changed silently)', (select jsonb_build_array(redeem_mode, max_redeem_percent) from public.loyalty_settings where restaurant_id = t.ctx('r')), '["tender", 100]');
select t.as_su('owner');
select public.save_loyalty_settings(10, 1, 10);
reset role;
select t.q('5.2 the 3-argument save leaves the mode on "tender"', (select redeem_mode from public.loyalty_settings where restaurant_id = t.ctx('r')), '"tender"');
select t.as_su('owner');
select t.err('5.3 an unknown mode is refused', $q$ select public.save_loyalty_settings(10, 1, 10, 'cash', 100) $q$, 'Choose how points are redeemed');
select t.err('5.4 a cap of 0 percent is refused', $q$ select public.save_loyalty_settings(10, 1, 10, 'discount', 0) $q$, 'between 1 and 100');
select t.err('5.5 a cap of 101 percent is refused', $q$ select public.save_loyalty_settings(10, 1, 10, 'discount', 101) $q$, 'between 1 and 100');
reset role;
select t.as_su('cash');
select t.err('5.6 a Cashier cannot change the rules (settings.manage)', $q$ select public.save_loyalty_settings(10, 1, 10, 'discount', 100) $q$, 'settings.manage');
reset role;
select t.as_su('owner');
select public.save_loyalty_settings(10, 1, 10, 'discount', 100);
reset role;
select t.q('5.7 the owner sets discount mode', (select jsonb_build_array(redeem_mode, max_redeem_percent) from public.loyalty_settings where restaurant_id = t.ctx('r')), '["discount", 100]');
select t.q('5.8 the change is in the audit trail', (select count(*) from public.audit_logs where action = 'loyalty.settings' and new_value->>'redeem_mode' = 'discount'), '1');

select t.seed('Vik', '99000 55555', 500) as vik \gset
select t.seed('Wren', '99000 66666', 20) as wren \gset
select t.seed('Xena', '99000 77777', 500) as xena \gset
select t.seed('Yan', '99000 88888', 500) as yan \gset

-- 5.10 the worked case: points 30 on a bill of pasta (free to discount) + pizza (restricted)
select t.cbill('{"pasta":1,"pizza":1}', '99000 55555', 'Vik', false) as "l1" \gset
select t.red('cash', :'l1'::uuid, 30) as r1 \gset
select t.same('5.10 redeem 30 points on pasta 100 + restricted pizza 100: discount 30 on the pasta only, tax 12.60 + 18.00, grand 200.60 -> 201',
  t.part(:'l1'::uuid), '{"order":{"subtotal":200,"discount":30,"tax":30.6,"sc":0,"rounding":0.4,"grand":201,"paid":0,"pstatus":"unpaid","tax_included":0,"exempt":0,"covered":0},"discounts":[{"type":"loyalty_points","value":30,"amount":30}]}');
select t.same('5.11 the result tells the screen what happened', :'r1'::jsonb, '{"points_used":30,"discount":30,"grand_total":201,"points_left":470}');
select t.same('5.12 per line: pasta carries the 30, pizza none', (select jsonb_agg(jsonb_build_object('n', product_name, 'd', line_discount, 't', line_tax) order by product_name) from public.order_items where order_id = :'l1'::uuid),
  '[{"n":"Pasta","d":30,"t":12.6},{"n":"Pizza","d":0,"t":18}]');
select t.same('5.13 the ledger has one redeem row of -30 for the bill and the balance fell', jsonb_build_object('rows', (select jsonb_agg(points) from public.loyalty_ledger where order_id = :'l1'::uuid and kind = 'redeem'), 'bal', t.bal('Vik')), '{"rows":[-30],"bal":470}');
select t.same('5.14 calc_params remembers the points', (select jsonb_build_object('d', calc_params->'loyalty_discount', 'p', calc_params->'loyalty_points') from public.orders where id = :'l1'::uuid), '{"d":30,"p":30}');
select t.as_su('cash');
select t.err('5.15 a second redeem on the same bill is refused', format('select public.redeem_points_discount(%L, 20)', :'l1'), 'Points are already used on this bill');
reset role;
select t.as_su('cash');
select t.err('5.16 the old "points as a payment" is refused while the outlet is in discount mode', format('select public.redeem_points(%L, 20)', :'l1'), 'redeems points as a discount');
reset role;

-- remove returns the points and restores the bill
select t.as_su('cash');
select public.remove_points_discount(:'l1'::uuid) as rm \gset
reset role;
select t.same('5.17 remove: 30 points back, the bill is the plain 236 again', jsonb_build_object('res', :'rm'::jsonb, 'bal', t.bal('Vik'), 'part', t.part(:'l1'::uuid),
   'cp', (select calc_params ? 'loyalty_points' from public.orders where id = :'l1'::uuid)),
  '{"res":{"points_returned":30,"grand_total":236,"points_left":500},"bal":500,"part":{"order":{"subtotal":200,"discount":0,"tax":36,"sc":0,"rounding":0,"grand":236,"paid":0,"pstatus":"unpaid","tax_included":0,"exempt":0,"covered":0},"discounts":[]},"cp":false}');
select t.as_su('cash');
select t.err('5.18 remove with nothing to remove is refused', format('select public.remove_points_discount(%L)', :'l1'), 'No points have been used on this bill');
reset role;

-- idempotent by client reference
select t.cbill('{"pasta":1}', '99000 55555', 'Vik', false) as "l2" \gset
select t.red('cash', :'l2'::uuid, 40, t.id('ref-a')) as ra1 \gset
select t.red('cash', :'l2'::uuid, 40, t.id('ref-a')) as ra2 \gset
select t.same('5.19 the same reference twice: one redeem row, the second answer is the first plus repeat',
  jsonb_build_object('rows', (select count(*) from public.loyalty_ledger where order_id = :'l2'::uuid and kind = 'redeem'), 'same', (:'ra2'::jsonb - 'repeat') = :'ra1'::jsonb, 'repeat', :'ra2'::jsonb->'repeat'),
  '{"rows":1,"same":true,"repeat":true}');
select t.as_su('cash');
select t.err('5.20 the same reference on another bill is refused', format('select public.redeem_points_discount(%L, 20, %L)', :'l1', t.id('ref-a')), 'already used for something else');
reset role;

-- cap by the discountable part, typed discount first
select t.cbill('{"pasta":1,"pizza":1}', '99000 77777', 'Xena', false, 20) as "l3" \gset
select t.red('cash', :'l3'::uuid, 400) as r3 \gset
select t.same('5.21 typed discount 20 + 400 points on a pool of 100: points are cut to 80 (what is left of the pool); total = pizza 118',
  jsonb_build_object('res', :'r3'::jsonb, 'part', t.part(:'l3'::uuid)),
  '{"res":{"points_used":80,"discount":80,"grand_total":118,"points_left":420},"part":{"order":{"subtotal":200,"discount":100,"tax":18,"sc":0,"rounding":0,"grand":118,"paid":0,"pstatus":"unpaid","tax_included":0,"exempt":0,"covered":0},"discounts":[{"type":"fixed_amount","value":20,"amount":20},{"type":"loyalty_points","value":80,"amount":80}]}}');
select t.cbill('{"pasta":1}', '99000 77777', 'Xena', false) as "l4" \gset
select t.as_su('cash');
select t.err('5.22 fewer than the minimum (10) is refused', format('select public.redeem_points_discount(%L, 5)', :'l4'), 'At least 10 points must be used at a time');
reset role;
select t.cbill('{"pasta":1}', '99000 66666', 'Wren', false) as "l5" \gset
select t.as_su('cash');
select t.err('5.23 more than the guest has is refused with the balance', format('select public.redeem_points_discount(%L, 50)', :'l5'), 'The guest has only 20.00 points');
select t.err('5.24 zero points is refused', format('select public.redeem_points_discount(%L, 0)', :'l5'), 'Enter the points to use');
reset role;
select t.new_bill('owner', '{"pasta":1}') as "l6" \gset
select t.as_su('cash');
select t.err('5.25 a bill with no guest is refused', format('select public.redeem_points_discount(%L, 20)', :'l6'), 'Add the guest''s phone number to the bill first');
reset role;
select t.cbill('{"pizza":1}', '99000 88888', 'Yan', false) as "l7" \gset
select t.as_su('cash');
select t.err('5.26 a bill with only restricted lines has nothing to discount', format('select public.redeem_points_discount(%L, 50)', :'l7'), 'Nothing on this bill can be discounted with points');
reset role;
select t.cbill('{"pasta":1}', '99000 88888', 'Yan', false) as "l8" \gset
update public.orders set calc_params = calc_params || '{"senior":{"share":1,"rate":20}}'::jsonb where id = :'l8'::uuid;
select t.as_su('cash');
select t.err('5.27 a senior citizen / PWD bill cannot use points', format('select public.redeem_points_discount(%L, 20)', :'l8'), 'senior citizen / PWD discount; points cannot be used on it');
reset role;
select t.cbill('{"pasta":1}', '99000 88888', 'Yan', true) as "l9" \gset
select t.as_su('cash');
select t.err('5.28 a paid bill cannot take points', format('select public.redeem_points_discount(%L, 20)', :'l9'), 'already has a payment');
reset role;
select t.cbill('{"pasta":1}', '99000 88888', 'Yan', false) as "l10" \gset
select t.as_su('wait');
select t.err('5.29 a Steward has no loyalty.redeem right', format('select public.redeem_points_discount(%L, 20)', :'l10'), '(loyalty.redeem)');
select t.err('5.30 ... nor can remove', format('select public.remove_points_discount(%L)', :'l10'), '(loyalty.redeem)');
reset role;
select t.as_su('chef');
select t.err('5.31 a Chef neither', format('select public.redeem_points_discount(%L, 20)', :'l10'), '(loyalty.redeem)');
reset role;
-- a bill with a payment already
select t.cbill('{"pasta":2}', '99000 88888', 'Yan', false) as "l11" \gset
select t.as_su('owner');
select public.pay_order(:'l11'::uuid, t.ctx('pmCash'), 50, 50, null, null, 0);
reset role;
select t.as_su('cash');
select t.err('5.32 a bill with a part payment cannot take points (nothing to change after money was taken)', format('select public.redeem_points_discount(%L, 20)', :'l11'), 'already has a payment');
reset role;

-- the discount follows the bill: cancel a line and the points shrink with the pool, the surplus goes back to the guest
select t.cbill('{"pasta":1,"soup":1}', '99000 77777', 'Xena', false) as "l12" \gset
select t.bal('Xena') as xb0 \gset
select t.red('cash', :'l12'::uuid, 150) as r12 \gset
select t.as_su('owner');
select public.cancel_order_item((select id from public.order_items where order_id = :'l12'::uuid and product_name = 'Soup'), 1, 'guest changed mind') as cx12 \gset
reset role;
select t.same('5.33 pool 160 -> 100 after the soup is cancelled: points 150 -> 100, 50 points back ("Bill changed"), order_discounts follows',
  jsonb_build_object('cp', (select jsonb_build_array(calc_params->'loyalty_points', calc_params->'loyalty_discount') from public.orders where id = :'l12'::uuid),
    'back', (select jsonb_agg(points) from public.loyalty_ledger where order_id = :'l12'::uuid and kind = 'adjust' and note = 'Bill changed'),
    'od', (select jsonb_agg(jsonb_build_array(value, amount)) from public.order_discounts where order_id = :'l12'::uuid and discount_type = 'loyalty_points'),
    'bal_used', :xb0::numeric - t.bal('Xena')), '{"cp":[100,100],"back":[50],"od":[[100,100]],"bal_used":100}');

-- the cap percentage
select t.as_su('owner');
select public.save_loyalty_settings(10, 1, 10, 'discount', 50);
reset role;
select t.cbill('{"pasta":1}', '99000 77777', 'Xena', false) as "l13" \gset
select t.red('cash', :'l13'::uuid, 300) as r13 \gset
select t.same('5.34 max 50 percent of the discountable part: 300 points -> 50', :'r13'::jsonb - 'grand_total' - 'points_left', '{"points_used":50,"discount":50}');
select t.as_su('owner');
select public.save_loyalty_settings(10, 1, 10, 'discount', 100);
reset role;

-- a void gives the points back
select t.cbill('{"pasta":1,"pizza":1}', '99000 77777', 'Xena', false) as "l14" \gset
select t.red('cash', :'l14'::uuid, 40) as r14 \gset
select t.as_su('owner');
select public.void_order(:'l14'::uuid, 'test void');
reset role;
select t.q('5.35 voiding a bill that used points returns them (net 0 for the bill)', (select sum(points) from public.loyalty_ledger where order_id = :'l14'::uuid), '0');

-- tender mode keeps the old way, and refuses the new
select t.as_su('owner');
select public.save_loyalty_settings(10, 1, 10, 'tender', 100);
reset role;
select t.cbill('{"pasta":1}', '99000 55555', 'Vik', false) as "l15" \gset
select t.as_su('cash');
select t.err('5.36 in tender mode the discount way is refused', format('select public.redeem_points_discount(%L, 20)', :'l15'), 'redeems points as a payment, not as a discount');
select public.redeem_points(:'l15'::uuid, 20) as rp \gset
reset role;
select t.same('5.37 ... and the old points-as-payment still works: a loyalty payment of 20, tax untouched', jsonb_build_object('paid', (select paid_total from public.orders where id = :'l15'::uuid), 'tax', (select tax_total from public.orders where id = :'l15'::uuid), 'disc', (select discount_total from public.orders where id = :'l15'::uuid)),
  '{"paid":20,"tax":18,"disc":0}');
select t.as_su('owner');
select public.save_loyalty_settings(10, 1, 10, 'discount', 100);
reset role;

-- forget a guest
set session_replication_role = replica;
update public.orders set guest_name = 'Uma Lapsed', guest_phone = '9900044444' where id = t.ctx('uma1');
set session_replication_role = origin;
select t.as_su('cash');
select t.err('5.40 a Cashier cannot delete a guest without the owner''s approval (settings.manage)', format('select public.forget_customer((select id from public.customers where name = %L), %L)', 'Uma Lapsed', 'asked to'), '(settings.manage)');
reset role;
select t.as_su('owner');
select t.err('5.41 a reason is required', format('select public.forget_customer((select id from public.customers where name = %L), %L)', 'Uma Lapsed', ' '), 'Write a short reason');
select public.forget_customer((select id from public.customers where name = 'Uma Lapsed'), 'guest asked us to delete her data');
reset role;
select t.same('5.42 forget: name, phone and the bill''s guest fields are scrubbed (even on a closed day); the bill and its money stay',
  (select jsonb_build_object('name', c.name, 'phone', c.phone, 'del', c.deleted_at is not null, 'g', o.guest_name, 'gp', o.guest_phone, 'paid', o.payment_status, 'total', o.grand_total > 0)
     from public.customers c join public.orders o on o.customer_id = c.id where o.id = t.ctx('uma1')),
  '{"name":"Deleted guest","phone":null,"del":true,"g":null,"gp":null,"paid":"paid","total":true}');
select t.q('5.43 her points were cleared by an adjust row (balance 0) and the audit trail says so', (select jsonb_build_array(app.points_balance(customer_id), (select count(*) from public.audit_logs where action = 'customer.forgotten')) from public.orders where id = t.ctx('uma1')), '[0, 1]');
select t.as_su('owner');
select t.err('5.44 deleting twice is refused', format('select public.forget_customer(%L, %L)', (select c.id from public.customers c join public.orders o on o.customer_id = c.id where o.id = t.ctx('uma1')), 'again'), 'already deleted');
reset role;
select t.as_su('owner');
select coalesce(public.find_customer('99000 44444')::text, 'null') as ff \gset
reset role;
select t.q('5.45 the deleted guest is no longer found by phone', jsonb_build_array((select count(*) from public.customers where phone like '%9900044444'), :'ff'::text), '[0, "null"]');

-- ================================================================ 6. customer reports (146)
reset role;
-- make Rita a returning guest (her first bill 5 days ago) and put one of Sam's bills in Outlet B
set session_replication_role = replica;
insert into public.business_days (restaurant_id, branch_id, business_date, status, closed_at) values (t.ctx('r'), t.ctx('b'), app.local_today(t.ctx('r')) - 5, 'closed', now()) on conflict do nothing;
update public.orders set business_date = app.local_today(t.ctx('r')) - 5 where id = t.ctx('rita1');
update public.orders set branch_id = t.id('outB') where id = t.ctx('sam1');
set session_replication_role = origin;
create function t.rc_oracle(p_from date, p_to date, p_branch uuid) returns jsonb language sql stable as $$
  with v as (select o.id, o.customer_id, o.business_date, o.grand_total - coalesce((select sum(cn.amount) from public.credit_notes cn where cn.order_id = o.id), 0) as net
               from public.orders o where o.restaurant_id = t.ctx('r') and (p_branch is null or o.branch_id = p_branch) and o.business_date between p_from and p_to
                and o.customer_id is not null and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null),
       f as (select o.customer_id, min(o.business_date) as first_on from public.orders o where o.restaurant_id = t.ctx('r') and (p_branch is null or o.branch_id = p_branch)
               and o.customer_id in (select customer_id from v) and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null group by o.customer_id),
       tot as (select count(*) as n from public.orders o where o.restaurant_id = t.ctx('r') and (p_branch is null or o.branch_id = p_branch) and o.business_date between p_from and p_to
               and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null)
  select jsonb_build_object('customers', (select count(distinct customer_id) from v), 'new', (select count(*) from f where first_on between p_from and p_to),
    'repeat', (select count(*) from f where not (first_on between p_from and p_to)), 'spend', coalesce((select sum(net) from v), 0),
    'bills_with_customer', (select count(*) from v), 'bills_total', (select n from tot),
    'capture_rate', case when (select n from tot) > 0 then round(100.0 * (select count(*) from v) / (select n from tot), 1) else 0 end) $$;
create function t.rc_totals(j jsonb) returns jsonb language sql immutable as $$ select (j->'totals') - 'repeat_rate' $$;
select app.local_today(t.ctx('r')) as today \gset
select t.as_su('owner');
select public.report_customers(:'today'::date - 1, :'today'::date) as rc_all \gset
select public.report_customers(:'today'::date - 120, :'today'::date) as rc_wide \gset
reset role;
select t.same('6.1 customers report, All outlets, 2 days: the totals equal what the bills say', t.rc_totals(:'rc_all'::jsonb), t.rc_oracle(:'today'::date - 1, :'today'::date, null)::text);
select t.same('6.2 ... over 120 days (the lapsed guest, 90 days ago, is in)', t.rc_totals(:'rc_wide'::jsonb), t.rc_oracle(:'today'::date - 120, :'today'::date, null)::text);
select t.same('6.3 Rita is a returning guest in the 2-day range (first visit 5 days ago), the others are new',
  (select jsonb_build_object('rita_new', r->'is_new', 'rita_visits', r->'visits', 'sam_new', (select r2->'is_new' from jsonb_array_elements(:'rc_all'::jsonb->'by_customer') r2 where r2->>'name' = 'Sam S.'))
     from jsonb_array_elements(:'rc_all'::jsonb->'by_customer') r where r->>'name' = 'Rita Regular'), '{"rita_new":false,"rita_visits":1,"sam_new":true}');
select t.q('6.4 repeat_rate is a percentage with one decimal', (:'rc_all'::jsonb #>> '{totals,repeat_rate}')::numeric = round(100.0 * (:'rc_all'::jsonb #>> '{totals,repeat}')::numeric / nullif((:'rc_all'::jsonb #>> '{totals,customers}')::numeric, 0), 1), 'true');
select t.q('6.5 by_day adds up to the totals (visits and spend)', jsonb_build_array((select sum((d->>'bills_with_customer')::int) from jsonb_array_elements(:'rc_wide'::jsonb->'by_day') d) = (:'rc_wide'::jsonb #>> '{totals,bills_with_customer}')::int,
   (select sum((d->>'spend')::numeric) from jsonb_array_elements(:'rc_wide'::jsonb->'by_day') d) = (:'rc_wide'::jsonb #>> '{totals,spend}')::numeric), '[true, true]');
select t.q('6.6 by_customer spend adds up to the total spend', (select sum((c->>'spend')::numeric) from jsonb_array_elements(:'rc_wide'::jsonb->'by_customer') c) = (:'rc_wide'::jsonb #>> '{totals,spend}')::numeric, 'true');
select t.q('6.7 the money flag is true for the owner', :'rc_all'::jsonb->'money', 'true');
-- scope: a Manager limited to Outlet A does not see Sam's Outlet B bill
select t.as_su('mgr');
select public.report_customers(:'today'::date - 1, :'today'::date) as rc_a \gset
reset role;
select t.same('6.8 a Manager limited to Outlet A: totals follow the outlet (Sam''s bill is in B)', t.rc_totals(:'rc_a'::jsonb), t.rc_oracle(:'today'::date - 1, :'today'::date, t.ctx('b'))::text);
select t.q('6.9 ... so All outlets has one more visit than Outlet A', (:'rc_all'::jsonb #>> '{totals,bills_with_customer}')::int - (:'rc_a'::jsonb #>> '{totals,bills_with_customer}')::int, '1');
-- money: a Cashier has report.view_sales but not report.view_financial -> spend is hidden, not refused
select t.as_su('cash');
select public.report_customers(:'today'::date - 1, :'today'::date) as rc_c \gset
reset role;
select t.same('6.10 a Cashier sees visits but no money: money false, spend / avg null',
  jsonb_build_object('money', :'rc_c'::jsonb->'money', 'spend', :'rc_c'::jsonb #> '{totals,spend}', 'row_spend', (:'rc_c'::jsonb->'by_customer'->0->'spend'), 'day_spend', (:'rc_c'::jsonb->'by_day'->0->'spend'),
     'visits', (:'rc_c'::jsonb #>> '{totals,bills_with_customer}')::int = (:'rc_a'::jsonb #>> '{totals,bills_with_customer}')::int),
  '{"money":false,"spend":null,"row_spend":null,"day_spend":null,"visits":true}');
select t.as_su('chef');
select t.err('6.11 a Chef is refused (customer.view)', format('select public.report_customers(%L, %L)', :'today', :'today'), '(customer.view)');
reset role;
select t.as_su('wait');
select t.err('6.12 a Steward has customer.view but no sales right (report.view_sales)', format('select public.report_customers(%L, %L)', :'today', :'today'), '(report.view_sales)');
reset role;
select t.as_su('owner');
select t.err('6.13 end before start', format('select public.report_customers(%L, %L)', :'today'::date, :'today'::date - 1), 'Choose a valid date range');
select t.err('6.14 more than a year', format('select public.report_customers(%L, %L)', :'today'::date - 400, :'today'::date), 'one year or less');
select t.err('6.15 a null date', $q$ select public.report_customers(null, current_date) $q$, 'Choose a valid date range');
reset role;

-- the points ledger report
select t.as_su('owner');
select public.report_loyalty_ledger(:'today'::date - 120, :'today'::date) as rl_all \gset
reset role;
select t.same('6.20 ledger report, All outlets: totals equal the ledger (earned, redeemed, reversed, adjusted, net)', :'rl_all'::jsonb->'totals',
  (select jsonb_build_object('earned', coalesce(sum(points) filter (where kind = 'earn'), 0), 'redeemed', coalesce(-sum(points) filter (where kind = 'redeem'), 0), 'reversed', coalesce(-sum(points) filter (where kind = 'reverse'), 0),
     'adjusted', coalesce(sum(points) filter (where kind in ('adjust', 'expire')), 0), 'net', coalesce(sum(points), 0))::text from public.loyalty_ledger where restaurant_id = t.ctx('r')));
select t.q('6.21 rows: one per ledger row, newest first, not truncated', jsonb_build_array(:'rl_all'::jsonb->>'total_rows', jsonb_array_length(:'rl_all'::jsonb->'rows'), :'rl_all'::jsonb->'truncated', (:'rl_all'::jsonb->>'total_rows')::int = (select count(*) from public.loyalty_ledger where restaurant_id = t.ctx('r'))),
  (select jsonb_build_array(count(*)::text, count(*), false, true)::text from public.loyalty_ledger where restaurant_id = t.ctx('r')));
select t.q('6.22 by_day adds up to the totals', (select jsonb_build_array(sum((d->>'earned')::numeric), sum((d->>'redeemed')::numeric), sum((d->>'reversed')::numeric), sum((d->>'adjusted')::numeric)) from jsonb_array_elements(:'rl_all'::jsonb->'by_day') d),
  (select jsonb_build_array(:'rl_all'::jsonb #> '{totals,earned}', :'rl_all'::jsonb #> '{totals,redeemed}', :'rl_all'::jsonb #> '{totals,reversed}', :'rl_all'::jsonb #> '{totals,adjusted}')::text));
select t.same('6.23 liability: positive balances only, valued at the point value',
  :'rl_all'::jsonb->'liability',
  (select jsonb_build_object('points_outstanding', coalesce(sum(b), 0), 'rupee_value', round(coalesce(sum(b), 0) * (select point_value from public.loyalty_settings where restaurant_id = t.ctx('r')), 2), 'customers_with_points', count(*))::text
     from (select sum(points) as b from public.loyalty_ledger where restaurant_id = t.ctx('r') group by customer_id having sum(points) > 0) z));
select t.q('6.24 rows with no bill (the test seeds) are listed as outlet "Manual"', (select count(*) > 0 from jsonb_array_elements(:'rl_all'::jsonb->'rows') r where r->>'outlet' = 'Manual'), 'true');
select t.as_su('mgr');
select public.report_loyalty_ledger(:'today'::date - 120, :'today'::date) as rl_a \gset
reset role;
select t.same('6.25 a Manager limited to Outlet A: only rows of Outlet A bills (no manual rows), totals follow',
  jsonb_build_object('net', :'rl_a'::jsonb #> '{totals,net}', 'manual', (select count(*) from jsonb_array_elements(:'rl_a'::jsonb->'rows') r where r->>'outlet' = 'Manual'),
     'rows', (:'rl_a'::jsonb->>'total_rows')::int),
  (select jsonb_build_object('net', coalesce(sum(l.points), 0), 'manual', 0, 'rows', count(*))::text from public.loyalty_ledger l join public.orders o on o.id = l.order_id where l.restaurant_id = t.ctx('r') and o.branch_id = t.ctx('b')));
select t.as_su('chef');
select t.err('6.26 a Chef is refused', format('select public.report_loyalty_ledger(%L, %L)', :'today', :'today'), '(customer.view)');
reset role;
select t.as_su('owner');
select t.err('6.27 end before start', format('select public.report_loyalty_ledger(%L, %L)', :'today'::date, :'today'::date - 1), 'Choose a valid date range');
reset role;
select t.as_su('other');
select t.err('6.28 a restaurant without the loyalty add-on is refused', format('select public.report_loyalty_ledger(%L, %L)', :'today', :'today'), 'oyalty');
reset role;
select t.q('6.29 both reports are closed to the public and anonymous roles', (select count(*) from information_schema.routine_privileges where routine_schema = 'public' and routine_name in ('report_customers', 'report_loyalty_ledger') and grantee in ('PUBLIC', 'anon')), '0');
select t.q('6.30 ... and open to signed-in users', (select count(*) from information_schema.routine_privileges where routine_schema = 'public' and routine_name in ('report_customers', 'report_loyalty_ledger') and grantee = 'authenticated'), '2');
-- put Sam's bill back
set session_replication_role = replica;
update public.orders set branch_id = t.ctx('b') where id = t.ctx('sam1');
set session_replication_role = origin;

-- ================================================================ 7. offline sync carries the guest and the discount block (147)
reset role;
create function t.sync(p_who text, p_bill jsonb) returns jsonb language plpgsql as $$
declare v jsonb;
begin perform t.as_su(p_who); v := public.sync_offline_bill(p_bill); perform set_config('role', 'postgres', false); return v; end $$;
-- the same guest-less bill as before 147 (dev2 seq 1, 'pre1'): now seq 2, 'post1'
select t.sync('cash', t.obill(2, 2, jsonb_build_array(t.oitem('dosa', 2, 120), t.oitem('cola', 1, 5)), 'post1') || jsonb_build_object('method_id', t.ctx('pmCash'))) as s0 \gset
select t.same('7.1 a guest-less offline bill: the answer, flags, total, line prices and customer are the same as before 147',
  jsonb_build_object('res', (:'s0'::jsonb) - array['order_id','bill_number'],
    'flags', (select o.offline_flags from public.orders o where o.client_ref = t.id('post1')),
    'total', (select o.grand_total from public.orders o where o.client_ref = t.id('post1')),
    'prices', (select jsonb_agg(oi.unit_price order by oi.product_name) from public.order_items oi join public.orders o on o.id = oi.order_id where o.client_ref = t.id('post1')),
    'cust', (select o.customer_id is null from public.orders o where o.client_ref = t.id('post1'))),
  (select v::text from t.before where k = 'sync_normal'));
-- a bill with a guest
select t.sync('cash', t.obill(1, 1, jsonb_build_array(t.oitem('dosa', 2, 120), t.oitem('cola', 1, 60)), 'g1', jsonb_build_object('method_id', t.ctx('pmCash'), 'guest_phone', '+91 99000 99999', 'guest_name', 'Offline Olga'))) as s1 \gset
select t.same('7.2 the guest is found/started from the phone: customer, name and phone on the bill',
  (select jsonb_build_object('cust', c.name, 'gname', o.guest_name, 'gphone', o.guest_phone is not null, 'paid', o.payment_status) from public.orders o join public.customers c on c.id = o.customer_id where o.client_ref = t.id('g1')),
  '{"cust":"Offline Olga","gname":"Offline Olga","gphone":true,"paid":"paid"}');
select t.q('7.3 the points are earned once, when the bill is marked paid', (select jsonb_build_array(count(*), sum(l.points) = floor((select grand_total from public.orders where client_ref = t.id('g1')) / 10)) from public.loyalty_ledger l where l.order_id = (select id from public.orders where client_ref = t.id('g1')) and l.kind = 'earn'), '[1, true]');
select t.sync('cash', t.obill(1, 1, jsonb_build_array(t.oitem('dosa', 2, 120), t.oitem('cola', 1, 60)), 'g1', jsonb_build_object('method_id', t.ctx('pmCash'), 'guest_phone', '+91 99000 99999', 'guest_name', 'Offline Olga'))) as s1b \gset
select t.same('7.4 a retried sync adds nothing: one bill, one earn row, the same answer', jsonb_build_object('bills', (select count(*) from public.orders where client_ref = t.id('g1')),
  'earn', (select count(*) from public.loyalty_ledger where kind = 'earn' and order_id = (select id from public.orders where client_ref = t.id('g1'))), 'customers', (select count(*) from public.customers where name = 'Offline Olga'),
  'same_order', (:'s1b'::jsonb->>'order_id') = (:'s1'::jsonb->>'order_id')), '{"bills":1,"earn":1,"customers":1,"same_order":true}');
-- a second bill for the same guest joins the same customer
select t.sync('cash', t.obill(1, 2, jsonb_build_array(t.oitem('cola', 1, 60)), 'g2', jsonb_build_object('method_id', t.ctx('pmCash'), 'guest_phone', '99000 99999'))) as s2 \gset
select t.q('7.5 the same phone on a second bill joins the same customer (and keeps the name)', (select jsonb_build_array(count(distinct o.customer_id), min(c.name)) from public.orders o join public.customers c on c.id = o.customer_id where o.client_ref in (t.id('g1'), t.id('g2'))), '[1, "Offline Olga"]');
-- a phone that is too short
select t.sync('cash', t.obill(1, 3, jsonb_build_array(t.oitem('cola', 1, 60)), 'g3', jsonb_build_object('method_id', t.ctx('pmCash'), 'guest_phone', '12345', 'guest_name', 'Short'))) as s3 \gset
select t.same('7.6 a too-short phone does not lose the bill: saved with no guest, flagged guest_phone_invalid, summary says so',
  (select jsonb_build_object('saved', true, 'cust', o.customer_id is null, 'gphone', o.guest_phone, 'flags', (select jsonb_agg(f->>'flag') from jsonb_array_elements(o.offline_flags) f),
     'summary', (select new_value->>'summary' from public.audit_logs where action = 'order.offline_flagged' and entity_id = o.id), 'new_cust', (select count(*) from public.customers where name = 'Short'))
     from public.orders o where o.client_ref = t.id('g3')),
  '{"saved":true,"cust":true,"gphone":null,"flags":["guest_phone_invalid"],"summary":"guest phone number was too short and was not saved","new_cust":0}');
-- discount block
select t.sync('owner', t.obill(3, 1, jsonb_build_array(t.oitem('pizza', 1, 100), t.oitem('pasta', 1, 100)), 'd1', jsonb_build_object('method_id', t.ctx('pmCash'), 'discount', 20))) as s4 \gset
select t.same('7.7 an offline bill with a discount of 20 over pizza (restricted) + pasta: 20 on the pasta only; nothing cut',
  (select jsonb_build_object('lines', (select jsonb_agg(jsonb_build_object('n', product_name, 'd', line_discount, 'b', discount_blocked) order by product_name) from public.order_items where order_id = o.id),
     'disc', o.discount_total, 'tax', o.tax_total, 'cut', (select count(*) from jsonb_array_elements(coalesce(o.offline_flags, '[]'::jsonb)) f where f->>'flag' = 'discount_cut'))
     from public.orders o where o.client_ref = t.id('d1')),
  '{"lines":[{"n":"Pasta","d":20,"b":false},{"n":"Pizza","d":0,"b":true}],"disc":20,"tax":32.4,"cut":0}');
select t.sync('owner', t.obill(3, 2, jsonb_build_array(t.oitem('pizza', 1, 100), t.oitem('pasta', 1, 100)), 'd2', jsonb_build_object('method_id', t.ctx('pmCash'), 'discount', 150))) as s5 \gset
select t.same('7.8 a till that did not know the flag asks for 150: the server cuts it to the pool (100) and flags discount_cut with both numbers',
  (select jsonb_build_object('disc', o.discount_total, 'cut', (select f from jsonb_array_elements(o.offline_flags) f where f->>'flag' = 'discount_cut'),
     'summary', (select new_value->>'summary' from public.audit_logs where action = 'order.offline_flagged' and entity_id = o.id) like '%cut to 100%')
     from public.orders o where o.client_ref = t.id('d2')),
  '{"disc":100,"cut":{"flag":"discount_cut","asked":150,"recorded":100},"summary":true}');
select t.sync('owner', t.obill(3, 3, jsonb_build_array(t.oitem('burger_l', 1, 220), t.oitem('pasta', 1, 100)), 'd3', jsonb_build_object('method_id', t.ctx('pmCash'), 'discount', 50))) as s6 \gset
select t.q('7.9 a restricted SIZE offline: the discount goes to the pasta, the Large burger keeps full price',
  (select jsonb_agg(line_discount order by product_name) from public.order_items where order_id = (select id from public.orders where client_ref = t.id('d3'))), '[0, 50]');
select t.q('7.10 offline bills carry the snapshot flag on their lines', (select jsonb_agg(discount_blocked order by product_name) from public.order_items where order_id = (select id from public.orders where client_ref = t.id('d1'))), '[false, true]');
select t.q('7.11 a replayed discount bill changes nothing (one bill)', (select count(*) from public.orders where client_ref = t.id('d1')), '1');

-- ================================================================ 8. erase lists and grants (148)
reset role;
select t.same('8.1 erase_groups: the four groups exist', (select jsonb_agg(k order by k) from jsonb_object_keys(app.erase_groups()) k), '["pos_master","pos_tx","stock_master","stock_tx"]');
select t.q('8.2 every table named in the lists exists', (select coalesce(jsonb_agg(g.k || '.' || e.t), '[]'::jsonb) from jsonb_each(app.erase_groups()) g(k, v), jsonb_array_elements_text(g.v) e(t) where to_regclass('public.' || e.t) is null), '[]');
select t.q('8.3 no table is in two groups, none twice', (select count(*) = count(distinct e.t) from jsonb_each(app.erase_groups()) g(k, v), jsonb_array_elements_text(g.v) e(t)), 'true');
select t.q('8.4 inside each group a child table is listed before the table it references (so the deletes never hit a foreign key)',
  (select coalesce(jsonb_agg(c.child || ' after ' || c.parent), '[]'::jsonb)
     from (select g.k, ch.rn as crn, pa.rn as prn, ch.t as child, pa.t as parent
             from jsonb_each(app.erase_groups()) g(k, v)
             cross join lateral (select e.t, e.o as rn from jsonb_array_elements_text(g.v) with ordinality e(t, o)) ch
             cross join lateral (select e.t, e.o as rn from jsonb_array_elements_text(g.v) with ordinality e(t, o)) pa
            where exists (select 1 from pg_constraint fk where fk.contype = 'f' and fk.conrelid = ('public.' || ch.t)::regclass and fk.confrelid = ('public.' || pa.t)::regclass) and ch.t <> pa.t) c
    where c.crn > c.prn), '[]');
select t.q('8.5 the stock-count tables (143) are in the transaction list, lines before counts',
  (select jsonb_build_array(a.o < b.o) from jsonb_array_elements_text(app.erase_groups()->'stock_tx') with ordinality a(t, o), jsonb_array_elements_text(app.erase_groups()->'stock_tx') with ordinality b(t, o) where a.t = 'stock_count_lines' and b.t = 'stock_counts'), '[true]');
select t.q('8.6 the new customer-facing tables stay in their old groups (customers master, loyalty ledger transaction)',
  (select jsonb_build_array(app.erase_groups()->'pos_master' ? 'customers', app.erase_groups()->'pos_tx' ? 'loyalty_ledger')), '[true, true]');
select t.q('8.7 erase_groups is not callable by the app', (select count(*) from information_schema.routine_privileges where routine_schema = 'app' and routine_name = 'erase_groups' and grantee in ('PUBLIC', 'anon', 'authenticated')), '0');
-- grants on existing restaurants
select t.same('8.8 Chef (stock rights come from 148): stock.view and stock.adjust, in both restaurants',
  (select jsonb_agg(n order by n) from (select r.restaurant_id::text = t.ctx('r')::text as mine, count(*) as n from public.roles r join public.role_permissions rp on rp.role_id = r.id where r.name = 'Chef' and r.is_system and rp.permission_key in ('stock.view', 'stock.adjust') group by r.restaurant_id) z),
  '[2, 2]');
select t.q('8.9 the custom Front desk role has customer.view but not loyalty.redeem and no stock rights', (select jsonb_agg(rp.permission_key order by rp.permission_key) from public.role_permissions rp where rp.role_id = t.ctx('roleCust') and rp.permission_key in ('customer.view', 'loyalty.redeem', 'stock.view', 'stock.adjust')), '["customer.view"]');
-- a restaurant created AFTER the migrations (the patched create_restaurant_with_owner)
insert into auth.users (id, email) values (t.id('auth:third'), 'third@t141.test');
select set_config('request.jwt.claim.sub', t.id('auth:third')::text, false);
select public.create_restaurant_with_owner('T141 Third Pvt Ltd', 'T141 Third', 'IN', 'Third Owner', 'Main', 'MN') as third \gset
select t.same('8.10 a NEW restaurant: customer.view for Owner, Manager, Cashier, Steward; loyalty.redeem for Owner, Manager, Cashier',
  jsonb_build_object('view', (select jsonb_agg(r.name order by r.name) from public.roles r where r.restaurant_id = :'third'::uuid and exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = 'customer.view')),
    'redeem', (select jsonb_agg(r.name order by r.name) from public.roles r where r.restaurant_id = :'third'::uuid and exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = 'loyalty.redeem'))),
  '{"view":["Cashier","Manager","Owner","Steward"],"redeem":["Cashier","Manager","Owner"]}');
select t.same('8.11 a NEW restaurant: Chef has stock.view + stock.adjust, nobody lacks what they had', 
  (select jsonb_agg(rp.permission_key order by rp.permission_key) from public.roles r join public.role_permissions rp on rp.role_id = r.id where r.restaurant_id = :'third'::uuid and r.name = 'Chef' and rp.permission_key like 'stock.%'), '["stock.adjust","stock.view"]');
select t.q('8.12 patched once only: the function body names the Cashier grants one time; the Chef grants are not in it (143 trigger gives them)', (select jsonb_build_array((length(d) - length(replace(d, '(v_cashier, ''customer.view'')', ''))) / length('(v_cashier, ''customer.view'')'),
   (length(d) - length(replace(d, '(v_chef, ''stock.view'')', ''))) / length('(v_chef, ''stock.view'')')) from (select pg_get_functiondef('app.create_restaurant_with_owner(text,text,character,text,text,text,text,text)'::regprocedure) as d) z), '[1, 0]');
select t.q('8.13 every right 141..148 needs exists in permissions', (select coalesce(jsonb_agg(k order by k), '[]'::jsonb) from (values ('customer.view'), ('loyalty.redeem'), ('stock.view'), ('stock.adjust')) v(k) where not exists (select 1 from public.permissions p where p.key = v.k)), '[]');

-- ================================================================ 9. integrator additions: offline snapshot flags, customer export audit
select t.as_su('owner');
select public.offline_snapshot(t.id('dev-snap')::text) as snap \gset
select t.is_('9.1 offline_snapshot: a restricted dish carries no_discount = true, an ordinary one false',
  (select bool_and(case when m->>'name' = 'Pizza' then (m->>'no_discount')::boolean else (m->>'no_discount')::boolean is false end)
     from jsonb_array_elements(:'snap'::jsonb->'menu') m where m->>'name' in ('Pizza', 'Pasta')) is true);
select t.is_('9.2 offline_snapshot: every menu item has the key (not just the restricted ones)',
  (select count(*) = count(m->'no_discount') from jsonb_array_elements(:'snap'::jsonb->'menu') m));
select t.q('9.3 offline_snapshot: settings.loyalty is true when the loyalty module is on', (:'snap'::jsonb->'settings'->'loyalty'), 'true');
select t.q('9.4 offline_snapshot patched once only', (select (length(d) - length(replace(d, '''no_discount''', ''))) / length('''no_discount''') from (select pg_get_functiondef('public.offline_snapshot(text)'::regprocedure) as d) x), '1');
select t.as_su('owner');
select public.log_customer_export(12, 'repeat');
select t.q('9.5 log_customer_export: the owner writes the audit row; it says how many and which filter, and holds no phone number',
  (select jsonb_build_array(new_value->>'rows', new_value->>'filter', new_value::text ~ '[0-9]{8,}') from public.audit_logs where action = 'customer.export' order by created_at desc limit 1), '["12","repeat",false]');
select t.as_su('chef');
select t.err('9.6 log_customer_export: a chef (no customer.export) is refused', $q$ select public.log_customer_export(1, 'all') $q$, '(customer.export)');
select t.q('9.7 log_customer_export is not callable by anon or public', (select count(*) from information_schema.routine_privileges where routine_schema = 'public' and routine_name = 'log_customer_export' and grantee in ('PUBLIC', 'anon')), '0');

-- ================================================================ 10. QA fix: points go back to the guest who spent them, even when the counter swapped the guest on the bill
reset role;
select c.id as xena_id from public.customers c where c.name = 'Xena' \gset
select c.id as wren_id from public.customers c where c.name = 'Wren' \gset
select coalesce(sum(points), 0) as xena_before from public.loyalty_ledger where customer_id = :'xena_id' \gset
select coalesce(sum(points), 0) as wren_before from public.loyalty_ledger where customer_id = :'wren_id' \gset
select t.new_bill('owner', '{"pasta":3}') as qa_o \gset
select t.as_su('owner');
select public.attach_customer(:'qa_o'::uuid, '99000 77777', 'Xena');
select public.redeem_points_discount(:'qa_o'::uuid, 10);
select public.set_order_guest(:'qa_o'::uuid, 'Wren', '99000 66666');
select public.remove_points_discount(:'qa_o'::uuid);
reset role;
select t.q('10.1 swap the guest after redeeming, then remove: the guest who spent the points gets them back (Xena net 0, Wren unchanged)',
  (select jsonb_build_array((select coalesce(sum(points), 0) from public.loyalty_ledger where customer_id = :'xena_id') - :xena_before::numeric,
                            (select coalesce(sum(points), 0) from public.loyalty_ledger where customer_id = :'wren_id') - :wren_before::numeric)), '[0, 0]');

-- result
\o
select case when ok then 'PASS' else 'FAIL' end as result, label, detail from t.res order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.res \gset
\echo
\echo RESULT: :passed passed, :failed failed
