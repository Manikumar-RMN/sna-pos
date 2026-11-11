-- Undo 238. undo_complimentary goes back to the 235 version (re-run that block), then the new objects are dropped.
drop function if exists public.set_comp_charge_to(uuid, uuid);
drop function if exists public.save_nc_charge_target(uuid, text, boolean);
drop function if exists public.list_nc_charge_targets(boolean);
alter table public.orders drop column if exists comp_charge_to;
drop table if exists public.nc_charge_targets;
