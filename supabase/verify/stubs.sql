-- Stand-ins for what a Supabase project provides, so the migrations can run on a plain PostgreSQL.
-- Test environment only. Never run this on a real Supabase project.
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema if not exists extensions; grant usage on schema extensions to public;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create schema auth; create schema vault; create schema net; create schema cron;
create function auth.uid() returns uuid language sql as 'select null::uuid';
create function auth.role() returns text language sql as 'select null::text';
create function auth.jwt() returns jsonb language sql as 'select null::jsonb';
create table auth.users(id uuid primary key default gen_random_uuid(), email text, encrypted_password text, raw_user_meta_data jsonb, raw_app_meta_data jsonb, email_confirmed_at timestamptz, created_at timestamptz default now(), updated_at timestamptz default now(), phone text, aud text, role text, instance_id uuid, confirmation_token text, recovery_token text, email_change_token_new text, email_change text, last_sign_in_at timestamptz, is_sso_user boolean default false, deleted_at timestamptz, banned_until timestamptz);
create table auth.identities(id uuid default gen_random_uuid(), user_id uuid, identity_data jsonb, provider text, provider_id text, last_sign_in_at timestamptz, created_at timestamptz, updated_at timestamptz);
create table vault.secrets(id uuid primary key default gen_random_uuid(), name text unique, secret text, description text);
create view vault.decrypted_secrets as select id, name, secret as decrypted_secret from vault.secrets;
create function vault.create_secret(s text, n text default null, d text default null) returns uuid language sql as 'insert into vault.secrets(name,secret,description) values (n,s,d) returning id';
create function net.http_post(url text, body jsonb default null, params jsonb default null, headers jsonb default null, timeout_milliseconds int default 5000) returns bigint language sql as 'select 1::bigint';
create table cron.job(jobid serial, jobname text, schedule text, command text);
create function cron.schedule(a text, b text, c text) returns bigint language sql as 'insert into cron.job(jobname,schedule,command) values (a,b,c); select 1::bigint';
create function cron.unschedule(a text) returns boolean language sql as 'select true';
