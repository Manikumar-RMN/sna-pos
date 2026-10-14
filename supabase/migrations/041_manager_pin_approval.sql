-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928091519, name '41_manager_pin_approval'. This is the SQL that actually ran.

create table public.approvals (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  requested_by uuid not null,
  approved_by uuid not null,
  permission_key text not null references public.permissions(key),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '2 minutes',
  used_at timestamptz
);
create index approvals_lookup on public.approvals (requested_by, permission_key) where used_at is null;
create table public.approval_failures (
  id bigserial primary key,
  restaurant_id uuid not null,
  user_id uuid not null,
  at timestamptz not null default now()
);
alter table public.approvals enable row level security;
alter table public.approval_failures enable row level security;
revoke all on public.approvals, public.approval_failures from anon, authenticated;

-- A manager types their PIN on this screen to allow one action the signed-in person lacks the right for.
create or replace function public.approve_with_pin(p_pin text, p_permission text) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_me uuid := app.current_user_id(); v_rest uuid := app.current_restaurant_id(); v_approver public.users%rowtype; v_fails int;
begin
  if v_me is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if not exists (select 1 from public.permissions where key = p_permission) then raise exception 'Unknown right.'; end if;
  select count(*) into v_fails from public.approval_failures where user_id = v_me and at > now() - interval '10 minutes';
  if v_fails >= 5 then raise exception 'Too many wrong PINs. Wait 10 minutes and try again.'; end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then raise exception 'Enter the 4 or 6 digit PIN.'; end if;
  select u.* into v_approver from public.users u
   where u.restaurant_id = v_rest and u.is_active and u.deleted_at is null and u.pin_hash is not null
     and u.pin_hash = app.pin_hash(v_rest, p_pin) limit 1;
  if not found or not exists (select 1 from public.role_permissions rp where rp.role_id = v_approver.role_id and rp.permission_key = p_permission) then
    insert into public.approval_failures (restaurant_id, user_id) values (v_rest, v_me);
    raise exception 'That PIN cannot approve this. Ask a manager to enter their own PIN.';
  end if;
  if v_approver.id = v_me then raise exception 'You already have this right; no approval is needed.'; end if;
  insert into public.approvals (restaurant_id, requested_by, approved_by, permission_key)
  values (v_rest, v_me, v_approver.id, p_permission);
  perform app.audit('approval.granted', 'users', v_approver.id,
    jsonb_build_object('permission', p_permission, 'for_user', v_me, 'approver', v_approver.full_name));
  return jsonb_build_object('approver', v_approver.full_name, 'permission', p_permission, 'valid_seconds', 120);
end $$;
revoke all on function public.approve_with_pin(text, text) from public, anon;
grant execute on function public.approve_with_pin(text, text) to authenticated;

-- Has the right, or a manager approved it for this one action.
create or replace function app.allowed(p_key text) returns boolean
language plpgsql volatile security definer set search_path to 'public','pg_temp' as $$
declare v_me uuid := app.current_user_id(); v_ap public.approvals%rowtype;
begin
  if app.has_permission(p_key) then return true; end if;
  if coalesce(current_setting('app.approved.' || replace(p_key, '.', '_'), true), '') = 'on' then return true; end if;
  if v_me is null then return false; end if;
  select * into v_ap from public.approvals
   where requested_by = v_me and permission_key = p_key and used_at is null and expires_at > now()
   order by created_at desc limit 1 for update skip locked;
  if not found then return false; end if;
  update public.approvals set used_at = now() where id = v_ap.id;
  perform set_config('app.approved.' || replace(p_key, '.', '_'), 'on', true);
  perform app.audit('approval.used', 'users', v_ap.approved_by, jsonb_build_object('permission', p_key, 'for_user', v_me));
  return true;
end $$;

create or replace function app.require_permission(p_key text) returns uuid
language plpgsql volatile security definer set search_path to 'public','pg_temp' as $$
begin
  if app.current_restaurant_id() is null then
    raise exception 'You are not signed in to a restaurant.';
  end if;
  if not app.allowed(p_key) then
    raise exception 'Your role does not allow this action (%).', p_key;
  end if;
  return app.current_user_id();
end $$;

-- Money functions use the same "right or approval" check, and say which right is missing.
do $$
declare d text; f text;
begin
  foreach f in array array['public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb,text)',
                           'public.adjust_order(uuid,numeric,text,boolean)'] loop
    d := pg_get_functiondef(f::regprocedure);
    d := replace(d, 'app.has_permission(''order.discount'')', 'app.allowed(''order.discount'')');
    d := replace(d, 'app.has_permission(''payment.take'')', 'app.allowed(''payment.take'')');
    d := replace(d, 'A manager must approve a discount.', 'A manager must approve a discount (order.discount).');
    d := replace(d, 'A manager must approve removing the service charge.', 'A manager must approve removing the service charge (order.discount).');
    d := replace(d, 'You need the right to give discounts to apply a senior citizen / PWD discount.', 'A manager must approve the senior citizen / PWD discount (order.discount).');
    d := replace(d, 'You do not have the right to take payment. Save the bill and ask the cashier to settle it.', 'You do not have the right to take payment (payment.take). Save the bill and ask the cashier to settle it.');
    if position('app.has_permission(''order.discount'')' in d) > 0 then raise exception 'patch failed for %', f; end if;
    execute d;
  end loop;
end $$;
