-- 077: money fixes left over from the 27 Sep team review
--
--  M7  A small discount spread over many lines no longer errors.
--  M3  A part-paid bill closes itself when a cancelled item brings the total
--      down to what was already paid.
--  M6  Voiding a bill whose cash sits in a closed shift always records the
--      cash coming out of the open drawer (and waits if no drawer is open).
--      A closed shift keeps the report it had when it closed.
--  M8  Splitting part of a line gives the moved part its own kitchen line;
--      voiding a bill cancels only that bill's kitchen lines.
--  M2  Reports show how much of "total billed" is still unpaid, and
--      "net collected" no longer counts money that has not been received.
--  M13 Add-items, split and credit note accept a request id, so a retry on a
--      bad connection cannot do the same thing twice.

------------------------------------------------------------------
-- Request ids
------------------------------------------------------------------
create table if not exists public.request_refs (
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  ref           uuid not null,
  kind          text not null,
  order_id      uuid,
  result        jsonb not null,
  created_at    timestamptz not null default now(),
  primary key (restaurant_id, ref)
);
create index if not exists request_refs_age on public.request_refs (restaurant_id, created_at);
alter table public.request_refs enable row level security;
revoke all on public.request_refs from anon, authenticated;
comment on table public.request_refs is
  'One row per finished request that carried a request id. A repeat of the same request gets the stored answer instead of running again. Written and read only by the database functions.';

------------------------------------------------------------------
-- A closed shift keeps its closing report
------------------------------------------------------------------
-- Kept in its own table that no signed-in person can read directly: the
-- figures are shown only through shift_report, which checks the right to see them.
create table if not exists public.shift_closings (
  shift_id      uuid primary key references public.shifts(id) on delete cascade,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  figures       jsonb not null,
  unpaid_orders uuid[] not null default '{}',
  created_at    timestamptz not null default now()
);
alter table public.shift_closings enable row level security;
revoke all on public.shift_closings from anon, authenticated;
comment on table public.shift_closings is
  'The report a shift had at the moment it closed, and the bills that were still unpaid then. Written and read only by the database functions.';

