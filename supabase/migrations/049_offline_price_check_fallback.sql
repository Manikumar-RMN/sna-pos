-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928093322, name '49_offline_price_check_fallback'. This is the SQL that actually ran.

do $$
declare d text;
begin
  d := pg_get_functiondef('public.sync_offline_bill(jsonb)'::regprocedure);
  d := replace(d, E'    if v_hist is null or v_price <> v_hist + v_delta then',
    E'    if v_hist is null then\n      select price into v_hist from public.product_price_history where product_id = v_prod.id order by valid_from limit 1;\n    end if;\n    if v_hist is null or (v_price <> v_hist + v_delta and v_price <> v_prod.price + v_delta) then');
  if position('order by valid_from limit 1' in d) = 0 then raise exception 'patch failed'; end if;
  execute d;
end $$;
