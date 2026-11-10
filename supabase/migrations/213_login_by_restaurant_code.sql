-- 213: one sign-in order for everyone: restaurant code, then username, then password.
-- A user code (EMP001) repeats across restaurants, so it only means something inside one restaurant. The username may
-- also be the person's email; either is looked up only among the people of the restaurant with that code.
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.login_staff(text,text,text)'::regprocedure); o := d;
  d := replace(d, 'lower(u.employee_code) = lower(trim(p_username))',
                  '(lower(u.employee_code) = lower(trim(p_username)) or lower(u.email::text) = lower(trim(p_username)))');
  if d = o then raise exception 'login_staff anchor changed'; end if;
  execute d;
end $$;
revoke all on function public.login_staff(text, text, text) from public;
grant execute on function public.login_staff(text, text, text) to anon, authenticated;