CREATE OR REPLACE FUNCTION app.shift_figures(p_shift uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  s public.shifts%rowtype;
  v_cash_sales numeric(14,2); v_cash_refunds numeric(14,2);
  v_in numeric(14,2); v_out numeric(14,2);
  v_bills int; v_sales numeric(14,2); v_voided int; v_unpaid int; v_methods jsonb;
  v_due numeric(14,2); v_late int; v_late_value numeric(14,2);
  v_frozen jsonb; v_open_ids uuid[]; v_moved int; v_moved_value numeric(14,2);
begin
  select * into s from public.shifts where id = p_shift;
  if not found then return null; end if;

  -- A closed shift's report is the one taken when it closed. Bills voided
  -- afterwards are listed beside it instead of silently changing it.
  if s.status = 'closed' then
    select c.figures, c.unpaid_orders into v_frozen, v_open_ids from public.shift_closings c where c.shift_id = s.id;
    if v_frozen is not null then
      select count(*), coalesce(sum(grand_total), 0) into v_late, v_late_value
        from public.orders
       where shift_id = s.id and status = 'voided' and merged_into is null and voided_at >= s.closed_at;
      -- A bill that was unpaid when this shift closed and was settled in a later
      -- shift is counted as that later shift's sale. Say so here, so the two
      -- shift reports are not read as two sales.
      select count(*), coalesce(sum(grand_total), 0) into v_moved, v_moved_value
        from public.orders
       where id = any(v_open_ids) and shift_id <> s.id and status <> 'voided' and merged_into is null;
      return v_frozen || jsonb_build_object('voided_after_close', v_late, 'voided_after_close_value', v_late_value,
                                            'paid_later', v_moved, 'paid_later_value', v_moved_value);
    end if;
  end if;

  select coalesce(sum(p.amount),0) into v_cash_sales
    from public.payments p
    join public.orders o on o.id = p.order_id
    join public.payment_methods pm on pm.id = p.payment_method_id
   where coalesce(p.shift_id, o.shift_id) = s.id and o.status <> 'voided'
     and pm.affects_cash_drawer and p.status = 'captured';

  select coalesce(sum(r.amount),0) into v_cash_refunds
    from public.refunds r
    left join public.payments p on p.id = r.payment_id
    join public.payment_methods pm on pm.id = coalesce(r.payment_method_id, p.payment_method_id)
   where pm.affects_cash_drawer
     and (r.shift_id = s.id
          or (r.shift_id is null and r.restaurant_id = s.restaurant_id
              and exists (select 1 from public.orders o2 where o2.id = r.order_id and o2.branch_id = s.branch_id)
              and r.created_at >= s.opened_at and (s.closed_at is null or r.created_at <= s.closed_at)));

  select coalesce(sum(amount) filter (where direction='in'),0),
         coalesce(sum(amount) filter (where direction='out'),0)
    into v_in, v_out from public.cash_movements where shift_id = s.id;

  select count(*) filter (where status <> 'voided'),
         coalesce(sum(grand_total) filter (where status <> 'voided'),0),
         count(*) filter (where status = 'voided'),
         count(*) filter (where status <> 'voided' and payment_status in ('unpaid', 'partial'))
    into v_bills, v_sales, v_voided, v_unpaid
    from public.orders where shift_id = s.id and merged_into is null;

  select coalesce(sum(o.grand_total - app.order_covered(o.id)), 0) into v_due
    from public.orders o
   where o.shift_id = s.id and o.merged_into is null and o.status <> 'voided'
     and o.payment_status in ('unpaid', 'partial');

  select coalesce(jsonb_agg(jsonb_build_object('method', m.name, 'bills', m.n, 'amount', m.amt)
                            order by m.amt desc), '[]'::jsonb)
    into v_methods
    from (select pm.name, count(*) n, sum(p.amount) amt
            from public.payments p
            join public.orders o on o.id = p.order_id
            join public.payment_methods pm on pm.id = p.payment_method_id
           where coalesce(p.shift_id, o.shift_id) = s.id and o.status <> 'voided' and p.status = 'captured'
           group by pm.name) m;

  return jsonb_build_object(
    'shift_id', s.id, 'status', s.status, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
    'opened_by', (select full_name from public.users where id = s.opened_by),
    'closed_by', (select full_name from public.users where id = s.closed_by),
    'opening_float', s.opening_float,
    'bills', v_bills, 'sales', v_sales, 'voided', v_voided, 'unpaid', v_unpaid, 'unpaid_amount', v_due,
    'cash_sales', v_cash_sales, 'cash_refunds', v_cash_refunds,
    'cash_in', v_in, 'cash_out', v_out,
    'expected_cash', case when s.status = 'closed' and s.expected_cash is not null
                          then s.expected_cash
                          else s.opening_float + v_cash_sales - v_cash_refunds + v_in - v_out end,
    'counted_cash', s.counted_cash, 'variance', s.cash_variance, 'notes', s.notes,
    'by_method', v_methods);
end $function$;

create or replace function app.freeze_shift_figures()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare f jsonb;
begin
  if new.status = 'closed' and old.status = 'open' then
    f := app.shift_figures(old.id);
    insert into public.shift_closings (shift_id, restaurant_id, figures, unpaid_orders)
    values (old.id, old.restaurant_id,
            f || jsonb_build_object(
              'status', 'closed', 'closed_at', new.closed_at,
              'closed_by', (select full_name from public.users where id = new.closed_by),
              'expected_cash', coalesce(new.expected_cash, (f->>'expected_cash')::numeric),
              'counted_cash', new.counted_cash, 'variance', new.cash_variance, 'notes', new.notes),
            coalesce((select array_agg(o.id) from public.orders o
                       where o.shift_id = old.id and o.merged_into is null and o.status <> 'voided'
                         and o.payment_status in ('unpaid', 'partial')), '{}'))
    on conflict (shift_id) do update set figures = excluded.figures, unpaid_orders = excluded.unpaid_orders, created_at = now();
  elsif new.status = 'open' and old.status = 'closed' then
    delete from public.shift_closings where shift_id = old.id;
  end if;
  return new;
end $$;
revoke all on function app.freeze_shift_figures() from public, anon, authenticated;

drop trigger if exists trg_freeze_shift_figures on public.shifts;
create trigger trg_freeze_shift_figures before update of status on public.shifts
  for each row execute function app.freeze_shift_figures();

------------------------------------------------------------------
-- The bill calculator (M7)
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.calc_bill(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_dc numeric; v_tc numeric; v_left int; v_best int;
  bases numeric[] := '{}'; rems numeric[] := '{}'; taken boolean[] := '{}';
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

  -- A small discount over many lines can leave the largest line with less than
  -- nothing (every small line rounds up to 0.01). When that happens, spread it
  -- again to the paisa by largest remainder: no line goes below zero or above
  -- its own value, and the parts still add up exactly.
  if n > 0 and v_subtotal > 0 and (discs[v_big] < 0 or discs[v_big] > subs[v_big]) then
    v_dc := v_discount * 100; v_tc := v_subtotal * 100; v_alloc := 0;
    for i in 1 .. n loop
      bases[i] := div(v_dc * (subs[i] * 100), v_tc);
      rems[i]  := mod(v_dc * (subs[i] * 100), v_tc);
      taken[i] := false;
      v_alloc  := v_alloc + bases[i];
    end loop;
    v_left := (v_dc - v_alloc)::int;
    while v_left > 0 loop
      v_best := 0;
      for i in 1 .. n loop
        if not taken[i] and (v_best = 0 or rems[i] > rems[v_best]) then v_best := i; end if;
      end loop;
      exit when v_best = 0;
      bases[v_best] := bases[v_best] + 1; taken[v_best] := true; v_left := v_left - 1;
    end loop;
    for i in 1 .. n loop discs[i] := round(bases[i] / 100, 2); end loop;
  end if;

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
end $function$;

CREATE OR REPLACE FUNCTION app.test_money()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  -- T16 a small discount over many lines: no line goes below zero, the parts add up
  r := app.calc_bill(jsonb_build_object('discount', 0.20, 'lines',
        (select jsonb_agg(jsonb_build_object('key', g, 'price', 10, 'qty', 1)) from generate_series(1, 30) g)));
  n := n + 1; if (select min((l->>'discount')::numeric) from jsonb_array_elements(r->'lines') l) < 0
     or (select sum((l->>'discount')::numeric) from jsonb_array_elements(r->'lines') l) <> 0.20
     or (r->>'grand_total')::numeric <> 299.80 then fails := fails || 'T16 small discount, many lines ' || r::text || E'\n'; end if;
  if fails <> '' then
    raise exception 'MONEY TESTS FAILED:%', E'\n' || fails;
  end if;
  return 'All ' || n || ' money tests passed';
end $function$;

------------------------------------------------------------------
-- Cancel an item (M3), void a bill (M6, M8)
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_order_item(p_order_item_id uuid, p_qty numeric, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.void');
  it public.order_items%rowtype; o public.orders%rowtype; v_q numeric; v_c jsonb; v_before numeric(14,2);
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'A reason is required to cancel an item.'; end if;
  select * into it from public.order_items where id = p_order_item_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That item is not on the bill.'; end if;
  select * into o from public.orders where id = it.order_id for update;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then
    raise exception 'Bill % is already paid. Use a refund instead.', o.bill_number;
  end if;
  if it.cancelled_at is not null then raise exception '% is already cancelled.', it.product_name; end if;
  v_q := coalesce(p_qty, it.quantity);
  if v_q <= 0 or v_q > it.quantity then
    raise exception 'Enter a quantity between 1 and % for %.', trim_scale(it.quantity), it.product_name;
  end if;
  v_before := o.grand_total;

  if v_q = it.quantity then
    if (select count(*) from public.order_items where order_id = o.id and cancelled_at is null) = 1 then
      raise exception '% is the only item on bill %. Void the bill instead.', it.product_name, o.bill_number;
    end if;
    update public.order_items set cancelled_at = now(), cancelled_by = v_user, cancelled_qty = cancelled_qty + v_q,
           cancel_reason = left(trim(p_reason), 200) where id = it.id;
    update public.kitchen_ticket_items set status = 'cancelled' where order_item_id = it.id and status in ('new', 'preparing');
  else
    update public.order_items set quantity = quantity - v_q, cancelled_qty = cancelled_qty + v_q,
           cancel_reason = left(trim(p_reason), 200) where id = it.id;
    update public.kitchen_ticket_items set quantity = quantity - v_q
     where order_item_id = it.id and status in ('new', 'preparing') and quantity > v_q;
  end if;
  update public.kitchen_tickets kt set status = 'cancelled'
   where kt.order_id = o.id and kt.status in ('new', 'preparing')
     and not exists (select 1 from public.kitchen_ticket_items k where k.kitchen_ticket_id = kt.id and k.status <> 'cancelled');

  v_c := app.recalc_order(o.id);
  if (v_c->>'grand_total')::numeric < app.order_covered(o.id) then
    raise exception 'Bill % already has % paid, which is more than the new total. Refund after payment instead.',
      o.bill_number, app.order_covered(o.id);
  end if;
  -- What was already paid now covers the whole (smaller) bill: close it.
  if app.order_covered(o.id) > 0 and (v_c->>'grand_total')::numeric = app.order_covered(o.id) then
    update public.orders set payment_status = 'paid' where id = o.id;
  end if;

  perform app.audit('order.cancel_item', 'order_items', it.id,
    jsonb_build_object('bill_number', o.bill_number, 'item', it.product_name, 'qty', v_q,
                       'reason', left(trim(p_reason), 200), 'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', v_before, 'qty', it.quantity));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'grand_total', (v_c->>'grand_total')::numeric,
    'paid', app.order_covered(o.id) > 0 and (v_c->>'grand_total')::numeric = app.order_covered(o.id));
end $function$;

CREATE OR REPLACE FUNCTION public.void_order(p_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.void');
  o public.orders%rowtype;
  v_cash numeric(14,2);
  v_open uuid;
begin
  if coalesce(trim(p_reason),'') = '' then raise exception 'A reason is required to void a bill.'; end if;
  select * into o from public.orders
   where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is already voided.', o.bill_number; end if;
  if o.status <> 'completed' then raise exception 'Only a completed bill can be voided.'; end if;
  if exists (select 1 from public.refunds where order_id = o.id) then
    raise exception 'Bill % already has a refund, so it cannot also be voided.', o.bill_number;
  end if;

  -- If the bill's shift is already closed, its cash is no longer in that
  -- drawer's count: the money goes back out of today's drawer instead.
  -- Cash that was counted into a shift which has since closed is given back
  -- from the drawer that is open now, so it must be written down there. With
  -- no drawer open there is nowhere to record it, so the void waits.
  select coalesce(sum(p.amount),0) into v_cash
    from public.payments p
    join public.payment_methods pm on pm.id = p.payment_method_id
    join public.shifts s on s.id = coalesce(p.shift_id, o.shift_id)
   where p.order_id = o.id and p.status = 'captured' and pm.affects_cash_drawer and s.status = 'closed';
  if v_cash > 0 then
    select id into v_open from public.shifts
     where branch_id = o.branch_id and status = 'open' limit 1;
    if v_open is null then v_open := app.auto_shift(o.branch_id); end if;
    if v_open is null then
      raise exception 'Open a shift before voiding bill %. Its cash (%) has to come out of a drawer that is being counted.', o.bill_number, v_cash;
    end if;
    insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (gen_random_uuid(), o.restaurant_id, v_open, 'out', v_cash,
            left('Cash returned for voided bill ' || o.bill_number, 200), v_user);
  end if;

  update public.orders set status = 'voided', voided_by = v_user, voided_at = now(),
         void_reason = left(trim(p_reason),300),
         payment_status = case when o.paid_total > 0 then 'refunded' else o.payment_status end
   where id = o.id;
  update public.payments set status = 'refunded' where order_id = o.id and status = 'captured';
  -- Cancel only this bill's own lines in the kitchen. After a split, a kitchen
  -- ticket can carry lines that now belong to another bill; those stay.
  update public.kitchen_ticket_items k set status = 'cancelled'
   where k.order_item_id in (select oi.id from public.order_items oi where oi.order_id = o.id)
     and k.status in ('new','preparing');
  update public.kitchen_tickets kt set status = 'cancelled'
   where kt.restaurant_id = o.restaurant_id and kt.status in ('new','preparing')
     and (kt.order_id = o.id
          or exists (select 1 from public.kitchen_ticket_items k join public.order_items oi on oi.id = k.order_item_id
                      where k.kitchen_ticket_id = kt.id and oi.order_id = o.id))
     and not exists (select 1 from public.kitchen_ticket_items k2
                      where k2.kitchen_ticket_id = kt.id and k2.status <> 'cancelled');

  perform app.audit('order.void', 'orders', o.id,
    jsonb_build_object('status','voided','reason', left(trim(p_reason),300)),
    jsonb_build_object('status', o.status, 'grand_total', o.grand_total));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'status', 'voided');
end $function$;

------------------------------------------------------------------
-- Reports (M2)
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sales_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_fin boolean;
  v_summary jsonb; v_by_day jsonb; v_by_hour jsonb; v_by_item jsonb; v_by_method jsonb; v_by_type jsonb;
  v_tax jsonb := '[]'::jsonb; v_refunds numeric(14,2); v_refund_count int; v_net numeric(14,2);
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_fin  := app.has_permission('report.view_financial');
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;

  drop table if exists _rep_orders;
  create temp table _rep_orders (id uuid primary key, created_at timestamptz, status text,
    order_type text, subtotal numeric, discount_total numeric, tax_total numeric, tax_included numeric,
    service_charge numeric, rounding_adjustment numeric, grand_total numeric, exempt_sales numeric, due numeric) on commit drop;
  insert into _rep_orders
  select id, created_at, status, order_type, subtotal, discount_total, tax_total, tax_included,
         service_charge, rounding_adjustment, grand_total, exempt_sales,
         case when status = 'completed' and payment_status in ('unpaid', 'partial')
              then grand_total - app.order_covered(id) else 0 end
    from public.orders
   where restaurant_id = v_rest and app.in_scope(branch_id) and created_at >= v_start and created_at < v_end
     and status in ('completed', 'voided') and merged_into is null;

  select coalesce(sum(r.amount), 0), count(*) into v_refunds, v_refund_count
    from public.refunds r where r.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = r.order_id)) and r.created_at >= v_start and r.created_at < v_end;
  select coalesce(sum(oi.net_amount), 0) into v_net
    from public.order_items oi join _rep_orders o on o.id = oi.order_id where o.status = 'completed';

  select jsonb_build_object(
      'bills',          count(*) filter (where status = 'completed'),
      'gross_sales',    coalesce(sum(subtotal) filter (where status = 'completed'), 0),
      'net_sales',      v_net,
      'discounts',      coalesce(sum(discount_total) filter (where status = 'completed'), 0),
      'service_charge', coalesce(sum(service_charge) filter (where status = 'completed'), 0),
      'tax',            coalesce(sum(tax_total) filter (where status = 'completed'), 0),
      'tax_included',   coalesce(sum(tax_included) filter (where status = 'completed'), 0),
      'exempt_sales',   coalesce(sum(exempt_sales) filter (where status = 'completed'), 0),
      'rounding',       coalesce(sum(rounding_adjustment) filter (where status = 'completed'), 0),
      'total_billed',   coalesce(sum(grand_total) filter (where status = 'completed'), 0),
      'average_bill',   coalesce(round(avg(grand_total) filter (where status = 'completed'), 2), 0),
      'voided_bills',   count(*) filter (where status = 'voided'),
      'voided_value',   coalesce(sum(grand_total) filter (where status = 'voided'), 0),
      'refunds',        v_refunds,
      'refund_count',   v_refund_count,
      'unpaid_bills',   count(*) filter (where status = 'completed' and due > 0),
      'unpaid_amount',  coalesce(sum(due), 0),
      'net_collected',  coalesce(sum(grand_total) filter (where status = 'completed'), 0) - coalesce(sum(due), 0) - v_refunds)
    into v_summary from _rep_orders;

  select coalesce(jsonb_agg(jsonb_build_object('day', d, 'bills', n, 'total', t) order by d), '[]'::jsonb) into v_by_day
    from (select (created_at at time zone v_tz)::date d, count(*) n, sum(grand_total) t
            from _rep_orders where status = 'completed' group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('hour', h, 'bills', n, 'total', t) order by h), '[]'::jsonb) into v_by_hour
    from (select extract(hour from created_at at time zone v_tz)::int h, count(*) n, sum(grand_total) t
            from _rep_orders where status = 'completed' group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('item', name, 'qty', q, 'amount', a) order by a desc), '[]'::jsonb) into v_by_item
    from (select oi.product_name name, sum(oi.quantity) q, sum(oi.line_subtotal) a
            from public.order_items oi join _rep_orders o on o.id = oi.order_id
           where o.status = 'completed' and oi.cancelled_at is null group by oi.product_name order by 3 desc limit 5000) x;
  select coalesce(jsonb_agg(jsonb_build_object('method', name, 'bills', n, 'amount', a) order by a desc), '[]'::jsonb) into v_by_method
    from (select pm.name, count(*) n, sum(p.amount) a
            from public.payments p join _rep_orders o on o.id = p.order_id
            join public.payment_methods pm on pm.id = p.payment_method_id
           where o.status = 'completed' group by pm.name) x;
  select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'bills', n, 'total', t) order by t desc), '[]'::jsonb) into v_by_type
    from (select order_type, count(*) n, sum(grand_total) t from _rep_orders where status = 'completed' group by 1) x;

  if v_fin then
    select coalesce(jsonb_agg(jsonb_build_object('component', c, 'rate', r, 'taxable', tx, 'tax', ta) order by r, c), '[]'::jsonb)
      into v_tax
      from (select t.component_name c, t.rate r, sum(t.taxable_amount) tx, sum(t.tax_amount) ta
              from public.order_item_taxes t join _rep_orders o on o.id = t.order_id
             where o.status = 'completed' group by 1, 2) x;
  end if;

  return jsonb_build_object('from', p_from, 'to', p_to, 'timezone', v_tz, 'financial', v_fin,
    'summary', v_summary, 'by_day', v_by_day, 'by_hour', v_by_hour, 'by_item', v_by_item,
    'by_method', v_by_method, 'by_type', v_by_type, 'tax', v_tax);
