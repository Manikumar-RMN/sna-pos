-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928175309, name '072_session_id_no_fk'. This is the SQL that actually ran.

-- Bills keep the session name and id as they were; editing sessions never touches old bills.
alter table public.orders drop constraint if exists orders_session_id_fkey;
