-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260925091846, name 'sna_pos_26_hide_pin_hash'. This is the SQL that actually ran.

-- Nobody reads PIN fingerprints through the API; only database functions use them.
revoke select on public.users from anon, authenticated, sna_pos_agent;
grant select (id, restaurant_id, auth_user_id, employee_code, full_name, email, phone, role_id, pin_set_at,
              is_active, last_login_at, created_at, updated_at, deleted_at, must_change_password)
  on public.users to authenticated, sna_pos_agent;
revoke update (pin_hash) on public.users from anon, authenticated;
