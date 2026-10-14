-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928175424, name '073_auto_close_keeps_auto_shift'. This is the SQL that actually ran.

-- Automatic day roll-over does not touch the automatic drawer: with shifts off it simply continues until a person
-- closes a day with a cash count. With shifts on, an open (manual) shift keeps the old day open.
create or replace function app.try_auto_close_day(p_day uuid) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.business_days; v_z jsonb;
begin
  select * into d from public.business_days where id = p_day and status = 'open' for update;
  if not found then return false; end if;
  if exists (select 1 from public.business_days where branch_id = d.branch_id and status = 'parked') then return false; end if;
  if exists (select 1 from public.orders where branch_id = d.branch_id and business_date = d.business_date and status = 'completed'
               and payment_status in ('unpaid', 'partial') and merged_into is null) then return false; end if;
  if coalesce((select shifts_enabled from public.branch_settings where branch_id = d.branch_id), false)
     and exists (select 1 from public.shifts where branch_id = d.branch_id and status = 'open') then return false; end if;
  update public.business_days set status = 'closed', closed_at = now(), closed_by = null,
         close_notes = 'Closed automatically at the day cutoff' where id = d.id;
  v_z := app.z_report(d.id);
  update public.business_days set z_report = v_z where id = d.id;
  insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, actor_type, new_value)
  values (d.restaurant_id, d.branch_id, null, 'day.close', 'business_days', d.id, 'system',
          jsonb_build_object('business_date', d.business_date, 'total_billed', v_z->'total_billed', 'bills', v_z->'bills', 'automatic', true));
  return true;
end $$;
revoke all on function app.try_auto_close_day(uuid) from public, anon, authenticated;
