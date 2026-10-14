-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260925091943, name 'sna_pos_28_fix_upi_check'. This is the SQL that actually ran.

alter table public.payment_methods drop constraint if exists payment_methods_upi_id_check;
alter table public.payment_methods add constraint payment_methods_upi_id_check
  check (upi_id is null or upi_id ~ '^[A-Za-z0-9._-]{2,200}@[A-Za-z][A-Za-z0-9]{1,63}$');
