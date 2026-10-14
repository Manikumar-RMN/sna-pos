-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928145052, name '069_push_gone_strict'. This is the SQL that actually ran.

create or replace function public.push_gone(p_secret text, p_endpoints text[]) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text;
begin
  select decrypted_secret into v from vault.decrypted_secrets where name = 'push_secret';
  if v is null or p_secret is null or p_secret is distinct from v then raise exception 'Not allowed.'; end if;
  delete from public.push_subscriptions where endpoint = any(p_endpoints);
end $$;
revoke all on function public.push_gone(text, text[]) from public;
grant execute on function public.push_gone(text, text[]) to anon, authenticated;
