-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928103431, name '058_outlet_billing_device'. This is the SQL that actually ran.

do $$
declare v_def text;
begin
  -- A new outlet gets its own billing series (like the first outlet).
  v_def := pg_get_functiondef('public.sna_create_outlet(uuid,text,text,text,text,text,text)'::regprocedure);
  v_def := replace(v_def, '  -- Owners can work in every outlet.', '');
  v_def := replace(v_def, '  insert into public.user_branches (user_id, branch_id, restaurant_id)',
    E'  insert into public.devices (restaurant_id, branch_id, name, device_type, bill_prefix)\n  values (q.restaurant_id, v_id, ''Counter 1'', ''tablet'', ''C1'');\n  insert into public.user_branches (user_id, branch_id, restaurant_id)');
  if position('''Counter 1''' in v_def) = 0 then raise exception 'patch failed'; end if;
  execute v_def;

  -- Basic: the limit is on shared counter tablets, not the built-in billing series.
  v_def := pg_get_functiondef('app.basic_limits()'::regprocedure);
  v_def := replace(v_def, 'if not new.is_active then return new; end if;', 'if not new.is_active or new.device_type <> ''counter'' then return new; end if;');
  v_def := replace(v_def, 'from public.devices where restaurant_id = new.restaurant_id and is_active and id <> new.id',
                          'from public.devices where restaurant_id = new.restaurant_id and is_active and device_type = ''counter'' and id <> new.id');
  execute v_def;
end $$;
