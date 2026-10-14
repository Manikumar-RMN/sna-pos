-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928094320, name '54_fy_label_search_path'. This is the SQL that actually ran.

alter function app.fy_label(text, date) set search_path to 'public','pg_temp';
