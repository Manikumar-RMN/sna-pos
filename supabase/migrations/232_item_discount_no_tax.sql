-- 232: item discount, category discount, and "No Tax" on a bill (Winsar parity, Stage 3).
--
-- What changes:
--   * order_items gets disc_kind / disc_value / disc_reason / disc_by (a per-line discount, percent or amount).
--   * app.calc_bill takes an optional per-line key "line_disc". With no line_disc anywhere the result is
--     identical to before (the bill-level discount is spread over value left AFTER line discounts).
--   * app.recalc_order reads the line discounts and the bill flag calc_params.no_tax.
--   * public.set_item_discount, public.set_category_discount, public.set_bill_no_tax (manager right order.discount).
--   * public.adjust_order is re-issued so the bill-level discount shown/stored excludes line discounts.
--   * branch_settings.allow_no_tax (default false): "No Tax" only works where the owner switched it on.
--
-- Rollback: see 232_item_discount_no_tax_rollback.sql.

alter table public.order_items
  add column if not exists disc_kind text,
  add column if not exists disc_value numeric(14,2) not null default 0,
  add column if not exists disc_reason text,
  add column if not exists disc_by uuid references public.users(id) on delete set null;
do $$ begin
  alter table public.order_items add constraint order_items_disc_kind_chk check (disc_kind is null or disc_kind in ('percent','amount'));
exception when duplicate_object then null; end $$;

alter table public.branch_settings add column if not exists allow_no_tax boolean not null default false;

-- ---------------------------------------------------------------- calc_bill (line_disc added)
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
  v_loy_in  numeric := round(coalesce((p->>'loyalty_discount')::numeric, 0), 2);
  v_sc_pct  numeric := coalesce((p->>'sc_percent')::numeric, 0);
  v_sc_tax  boolean := coalesce((p->>'sc_taxable')::boolean, false);
  v_share   numeric := coalesce((p->'senior'->>'share')::numeric, 0);
  v_s_pct   numeric := coalesce((p->'senior'->>'rate')::numeric, 20);
  v_round   text    := coalesce(p->>'rounding', 'none');

  subs numeric[] := '{}';
  vals numeric[] := '{}';
  lds  numeric[] := '{}';
  discs numeric[] := '{}';
  v_subtotal numeric := 0;
  v_big int := 0;
  v_alloc numeric := 0;
  v_discount numeric;
  v_pool numeric := 0; v_manual numeric := 0; v_loy numeric := 0; v_nd boolean; v_any_nd boolean := false; elig boolean[] := '{}';
  v_ld numeric; t_ld numeric := 0;

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
  v_dc numeric; v_tc numeric; v_left int; v_best int; v_net_old numeric; v_net_adj numeric := 0;
  bases numeric[] := '{}'; rems numeric[] := '{}'; taken boolean[] := '{}';
