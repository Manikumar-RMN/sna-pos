-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260925082707, name 'sna_pos_21_fix_empty_senior_marker'. This is the SQL that actually ran.

do $$
declare d text;
begin
  d := pg_get_functiondef('public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb)'::regprocedure);
  d := replace(d, $x$(v_in->'calc') - 'lines', v_in->'senior');$x$, $x$(v_in->'calc') - 'lines', nullif(v_in->'senior', 'null'::jsonb));$x$);
  execute d;
  d := pg_get_functiondef('public.split_order(uuid,jsonb)'::regprocedure);
  d := replace(d, $x$or o.senior_details is not null$x$, $x$or nullif(o.senior_details, 'null'::jsonb) is not null$x$);
  execute d;
  d := pg_get_functiondef('public.merge_orders(uuid,uuid)'::regprocedure);
  d := replace(d, $x$or s.senior_details is not null$x$, $x$or nullif(s.senior_details, 'null'::jsonb) is not null$x$);
  execute d;
  if pg_get_functiondef('public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb)'::regprocedure) not like '%nullif(v_in->''senior''%'
     or pg_get_functiondef('public.split_order(uuid,jsonb)'::regprocedure) not like '%nullif(o.senior_details%'
     or pg_get_functiondef('public.merge_orders(uuid,uuid)'::regprocedure) not like '%nullif(s.senior_details%' then
    raise exception 'patch did not apply';
  end if;
end $$;
update public.orders set senior_details = null where senior_details = 'null'::jsonb;
