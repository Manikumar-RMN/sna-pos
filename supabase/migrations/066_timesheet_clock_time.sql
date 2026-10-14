-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928144111, name '066_timesheet_clock_time'. This is the SQL that actually ran.
-- The text previously in git under this number differed from what ran (see git history before the commit that added this header).

create or replace function public.clock_in() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.current_user_id(); v_id uuid; v_at timestamptz := date_trunc('second', clock_timestamp());
begin
  perform app.require_feature('timesheets');
  if v_user is null then raise exception 'Not signed in.'; end if;
  if exists (select 1 from public.time_entries where user_id = v_user and clock_out is null) then raise exception 'You are already clocked in.'; end if;
  insert into public.time_entries (restaurant_id, branch_id, user_id, clock_in) values (app.current_restaurant_id(), app.current_branch_id(), v_user, v_at)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'clock_in', v_at);
end $$;

create or replace function public.clock_out() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.current_user_id(); e public.time_entries%rowtype;
begin
  perform app.require_feature('timesheets');
  update public.time_entries set clock_out = greatest(clock_timestamp(), clock_in + interval '1 second')
   where user_id = v_user and clock_out is null returning * into e;
  if e.id is null then raise exception 'You are not clocked in.'; end if;
  return jsonb_build_object('id', e.id, 'hours', round(extract(epoch from (e.clock_out - e.clock_in)) / 3600.0, 2));
end $$;
revoke all on function public.clock_in(), public.clock_out() from public, anon;
grant execute on function public.clock_in(), public.clock_out() to authenticated;
