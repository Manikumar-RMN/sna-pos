-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260923074950, name 'sna_pos_01_core'. This is the SQL that actually ran.

-- SNA POS schema v2.0 — part 1 of 4: reference data, tenancy, tax engine, menu, dining, customers
create extension if not exists "pgcrypto";
create extension if not exists "citext";
create schema if not exists app;

create table public.countries (
    code              char(2)       primary key,
    name              text          not null,
    default_currency  char(3)       not null,
    default_timezone  text          not null,
    tax_system_name   text          not null,
    -- Does this country legally require a government-certified e-invoice
    -- from the POS itself? (Saudi Arabia = yes. This can block a launch.)
    requires_fiscal_certification boolean not null default false,
    is_supported      boolean       not null default false,
    created_at        timestamptz   not null default now()
);

create table public.currencies (
    code           char(3)  primary key,
    name           text     not null,
    symbol         text     not null,
    decimal_places smallint not null default 2 check (decimal_places between 0 and 4)
);

-- TENANCY: the restaurant is the tenant. restaurant_id is the isolation key.
create table public.restaurants (
    id                uuid        primary key default gen_random_uuid(),
    legal_name        text        not null,
    trading_name      text        not null,
    country_code      char(2)     not null references public.countries(code),
    currency_code     char(3)     not null references public.currencies(code),
    timezone          text        not null,
    -- GSTIN in India, TRN in the UAE, VAT number elsewhere. One field, not three.
    tax_registration_no text,
    contact_email     citext,
    contact_phone     text,
    logo_url          text,
    subscription_status text      not null default 'trial'
                        check (subscription_status in ('trial','active','past_due','suspended','cancelled')),
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now(),
    deleted_at        timestamptz
);

create table public.branches (
    id             uuid        primary key default gen_random_uuid(),
    restaurant_id  uuid        not null references public.restaurants(id) on delete restrict,
    name           text        not null,
    code           text        not null,
    address_line1  text,
    address_line2  text,
    city           text,
    state_or_region text,
    postal_code    text,
    country_code   char(2)     not null references public.countries(code),
    phone          text,
    timezone       text        not null,
    is_active      boolean     not null default true,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    deleted_at     timestamptz,
    unique (restaurant_id, code)
);
create index idx_branches_restaurant on public.branches(restaurant_id) where deleted_at is null;

create table public.roles (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text        not null,
    is_system     boolean     not null default false,
    created_at    timestamptz not null default now(),
    unique (restaurant_id, name)
);

-- Permissions as rows, not one JSON blob. This is what makes
-- "a cashier cannot delete a bill" enforceable and auditable.
create table public.permissions (
    key         text primary key,
    description text not null,
    is_sensitive boolean not null default false
);

create table public.role_permissions (
    role_id        uuid not null references public.roles(id) on delete cascade,
    permission_key text not null references public.permissions(key) on delete cascade,
    primary key (role_id, permission_key)
);

create table public.users (
    id             uuid        primary key default gen_random_uuid(),
    restaurant_id  uuid        not null references public.restaurants(id) on delete restrict,
    -- Passwords are NEVER stored here; Supabase Auth holds them, hashed.
    auth_user_id   uuid        unique,
    employee_code  text        not null,
    full_name      text        not null,
    email          citext,
    phone          text,
    role_id        uuid        not null references public.roles(id) on delete restrict,
    -- Floor staff sign in on a shared terminal with a short PIN, stored
    -- only as a bcrypt hash, never in plain text.
    pin_hash       text,
    pin_set_at     timestamptz,
    is_active      boolean     not null default true,
    last_login_at  timestamptz,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    deleted_at     timestamptz,
    unique (restaurant_id, employee_code)
);
create index idx_users_restaurant on public.users(restaurant_id) where deleted_at is null;
create index idx_users_auth on public.users(auth_user_id);

create table public.user_branches (
    user_id       uuid not null references public.users(id) on delete cascade,
    branch_id     uuid not null references public.branches(id) on delete cascade,
    restaurant_id uuid not null references public.restaurants(id) on delete cascade,
    primary key (user_id, branch_id)
);

-- Registered billing devices. Needed for offline sync and to know which
-- terminal produced a bill.
create table public.devices (
    id             uuid        primary key default gen_random_uuid(),
    restaurant_id  uuid        not null references public.restaurants(id) on delete cascade,
    branch_id      uuid        not null references public.branches(id) on delete cascade,
    name           text        not null,
    device_type    text        not null default 'tablet'
                    check (device_type in ('tablet','desktop','phone','kiosk')),
    last_seen_at   timestamptz,
    is_active      boolean     not null default true,
    created_at     timestamptz not null default now()
);
create index idx_devices_branch on public.devices(branch_id);

-- TAX ENGINE (country-agnostic).
--   tax_group      - what the owner picks on a product ("Food 5%")
--   tax_rate       - what that group means, valid between two dates
--   tax_component  - how it breaks down on the printed bill
-- India 5% -> CGST 2.5 + SGST 2.5 (intra) or IGST 5.0 (inter)
-- UAE 5% -> one VAT component. Adding a country is data entry, not code.
create table public.tax_groups (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text        not null,
    -- Are menu prices entered tax-inclusive or tax-exclusive? Differs by
    -- country and by restaurant. Getting it wrong makes every bill wrong.
    is_price_inclusive boolean not null default false,
    is_active     boolean     not null default true,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    unique (restaurant_id, name)
);

