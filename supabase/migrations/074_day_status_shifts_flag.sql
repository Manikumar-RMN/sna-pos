-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928175531, name '074_day_status_shifts_flag'. This is the SQL that actually ran.

do $$
declare d text := pg_get_functiondef('public.day_status()'::regprocedure); n text;
begin
  n := replace(d, $x$select exists (select 1 from public.shifts where branch_id = v_branch and status = 'open') into v_shift;$x$,
    $x$select exists (select 1 from public.shifts where branch_id = v_branch and status = 'open')
       and coalesce((select shifts_enabled from public.branch_settings where branch_id = v_branch), false) into v_shift;$x$);
  n := replace(n, $x$'can_close', app.has_permission('day.close'),$x$,
    $x$'shifts_enabled', coalesce((select shifts_enabled from public.branch_settings where branch_id = v_branch), false),
    'expected_cash', (select (app.shift_figures(s.id)->>'expected_cash')::numeric from public.shifts s where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1),
    'can_close', app.has_permission('day.close'),$x$);
  if n = d or position('shifts_enabled' in n) = 0 or position('and coalesce((select shifts_enabled' in n) = 0 then raise exception 'day_status patch failed'; end if;
  execute n;
end $$;
