-- Group 2 security fixes.
-- 1. Cash can only be given back up to the cash that was taken on that bill (a card or UPI bill can no longer be refunded in cash).
-- 2. A manager can clear a sign-in lock (someone typing wrong passwords for a username can no longer keep that person locked out for good).
-- Rollback: 248_group2_security_rollback.sql
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.issue_credit_note(uuid,numeric,uuid,text,uuid)'::regprocedure); o := d;
  d := replace(d, E'  select id into v_shift from public.shifts where branch_id = o.branch_id and status = ''open'' limit 1; if v_shift is null then',
E'  if v_kind = ''cash'' then\n    declare v_cash_in numeric(14,2); v_cash_out numeric(14,2);\n    begin\n      select coalesce(sum(p.amount), 0) into v_cash_in from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id\n       where p.order_id = o.id and p.status = ''captured'' and pm.kind = ''cash'';\n      select coalesce(sum(r.amount), 0) into v_cash_out from public.refunds r join public.payment_methods pm on pm.id = r.payment_method_id\n       where r.order_id = o.id and pm.kind = ''cash'';\n      if v_amount > v_cash_in - v_cash_out then\n        raise exception ''Only % was paid in cash on bill %, so that is the most that can be given back in cash. Give the rest back by the way it was paid.'', greatest(v_cash_in - v_cash_out, 0), o.bill_number;\n      end if;\n    end;\n  end if;\n  select id into v_shift from public.shifts where branch_id = o.branch_id and status = ''open'' limit 1; if v_shift is null then');
  if d = o then raise exception 'issue_credit_note anchor changed'; end if;
  execute d;
end $$;

create or replace function public.unlock_staff_login(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_me uuid := app.require_permission('user.manage'); u record;
begin
  select id, full_name into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id() and deleted_at is null;
  if not found then raise exception 'Staff member not found.'; end if;
  update public.users set login_failed_count = 0, login_locked_until = null where id = u.id;
  perform app.audit('user.login_unlocked', 'users', u.id, jsonb_build_object('by', v_me, 'name', u.full_name));
  return jsonb_build_object('user_id', u.id, 'name', u.full_name);
end $function$;
revoke all on function public.unlock_staff_login(uuid) from public, anon;
grant execute on function public.unlock_staff_login(uuid) to authenticated;