end $function$;

CREATE OR REPLACE FUNCTION app.z_report(p_day uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.business_days; v jsonb; v_pay jsonb; v_tax jsonb; v_cn jsonb; v_shifts jsonb; v_types jsonb;
begin
  select * into d from public.business_days where id = p_day;
  if not found then return null; end if;
  select jsonb_build_object(
      'bills', count(*) filter (where status = 'completed'),
      'first_bill', min(bill_number) filter (where status <> 'voided'),
      'last_bill', max(bill_number) filter (where status <> 'voided'),
      'gross_sales', coalesce(sum(subtotal) filter (where status = 'completed'), 0),
      'discounts', coalesce(sum(discount_total) filter (where status = 'completed'), 0),
      'service_charge', coalesce(sum(service_charge) filter (where status = 'completed'), 0),
      'tax', coalesce(sum(tax_total) filter (where status = 'completed'), 0),
      'tax_included', coalesce(sum(tax_included) filter (where status = 'completed'), 0),
      'rounding', coalesce(sum(rounding_adjustment) filter (where status = 'completed'), 0),
      'total_billed', coalesce(sum(grand_total) filter (where status = 'completed'), 0),
      'voided_bills', count(*) filter (where status = 'voided'),
      'voided_value', coalesce(sum(grand_total) filter (where status = 'voided'), 0),
      'unpaid_bills', count(*) filter (where status = 'completed' and payment_status in ('unpaid', 'partial')),
      'unpaid_amount', coalesce(sum(grand_total - app.order_covered(id)) filter (where status = 'completed' and payment_status in ('unpaid', 'partial')), 0))
    into v from public.orders
   where branch_id = d.branch_id and business_date = d.business_date and merged_into is null;

  select coalesce(jsonb_agg(jsonb_build_object('method', name, 'count', n, 'amount', a) order by a desc), '[]'::jsonb)
    into v_pay from (
      select pm.name, count(*) n, sum(p.amount) a from public.payments p
        join public.orders o on o.id = p.order_id join public.payment_methods pm on pm.id = p.payment_method_id
       where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status <> 'voided' and p.status = 'captured'
       group by pm.name) x;
  select coalesce(jsonb_agg(jsonb_build_object('component', c, 'rate', r, 'taxable', tx, 'tax', ta) order by r, c), '[]'::jsonb)
    into v_tax from (
      select t.component_name c, t.rate r, sum(t.taxable_amount) tx, sum(t.tax_amount) ta
        from public.order_item_taxes t join public.orders o on o.id = t.order_id
       where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status = 'completed'
       group by 1, 2) x;
  select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0), 'tax', coalesce(sum(tax_amount), 0),
           'list', coalesce(jsonb_agg(jsonb_build_object('number', number, 'amount', amount, 'bill',
                     (select bill_number from public.orders where id = cn.order_id), 'reason', reason) order by number), '[]'::jsonb))
    into v_cn from public.credit_notes cn where cn.branch_id = d.branch_id and cn.business_date = d.business_date;
  select coalesce(jsonb_agg(app.shift_figures(s.id) order by s.opened_at), '[]'::jsonb) into v_shifts
    from public.shifts s where s.branch_id = d.branch_id
     and exists (select 1 from public.orders o where o.shift_id = s.id and o.business_date = d.business_date
                 union all select 1 from public.payments p join public.orders o on o.id = p.order_id
                  where p.shift_id = s.id and o.business_date = d.business_date);
  select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'bills', n, 'total', t) order by t desc), '[]'::jsonb) into v_types
    from (select order_type, count(*) n, sum(grand_total) t from public.orders
           where branch_id = d.branch_id and business_date = d.business_date and status = 'completed' and merged_into is null
           group by 1) x;

  return v || jsonb_build_object(
    'business_date', d.business_date, 'branch', (select name from public.branches where id = d.branch_id),
    'status', d.status, 'opened_at', d.opened_at, 'closed_at', d.closed_at,
    'closed_by', (select full_name from public.users where id = d.closed_by),
    'payments', v_pay, 'taxes', v_tax, 'credit_notes', v_cn, 'shifts', v_shifts, 'by_type', v_types, 'sessions', (select coalesce(jsonb_agg(jsonb_build_object('session', sn, 'bills', c, 'total', t) order by first_at), '[]'::jsonb) from (select coalesce(o.session_name, 'Other') sn, count(*) c, sum(o.grand_total) t, min(o.created_at) first_at from public.orders o where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status = 'completed' and o.merged_into is null group by 1) ss),
    'net_sales_after_credit_notes', (v->>'total_billed')::numeric - (v_cn->>'amount')::numeric,
    'reopen_count', d.reopen_count);
