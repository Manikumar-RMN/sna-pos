-- 166: find a stay's id from its stay number, for "move charge to stay #N" (SNA Hospitality). Additive. Safe to run again.
create or replace function public.fo_stay_by_no(p_stay_no int) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select id into v_id from public.fo_stays
   where restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() and stay_no = p_stay_no;
  return v_id;
end $$;
revoke all on function public.fo_stay_by_no(int) from public, anon;
grant execute on function public.fo_stay_by_no(int) to authenticated, service_role;
