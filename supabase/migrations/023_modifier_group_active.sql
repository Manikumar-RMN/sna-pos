-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260925083134, name 'sna_pos_23_modifier_group_active'. This is the SQL that actually ran.

alter table public.modifier_groups add column if not exists is_active boolean not null default true;
-- A retired group no longer applies to any item.
do $$
declare d text;
begin
  d := pg_get_functiondef('app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb)'::regprocedure);
  d := replace(d, $x$where pmg.product_id = v_product.id
    loop$x$, $x$where pmg.product_id = v_product.id and mg.is_active
    loop$x$);
  d := replace(d, $x$join public.modifier_groups mg on mg.id = mi.modifier_group_id
        join public.product_modifier_groups$x$, $x$join public.modifier_groups mg on mg.id = mi.modifier_group_id and mg.is_active
        join public.product_modifier_groups$x$);
  execute d;
  if (length(pg_get_functiondef('app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb)'::regprocedure))
      - length(replace(pg_get_functiondef('app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb)'::regprocedure), 'mg.is_active', ''))) / 11 <> 2 then
    raise exception 'patch did not apply';
  end if;
end $$;
select app.test_money();
