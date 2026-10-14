-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928144220, name '067_offline_snapshot_hide_redeem_methods'. This is the SQL that actually ran.

do $$
declare d text := pg_get_functiondef('public.offline_snapshot(text)'::regprocedure);
begin
  if position('kind not in (''gift_card'', ''loyalty'')' in d) = 0 then
    d := replace(d, 'payment_methods where restaurant_id = v_rest and is_active',
                    'payment_methods where restaurant_id = v_rest and is_active and kind not in (''gift_card'', ''loyalty'')');
    execute d;
  end if;
end $$;
