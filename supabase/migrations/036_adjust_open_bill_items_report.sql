-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928090242, name '36_adjust_open_bill_items_report'. This is the SQL that actually ran.

-- Discount and service charge on an open (unpaid) bill.
create or replace function public.adjust_order(p_order_id uuid, p_discount_amount numeric, p_discount_reason text default null, p_service_charge boolean default null)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; p jsonb; bs record;
  v_old_disc numeric(14,2); v_new_disc numeric(14,2) := round(coalesce(p_discount_amount, 0), 2);
  v_old_sc boolean; v_new_sc boolean; v_c jsonb; v_before numeric(14,2);
begin
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
  if v_new_disc > v_old_disc and not app.has_permission('order.discount') then
    raise exception 'A manager must approve a discount.';
  end if;
  if v_old_sc and not v_new_sc and not app.has_permission('order.discount') then
    raise exception 'A manager must approve removing the service charge.';
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

  delete from public.order_discounts where order_id = o.id and discount_type = 'fixed_amount';
  if (v_c->>'discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (o.restaurant_id, o.id, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric,
            nullif(left(trim(coalesce(p_discount_reason, '')), 200), ''), v_user);
  end if;

  perform app.audit('order.adjust', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'discount', (v_c->>'discount')::numeric,
                       'service_charge_on', v_new_sc, 'grand_total', (v_c->>'grand_total')::numeric,
                       'reason', nullif(trim(coalesce(p_discount_reason, '')), '')),
    jsonb_build_object('discount', v_old_disc, 'service_charge_on', v_old_sc, 'grand_total', v_before));
  return jsonb_build_object('order_id', o.id, 'grand_total', (v_c->>'grand_total')::numeric, 'changed', true);
end $$;
revoke all on function public.adjust_order(uuid,numeric,text,boolean) from public, anon;
grant execute on function public.adjust_order(uuid,numeric,text,boolean) to authenticated;

-- Items report: every item, not just the top 50.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.sales_report(date,date)'::regprocedure);
  if position('order by 3 desc limit 50' in d) = 0 then raise exception 'sales_report changed; patch by hand'; end if;
  d := replace(d, 'order by 3 desc limit 50', 'order by 3 desc limit 5000');
  execute d;
end $$;
