-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928093255, name '48_offline_sync_device_lookup'. This is the SQL that actually ran.

do $$
declare d text;
begin
  d := pg_get_functiondef('public.sync_offline_bill(jsonb)'::regprocedure);
  d := replace(d, E'  select n.device_id into v_device from app.next_bill_number(v_branch) n;   -- only to get the billing device; its counter is put back below\n  update public.devices set next_bill_seq = next_bill_seq - 1 where id = v_device;\n',
    E'  select d.id into v_device from public.devices d where d.branch_id = v_branch and d.is_active and d.device_type <> ''counter'' order by d.created_at limit 1;\n');
  if position('next_bill_seq - 1' in d) > 0 then raise exception 'patch failed'; end if;
  execute d;
end $$;
