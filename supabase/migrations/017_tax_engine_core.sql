-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260924174602, name 'sna_pos_17_tax_engine_core'. This is the SQL that actually ran.

-- SNA POS migration 17: the tax engine as ONE pure function.
--
-- app.calc_bill(input jsonb) -> jsonb does all bill arithmetic and touches no
-- table. The billing screen's live preview, the saved bill and the automated
-- tests all use this same function, so they can never disagree.
--
-- Supports, per line:
--   * tax-exclusive or tax-inclusive prices
--   * any number of tax components; a component marked "compound" is charged on
--     the price PLUS the components before it (tax on tax, e.g. Dubai VAT on the
--     7% municipality fee)
--   * a service charge, optionally taxable (SG/MY/TH/ID/PH/AE tax it; India
--     does not)
--   * Philippine senior citizen / PWD discount: the senior's share is made
--     VAT-exempt first, then 20% is taken off the exempt price
--   * a bill-level discount spread across lines by value, exact to the paisa
-- and it asserts its own invariant: the bill total equals the sum of line totals.

create or replace function app.round_cash(p_amount numeric, p_mode text)
returns numeric language sql immutable set search_path = public, pg_temp as $$
  select case coalesce(p_mode, 'none')
    when 'nearest_1'    then round(p_amount, 0)
    when 'nearest_0_05' then round(p_amount / 0.05) * 0.05
    when 'nearest_0_10' then round(p_amount / 0.10) * 0.10
    else round(p_amount, 2) end
$$;

create or replace function app.calc_bill(p jsonb)
returns jsonb language plpgsql immutable set search_path = public, pg_temp as $$
declare
  v_lines   jsonb   := coalesce(p->'lines', '[]'::jsonb);
  n         int     := jsonb_array_length(coalesce(p->'lines', '[]'::jsonb));
  v_disc_in numeric := round(coalesce((p->>'discount')::numeric, 0), 2);
  v_sc_pct  numeric := coalesce((p->>'sc_percent')::numeric, 0);
  v_sc_tax  boolean := coalesce((p->>'sc_taxable')::boolean, false);
  v_share   numeric := coalesce((p->'senior'->>'share')::numeric, 0);
  v_s_pct   numeric := coalesce((p->'senior'->>'rate')::numeric, 20);
  v_round   text    := coalesce(p->>'rounding', 'none');

  subs numeric[] := '{}';
  discs numeric[] := '{}';
  v_subtotal numeric := 0;
  v_big int := 1;
  v_alloc numeric := 0;
  v_discount numeric;

  i int; k int; ln jsonb; comps jsonb; c jsonb;
  v_sub numeric; v_disc numeric; v_incl boolean; v_f numeric; v_rate numeric; v_cmp boolean;
  v_s_gross numeric; v_s_net numeric; v_s_disc numeric; v_s_removed numeric;
  v_r_amt numeric; v_net numeric; v_sc numeric;
  v_pi numeric; v_ps numeric; v_bi numeric; v_bs numeric; v_ai numeric; v_as numeric;
  ai numeric[]; bi numeric[];
  v_line_taxes jsonb; v_line_total numeric; v_line_tax numeric; v_line_incl numeric;
  o_lines jsonb := '[]'::jsonb;
  t_disc numeric := 0; t_sdisc numeric := 0; t_removed numeric := 0; t_sc numeric := 0;
  t_tax numeric := 0; t_incl numeric := 0; t_exempt numeric := 0; t_net numeric := 0;
  t_lines numeric := 0;
  v_before numeric; v_grand numeric;
  v_taxmap jsonb := '{}'::jsonb; v_key text; v_taxes jsonb;
