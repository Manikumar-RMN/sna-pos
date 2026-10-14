-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260925091801, name 'sna_pos_25_device_id_execute'. This is the SQL that actually ran.

grant execute on function app.device_id() to authenticated;
