-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928090408, name '37_discount_cannot_exceed_bill'. This is the SQL that actually ran.

do $$
declare d text;
begin
  d := pg_get_functiondef('public.adjust_order(uuid,numeric,text,boolean)'::regprocedure);
  d := replace(d, E'v_c := app.recalc_order(o.id);\n',
    E'v_c := app.recalc_order(o.id);\n  if (v_c->>''discount'')::numeric < v_new_disc then\n    raise exception ''The discount (%) is more than the bill (%).'', v_new_disc, (v_c->>''subtotal'')::numeric;\n  end if;\n');
  if position('is more than the bill' in d) = 0 then raise exception 'patch adjust_order failed'; end if;
  execute d;

  d := pg_get_functiondef('public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb,text)'::regprocedure);
  d := replace(d, E'v_c := app.recalc_order(v_order_id);\n',
    E'v_c := app.recalc_order(v_order_id);\n  if (v_c->>''discount'')::numeric < round(coalesce(p_discount_amount, 0), 2) then\n    raise exception ''The discount (%) is more than the bill (%).'', round(p_discount_amount, 2), (v_c->>''subtotal'')::numeric;\n  end if;\n');
  if position('is more than the bill' in d) = 0 then raise exception 'patch create_order failed'; end if;
  execute d;
end $$;
