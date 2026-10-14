-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928102335, name '056_feature_grants'. This is the SQL that actually ran.

grant execute on function app.feature_on(uuid,text), app.sna_staff_id() to authenticated;
