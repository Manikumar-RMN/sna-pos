-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260924165452, name 'sna_pos_16_tax_rates_account_state'. This is the SQL that actually ran.

-- SNA POS migration 16: change a tax group's rate, add a tax group, and tell a
-- signed-in person whether their staff access is active or switched off.

create or replace function app.write_tax_components(p_restaurant uuid, p_rate_id uuid, p_total numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_country char(2); v_sys text;
begin
  select r.country_code, c.tax_system_name into v_country, v_sys
    from public.restaurants r join public.countries c on c.code = r.country_code
   where r.id = p_restaurant;
  delete from public.tax_rate_components where tax_rate_id = p_rate_id;
  if v_country = 'IN' then
    insert into public.tax_rate_components (restaurant_id, tax_rate_id, name, rate, applies_when, display_order) values
      (p_restaurant, p_rate_id, 'CGST', round(p_total / 2, 3), 'intra_region', 1),
      (p_restaurant, p_rate_id, 'SGST', round(p_total / 2, 3), 'intra_region', 2),
      (p_restaurant, p_rate_id, 'IGST', p_total,               'inter_region', 3);
  else
    insert into public.tax_rate_components (restaurant_id, tax_rate_id, name, rate, applies_when, display_order)
    values (p_restaurant, p_rate_id, coalesce(v_sys, 'Tax'), p_total, 'always', 1);
  end if;
end $$;
revoke all on function app.write_tax_components(uuid, uuid, numeric) from public, anon, authenticated;

-- A new rate takes effect today. Past bills keep the tax they were charged,
-- because every bill froze its own tax lines when it was created.
create or replace function public.set_tax_rate(p_tax_group_id uuid, p_total_rate numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('tax.manage');
  v_rest uuid := app.current_restaurant_id();
  g public.tax_groups%rowtype;
  cur public.tax_rates%rowtype;
  v_has boolean;
  v_rate uuid;
  v_r numeric := round(p_total_rate, 3);
begin
  if v_r is null or v_r < 0 or v_r > 40 then
    raise exception 'Enter a tax rate between 0 and 40 percent.';
  end if;
  select * into g from public.tax_groups where id = p_tax_group_id and restaurant_id = v_rest;
  if not found then raise exception 'Tax group not found.'; end if;

  select * into cur from public.tax_rates
   where tax_group_id = g.id and valid_from <= current_date
     and (valid_to is null or valid_to >= current_date)
   order by valid_from desc limit 1 for update;
  v_has := found;
  if v_has and cur.total_rate = v_r then return; end if;

  if v_has and cur.valid_from = current_date then
    update public.tax_rates set total_rate = v_r where id = cur.id;
    v_rate := cur.id;
  else
    if v_has then
      update public.tax_rates set valid_to = current_date - 1 where id = cur.id;
    end if;
    insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
    values (v_rest, g.id, v_r, current_date) returning id into v_rate;
  end if;
  perform app.write_tax_components(v_rest, v_rate, v_r);

  perform app.audit('tax.rate_change', 'tax_groups', g.id,
    jsonb_build_object('group', g.name, 'rate', v_r),
    case when v_has then jsonb_build_object('rate', cur.total_rate) else null end);
end $$;

create or replace function public.create_tax_group(p_name text, p_total_rate numeric)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('tax.manage');
  v_rest uuid := app.current_restaurant_id();
  v_group uuid;
  v_rate uuid;
  v_r numeric := round(p_total_rate, 3);
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a name for the tax group.'; end if;
  if v_r is null or v_r < 0 or v_r > 40 then
    raise exception 'Enter a tax rate between 0 and 40 percent.';
  end if;
  if exists (select 1 from public.tax_groups where restaurant_id = v_rest and lower(name) = lower(trim(p_name))) then
    raise exception 'A tax group with that name already exists.';
  end if;
  insert into public.tax_groups (restaurant_id, name, is_price_inclusive)
  values (v_rest, left(trim(p_name), 60), false) returning id into v_group;
  insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
  values (v_rest, v_group, v_r, current_date) returning id into v_rate;
  perform app.write_tax_components(v_rest, v_rate, v_r);
  perform app.audit('tax.group_create', 'tax_groups', v_group,
    jsonb_build_object('name', trim(p_name), 'rate', v_r));
  return v_group;
end $$;

-- 'active' | 'deactivated' | 'new' (no restaurant yet) | 'signed_out'
create or replace function public.my_account_state()
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when auth.uid() is null then 'signed_out'
    when exists (select 1 from public.users where auth_user_id = auth.uid()
                 and deleted_at is null and is_active) then 'active'
    when exists (select 1 from public.users where auth_user_id = auth.uid()
                 and deleted_at is null) then 'deactivated'
    else 'new' end
$$;

revoke all on function public.set_tax_rate(uuid, numeric), public.create_tax_group(text, numeric),
  public.my_account_state() from public, anon;
grant execute on function public.set_tax_rate(uuid, numeric), public.create_tax_group(text, numeric),
  public.my_account_state() to authenticated;
