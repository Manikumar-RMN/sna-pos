-- 237: Winsar Discount Type "Applicable Days". discount_presets.days smallint[] (1 = Monday ... 7 = Sunday, null = every day).
-- Applied live as migration 237_discount_preset_days. It (1) adds the column and a check, (2) re-creates list_discount_presets with the
-- weekday test, (3) re-creates list_discount_presets_admin with a trailing days column, (4) drops the 10-argument save_discount_preset
-- and re-creates it with a trailing p_days smallint[] argument (stored as null when all 7 days are chosen), writing days to the audit row.
-- The bodies are the 152 versions plus those changes; see the live database (pg_get_functiondef) for the exact text.
-- Rollback: 237_discount_preset_days_rollback.sql.
alter table public.discount_presets add column if not exists days smallint[];
alter table public.discount_presets drop constraint if exists discount_presets_days_check;
alter table public.discount_presets add constraint discount_presets_days_check check (days is null or (cardinality(days) between 1 and 7 and days <@ array[1,2,3,4,5,6,7]::smallint[]));
