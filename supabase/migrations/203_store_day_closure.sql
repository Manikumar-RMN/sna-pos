-- Store Day Closure: lock one finished day so nothing can be posted or back-dated into it.
create table if not exists public.stock_day_closures (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  day date not null,
  closed_by uuid not null,
  closed_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid,
  revoke_reason text
);
create unique index if not exists stock_day_closures_open_uq on public.stock_day_closures (branch_id, day) where revoked_at is null;
alter table public.stock_day_closures enable row level security;
grant select on public.stock_day_closures to authenticated;
drop policy if exists tenant_read on public.stock_day_closures;
create policy tenant_read on public.stock_day_closures for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id())
  and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));

-- Every stock writer already calls this check, so it now also refuses a closed day.
create or replace function app.assert_month_open(p_branch uuid, p_date date) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from public.stock_month_closures c where c.branch_id = p_branch and c.revoked_at is null and c.month = date_trunc('month', p_date)::date) then
    raise exception 'The stock for % is closed. Ask the owner to re-open that month first.', to_char(p_date, 'Mon YYYY');
  end if;
  if exists (select 1 from public.stock_day_closures d where d.branch_id = p_branch and d.revoked_at is null and d.day = p_date) then
    raise exception 'The stock for % is closed. Ask the owner to re-open that day first.', to_char(p_date, 'DD Mon YYYY');
  end if;
end $$;

create or replace function public.close_stock_day(p_day date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_today date; v_id uuid := gen_random_uuid();
begin
  perform app.require_feature('stock');
  if p_day is null then raise exception 'Choose a day.'; end if;
  v_today := (now() at time zone coalesce((select timezone from public.restaurants where id = v_rest), 'UTC'))::date;
  if p_day >= v_today then raise exception 'Only a finished day can be closed. % is not over yet.', to_char(p_day, 'DD Mon YYYY'); end if;
  perform pg_advisory_xact_lock(hashtext('dayclose:' || v_branch::text));
  if exists (select 1 from public.stock_day_closures c where c.branch_id = v_branch and c.day = p_day and c.revoked_at is null) then
    raise exception '% is already closed.', to_char(p_day, 'DD Mon YYYY');
  end if;
  if exists (select 1 from public.stock_month_closures c where c.branch_id = v_branch and c.revoked_at is null and c.month = date_trunc('month', p_day)::date) then
    raise exception 'The whole month is already closed.';
  end if;
  insert into public.stock_day_closures (id, restaurant_id, branch_id, day, closed_by) values (v_id, v_rest, v_branch, p_day, v_user);
  perform app.audit('stock.day_close', 'stock_day_closures', v_id, jsonb_build_object('day', p_day));
  return jsonb_build_object('id', v_id, 'day', p_day);
end $$;
revoke all on function public.close_stock_day(date) from public, anon;
grant execute on function public.close_stock_day(date) to authenticated;

create or replace function public.reopen_stock_day(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('settings.manage');
  c public.stock_day_closures%rowtype;
begin
  perform app.require_feature('stock');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for re-opening the day.'; end if;
  select * into c from public.stock_day_closures where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Closed day not found.'; end if;
  if c.revoked_at is not null then raise exception '% is already open.', to_char(c.day, 'DD Mon YYYY'); end if;
  update public.stock_day_closures set revoked_at = now(), revoked_by = v_user, revoke_reason = left(trim(p_reason), 300) where id = c.id;
  perform app.audit('stock.day_reopen', 'stock_day_closures', c.id, jsonb_build_object('day', c.day, 'reason', left(trim(p_reason), 300)));
  return jsonb_build_object('id', c.id, 'day', c.day);
end $$;
revoke all on function public.reopen_stock_day(uuid, text) from public, anon;
grant execute on function public.reopen_stock_day(uuid, text) to authenticated;
