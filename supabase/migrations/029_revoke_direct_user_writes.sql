-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260927043444, name 'sna_pos_29_revoke_direct_user_writes'. This is the SQL that actually ran.

-- Staff records change only through the SECURITY DEFINER functions (invite, PIN,
-- role, access, password). Row Level Security already blocks direct writes; this
-- also removes the table privileges so it cannot be undone by a policy mistake.
revoke insert, update, delete on public.users from anon, authenticated;
revoke insert, update, delete, select on public.pin_sessions from anon, authenticated;
