-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260923092831, name 'sna_pos_08_grant_app_schema_usage'. This is the SQL that actually ran.

-- Bug found by testing: signed-in users were granted EXECUTE on the app.*
-- functions but never USAGE on the app schema itself, so any direct call
-- from the application failed with "permission denied for schema app".
-- Row Level Security still worked, because policy expressions are evaluated
-- with the table owner's rights rather than the caller's - which is exactly
-- why this stayed hidden until a function was called directly.
--
-- USAGE on a schema only allows referring to objects inside it; each
-- function's own EXECUTE grant still decides what can actually be run, and
-- those remain restricted to the two helpers plus this bootstrap function.
grant usage on schema app to authenticated;
