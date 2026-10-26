-- 130: scheduled (future-dated) tax rate changes.
--
-- Data model already exists (tax_rates.valid_from / valid_to). What was missing:
--   * a way to say "from 1 April the rate is 12%" in advance (schedule_tax_group / cancel_scheduled_tax), and
--   * an immediate change ("Save now") must also drop a pending schedule, otherwise the old plan would silently
--     overwrite the new rate on its date.
-- Bills keep their own copy of the tax (order_items.tax_comps), so nothing already billed ever changes.
-- Additive: two new functions, one helper, one CREATE OR REPLACE of app.write_tax_group (same signature, same behaviour
-- unless a pending row exists). No table, column or data is touched. One transaction.

-- "Today" for an immediate change: the calendar date, or - while a business day that started yesterday is still open
-- (between midnight and the day cutoff) - that open business day, because bills are priced by business date (131).
-- A STALE open day (its date is older than the branch's business today, e.g. a day nobody closed) does not count:
-- it is lifted to the branch's business today, the same rule bill_input uses.
create or replace function app.tax_today(p_restaurant uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select least(app.local_today(p_restaurant),
               coalesce((select min(greatest(bd.business_date, coalesce(app.business_today(bd.branch_id), bd.business_date)))
                           from public.business_days bd
                          where bd.restaurant_id = p_restaurant and bd.status = 'open'), app.local_today(p_restaurant)))
$$;
revoke all on function app.tax_today(uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION app.write_tax_group(p_restaurant uuid, p_group uuid, p_comps jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cur public.tax_rates%rowtype; v_has boolean; v_rate uuid; c jsonb; k int := 0; v_today date := app.tax_today(p_restaurant);
begin
  -- An immediate change replaces any rate that was scheduled for later.
  delete from public.tax_rate_components where tax_rate_id in
    (select id from public.tax_rates where tax_group_id = p_group and restaurant_id = p_restaurant and valid_from > v_today);
  delete from public.tax_rates where tax_group_id = p_group and restaurant_id = p_restaurant and valid_from > v_today;
  select * into cur from public.tax_rates
   where tax_group_id = p_group and valid_from <= v_today
     and (valid_to is null or valid_to >= v_today)
   order by valid_from desc limit 1 for update;
  v_has := found;
  if v_has and cur.valid_from = v_today then
    update public.tax_rates set total_rate = app.effective_rate(p_comps), valid_to = null where id = cur.id;
    v_rate := cur.id;
    delete from public.tax_rate_components where tax_rate_id = cur.id;
  else
    if v_has then update public.tax_rates set valid_to = v_today - 1 where id = cur.id; end if;
    insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
    values (p_restaurant, p_group, app.effective_rate(p_comps), v_today) returning id into v_rate;
  end if;
  for c in select * from jsonb_array_elements(coalesce(p_comps, '[]'::jsonb)) loop
    k := k + 1;
    insert into public.tax_rate_components
      (restaurant_id, tax_rate_id, name, rate, applies_when, display_order, is_compound)
    values (p_restaurant, v_rate, left(trim(c->>'name'), 40), (c->>'rate')::numeric,
            coalesce(c->>'applies_when', 'always'), k, coalesce((c->>'compound')::boolean, false));
  end loop;
end $function$;

-- Schedule a rate for a future date. The current rate is closed the day before; one pending change per group.
create or replace function public.schedule_tax_group(p_group uuid, p_components jsonb, p_effective_from date)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('tax.manage');
  v_rest uuid := app.current_restaurant_id();
  v_today date; cur public.tax_rates%rowtype; v_rate uuid; c jsonb; k int := 0; v_old jsonb;
begin
  if v_rest is null then raise exception 'Not signed in.'; end if;
  if p_group is null or not exists (select 1 from public.tax_groups where id = p_group and restaurant_id = v_rest) then
    raise exception 'Tax group not found.';
  end if;
  if p_effective_from is null then raise exception 'Choose the date the new rate starts.'; end if;
  v_today := app.local_today(v_rest);
  if p_effective_from <= v_today then
    raise exception 'The start date must be after today. To change the rate now, save it without a date.';
  end if;
  if p_effective_from > v_today + 366 then raise exception 'Schedule at most one year ahead.'; end if;
  if p_components is null or jsonb_typeof(p_components) <> 'array' then raise exception 'Invalid tax list.'; end if;
  if jsonb_array_length(p_components) > 6 then raise exception 'A tax group can have at most 6 taxes.'; end if;
  for c in select * from jsonb_array_elements(p_components) loop
    if coalesce(trim(c->>'name'), '') = '' then raise exception 'Every tax needs a name.'; end if;
    if (c->>'rate') is null or (c->>'rate')::numeric < 0 or (c->>'rate')::numeric > 40 then
      raise exception 'Tax rates must be between 0 and 40 percent.';
    end if;
    if coalesce(c->>'applies_when', 'always') not in ('always', 'intra_region', 'inter_region') then
      raise exception 'Unknown option for when a tax applies.';
    end if;
  end loop;
  perform 1 from public.tax_groups where id = p_group for update;   -- serialise two people scheduling the same group
  if exists (select 1 from public.tax_rates where tax_group_id = p_group and restaurant_id = v_rest and valid_from > v_today) then
    raise exception 'A change is already scheduled for this tax group. Cancel it first.';
  end if;
  select * into cur from public.tax_rates
   where tax_group_id = p_group and restaurant_id = v_rest and valid_from <= v_today
     and (valid_to is null or valid_to >= v_today)
   order by valid_from desc limit 1 for update;
  if found then
    select coalesce(jsonb_agg(jsonb_build_object('name', c2.name, 'rate', c2.rate) order by c2.display_order), '[]'::jsonb)
      into v_old from public.tax_rate_components c2 where c2.tax_rate_id = cur.id;
    update public.tax_rates set valid_to = p_effective_from - 1 where id = cur.id;
  end if;
  insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
  values (v_rest, p_group, app.effective_rate(p_components), p_effective_from) returning id into v_rate;
  for c in select * from jsonb_array_elements(p_components) loop
    k := k + 1;
    insert into public.tax_rate_components
      (restaurant_id, tax_rate_id, name, rate, applies_when, display_order, is_compound)
    values (v_rest, v_rate, left(trim(c->>'name'), 40), (c->>'rate')::numeric,
            coalesce(c->>'applies_when', 'always'), k, coalesce((c->>'compound')::boolean, false));
  end loop;
  perform app.audit('tax.rate_scheduled', 'tax_groups', p_group,
    jsonb_build_object('effective_from', p_effective_from, 'components', p_components), v_old);
  return jsonb_build_object('group_id', p_group, 'tax_rate_id', v_rate, 'effective_from', p_effective_from);
end $$;
revoke all on function public.schedule_tax_group(uuid, jsonb, date) from public, anon;
grant execute on function public.schedule_tax_group(uuid, jsonb, date) to authenticated;

-- Cancel the pending change of a group: the pending rate is removed and the current rate runs on.
create or replace function public.cancel_scheduled_tax(p_group uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('tax.manage');
  v_rest uuid := app.current_restaurant_id();
  v_today date; pend public.tax_rates%rowtype; v_old jsonb;
begin
  if v_rest is null then raise exception 'Not signed in.'; end if;
  if p_group is null or not exists (select 1 from public.tax_groups where id = p_group and restaurant_id = v_rest) then
    raise exception 'Tax group not found.';
  end if;
  v_today := app.local_today(v_rest);
  perform 1 from public.tax_groups where id = p_group for update;
  select * into pend from public.tax_rates
   where tax_group_id = p_group and restaurant_id = v_rest and valid_from > v_today order by valid_from limit 1 for update;
  if not found then raise exception 'No change is scheduled for this tax group.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('name', c2.name, 'rate', c2.rate) order by c2.display_order), '[]'::jsonb)
    into v_old from public.tax_rate_components c2 where c2.tax_rate_id = pend.id;
  delete from public.tax_rate_components where tax_rate_id = pend.id;
  delete from public.tax_rates where id = pend.id;
  -- the rate that was running until the day before the pending one runs on again
  update public.tax_rates set valid_to = null
   where tax_group_id = p_group and restaurant_id = v_rest and valid_to = pend.valid_from - 1;
  perform app.audit('tax.rate_schedule_cancelled', 'tax_groups', p_group,
    jsonb_build_object('cancelled', true), jsonb_build_object('effective_from', pend.valid_from, 'components', v_old));
  return jsonb_build_object('group_id', p_group, 'cancelled', true);
end $$;
revoke all on function public.cancel_scheduled_tax(uuid) from public, anon;
grant execute on function public.cancel_scheduled_tax(uuid) to authenticated;