begin
  if v_disc_in < 0 then raise exception 'A discount cannot be negative.'; end if;
  if v_loy_in < 0 then raise exception 'A points discount cannot be negative.'; end if;
  if v_share < 0 or v_share > 1 then raise exception 'The senior citizen / PWD share must be between 0 and 100%%.'; end if;
  if v_share > 0 and v_disc_in > 0 then
    raise exception 'A senior citizen / PWD discount cannot be combined with another discount.';
  end if;
  if v_share > 0 and v_loy_in > 0 then
    raise exception 'A senior citizen / PWD discount cannot be combined with loyalty points.';
  end if;
  if v_sc_pct < 0 or v_sc_pct > 100 then raise exception 'The service charge must be between 0 and 100%%.'; end if;

  -- Pass 1: line subtotals at menu price; 232: a line's own discount comes off first (never more than the line).
  for i in 0 .. n - 1 loop
    ln := v_lines -> i;
    v_sub := round((ln->>'price')::numeric * (ln->>'qty')::numeric, 2);
    if v_sub < 0 then raise exception 'A line cannot be negative.'; end if;
    subs := subs || v_sub;
    v_subtotal := v_subtotal + v_sub;
    v_ld := least(greatest(round(coalesce((ln->>'line_disc')::numeric, 0), 2), 0), v_sub);
    if v_ld > 0 and v_share > 0 then
      raise exception 'A senior citizen / PWD discount cannot be combined with an item discount.';
    end if;
    lds := lds || v_ld; t_ld := t_ld + v_ld;
    vals := vals || (v_sub - v_ld);
    -- 141: a line with no_disc takes no share of the bill discount; the pool is what the discount can come out of.
    v_nd := coalesce((ln->>'no_disc')::boolean, false);
    elig := elig || (not v_nd);
    if v_nd then v_any_nd := true; end if;
    if not v_nd then
      v_pool := v_pool + (v_sub - v_ld);
      if v_big = 0 or (v_sub - v_ld) > vals[v_big] then v_big := i + 1; end if;
    end if;
  end loop;

  -- Pass 2: spread the bill discount by value (after line discounts); the largest line takes the
  -- rounding remainder so the parts always add up exactly.
  v_manual   := least(v_disc_in, v_pool);
  v_loy      := least(v_loy_in, v_pool - v_manual);
  v_discount := v_manual + v_loy;
  for i in 1 .. n loop
    if not elig[i] or i = v_big or v_pool = 0 then
      discs := discs || 0::numeric;
    else
      v_disc := round(v_discount * vals[i] / v_pool, 2);
      discs := discs || v_disc;
      v_alloc := v_alloc + v_disc;
    end if;
  end loop;
  if v_big > 0 then discs[v_big] := v_discount - v_alloc; end if;

  if v_big > 0 and v_pool > 0 and (discs[v_big] < 0 or discs[v_big] > vals[v_big]) then
    v_dc := v_discount * 100; v_tc := v_pool * 100; v_alloc := 0;
    for i in 1 .. n loop
      bases[i] := case when elig[i] then div(v_dc * (vals[i] * 100), v_tc) else 0 end;
      rems[i]  := case when elig[i] then mod(v_dc * (vals[i] * 100), v_tc) else 0 end;
      taken[i] := not elig[i];
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

  -- 232: put each line's own discount back on top of its share of the bill discount.
  for i in 1 .. n loop discs[i] := discs[i] + lds[i]; end loop;

  -- Pass 3: each line.
  for i in 0 .. n - 1 loop
    ln    := v_lines -> i;
    comps := coalesce(ln->'comps', '[]'::jsonb);
    v_incl := coalesce((ln->>'inclusive')::boolean, false);
    v_sub  := subs[i + 1];
    v_disc := discs[i + 1];

    v_f := 0;
    for k in 0 .. jsonb_array_length(comps) - 1 loop
      c := comps -> k;
      v_rate := coalesce((c->>'rate')::numeric, 0);
      v_cmp  := coalesce((c->>'compound')::boolean, false);
      v_f := v_f + v_rate / 100 * (1 + case when v_cmp then v_f else 0 end);
    end loop;

    v_s_gross   := round(v_sub * v_share, 2);
    v_s_net     := case when v_incl then round(v_s_gross / (1 + v_f), 2) else v_s_gross end;
    v_s_removed := v_s_gross - v_s_net;
    v_s_disc    := round(v_s_net * v_s_pct / 100, 2);

    v_r_amt := v_sub - v_s_gross - v_disc;
    v_net   := case when v_incl then round(v_r_amt / (1 + v_f), 2) else v_r_amt end;

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
    v_net_adj := 0;
    if v_incl then v_net_old := v_net; v_net := v_r_amt - v_pi; v_net_adj := v_net - v_net_old; end if;

    v_sc := round((v_net + v_s_net) * v_sc_pct / 100, 2);

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
        'taxable', bi[k + 1] + v_net_adj + v_bs, 'amount', ai[k + 1] + v_as);
      v_key := (c->>'name') || '|' || v_rate::text;
      v_taxmap := jsonb_set(v_taxmap, array[v_key], jsonb_build_object(
        'name', c->>'name', 'rate', v_rate,
        'taxable', coalesce((v_taxmap->v_key->>'taxable')::numeric, 0) + bi[k + 1] + v_net_adj + v_bs,
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

  if v_before <> t_lines then
    raise exception 'Internal check failed: bill total % does not equal line total %.', v_before, t_lines;
  end if;

  v_grand := app.round_cash(v_before, v_round);

  select coalesce(jsonb_agg(value order by (value->>'rate')::numeric, value->>'name'), '[]'::jsonb)
    into v_taxes from jsonb_each(v_taxmap);

  return jsonb_build_object(
    'lines', o_lines,
    'subtotal', v_subtotal, 'discount', t_disc - v_loy, 'senior_discount', t_sdisc,
    'tax_exempt_amount', t_removed, 'exempt_sales', t_exempt,
    'service_charge', t_sc, 'tax_total', t_tax, 'tax_included', t_incl,
    'net_sales', t_net, 'before_round', v_before,
    'rounding', v_grand - v_before, 'grand_total', v_grand,
    'taxes', v_taxes)
    || case when v_any_nd then jsonb_build_object('discountable_subtotal', v_pool) else '{}'::jsonb end
    || case when v_loy_in > 0 then jsonb_build_object('loyalty_discount', v_loy) else '{}'::jsonb end
    -- 232: appears only when an item discount is in play, so every ordinary bill's result is byte-identical to before
    || case when t_ld > 0 then jsonb_build_object('line_discount', t_ld) else '{}'::jsonb end;
end $function$;

-- ---------------------------------------------------------------- recalc_order (line discounts, no_tax)
CREATE OR REPLACE FUNCTION app.recalc_order(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  o public.orders%rowtype; p jsonb; r record; i int := 0; v_lines jsonb := '[]'::jsonb; v_map jsonb := '{}'::jsonb;
  v_c jsonb; l jsonb; t jsonb; v_id uuid; v_comps jsonb; v_comp_all boolean;
  v_no_tax boolean; v_ld numeric; v_price numeric; v_f numeric; k int; cc jsonb; v_sub numeric;
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Bill not found.'; end if;
  p := coalesce(o.calc_params, '{}'::jsonb);
  v_comp_all := coalesce((p->>'comp_all')::boolean, false);
  v_no_tax := coalesce((p->>'no_tax')::boolean, false);

  for r in select id, unit_price, quantity, is_price_inclusive, tax_comps, discount_blocked, disc_kind, disc_value
             from public.order_items where order_id = p_order and cancelled_at is null
            order by created_at, id loop
    i := i + 1;
    v_comps := coalesce(r.tax_comps,
      (select jsonb_agg(jsonb_build_object('name', component_name, 'rate', rate, 'compound', false) order by id)
         from public.order_item_taxes where order_item_id = r.id), '[]'::jsonb);

    v_price := r.unit_price;
    if v_no_tax then
      -- 232: tax taken off the bill. A tax-inclusive menu price drops to its net price; tax-exclusive prices stay.
      if coalesce(r.is_price_inclusive, false) then
        v_f := 0;
        for k in 0 .. jsonb_array_length(v_comps) - 1 loop
          cc := v_comps -> k;
          v_f := v_f + coalesce((cc->>'rate')::numeric, 0) / 100
                       * (1 + case when coalesce((cc->>'compound')::boolean, false) then v_f else 0 end);
        end loop;
        v_price := r.unit_price / (1 + v_f);
      end if;
    end if;

    v_lines := v_lines || (jsonb_build_object('key', i, 'price', v_price, 'qty', r.quantity,
                 'inclusive', case when v_no_tax then false else coalesce(r.is_price_inclusive, false) end,
                 'comps', case when v_no_tax then '[]'::jsonb else v_comps end)
                 || case when coalesce(r.discount_blocked, false) and not v_comp_all then jsonb_build_object('no_disc', true) else '{}'::jsonb end);

    -- 232: the line's own discount (not on a line that cannot be discounted, and not on a complimentary bill)
    if r.disc_kind is not null and r.disc_value > 0 and not v_comp_all and not coalesce(r.discount_blocked, false) then
      v_sub := round(v_price * r.quantity, 2);
      v_ld := case when r.disc_kind = 'percent' then round(v_sub * least(r.disc_value, 100) / 100, 2)
                   else least(r.disc_value, v_sub) end;
      if v_ld > 0 then
        v_lines := jsonb_set(v_lines, array[(i - 1)::text, 'line_disc'], to_jsonb(v_ld));
      end if;
    end if;

    v_map := v_map || jsonb_build_object(i::text, jsonb_build_object('id', r.id, 'comps', v_comps));
  end loop;
  if i = 0 then raise exception 'Bill % has no items left. Void it instead.', o.bill_number; end if;

  v_c := app.calc_bill(jsonb_build_object(
    'lines', v_lines, 'discount', coalesce((p->>'discount')::numeric, 0), 'loyalty_discount', coalesce((p->>'loyalty_discount')::numeric, 0),
    'sc_percent', coalesce((p->>'sc_percent')::numeric, 0), 'sc_taxable', coalesce((p->>'sc_taxable')::boolean, false) and not v_no_tax,
    'senior', case when p->'senior' is null or p->'senior' = 'null'::jsonb then null else p->'senior' end,
    'rounding', coalesce(p->>'rounding', 'none')));

  perform set_config('app.recalc', 'on', true);

  for l in select * from jsonb_array_elements(v_c->'lines') loop
    v_id := (v_map->(l->>'key')->>'id')::uuid;
    update public.order_items set
        line_subtotal = (l->>'subtotal')::numeric,
        line_discount = (l->>'discount')::numeric + (l->>'senior_discount')::numeric,
        line_tax = (l->>'tax')::numeric, line_total = (l->>'total')::numeric,
        net_amount = (l->>'net')::numeric, service_charge = (l->>'service_charge')::numeric,
        tax_included = (l->>'tax_included')::numeric, tax_comps = v_map->(l->>'key')->'comps'
     where id = v_id;
    delete from public.order_item_taxes where order_item_id = v_id;
    for t in select * from jsonb_array_elements(l->'taxes') loop
      insert into public.order_item_taxes (restaurant_id, order_id, order_item_id, component_name, rate, taxable_amount, tax_amount)
      values (o.restaurant_id, o.id, v_id, t->>'name', (t->>'rate')::numeric, (t->>'taxable')::numeric, (t->>'amount')::numeric);
    end loop;
  end loop;

  update public.order_items set line_subtotal = 0, line_discount = 0, line_tax = 0, line_total = 0,
         net_amount = 0, service_charge = 0, tax_included = 0
   where order_id = p_order and cancelled_at is not null and (line_total <> 0 or line_subtotal <> 0);
  delete from public.order_item_taxes
   where order_item_id in (select id from public.order_items where order_id = p_order and cancelled_at is not null);

  -- 232: the bill-level discount row holds only the bill-level part (item discounts live on the lines)
  update public.order_discounts set
         amount = (v_c->>'discount')::numeric - coalesce((v_c->>'line_discount')::numeric, 0),
         value  = (v_c->>'discount')::numeric - coalesce((v_c->>'line_discount')::numeric, 0)
   where order_id = p_order and discount_type = 'fixed_amount';
  update public.order_discounts set amount = (v_c->>'senior_discount')::numeric
   where order_id = p_order and discount_type = 'senior_pwd';
  update public.order_discounts set amount = coalesce((v_c->>'loyalty_discount')::numeric, 0)
   where order_id = p_order and discount_type = 'loyalty_points';

  update public.orders set
      subtotal = (v_c->>'subtotal')::numeric,
      discount_total = (v_c->>'discount')::numeric + coalesce((v_c->>'loyalty_discount')::numeric, 0) + (v_c->>'senior_discount')::numeric,
      tax_total = (v_c->>'tax_total')::numeric,
      tax_included = (v_c->>'tax_included')::numeric,
      tax_exempt_amount = (v_c->>'tax_exempt_amount')::numeric,
      exempt_sales = (v_c->>'exempt_sales')::numeric,
      service_charge = (v_c->>'service_charge')::numeric,
      rounding_adjustment = (v_c->>'rounding')::numeric,
      grand_total = (v_c->>'grand_total')::numeric
   where id = p_order;

  if coalesce((p->>'loyalty_points')::numeric, 0) > 0
     and coalesce((v_c->>'loyalty_discount')::numeric, 0) < coalesce((p->>'loyalty_discount')::numeric, 0) then
    perform app.loyalty_trim(p_order, coalesce((v_c->>'loyalty_discount')::numeric, 0));
  end if;

  perform set_config('app.recalc', 'off', true);
  return v_c;
end $function$;

-- ---------------------------------------------------------------- adjust_order (bill-level part only)
CREATE OR REPLACE FUNCTION public.adjust_order(p_order_id uuid, p_discount_amount numeric, p_discount_reason text DEFAULT NULL::text, p_service_charge boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; p jsonb; bs record;
  v_old_disc numeric(14,2); v_new_disc numeric(14,2) := round(coalesce(p_discount_amount, 0), 2);
  v_old_sc boolean; v_new_sc boolean; v_c jsonb; v_before numeric(14,2); v_loy numeric(14,2); v_pool numeric(14,2);
  v_bill_part numeric(14,2);
begin
  perform app.require_feature('pos');
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment, so its discount or service charge cannot be changed.', o.bill_number;
  end if;
  if v_new_disc < 0 then raise exception 'A discount cannot be negative.'; end if;

  p := coalesce(o.calc_params, '{}'::jsonb);
  v_old_disc := coalesce((p->>'discount')::numeric, 0);
  v_old_sc := coalesce((p->>'sc_percent')::numeric, 0) > 0;

  select coalesce(s.service_charge_percent, 0) as pct, coalesce(s.service_charge_taxable, false) as taxable
    into bs from public.branch_settings s where s.branch_id = o.branch_id;
  v_new_sc := coalesce(p_service_charge, v_old_sc) and coalesce(bs.pct, 0) > 0;

  if v_new_disc > 0 and p->'senior' is not null and p->'senior' <> 'null'::jsonb then
    raise exception 'This bill has a senior citizen / PWD discount; another discount cannot be added.';
  end if;
  if v_new_disc > v_old_disc and not app.allowed('order.discount') then
    raise exception 'A manager must approve a discount (order.discount).';
  end if;
  if v_old_sc and not v_new_sc and not app.allowed('order.discount') then
    raise exception 'A manager must approve removing the service charge (order.discount).';
  end if;
  if v_new_disc = v_old_disc and v_new_sc = v_old_sc then
    return jsonb_build_object('order_id', o.id, 'grand_total', o.grand_total, 'changed', false);
  end if;

  v_before := o.grand_total;
  perform set_config('app.recalc', 'on', true);
  update public.orders set calc_params = p
      || jsonb_build_object('discount', v_new_disc,
                            'sc_percent', case when v_new_sc then bs.pct else 0 end,
                            'sc_taxable', coalesce(bs.taxable, false))
   where id = o.id;
  v_c := app.recalc_order(o.id);
  v_bill_part := (v_c->>'discount')::numeric - coalesce((v_c->>'line_discount')::numeric, 0);
  if v_bill_part < v_new_disc then
    v_pool := coalesce((v_c->>'discountable_subtotal')::numeric, (v_c->>'subtotal')::numeric);
    v_loy  := coalesce((p->>'loyalty_discount')::numeric, 0);
    if v_pool < (v_c->>'subtotal')::numeric then
      raise exception 'The discount can be at most % (some items on this bill cannot be discounted).', greatest(v_pool - v_loy, 0);
    elsif v_loy > 0 then
      raise exception 'The discount can be at most % (loyalty points already pay % of this bill).', greatest(v_pool - v_loy, 0), v_loy;
    end if;
    raise exception 'The discount (%) is more than the bill (%).', v_new_disc, (v_c->>'subtotal')::numeric;
  end if;

  delete from public.order_discounts where order_id = o.id and discount_type = 'fixed_amount';
  if v_bill_part > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (o.restaurant_id, o.id, 'fixed_amount', v_bill_part, v_bill_part,
            nullif(left(trim(coalesce(p_discount_reason, '')), 200), ''), v_user);
  end if;

  perform app.audit('order.adjust', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'discount', v_bill_part,
                       'service_charge_on', v_new_sc, 'grand_total', (v_c->>'grand_total')::numeric,
                       'reason', nullif(trim(coalesce(p_discount_reason, '')), '')),
    jsonb_build_object('discount', v_old_disc, 'service_charge_on', v_old_sc, 'grand_total', v_before));
  return jsonb_build_object('order_id', o.id, 'grand_total', (v_c->>'grand_total')::numeric, 'changed', true);
end $function$;

-- ---------------------------------------------------------------- shared guard
create or replace function app.discount_guard(p_order_id uuid, p_reason text)
returns public.orders
language plpgsql security definer set search_path to 'public','pg_temp'
as $$
declare o public.orders%rowtype; p jsonb;
begin
  perform app.require_permission('order.create');
  if not app.allowed('order.discount') then raise exception 'A manager must approve this (order.discount).'; end if;
  perform app.require_feature('pos');
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment, so it cannot be changed.', o.bill_number;
  end if;
  p := coalesce(o.calc_params, '{}'::jsonb);
  if p->'senior' is not null and p->'senior' <> 'null'::jsonb then
    raise exception 'This bill has a senior citizen / PWD discount; an item discount cannot be added.';
  end if;
  if coalesce((p->>'comp_all')::boolean, false) then
    raise exception 'This bill is complimentary; it takes no other discount.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason.'; end if;
  return o;
end $$;

-- ---------------------------------------------------------------- item discount
create or replace function public.set_item_discount(p_order_id uuid, p_item_id uuid, p_kind text, p_value numeric, p_reason text)
returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp'
as $$
declare
  o public.orders%rowtype; it public.order_items%rowtype; v_user uuid; v_c jsonb; v_before numeric(14,2);
  v_kind text := lower(coalesce(p_kind, 'none')); v_val numeric(14,2) := round(coalesce(p_value, 0), 2);
begin
  if v_kind = 'none' or v_val = 0 then v_kind := 'none'; v_val := 0; end if;
  if v_kind not in ('none','percent','amount') then raise exception 'Choose percent or amount.'; end if;
  if v_val < 0 then raise exception 'A discount cannot be negative.'; end if;
  if v_kind = 'percent' and v_val > 100 then raise exception 'A percentage discount cannot be more than 100.'; end if;
  o := app.discount_guard(p_order_id, p_reason);
  v_user := auth.uid();
  select * into it from public.order_items where id = p_item_id and order_id = o.id and cancelled_at is null for update;
  if not found then raise exception 'That item is not on this bill.'; end if;
  if it.discount_blocked and v_kind <> 'none' then raise exception '% cannot be discounted.', it.product_name; end if;
  if v_kind = 'amount' and v_val > round(it.unit_price * it.quantity, 2) then
    raise exception 'The discount is more than the item (%).', round(it.unit_price * it.quantity, 2);
  end if;

  v_before := o.grand_total;
  perform set_config('app.recalc', 'on', true);
  update public.order_items set
         disc_kind = case when v_kind = 'none' then null else v_kind end,
         disc_value = v_val,
         disc_reason = case when v_kind = 'none' then null else left(trim(p_reason), 200) end,
         disc_by = case when v_kind = 'none' then null else v_user end
   where id = it.id;
  v_c := app.recalc_order(o.id);

  perform app.audit('order.item_discount', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'item', it.product_name, 'kind', v_kind, 'value', v_val,
                       'reason', trim(p_reason), 'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('kind', it.disc_kind, 'value', it.disc_value, 'grand_total', v_before));
  return jsonb_build_object('order_id', o.id, 'grand_total', (v_c->>'grand_total')::numeric);
end $$;

-- ---------------------------------------------------------------- category discount (percent on every item of a category)
create or replace function public.set_category_discount(p_order_id uuid, p_category_id uuid, p_percent numeric, p_reason text)
returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp'
as $$
declare
  o public.orders%rowtype; v_user uuid; v_c jsonb; v_before numeric(14,2); v_pct numeric(14,2) := round(coalesce(p_percent, 0), 2);
  v_n int; v_cat text;
begin
  if v_pct < 0 or v_pct > 100 then raise exception 'The percentage must be between 0 and 100.'; end if;
  o := app.discount_guard(p_order_id, p_reason);
  v_user := auth.uid();
  select name into v_cat from public.categories where id = p_category_id and restaurant_id = o.restaurant_id;
  if not found then raise exception 'Category not found.'; end if;
  v_before := o.grand_total;
  perform set_config('app.recalc', 'on', true);
  update public.order_items i set
         disc_kind = case when v_pct = 0 then null else 'percent' end,
         disc_value = v_pct,
         disc_reason = case when v_pct = 0 then null else left(trim(p_reason), 200) end,
         disc_by = case when v_pct = 0 then null else v_user end
   where i.order_id = o.id and i.cancelled_at is null and not i.discount_blocked
     and i.product_id in (select id from public.products where category_id = p_category_id);
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'No item of % on this bill can be discounted.', v_cat; end if;
  v_c := app.recalc_order(o.id);
  perform app.audit('order.category_discount', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'category', v_cat, 'percent', v_pct, 'items', v_n,
                       'reason', trim(p_reason), 'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', v_before));
  return jsonb_build_object('order_id', o.id, 'grand_total', (v_c->>'grand_total')::numeric, 'items', v_n);
end $$;

-- ---------------------------------------------------------------- No Tax on a bill
create or replace function public.set_bill_no_tax(p_order_id uuid, p_on boolean, p_reason text)
returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp'
as $$
declare
  o public.orders%rowtype; p jsonb; v_c jsonb; v_before numeric(14,2); v_allow boolean;
begin
  o := app.discount_guard(p_order_id, p_reason);
  select coalesce(allow_no_tax, false) into v_allow from public.branch_settings where branch_id = o.branch_id;
  if coalesce(p_on, false) and not coalesce(v_allow, false) then
    raise exception 'Taking tax off a bill is switched off for this outlet. The owner can allow it in settings.';
  end if;
  p := coalesce(o.calc_params, '{}'::jsonb);
  if coalesce((p->>'no_tax')::boolean, false) = coalesce(p_on, false) then
    return jsonb_build_object('order_id', o.id, 'grand_total', o.grand_total, 'changed', false);
  end if;
  v_before := o.grand_total;
  perform set_config('app.recalc', 'on', true);
  update public.orders set calc_params = p || jsonb_build_object('no_tax', coalesce(p_on, false),
         'no_tax_reason', case when coalesce(p_on, false) then left(trim(p_reason), 200) else null end)
   where id = o.id;
  v_c := app.recalc_order(o.id);
  perform app.audit('order.no_tax', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'no_tax', coalesce(p_on, false), 'reason', trim(p_reason),
                       'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', v_before));
  return jsonb_build_object('order_id', o.id, 'grand_total', (v_c->>'grand_total')::numeric, 'changed', true);
end $$;

revoke all on function public.set_item_discount(uuid,uuid,text,numeric,text) from public, anon;
revoke all on function public.set_category_discount(uuid,uuid,numeric,text) from public, anon;
revoke all on function public.set_bill_no_tax(uuid,boolean,text) from public, anon;
revoke all on function app.discount_guard(uuid,text) from public, anon, authenticated;
grant execute on function public.set_item_discount(uuid,uuid,text,numeric,text) to authenticated;
grant execute on function public.set_category_discount(uuid,uuid,numeric,text) to authenticated;
grant execute on function public.set_bill_no_tax(uuid,boolean,text) to authenticated;
