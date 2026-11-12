-- Split a bill that has a bill-level discount (Winsar allows it). The discount amount is shared between the two bills in proportion to the
-- value of the items each one holds. Still blocked: no-charge bills, senior/PWD bills and bills with item/category discounts.
do $mig$
declare
  d text := pg_get_functiondef('public.split_order(uuid,jsonb,uuid)'::regprocedure);
  d2 text;
begin
  d2 := regexp_replace(d, 'coalesce\(\(o\.calc_params->>''discount''\)::numeric, 0\) > 0 or nullif\(', 'o.comp_kind is not null or nullif(');
  if d2 = d then raise exception 'split_order guard not found'; end if;
  d := d2;
  d2 := regexp_replace(d, 'v_seen record; v_out jsonb;', 'v_seen record; v_out jsonb; v_disc numeric; v_g1 numeric; v_g2 numeric; v_d2 numeric;');
  if d2 = d then raise exception 'split_order declare not found'; end if;
  d := d2;
  d2 := regexp_replace(d, 'v_c1 := app\.recalc_order\(o\.id\);', $r$v_disc := coalesce((o.calc_params->>'discount')::numeric, 0);
  if v_disc > 0 then
    select coalesce(sum((unit_price + coalesce(modifier_total, 0)) * quantity), 0) into v_g1 from public.order_items where order_id = o.id and cancelled_at is null;
    select coalesce(sum((unit_price + coalesce(modifier_total, 0)) * quantity), 0) into v_g2 from public.order_items where order_id = v_new and cancelled_at is null;
    if v_g1 + v_g2 > 0 then
      v_d2 := round(v_disc * v_g2 / (v_g1 + v_g2), 2);
      update public.orders set calc_params = jsonb_set(coalesce(calc_params, '{}'::jsonb), '{discount}', to_jsonb(v_disc - v_d2)) where id = o.id;
      update public.orders set calc_params = jsonb_set(coalesce(calc_params, '{}'::jsonb), '{discount}', to_jsonb(v_d2)) where id = v_new;
    end if;
  end if;
  v_c1 := app.recalc_order(o.id);$r$);
  if d2 = d then raise exception 'split_order recalc not found'; end if;
  execute d2;
end
$mig$;