end $function$;

------------------------------------------------------------------
-- Request ids on add items, split and credit note (M13); split also
-- keeps the kitchen in step (M8)
------------------------------------------------------------------
drop function if exists public.add_order_items(uuid, jsonb);
CREATE OR REPLACE FUNCTION public.add_order_items(p_order_id uuid, p_items jsonb, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid;
  o public.orders%rowtype; v_in jsonb; v_ids uuid[]; v_c jsonb; v_auto boolean; v_before numeric(14,2);
  v_seen record; v_out jsonb;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen
      from public.request_refs rr where rr.restaurant_id = app.current_restaurant_id() and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'add_items' or v_seen.order_id is distinct from p_order_id then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  v_user := app.require_permission('order.create');
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then
    raise exception 'Bill % is already paid. Start a new bill for more items.', o.bill_number;
  end if;
  perform app.auto_shift(o.branch_id); if not exists (select 1 from public.shifts where branch_id = o.branch_id and status = 'open') then
    raise exception 'Open a shift before taking bills.';
  end if;
  v_before := o.grand_total;
  v_in := app.bill_input(o.restaurant_id, o.branch_id, p_items, 0, null, null);
  v_ids := app.insert_order_lines(o.id, o.restaurant_id, v_in->'calc'->'lines');
  v_c := app.recalc_order(o.id);

  select coalesce(bs.auto_print_kot, true) into v_auto from public.branch_settings bs where bs.branch_id = o.branch_id;
  if coalesce(v_auto, true) then perform app.create_kitchen_ticket(o.id, v_ids); end if;

  perform app.audit('order.add_items', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'lines_added', coalesce(array_length(v_ids, 1), 0),
                       'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', v_before));
  v_out := jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number,
    'grand_total', (v_c->>'grand_total')::numeric,
    'balance', (v_c->>'grand_total')::numeric - app.order_covered(o.id));
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result)
    values (app.current_restaurant_id(), p_client_ref, 'add_items', p_order_id, v_out);
    -- Request ids only matter for a retry within minutes; old ones are cleared as new ones arrive.
    delete from public.request_refs
     where restaurant_id = app.current_restaurant_id() and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $function$;
