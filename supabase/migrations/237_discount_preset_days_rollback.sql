-- Undo 237: put back the three 152 functions (re-run their blocks from 152_reasons_discount_presets_day_close.sql), then drop the column.
drop function if exists public.save_discount_preset(uuid, text, text, numeric, date, date, text[], uuid[], boolean, integer, smallint[]);
-- (re-run 152: list_discount_presets, list_discount_presets_admin, save_discount_preset)
alter table public.discount_presets drop constraint if exists discount_presets_days_check;
alter table public.discount_presets drop column if exists days;
