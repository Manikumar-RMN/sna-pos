-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928175243, name '071_auto_shift_id'. This is the SQL that actually ran.

create or replace function app.auto_shift(p_branch uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; v_on boolean; v_rest uuid; v_user uuid;
begin
  select id into v from public.shifts where branch_id = p_branch and status = 'open' order by opened_at desc limit 1;
  if v is not null then return v; end if;
  select coalesce(bs.shifts_enabled, false), b.restaurant_id into v_on, v_rest
    from public.branches b left join public.branch_settings bs on bs.branch_id = b.id where b.id = p_branch;
  if v_rest is null or v_on then return null; end if;
  perform pg_advisory_xact_lock(hashtext('auto_shift:' || p_branch::text));
  select id into v from public.shifts where branch_id = p_branch and status = 'open' limit 1;
  if v is not null then return v; end if;
  v_user := coalesce(app.current_user_id(),
    (select u.id from public.users u join public.roles r on r.id = u.role_id
      where u.restaurant_id = v_rest and r.name = 'Owner' order by u.created_at limit 1));
  v := gen_random_uuid();
  insert into public.shifts (id, restaurant_id, branch_id, opened_by, opening_float, opened_at, status, notes)
  values (v, v_rest, p_branch, v_user, 0, now(), 'open', 'Automatic (shifts are off)');
  return v;
end $$;
revoke all on function app.auto_shift(uuid) from public, anon, authenticated;
