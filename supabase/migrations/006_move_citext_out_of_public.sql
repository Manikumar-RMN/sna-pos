-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260923075228, name 'sna_pos_06_move_citext_out_of_public'. This is the SQL that actually ran.

-- Supabase's security linter flags extensions installed in the public schema:
-- anything in public is reachable through the API surface, so extension
-- functions belong in the dedicated extensions schema instead.
-- The database search_path already includes extensions, so existing citext
-- columns keep working.
alter extension citext set schema extensions;