begin
  if v_disc_in < 0 then raise exception 'A discount cannot be negative.'; end if;
  if v_share < 0 or v_share > 1 then raise exception 'The senior citizen / PWD share must be between 0 and 100%%.'; end if;
  if v_share > 0 and v_disc_in > 0 then
    raise exception 'A senior citizen / PWD discount cannot be combined with another discount.';
  end if;
  if v_sc_pct < 0 or v_sc_pct > 100 then raise exception 'The service charge must be between 0 and 100%%.'; end if;

  -- Pass 1: line subtotals at menu price.
  for i in 0 .. n - 1 loop
    ln := v_lines -> i;
    v_sub := round((ln->>'price')::numeric * (ln->>'qty')::numeric, 2);
    if v_sub < 0 then raise exception 'A line cannot be negative.'; end if;
    subs := subs || v_sub;
    v_subtotal := v_subtotal + v_sub;
    if v_sub > subs[v_big] then v_big := i + 1; end if;
  end loop;

  -- Pass 2: spread the bill discount by value; the largest line takes the
  -- rounding remainder so the parts always add up exactly.
  v_discount := least(v_disc_in, v_subtotal);
  for i in 1 .. n loop
    if i = v_big or v_subtotal = 0 then
      discs := discs || 0::numeric;
    else
      v_disc := round(v_discount * subs[i] / v_subtotal, 2);
      discs := discs || v_disc;
      v_alloc := v_alloc + v_disc;
    end if;
  end loop;
  if n > 0 then discs[v_big] := v_discount - v_alloc; end if;

  -- Pass 3: each line.
  for i in 0 .. n - 1 loop
    ln    := v_lines -> i;
    comps := coalesce(ln->'comps', '[]'::jsonb);
    v_incl := coalesce((ln->>'inclusive')::boolean, false);
    v_sub  := subs[i + 1];
    v_disc := discs[i + 1];

    -- Effective tax factor per 1.00 of net price (compound components apply on
    -- net + earlier components).
    v_f := 0;
    for k in 0 .. jsonb_array_length(comps) - 1 loop
      c := comps -> k;
      v_rate := coalesce((c->>'rate')::numeric, 0);
      v_cmp  := coalesce((c->>'compound')::boolean, false);
      v_f := v_f + v_rate / 100 * (1 + case when v_cmp then v_f else 0 end);
    end loop;

    -- Senior citizen / PWD share: VAT removed, then the percentage off.
    v_s_gross   := round(v_sub * v_share, 2);
    v_s_net     := case when v_incl then round(v_s_gross / (1 + v_f), 2) else v_s_gross end;
    v_s_removed := v_s_gross - v_s_net;
    v_s_disc    := round(v_s_net * v_s_pct / 100, 2);

    -- Regular (taxable) part of the line.
    v_r_amt := v_sub - v_s_gross - v_disc;
    v_net   := case when v_incl then round(v_r_amt / (1 + v_f), 2) else v_r_amt end;

    -- Item taxes.
    ai := '{}'; bi := '{}'; v_pi := 0;
    for k in 0 .. jsonb_array_length(comps) - 1 loop
      c := comps -> k;
      v_rate := coalesce((c->>'rate')::numeric, 0);
      v_cmp  := coalesce((c->>'compound')::boolean, false);
      v_bi := v_net + case when v_cmp then v_pi else 0 end;
      v_ai := round(v_bi * v_rate / 100, 2);
      ai := ai || v_ai; bi := bi || v_bi;
      v_pi := v_pi + v_ai;
    end loop;
    -- Inclusive price: whatever is not tax is the net, so the line is exact.
    if v_incl then v_net := v_r_amt - v_pi; end if;

    -- Service charge on the pre-discount-for-seniors net value.
    v_sc := round((v_net + v_s_net) * v_sc_pct / 100, 2);

    -- Tax on the service charge (added on top, never included).
    v_ps := 0; v_line_taxes := '[]'::jsonb;
    for k in 0 .. jsonb_array_length(comps) - 1 loop
      c := comps -> k;
      v_rate := coalesce((c->>'rate')::numeric, 0);
      v_cmp  := coalesce((c->>'compound')::boolean, false);
      if v_sc_tax then
        v_bs := v_sc + case when v_cmp then v_ps else 0 end;
        v_as := round(v_bs * v_rate / 100, 2);
      else
        v_bs := 0; v_as := 0;
      end if;
      v_ps := v_ps + v_as;
      v_line_taxes := v_line_taxes || jsonb_build_object(
        'name', c->>'name', 'rate', v_rate, 'compound', v_cmp,
        'taxable', bi[k + 1] + v_bs, 'amount', ai[k + 1] + v_as);
      v_key := (c->>'name') || '|' || v_rate::text;
      v_taxmap := jsonb_set(v_taxmap, array[v_key], jsonb_build_object(
        'name', c->>'name', 'rate', v_rate,
        'taxable', coalesce((v_taxmap->v_key->>'taxable')::numeric, 0) + bi[k + 1] + v_bs,
        'amount',  coalesce((v_taxmap->v_key->>'amount')::numeric, 0) + ai[k + 1] + v_as));
    end loop;

    v_line_tax   := v_pi + v_ps;
    v_line_incl  := case when v_incl then v_pi else 0 end;
    v_line_total := (case when v_incl then v_r_amt else v_net + v_pi end)
                    + (v_s_net - v_s_disc) + v_sc + v_ps;

    o_lines := o_lines || jsonb_build_object(
      'key', ln->'key', 'subtotal', v_sub, 'discount', v_disc,
      'senior_discount', v_s_disc, 'exempt_sales', v_s_net, 'tax_exempt_amount', v_s_removed,
      'net', v_net + v_s_net - v_s_disc, 'taxable_net', v_net,
      'service_charge', v_sc, 'tax', v_line_tax, 'tax_included', v_line_incl,
      'total', v_line_total, 'inclusive', v_incl, 'taxes', v_line_taxes);

    t_disc := t_disc + v_disc;          t_sdisc := t_sdisc + v_s_disc;
    t_removed := t_removed + v_s_removed; t_exempt := t_exempt + v_s_net;
    t_sc := t_sc + v_sc;                t_tax := t_tax + v_line_tax;
    t_incl := t_incl + v_line_incl;     t_net := t_net + v_net + v_s_net - v_s_disc;
    t_lines := t_lines + v_line_total;
  end loop;

  v_before := v_subtotal - t_disc - t_sdisc - t_removed + t_sc + t_tax - t_incl;

  -- Invariant: the bill must equal the sum of its lines. If it ever does not,
  -- refuse rather than print a wrong bill.
  if v_before <> t_lines then
    raise exception 'Internal check failed: bill total % does not equal line total %.', v_before, t_lines;
  end if;

  v_grand := app.round_cash(v_before, v_round);

  select coalesce(jsonb_agg(value order by (value->>'rate')::numeric, value->>'name'), '[]'::jsonb)
    into v_taxes from jsonb_each(v_taxmap);

  return jsonb_build_object(
    'lines', o_lines,
    'subtotal', v_subtotal, 'discount', t_disc, 'senior_discount', t_sdisc,
    'tax_exempt_amount', t_removed, 'exempt_sales', t_exempt,
    'service_charge', t_sc, 'tax_total', t_tax, 'tax_included', t_incl,
    'net_sales', t_net, 'before_round', v_before,
    'rounding', v_grand - v_before, 'grand_total', v_grand,
    'taxes', v_taxes);
