-- 156: one read for the Front Office setup screen and the booking form (SNA Hospitality). Depends on 152. Additive only.
-- Room types (restaurant-wide), this outlet's rooms and its settings, in one call. Read only; needs fo.view or fo.manage.
-- Safe to run again.
create or replace function public.fo_setup() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  return jsonb_build_object(
    'room_types', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'code', t.code, 'name', t.name, 'base_rate', t.base_rate,
        'max_occupancy', t.max_occupancy, 'display_order', t.display_order, 'active', t.active)
        order by t.display_order, t.name)
      from public.fo_room_types t where t.restaurant_id = v_rest), '[]'::jsonb),
    'rooms', coalesce((select jsonb_agg(jsonb_build_object(
        'id', r.id, 'room_number', r.room_number, 'room_type_id', r.room_type_id,
        'floor', r.floor_label, 'active', r.active)
        order by r.floor_label nulls first, r.room_number)
      from public.fo_rooms r where r.restaurant_id = v_rest and r.branch_id = v_branch), '[]'::jsonb),
    'settings', coalesce((select to_jsonb(s) - 'restaurant_id' - 'branch_id'
      from public.fo_branch_settings s where s.branch_id = v_branch),
      jsonb_build_object('room_tax_pct', 5, 'room_tax_pct_high', 18, 'room_tax_threshold', 7500,
                         'other_tax_pct', 5, 'check_in_time', '12:00', 'check_out_time', '11:00')));
end $$;
revoke all on function public.fo_setup() from public, anon;
grant execute on function public.fo_setup() to authenticated, service_role;
