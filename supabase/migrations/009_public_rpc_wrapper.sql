-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260923093207, name 'sna_pos_09_public_rpc_wrapper'. This is the SQL that actually ran.

-- Found while wiring up the application: PostgREST (the API the app talks to)
-- only exposes functions in the schemas it is configured for — `public` by
-- default. app.create_restaurant_with_owner is therefore invisible to
-- supabase.rpc(), so the setup screen could never have called it.
--
-- The fix is a thin wrapper in public rather than exposing the whole `app`
-- schema, which would also publish the internal helpers (current_restaurant_id,
-- has_permission, the trigger functions) as callable API endpoints. Keeping
-- `app` private and publishing one named entry point is the smaller surface.
--
-- The wrapper is SECURITY INVOKER: it adds no privileges of its own and simply
-- forwards to the definer function, which does its own auth checks.

create or replace function public.create_restaurant_with_owner(
    p_legal_name    text,
    p_trading_name  text,
    p_country_code  char(2),
    p_owner_name    text,
    p_branch_name   text default 'Main Branch',
    p_branch_code   text default 'MN',
    p_timezone      text default null,
    p_tax_registration_no text default null
)
returns uuid
language sql
security invoker
set search_path = public, pg_temp
as $$
    select app.create_restaurant_with_owner(
        p_legal_name, p_trading_name, p_country_code, p_owner_name,
        p_branch_name, p_branch_code, p_timezone, p_tax_registration_no);
$$;

revoke all on function public.create_restaurant_with_owner(
    text, text, char(2), text, text, text, text, text) from public;
grant execute on function public.create_restaurant_with_owner(
    text, text, char(2), text, text, text, text, text) to authenticated;
