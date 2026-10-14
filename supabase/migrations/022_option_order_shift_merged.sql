-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260925082820, name 'sna_pos_22_option_order_shift_merged'. This is the SQL that actually ran.

do $$
declare d text;
begin
  d := pg_get_functiondef('app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb)'::regprocedure);
  d := replace(d, 'order by mg.created_at, mg.id, mi.display_order, mi.name', 'order by mg.is_required desc, mg.min_select desc, mg.name, mi.display_order, mi.name');
  execute d;
  d := pg_get_functiondef('app.shift_figures(uuid)'::regprocedure);
  d := replace(d, 'from public.orders where shift_id = s.id;', 'from public.orders where shift_id = s.id and merged_into is null;');
  execute d;
  if pg_get_functiondef('app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb)'::regprocedure) like '%mg.created_at, mg.id%'
     or pg_get_functiondef('app.shift_figures(uuid)'::regprocedure) not like '%merged_into is null%' then
    raise exception 'patch did not apply';
  end if;
end $$;