-- Never edit a rate that has been used on a bill - close it with valid_to
-- and insert a new row. Old bills keep their own frozen breakdown.
create table public.tax_rates (
    id           uuid        primary key default gen_random_uuid(),
    restaurant_id uuid       not null references public.restaurants(id) on delete cascade,
    tax_group_id uuid        not null references public.tax_groups(id) on delete cascade,
    total_rate   numeric(6,3) not null check (total_rate >= 0 and total_rate <= 100),
    valid_from   date        not null,
    valid_to     date,
    created_at   timestamptz not null default now(),
    check (valid_to is null or valid_to >= valid_from)
);
create index idx_tax_rates_lookup on public.tax_rates(tax_group_id, valid_from desc);

create table public.tax_rate_components (
    id           uuid        primary key default gen_random_uuid(),
    restaurant_id uuid       not null references public.restaurants(id) on delete cascade,
    tax_rate_id  uuid        not null references public.tax_rates(id) on delete cascade,
    name         text        not null,
    rate         numeric(6,3) not null check (rate >= 0),
    display_order smallint   not null default 0,
    -- Makes Indian CGST/SGST vs IGST work without a special case in code.
    applies_when text        not null default 'always'
                  check (applies_when in ('always','intra_region','inter_region'))
);
create index idx_tax_components_rate on public.tax_rate_components(tax_rate_id);

-- MENU
create table public.categories (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text        not null,
    image_url     text,
    display_order smallint    not null default 0,
    is_active     boolean     not null default true,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    deleted_at    timestamptz,
    unique (restaurant_id, name)
);
create index idx_categories_restaurant on public.categories(restaurant_id) where deleted_at is null;

create table public.products (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    category_id   uuid        not null references public.categories(id) on delete restrict,
    tax_group_id  uuid        not null references public.tax_groups(id) on delete restrict,
    sku           text,
    barcode       text,
    name          text        not null,
    short_name    text,
    description   text,
    -- Whether this price includes tax is decided by tax_groups.is_price_inclusive.
    price         numeric(14,2) not null check (price >= 0),
    cost_price    numeric(14,2) check (cost_price >= 0),
    image_url     text,
    kitchen_station text,
    is_veg        boolean,
    is_available  boolean     not null default true,
    display_order smallint    not null default 0,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    deleted_at    timestamptz,
    unique (restaurant_id, sku)
);
create index idx_products_restaurant on public.products(restaurant_id) where deleted_at is null;
create index idx_products_category on public.products(category_id) where deleted_at is null;
create index idx_products_name_search on public.products using gin (to_tsvector('simple', name));

create table public.modifier_groups (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text        not null,
    min_select    smallint    not null default 0,
    max_select    smallint    not null default 1,
    is_required   boolean     not null default false,
    created_at    timestamptz not null default now(),
    check (max_select >= min_select)
);

create table public.modifier_items (
    id                uuid        primary key default gen_random_uuid(),
    restaurant_id     uuid        not null references public.restaurants(id) on delete cascade,
    modifier_group_id uuid        not null references public.modifier_groups(id) on delete cascade,
    name              text        not null,
    price_delta       numeric(14,2) not null default 0,
    display_order     smallint    not null default 0,
    is_active         boolean     not null default true
);

create table public.product_modifier_groups (
    product_id        uuid not null references public.products(id) on delete cascade,
    modifier_group_id uuid not null references public.modifier_groups(id) on delete cascade,
    restaurant_id     uuid not null references public.restaurants(id) on delete cascade,
    primary key (product_id, modifier_group_id)
);

-- DINING AREA
create table public.floors (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    branch_id     uuid        not null references public.branches(id) on delete cascade,
    name          text        not null,
    display_order smallint    not null default 0
);

create table public.dining_tables (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    branch_id     uuid        not null references public.branches(id) on delete cascade,
    floor_id      uuid        references public.floors(id) on delete set null,
    table_number  text        not null,
    seats         smallint    not null default 4 check (seats > 0),
    status        text        not null default 'free'
                   check (status in ('free','occupied','reserved','cleaning')),
    is_active     boolean     not null default true,
    updated_at    timestamptz not null default now(),
    unique (branch_id, table_number)
);
create index idx_tables_branch on public.dining_tables(branch_id);

-- CUSTOMERS
create table public.customers (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text,
    phone         text,
    email         citext,
    -- The customer's own tax number, for a company asking for a tax invoice.
    tax_registration_no text,
    date_of_birth date,
    notes         text,
    -- Consent, required under India's DPDP Act 2023 and under GDPR.
    marketing_consent boolean  not null default false,
    consent_given_at  timestamptz,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    deleted_at    timestamptz,
    unique (restaurant_id, phone)
);
create index idx_customers_restaurant on public.customers(restaurant_id) where deleted_at is null;
create index idx_customers_phone on public.customers(restaurant_id, phone) where deleted_at is null;