end $$;

-- ---------------------------------------------------------------------------
-- The money test suite. Every expected figure below was worked out by hand
-- from each country's rules. Run: select app.test_money();
-- ---------------------------------------------------------------------------
create or replace function app.test_money()
returns text language plpgsql set search_path = public, pg_temp as $$
declare
  r jsonb; fails text := ''; n int := 0;
  gst5  jsonb := '[{"name":"CGST","rate":2.5},{"name":"SGST","rate":2.5}]';
  gst12 jsonb := '[{"name":"CGST","rate":6},{"name":"SGST","rate":6}]';
  procedure_dummy int;
begin
  -- helper via inline checks
  -- T1 India: 2x40 @5% + 1x20 @12%, round to rupee -> 106
  r := app.calc_bill(jsonb_build_object('rounding','nearest_1','lines', jsonb_build_array(
        jsonb_build_object('key',1,'price',40,'qty',2,'comps',gst5),
        jsonb_build_object('key',2,'price',20,'qty',1,'comps',gst12))));
  n := n + 1; if (r->>'tax_total')::numeric <> 6.40 or (r->>'grand_total')::numeric <> 106 or (r->>'rounding')::numeric <> -0.40 then fails := fails || 'T1 India ' || r::text || E'\n'; end if;

  -- T2 Singapore "++": 100 + 10% service = 110, 9% GST on 110 = 9.90 -> 119.90
  r := app.calc_bill('{"sc_percent":10,"sc_taxable":true,"lines":[{"key":1,"price":100,"qty":1,"comps":[{"name":"GST","rate":9}]}]}');
  n := n + 1; if (r->>'service_charge')::numeric <> 10 or (r->>'tax_total')::numeric <> 9.90 or (r->>'grand_total')::numeric <> 119.90 then fails := fails || 'T2 Singapore ' || r::text || E'\n'; end if;

  -- T3 UAE tax-inclusive: 105 incl 5% VAT -> net 100, VAT 5 included, total 105
  r := app.calc_bill('{"lines":[{"key":1,"price":105,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":5}]}]}');
  n := n + 1; if (r->>'net_sales')::numeric <> 100 or (r->>'tax_included')::numeric <> 5 or (r->>'grand_total')::numeric <> 105 then fails := fails || 'T3 UAE inclusive ' || r::text || E'\n'; end if;

  -- T4 Dubai tax on tax: 112.35 incl; 7% municipality fee, then 5% VAT on (net + fee)
  r := app.calc_bill('{"lines":[{"key":1,"price":112.35,"qty":1,"inclusive":true,"comps":[{"name":"Municipality fee","rate":7},{"name":"VAT","rate":5,"compound":true}]}]}');
  n := n + 1; if (r->>'net_sales')::numeric <> 100 or (r->>'tax_total')::numeric <> 12.35 or (r->>'grand_total')::numeric <> 112.35
     or (r->'lines'->0->'taxes'->1->>'amount')::numeric <> 5.35 then fails := fails || 'T4 Dubai compound ' || r::text || E'\n'; end if;

  -- T5 Philippines senior, whole bill: 500 incl 12% -> exempt 446.43, 20% = 89.29, pays 357.14
  r := app.calc_bill('{"senior":{"share":1},"lines":[{"key":1,"price":500,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":12}]}]}');
  n := n + 1; if (r->>'exempt_sales')::numeric <> 446.43 or (r->>'senior_discount')::numeric <> 89.29
     or (r->>'tax_exempt_amount')::numeric <> 53.57 or (r->>'tax_total')::numeric <> 0 or (r->>'grand_total')::numeric <> 357.14
     then fails := fails || 'T5 PH senior ' || r::text || E'\n'; end if;

  -- T6 Philippines shared platter: 1000 incl, 1 senior of 4 -> 928.57
  r := app.calc_bill('{"senior":{"share":0.25},"lines":[{"key":1,"price":1000,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":12}]}]}');
  n := n + 1; if (r->>'exempt_sales')::numeric <> 223.21 or (r->>'senior_discount')::numeric <> 44.64
     or (r->>'tax_total')::numeric <> 80.36 or (r->>'grand_total')::numeric <> 928.57
     then fails := fails || 'T6 PH shared ' || r::text || E'\n'; end if;

  -- T7 Malaysia: 100 + 10% service; 6% service tax on 110 -> 116.60
  r := app.calc_bill('{"sc_percent":10,"sc_taxable":true,"lines":[{"key":1,"price":100,"qty":1,"comps":[{"name":"SST","rate":6}]}]}');
  n := n + 1; if (r->>'tax_total')::numeric <> 6.60 or (r->>'grand_total')::numeric <> 116.60 then fails := fails || 'T7 Malaysia ' || r::text || E'\n'; end if;
  -- T7b Malaysia 5-sen cash rounding (Bank Negara rule)
  n := n + 1; if app.round_cash(116.62,'nearest_0_05') <> 116.60 or app.round_cash(116.63,'nearest_0_05') <> 116.65
     or app.round_cash(116.67,'nearest_0_05') <> 116.65 or app.round_cash(116.68,'nearest_0_05') <> 116.70
     then fails := fails || 'T7b 5-sen rounding' || E'\n'; end if;

  -- T8 Thailand net pricing: 107 incl 7% VAT + 10% service; VAT also on service -> 117.70
  r := app.calc_bill('{"sc_percent":10,"sc_taxable":true,"lines":[{"key":1,"price":107,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":7}]}]}');
  n := n + 1; if (r->>'service_charge')::numeric <> 10 or (r->>'tax_total')::numeric <> 7.70 or (r->>'tax_included')::numeric <> 7
     or (r->>'grand_total')::numeric <> 117.70 then fails := fails || 'T8 Thailand ' || r::text || E'\n'; end if;

  -- T9 Indonesia (Jakarta rule): PBJT 10% on (100 - 10 discount + 5% service) -> 103.95
  r := app.calc_bill('{"discount":10,"sc_percent":5,"sc_taxable":true,"lines":[{"key":1,"price":100,"qty":1,"comps":[{"name":"PBJT","rate":10}]}]}');
  n := n + 1; if (r->>'service_charge')::numeric <> 4.50 or (r->>'tax_total')::numeric <> 9.45 or (r->>'grand_total')::numeric <> 103.95
     then fails := fails || 'T9 Indonesia ' || r::text || E'\n'; end if;

  -- T10 discount split is exact: 10 off 20+40+40
  r := app.calc_bill('{"discount":10,"lines":[{"key":1,"price":20,"qty":1},{"key":2,"price":40,"qty":1},{"key":3,"price":40,"qty":1}]}');
  n := n + 1; if (select sum((l->>'discount')::numeric) from jsonb_array_elements(r->'lines') l) <> 10
     or (r->>'grand_total')::numeric <> 90 then fails := fails || 'T10 discount split ' || r::text || E'\n'; end if;

  -- T10b awkward split: 10 off three equal lines of 33.33
  r := app.calc_bill('{"discount":10,"lines":[{"key":1,"price":33.33,"qty":1},{"key":2,"price":33.33,"qty":1},{"key":3,"price":33.33,"qty":1}]}');
  n := n + 1; if (select sum((l->>'discount')::numeric) from jsonb_array_elements(r->'lines') l) <> 10
     or (r->>'grand_total')::numeric <> 89.99 then fails := fails || 'T10b awkward split ' || r::text || E'\n'; end if;

  -- T11 India with a voluntary service charge that is NOT taxed: 100 + 10 + 5 = 115
  r := app.calc_bill(jsonb_build_object('sc_percent',10,'sc_taxable',false,'lines',jsonb_build_array(
        jsonb_build_object('key',1,'price',100,'qty',1,'comps',gst5))));
  n := n + 1; if (r->>'service_charge')::numeric <> 10 or (r->>'tax_total')::numeric <> 5 or (r->>'grand_total')::numeric <> 115
     then fails := fails || 'T11 India service charge ' || r::text || E'\n'; end if;

  -- T12 inclusive with awkward cents: 3 x 99.99 incl 9% -> tax 24.77, total unchanged
  r := app.calc_bill('{"lines":[{"key":1,"price":99.99,"qty":3,"inclusive":true,"comps":[{"name":"GST","rate":9}]}]}');
  n := n + 1; if (r->>'tax_included')::numeric <> 24.77 or (r->>'net_sales')::numeric <> 275.20 or (r->>'grand_total')::numeric <> 299.97
     then fails := fails || 'T12 inclusive cents ' || r::text || E'\n'; end if;

  -- T13 discount larger than the bill is capped at the bill
  r := app.calc_bill('{"discount":500,"lines":[{"key":1,"price":100,"qty":1,"comps":[{"name":"VAT","rate":5}]}]}');
  n := n + 1; if (r->>'discount')::numeric <> 100 or (r->>'grand_total')::numeric <> 0 then fails := fails || 'T13 discount cap ' || r::text || E'\n'; end if;

  -- T14 guards: senior + discount together is refused
  n := n + 1;
  begin
    perform app.calc_bill('{"discount":5,"senior":{"share":1},"lines":[{"key":1,"price":100,"qty":1}]}');
    fails := fails || 'T14 senior+discount was allowed' || E'\n';
  exception when others then null; end;

  -- T15 mixed inclusive + exclusive lines on one bill
  r := app.calc_bill('{"lines":[{"key":1,"price":105,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":5}]},{"key":2,"price":100,"qty":1,"comps":[{"name":"VAT","rate":5}]}]}');
  n := n + 1; if (r->>'tax_total')::numeric <> 10 or (r->>'tax_included')::numeric <> 5 or (r->>'grand_total')::numeric <> 210
     then fails := fails || 'T15 mixed ' || r::text || E'\n'; end if;

  if fails <> '' then
    raise exception 'MONEY TESTS FAILED:%', E'\n' || fails;
  end if;
  return 'All ' || n || ' money tests passed';
end $$;

revoke all on function app.calc_bill(jsonb), app.round_cash(numeric, text), app.test_money() from public, anon;
grant execute on function app.calc_bill(jsonb), app.round_cash(numeric, text) to authenticated;