revoke all on function public.add_order_items(uuid, jsonb, uuid) from public, anon;
grant execute on function public.add_order_items(uuid, jsonb, uuid) to authenticated, service_role;

drop function if exists public.split_order(uuid, jsonb);
CREATE OR REPLACE FUNCTION public.split_order(p_order_id uuid, p_items jsonb, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid;
  o public.orders%rowtype; it public.order_items%rowtype; r record; v_shift uuid; v_device uuid; v_bill text;
  v_new uuid := gen_random_uuid(); v_line uuid; v_c1 jsonb; v_c2 jsonb; v_moved int := 0;
  v_seen record; v_out jsonb;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen
      from public.request_refs rr where rr.restaurant_id = app.current_restaurant_id() and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'split' or v_seen.order_id is distinct from p_order_id then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  v_user := app.require_permission('order.create');
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment. Split the payment instead.', o.bill_number;
  end if;
  if coalesce((o.calc_params->>'discount')::numeric, 0) > 0 or nullif(o.senior_details, 'null'::jsonb) is not null
     or exists (select 1 from public.order_discounts where order_id = o.id) then
    raise exception 'Bill % has a discount, so it cannot be split. Split the payment instead.', o.bill_number;
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Choose the items to move to the new bill.';
  end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

  select n.device_id, n.bill_no into v_device, v_bill from app.next_bill_number(o.branch_id) n;
  insert into public.orders
    (id, restaurant_id, branch_id, device_id, bill_number, order_type, dining_table_id, customer_id,
     cashier_id, shift_id, currency_code, status, payment_status, client_created_at, calc_params)
  values
    (v_new, o.restaurant_id, o.branch_id, v_device, v_bill, o.order_type, o.dining_table_id, o.customer_id,
     v_user, v_shift, o.currency_code, 'open', 'unpaid', now(), o.calc_params);

  for r in select (x->>'order_item_id') as oid, sum(coalesce((x->>'qty')::numeric, 0)) as q
             from jsonb_array_elements(p_items) x group by 1 loop
    if coalesce(r.oid, '') !~* '^[0-9a-f-]{36}$' then raise exception 'An item is not on this bill.'; end if;
    select * into it from public.order_items where id = r.oid::uuid and order_id = o.id and cancelled_at is null for update;
    if not found then raise exception 'An item is not on this bill.'; end if;
    if r.q <= 0 then continue; end if;
    if r.q > it.quantity then raise exception 'Only % of % are on the bill.', trim_scale(it.quantity), it.product_name; end if;
    v_moved := v_moved + 1;
    if r.q = it.quantity then
      update public.order_items set order_id = v_new where id = it.id;
      update public.order_item_taxes set order_id = v_new where order_item_id = it.id;
    else
      update public.order_items set quantity = quantity - r.q where id = it.id;
      v_line := gen_random_uuid();
      insert into public.order_items
        (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity, modifier_total,
         line_subtotal, line_discount, line_tax, line_total, is_price_inclusive, kitchen_note,
         net_amount, service_charge, tax_included, tax_comps, options_text, created_at)
      values
        (v_line, it.restaurant_id, v_new, it.product_id, it.product_name, it.unit_price, r.q, it.modifier_total,
         0, 0, 0, 0, it.is_price_inclusive, it.kitchen_note, 0, 0, 0, it.tax_comps, it.options_text, clock_timestamp());
      insert into public.order_item_modifiers (restaurant_id, order_item_id, modifier_item_id, name, price_delta)
      select restaurant_id, v_line, modifier_item_id, name, price_delta from public.order_item_modifiers where order_item_id = it.id;
      -- The kitchen already has this line. Give the moved part its own kitchen
      -- line, so cancelling or voiding one bill never touches the other's food.
      insert into public.kitchen_ticket_items (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note, status, product_name_local)
      select k.restaurant_id, k.kitchen_ticket_id, v_line, k.product_name, r.q, k.note, k.status, k.product_name_local
        from public.kitchen_ticket_items k
       where k.order_item_id = it.id and k.status <> 'cancelled' and k.quantity > r.q
       order by k.id limit 1;
      update public.kitchen_ticket_items set quantity = quantity - r.q
       where id = (select k.id from public.kitchen_ticket_items k
                    where k.order_item_id = it.id and k.status <> 'cancelled' and k.quantity > r.q
                    order by k.id limit 1);
    end if;
  end loop;
  if v_moved = 0 then raise exception 'Choose the items to move to the new bill.'; end if;
  if not exists (select 1 from public.order_items where order_id = o.id and cancelled_at is null) then
    raise exception 'Leave at least one item on bill %.', o.bill_number;
  end if;

  v_c1 := app.recalc_order(o.id);
  v_c2 := app.recalc_order(v_new);
  update public.orders set status = 'completed',
         payment_status = case when (v_c2->>'grand_total')::numeric = 0 then 'paid' else 'unpaid' end
   where id = v_new;

  perform app.audit('order.split', 'orders', v_new,
    jsonb_build_object('bill_number', v_bill, 'split_from', o.bill_number, 'grand_total', (v_c2->>'grand_total')::numeric),
    jsonb_build_object('source_total_before', o.grand_total, 'source_total_after', (v_c1->>'grand_total')::numeric));
  v_out := jsonb_build_object('order_id', v_new, 'bill_number', v_bill, 'grand_total', (v_c2->>'grand_total')::numeric,
                            'source_bill_number', o.bill_number, 'source_grand_total', (v_c1->>'grand_total')::numeric);
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result)
    values (app.current_restaurant_id(), p_client_ref, 'split', p_order_id, v_out);
    -- Request ids only matter for a retry within minutes; old ones are cleared as new ones arrive.
    delete from public.request_refs
     where restaurant_id = app.current_restaurant_id() and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $function$;
