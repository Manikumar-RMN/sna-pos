-- 178: One edition. The old Professional-only features no longer depend on an edition; each is part of a module the client buys.
--   pos         : kitchen_stations, courses (hold and fire), merge, reservations, timesheets, open_api
--   stock       : accounting (export), central_kitchen
--   always on   : multi_outlet, custom_roles (flat price per client, no outlet or role limits)
-- A bundled feature is on exactly when its parent module is on (app.feature_on). The Basic limits (300 menu items, user, device
-- and outlet caps) are removed. The edition column and the monthly charge formula are NOT changed here: the charge moves to
-- "sum of module prices" only once every module has a price (otherwise existing invoices would drop).
-- Safe to run again.
alter table public.modules add column if not exists parent text references public.modules(key);

update public.modules set parent = 'pos'   where key in ('kitchen_stations', 'courses', 'merge', 'reservations', 'timesheets', 'open_api');
update public.modules set parent = 'stock' where key in ('accounting', 'central_kitchen');

create or replace function app.feature_on(p_restaurant uuid, p_key text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((
    select case
             when m.parent is not null then exists (select 1 from public.restaurant_modules rm
                                                     where rm.restaurant_id = r.id and rm.module_key = m.parent)
             when m.kind = 'professional' then true
             else exists (select 1 from public.restaurant_modules rm
                           where rm.restaurant_id = r.id and rm.module_key = m.key)
           end
      from public.modules m, public.restaurants r
     where m.key = p_key and r.id = p_restaurant), false)
$$;

create or replace function app.require_feature(p_key text) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m public.modules%rowtype; pm public.modules%rowtype;
begin
  if app.feature_on(app.current_restaurant_id(), p_key) then return; end if;
  select * into m from public.modules where key = p_key;
  if m.parent is not null then
    select * into pm from public.modules where key = m.parent;
    raise exception '% is part of the % module, which is not switched on. Ask for it in Settings → Plan and modules.', coalesce(m.name, p_key), coalesce(pm.name, m.parent);
  end if;
  raise exception 'The % module is not switched on. Ask for it in Settings → Plan and modules.', coalesce(m.name, p_key);
end $$;

drop trigger if exists trg_basic_limits on public.products;
drop trigger if exists trg_basic_limits on public.users;
drop trigger if exists trg_basic_limits on public.devices;
drop trigger if exists trg_basic_limits on public.branches;
drop function if exists app.basic_limits();
