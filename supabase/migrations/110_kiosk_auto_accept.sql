-- 110: Kiosk orders can become bills by themselves.
-- A kiosk can be given a "billing user" (a staff login allowed to take orders). Each kiosk order is then accepted at
-- once as that user: a takeaway bill and the kitchen ticket are made straight away and the kiosk shows the token.
-- If anything stops it (that user is switched off, an item ran out…), the order simply waits on Table orders as before.

alter table public.dining_tables add column kiosk_user_id uuid references public.users(id) on delete set null;

create or replace function public.kiosk_set_auto(p_id uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_me uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id();
begin
  if not exists (select 1 from public.dining_tables where id = p_id and restaurant_id = v_rest and is_kiosk and is_active) then
    raise exception 'That kiosk was not found.';
  end if;
  if p_user is not null and not exists (
       select 1 from public.users u join public.role_permissions rp on rp.role_id = u.role_id
        where u.id = p_user and u.restaurant_id = v_rest and u.is_active and u.deleted_at is null and rp.permission_key = 'order.create'
          and u.auth_user_id is not null) then
    raise exception 'Choose an active staff login that signs in with email and is allowed to take orders.';
  end if;
  update public.dining_tables set kiosk_user_id = p_user where id = p_id;
  perform app.audit('kiosk.auto_accept', 'dining_tables', p_id, jsonb_build_object('user', p_user), null);
end $function$;
revoke all on function public.kiosk_set_auto(uuid, uuid) from public, anon;
grant execute on function public.kiosk_set_auto(uuid, uuid) to authenticated, service_role;

-- Accepts a kiosk order as the kiosk's billing user. Never fails the guest's order: on any problem it stays waiting.
create or replace function app.kiosk_auto_accept(p_request uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_claims text := current_setting('request.jwt.claims', true); v_sub text := current_setting('request.jwt.claim.sub', true); v_auth uuid;
begin
  select auth_user_id into v_auth from public.users where id = p_user and is_active and deleted_at is null and not coalesce(must_change_password, false);
  if v_auth is null then return; end if;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_auth::text, true);
    perform public.accept_qr_order(p_request);
  exception when others then
    null;  -- stays on Table orders for the staff
  end;
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
end $function$;
revoke all on function app.kiosk_auto_accept(uuid, uuid) from public, anon, authenticated;

create or replace function public.kiosk_list()
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.table_number, 'token', t.qr_token, 'auto_user', t.kiosk_user_id, 'auto_user_name', u.full_name)
         order by t.table_number), '[]'::jsonb)
    from public.dining_tables t left join public.users u on u.id = t.kiosk_user_id
   where t.restaurant_id = app.current_restaurant_id() and t.branch_id = app.current_branch_id() and t.is_kiosk and t.is_active
     and app.allowed('settings.manage')
$function$;

do $patch$
declare d text;
begin
  d := pg_get_functiondef('public.qr_place_order'::regproc);
  if position('  return jsonb_build_object(''request_id'', v_id, ''key'', v_key, ''estimated_total'', v_total);' in d) = 0 then
    raise exception 'qr_place_order is not the expected version.';
  end if;
  d := replace(d, '  return jsonb_build_object(''request_id'', v_id, ''key'', v_key, ''estimated_total'', v_total);',
    '  if t.is_kiosk and t.kiosk_user_id is not null then perform app.kiosk_auto_accept(v_id, t.kiosk_user_id); end if;
  return jsonb_build_object(''request_id'', v_id, ''key'', v_key, ''estimated_total'', v_total);');
  execute d;
end $patch$;
