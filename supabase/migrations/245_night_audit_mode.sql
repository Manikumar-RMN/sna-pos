-- Night audit: Auto (the day closes by itself at the cutoff when nothing blocks it) or Manual (like RMS: the day stays open
-- until a person runs Day close, and bills keep landing on that day).
alter table public.branch_settings
  add column if not exists night_audit_mode text not null default 'auto' check (night_audit_mode in ('auto', 'manual'));

create or replace function app.try_auto_close_day(p_day uuid)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare d public.business_days; v_z jsonb;
begin
  select * into d from public.business_days where id = p_day and status = 'open' for update;
  if not found then return false; end if;
  if coalesce((select night_audit_mode from public.branch_settings where branch_id = d.branch_id), 'auto') = 'manual' then return false; end if;
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
end $function$;

drop function if exists public.save_day_settings(boolean, time without time zone);
create or replace function public.save_day_settings(p_shifts_enabled boolean, p_cutoff time without time zone, p_night_audit text default 'auto')
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  perform app.require_permission('settings.manage');
  if p_cutoff < '00:00' or p_cutoff > '08:00' then raise exception 'The day cutoff must be between midnight and 8 a.m.'; end if;
  if p_night_audit not in ('auto', 'manual') then raise exception 'Night audit must be automatic or manual.'; end if;
  update public.branch_settings set shifts_enabled = p_shifts_enabled, day_cutoff = p_cutoff, night_audit_mode = p_night_audit, updated_at = now()
   where restaurant_id = app.current_restaurant_id();
  perform app.audit('settings.day', 'branch_settings', null,
    jsonb_build_object('shifts_enabled', p_shifts_enabled, 'day_cutoff', p_cutoff, 'night_audit', p_night_audit), null);
end $function$;

revoke all on function public.save_day_settings(boolean, time without time zone, text) from public, anon;
grant execute on function public.save_day_settings(boolean, time without time zone, text) to authenticated;
