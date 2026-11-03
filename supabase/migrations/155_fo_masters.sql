-- 155: Front Office masters (SNA Hospitality). Depends on 152. Additive only.
-- Room types, rooms and the per-property settings, so the module can be set up from the Settings screen without SQL.
-- A room type or room is never deleted once a stay has used it; it is switched off (active = false) so history stays readable.
-- Safe to run again.

create or replace function public.fo_save_room_type(
  p_code text, p_name text, p_base_rate numeric default 0, p_max_occupancy int default 2,
  p_display_order int default 0, p_active boolean default true, p_room_type_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_id uuid;
begin
  perform app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_code, '')), '') = '' then raise exception 'Give the room type a short code.'; end if;
  if coalesce(btrim(coalesce(p_name, '')), '') = '' then raise exception 'Give the room type a name.'; end if;
  if coalesce(p_base_rate, 0) < 0 then raise exception 'The rate cannot be negative.'; end if;

  if p_room_type_id is null then
    insert into public.fo_room_types (restaurant_id, code, name, base_rate, max_occupancy, display_order, active)
    values (v_rest, upper(btrim(p_code)), btrim(p_name), coalesce(p_base_rate, 0),
            coalesce(p_max_occupancy, 2), coalesce(p_display_order, 0), coalesce(p_active, true))
    returning id into v_id;
    perform app.audit('fo_room_type_created', 'fo_room_type', v_id, jsonb_build_object('code', upper(btrim(p_code)), 'name', btrim(p_name)));
    return jsonb_build_object('room_type_id', v_id, 'created', true);
  end if;

  update public.fo_room_types set
    code = upper(btrim(p_code)), name = btrim(p_name), base_rate = coalesce(p_base_rate, base_rate),
    max_occupancy = coalesce(p_max_occupancy, max_occupancy), display_order = coalesce(p_display_order, display_order),
    active = coalesce(p_active, active)
   where id = p_room_type_id and restaurant_id = v_rest returning id into v_id;
  if v_id is null then raise exception 'That room type was not found.'; end if;
  perform app.audit('fo_room_type_updated', 'fo_room_type', v_id, jsonb_build_object('code', upper(btrim(p_code)), 'name', btrim(p_name)));
  return jsonb_build_object('room_type_id', v_id, 'created', false);
end $$;

create or replace function public.fo_save_room(
  p_room_number text, p_room_type_id uuid, p_floor_label text default null,
  p_active boolean default true, p_room_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_id uuid;
begin
  perform app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_room_number, '')), '') = '' then raise exception 'Give the room a number.'; end if;
  if not exists (select 1 from public.fo_room_types where id = p_room_type_id and restaurant_id = v_rest) then
    raise exception 'That room type was not found.'; end if;

  if p_room_id is null then
    insert into public.fo_rooms (restaurant_id, branch_id, room_type_id, room_number, floor_label, active)
    values (v_rest, v_branch, p_room_type_id, btrim(p_room_number), nullif(btrim(coalesce(p_floor_label, '')), ''),
            coalesce(p_active, true))
    returning id into v_id;
    perform app.audit('fo_room_created', 'fo_room', v_id, jsonb_build_object('room_number', btrim(p_room_number)));
    return jsonb_build_object('room_id', v_id, 'created', true);
  end if;

  -- A room with a guest in it keeps its type: moving it would rewrite what the guest booked.
  if exists (select 1 from public.fo_stays s where s.room_id = p_room_id and s.status = 'inhouse')
     and exists (select 1 from public.fo_rooms r where r.id = p_room_id and r.room_type_id <> p_room_type_id) then
    raise exception 'That room has a guest in it, so its type cannot change.';
  end if;

  update public.fo_rooms set
    room_number = btrim(p_room_number), room_type_id = p_room_type_id,
    floor_label = nullif(btrim(coalesce(p_floor_label, '')), ''), active = coalesce(p_active, active)
   where id = p_room_id and restaurant_id = v_rest and branch_id = v_branch returning id into v_id;
  if v_id is null then raise exception 'That room was not found.'; end if;
  perform app.audit('fo_room_updated', 'fo_room', v_id, jsonb_build_object('room_number', btrim(p_room_number)));
  return jsonb_build_object('room_id', v_id, 'created', false);
end $$;

create or replace function public.fo_save_settings(
  p_room_tax_pct numeric default null, p_room_tax_pct_high numeric default null,
  p_room_tax_threshold numeric default null, p_other_tax_pct numeric default null,
  p_check_in_time time default null, p_check_out_time time default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); s public.fo_branch_settings;
begin
  perform app.require_fo(array['fo.manage']);
  insert into public.fo_branch_settings (branch_id, restaurant_id) values (v_branch, v_rest) on conflict do nothing;
  update public.fo_branch_settings set
    room_tax_pct = coalesce(p_room_tax_pct, room_tax_pct),
    room_tax_pct_high = coalesce(p_room_tax_pct_high, room_tax_pct_high),
    room_tax_threshold = coalesce(p_room_tax_threshold, room_tax_threshold),
    other_tax_pct = coalesce(p_other_tax_pct, other_tax_pct),
    check_in_time = coalesce(p_check_in_time, check_in_time),
    check_out_time = coalesce(p_check_out_time, check_out_time),
    updated_at = now()
   where branch_id = v_branch returning * into s;
  perform app.audit('fo_settings_saved', 'fo_branch_settings', null, to_jsonb(s));
  return to_jsonb(s);
end $$;

revoke all on function
  public.fo_save_room_type(text, text, numeric, int, int, boolean, uuid),
  public.fo_save_room(text, uuid, text, boolean, uuid),
  public.fo_save_settings(numeric, numeric, numeric, numeric, time, time) from public, anon;
grant execute on function
  public.fo_save_room_type(text, text, numeric, int, int, boolean, uuid),
  public.fo_save_room(text, uuid, text, boolean, uuid),
  public.fo_save_settings(numeric, numeric, numeric, numeric, time, time) to authenticated, service_role;
