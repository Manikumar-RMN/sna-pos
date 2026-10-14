-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20261007095103, name 'ai_employee_mvp_schema'. This is the SQL that actually ran.

create extension if not exists pgcrypto;

create table if not exists public.businesses (
 id uuid primary key default gen_random_uuid(),
 name text not null,
 industry text not null default 'real_estate',
 city text,
 created_at timestamptz not null default now()
);

create table if not exists public.ai_employees (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 name text not null,
 role text not null default 'sales',
 system_prompt text,
 status text not null default 'online',
 created_at timestamptz not null default now()
);

create table if not exists public.leads (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 name text not null,
 phone text,
 source text,
 requirement text,
 budget text,
 timeline text,
 score integer not null default 0 check (score between 0 and 100),
 status text not null default 'cold',
 next_action text,
 notes text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table if not exists public.properties (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 project_name text not null,
 location text,
 property_type text,
 bedrooms integer,
 price text,
 availability text,
 details text,
 created_at timestamptz not null default now()
);

create table if not exists public.interactions (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 lead_id uuid references public.leads(id) on delete set null,
 channel text not null,
 direction text,
 summary text,
 outcome text,
 created_at timestamptz not null default now()
);

create table if not exists public.appointments (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 lead_id uuid references public.leads(id) on delete cascade,
 appointment_type text not null default 'site_visit',
 scheduled_at timestamptz not null,
 status text not null default 'scheduled',
 notes text,
 created_at timestamptz not null default now()
);

create table if not exists public.knowledge_items (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 category text not null,
 title text not null,
 content text not null,
 active boolean not null default true,
 created_at timestamptz not null default now()
);

create index if not exists leads_business_status_idx on public.leads(business_id,status);
create index if not exists leads_business_created_idx on public.leads(business_id,created_at desc);
create index if not exists properties_business_idx on public.properties(business_id);
create index if not exists interactions_lead_idx on public.interactions(lead_id,created_at desc);
create index if not exists appointments_business_idx on public.appointments(business_id,scheduled_at);

alter table public.businesses enable row level security;
alter table public.ai_employees enable row level security;
alter table public.leads enable row level security;
alter table public.properties enable row level security;
alter table public.interactions enable row level security;
alter table public.appointments enable row level security;
alter table public.knowledge_items enable row level security;