revoke all on function public.split_order(uuid, jsonb, uuid) from public, anon;
grant execute on function public.split_order(uuid, jsonb, uuid) to authenticated, service_role;

drop function if exists public.issue_credit_note(uuid, numeric, uuid, text);
CREATE OR REPLACE FUNCTION public.issue_credit_note(p_order_id uuid, p_amount numeric, p_method_id uuid, p_reason text, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid;
  o public.orders%rowtype; v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_done numeric(14,2); v_left numeric(14,2); v_country text; v_day public.business_days; v_shift uuid;
  v_kind text; v_ratio numeric; v_tax numeric(14,2); v_taxes jsonb; v_no text; v_seq int; v_fy text; v_code text;
  v_id uuid := gen_random_uuid(); v_deadline date;
  v_seen record; v_out jsonb;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen
      from public.request_refs rr where rr.restaurant_id = app.current_restaurant_id() and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'credit_note' or v_seen.order_id is distinct from p_order_id then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  v_user := app.require_permission('order.refund');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for the credit note.'; end if;
  if v_amount <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status <> 'completed' or o.merged_into is not null then raise exception 'Only a completed bill can get a credit note.'; end if;
  if o.payment_status in ('unpaid', 'partial') then
    raise exception 'Bill % is not fully paid. Cancel items or void it instead.', o.bill_number;
  end if;
  select coalesce(sum(amount), 0) into v_done from public.refunds where order_id = o.id;
  v_left := o.paid_total - v_done;
  if v_left <= 0 then raise exception 'Bill % has already been fully refunded.', o.bill_number; end if;
  if v_amount > v_left then raise exception 'The most that can be refunded on bill % is %.', o.bill_number, v_left; end if;

  select country_code into v_country from public.restaurants where id = o.restaurant_id;
  v_day := app.open_business_day(o.branch_id);
  if v_country = 'IN' then
    v_deadline := make_date(case when extract(month from o.business_date) >= 4 then extract(year from o.business_date)::int + 1
                                 else extract(year from o.business_date)::int end, 11, 30);
    if v_day.business_date > v_deadline then
      raise exception 'Under GST rules a credit note for bill % could only be issued until %.', o.bill_number, to_char(v_deadline, 'DD Mon YYYY');
    end if;
  end if;

  select pm.kind into v_kind from public.payment_methods pm where pm.id = p_method_id and pm.restaurant_id = o.restaurant_id and pm.is_active;
  if not found then raise exception 'Choose how the money is given back.'; end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_kind = 'cash' and v_shift is null then raise exception 'Open a shift before giving cash back.'; end if;

  v_ratio := case when o.grand_total > 0 then v_amount / o.grand_total else 0 end;
  select coalesce(jsonb_agg(jsonb_build_object('name', c, 'rate', r, 'amount', round(a * v_ratio, 2)) order by r, c), '[]'::jsonb),
         coalesce(sum(round(a * v_ratio, 2)), 0)
    into v_taxes, v_tax
    from (select component_name c, rate r, sum(tax_amount) a from public.order_item_taxes where order_id = o.id group by 1, 2) x;

  perform pg_advisory_xact_lock(hashtext('credit_note:' || o.branch_id::text));
  v_fy := app.fy_label(v_country, v_day.business_date);
  if v_country = 'IN' then v_fy := substr(v_fy, 3, 2) || substr(v_fy, 6, 2); end if;  -- 2026-27 -> 2627 (GST: max 16 characters)
  select code into v_code from public.branches where id = o.branch_id;
  select count(*) + 1 into v_seq from public.credit_notes
   where branch_id = o.branch_id and number like 'CN-' || v_code || '-' || v_fy || '-%';
  v_no := 'CN-' || v_code || '-' || v_fy || '-' || lpad(v_seq::text, 4, '0');

  insert into public.credit_notes (id, restaurant_id, branch_id, order_id, number, business_date, shift_id, amount,
                                   tax_amount, taxes, reason, payment_method_id, created_by)
  values (v_id, o.restaurant_id, o.branch_id, o.id, v_no, v_day.business_date, v_shift, v_amount, v_tax, v_taxes,
          left(trim(p_reason), 300), p_method_id, v_user);
  insert into public.refunds (id, restaurant_id, order_id, payment_id, amount, reason, approved_by, client_created_at,
                              shift_id, payment_method_id, credit_note_id)
  values (gen_random_uuid(), o.restaurant_id, o.id, null, v_amount, left(trim(p_reason), 300), v_user, now(),
          v_shift, p_method_id, v_id);

  perform set_config('app.day_ok', 'on', true);
  update public.orders set payment_status = case when v_done + v_amount >= o.paid_total then 'refunded' else 'partially_refunded' end
   where id = o.id;
  perform set_config('app.day_ok', 'off', true);

  perform app.audit('credit_note.issue', 'credit_notes', v_id,
    jsonb_build_object('number', v_no, 'bill_number', o.bill_number, 'amount', v_amount, 'tax', v_tax,
                       'method_kind', v_kind, 'reason', left(trim(p_reason), 300)));
  v_out := jsonb_build_object('credit_note_id', v_id, 'number', v_no, 'amount', v_amount, 'tax', v_tax,
                            'remaining', v_left - v_amount);
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result)
    values (app.current_restaurant_id(), p_client_ref, 'credit_note', p_order_id, v_out);
    -- Request ids only matter for a retry within minutes; old ones are cleared as new ones arrive.
    delete from public.request_refs
     where restaurant_id = app.current_restaurant_id() and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $function$;
revoke all on function public.issue_credit_note(uuid, numeric, uuid, text, uuid) from public, anon;
grant execute on function public.issue_credit_note(uuid, numeric, uuid, text, uuid) to authenticated, service_role;
