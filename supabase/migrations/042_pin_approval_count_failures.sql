-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928091552, name '42_pin_approval_count_failures'. This is the SQL that actually ran.

create or replace function public.approve_with_pin(p_pin text, p_permission text) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_me uuid := app.current_user_id(); v_rest uuid := app.current_restaurant_id(); v_approver public.users%rowtype; v_fails int;
begin
  if v_me is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if not exists (select 1 from public.permissions where key = p_permission) then raise exception 'Unknown right.'; end if;
  select count(*) into v_fails from public.approval_failures where user_id = v_me and at > now() - interval '10 minutes';
  if v_fails >= 5 then
    return jsonb_build_object('ok', false, 'error', 'Too many wrong PINs. Wait 10 minutes and try again.');
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then
    return jsonb_build_object('ok', false, 'error', 'Enter the 4 or 6 digit PIN.');
  end if;
  select u.* into v_approver from public.users u
   where u.restaurant_id = v_rest and u.is_active and u.deleted_at is null and u.pin_hash is not null
     and u.pin_hash = app.pin_hash(v_rest, p_pin) limit 1;
  if not found or not exists (select 1 from public.role_permissions rp where rp.role_id = v_approver.role_id and rp.permission_key = p_permission) then
    -- Recorded (and not rolled back) so repeated guessing locks the approval screen.
    insert into public.approval_failures (restaurant_id, user_id) values (v_rest, v_me);
    return jsonb_build_object('ok', false, 'error', 'That PIN cannot approve this. Ask a manager to enter their own PIN.');
  end if;
  if v_approver.id = v_me then return jsonb_build_object('ok', false, 'error', 'You already have this right; no approval is needed.'); end if;
  insert into public.approvals (restaurant_id, requested_by, approved_by, permission_key)
  values (v_rest, v_me, v_approver.id, p_permission);
  perform app.audit('approval.granted', 'users', v_approver.id,
    jsonb_build_object('permission', p_permission, 'for_user', v_me, 'approver', v_approver.full_name));
  return jsonb_build_object('ok', true, 'approver', v_approver.full_name, 'permission', p_permission, 'valid_seconds', 120);
end $$;
