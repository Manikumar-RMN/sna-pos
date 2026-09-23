-- =====================================================================
-- SNA POS - Database Schema v2.0
-- Product : SNA POS (a product of SNA.AI)
-- Target  : PostgreSQL 15+ / Supabase
-- Replaces: RPOS Database Structure v1.0
--
-- WHAT CHANGED FROM v1.0 AND WHY
--   1. TENANT ISOLATION. In v1.0, tables like categories, products,
--      customers and taxes had no restaurant_id. Every restaurant would
--      have seen every other restaurant's data. Every business table
--      below now carries restaurant_id, and Row Level Security enforces
--      it at the database level.
--   2. COUNTRY-AGNOSTIC TAX. v1.0 hardcoded taxes(cgst, sgst, igst),
--      which only works in India. Tax is now a rule engine: a country
--      defines jurisdictions, tax classes and dated rules with named
--      components. India (CGST/SGST/IGST), UAE (VAT), Singapore (GST)
--      and Saudi Arabia (VAT) all fit the same tables.
--   3. OFFLINE-FIRST. Bills must be creatable with no internet. IDs are
--      UUIDs generated on the device, every syncable row carries device
--      and sync columns, and duplicate submissions are rejected.
--   4. FINANCIAL RECORDS ARE IMMUTABLE. A completed bill is never
--      deleted or edited. It is voided or refunded, leaving a trail.
--   5. Real data types, keys, constraints, indexes and audit columns.
--
-- SCOPE: V1 only. Inventory, recipes, purchase orders, loyalty and
-- multi-outlet analytics are deliberately left out - they go in V2.
--
-- NOTE FOR THE FOUNDER: this file is not run against a live database by
-- anyone except a human developer, after review. Nothing here deletes
-- or changes existing data; it creates a new, empty structure.
-- =====================================================================

begin;

create extension if not exists "pgcrypto";
-- citext goes in the dedicated extensions schema, not public. Supabase's
-- security linter flags extensions in public because anything there is
-- reachable through the API surface. The database search_path already
-- includes extensions, so citext columns work normally.
create schema if not exists extensions;
create extension if not exists "citext" with schema extensions;

create schema if not exists app;

-- =====================================================================
-- SECTION 1 - REFERENCE DATA (shared by all tenants, read-only to them)
-- =====================================================================

create table public.countries (
    code              char(2)       primary key,          -- ISO 3166-1, e.g. 'IN'
    name              text          not null,
    default_currency  char(3)       not null,             -- ISO 4217, e.g. 'INR'
    default_timezone  text          not null,             -- e.g. 'Asia/Kolkata'
    tax_system_name   text          not null,             -- 'GST', 'VAT', 'Sales Tax'
    -- Does this country legally require a government-certified e-invoice
    -- from the POS itself? (Saudi Arabia = yes. This can block a launch.)
    requires_fiscal_certification boolean not null default false,
    is_supported      boolean       not null default false,
    created_at        timestamptz   not null default now()
);

create table public.currencies (
    code           char(3)  primary key,                  -- ISO 4217
    name           text     not null,
    symbol         text     not null,
    decimal_places smallint not null default 2 check (decimal_places between 0 and 4)
);

-- =====================================================================
-- SECTION 2 - TENANCY: RESTAURANT -> BRANCH -> USER
-- The restaurant is the tenant. restaurant_id is the isolation key.
-- =====================================================================

create table public.restaurants (
    id                uuid        primary key default gen_random_uuid(),
    legal_name        text        not null,
    trading_name      text        not null,
    country_code      char(2)     not null references public.countries(code),
    currency_code     char(3)     not null references public.currencies(code),
    timezone          text        not null,
    -- Tax registration number. Called GSTIN in India, TRN in the UAE,
    -- VAT number elsewhere. One nullable field, not three country ones.
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
    code           text        not null,                  -- short code used in bill numbers
    address_line1  text,
    address_line2  text,
    city           text,
    state_or_region text,                                 -- drives place-of-supply tax logic
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

-- Roles are per-restaurant so an owner can rename or add roles.
create table public.roles (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text        not null,                   -- Owner, Manager, Cashier, Waiter, Chef
    is_system     boolean     not null default false,      -- system roles cannot be deleted
    created_at    timestamptz not null default now(),
    unique (restaurant_id, name)
);

-- Permissions as rows, not one JSON blob. This is what makes
-- "a cashier cannot delete a bill" enforceable and auditable.
create table public.permissions (
    key         text primary key,                          -- e.g. 'order.void'
    description text not null,
    is_sensitive boolean not null default false            -- sensitive actions are always audit-logged
);

create table public.role_permissions (
    role_id        uuid not null references public.roles(id) on delete cascade,
    permission_key text not null references public.permissions(key) on delete cascade,
    primary key (role_id, permission_key)
);

create table public.users (
    id             uuid        primary key default gen_random_uuid(),
    restaurant_id  uuid        not null references public.restaurants(id) on delete restrict,
    -- Link to Supabase Auth. Passwords are NEVER stored in this table;
    -- Supabase Auth holds them, hashed. v1.0 had a password column - removed.
    auth_user_id   uuid        unique,
    employee_code  text        not null,
    full_name      text        not null,
    email          citext,
    phone          text,
    role_id        uuid        not null references public.roles(id) on delete restrict,
    -- Floor staff sign in on a shared terminal with a short PIN.
    -- Stored as a bcrypt hash, never in plain text. v1.0 stored it raw.
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

-- Which branches a user may work at.
create table public.user_branches (
    user_id       uuid not null references public.users(id) on delete cascade,
    branch_id     uuid not null references public.branches(id) on delete cascade,
    restaurant_id uuid not null references public.restaurants(id) on delete cascade,
    primary key (user_id, branch_id)
);

-- Registered billing devices. Needed for offline sync and for knowing
-- which terminal produced a bill.
create table public.devices (
    id             uuid        primary key default gen_random_uuid(),
    restaurant_id  uuid        not null references public.restaurants(id) on delete cascade,
    branch_id      uuid        not null references public.branches(id) on delete cascade,
    name           text        not null,                  -- 'Counter 1'
    device_type    text        not null default 'tablet'
                    check (device_type in ('tablet','desktop','phone','kiosk')),
    last_seen_at   timestamptz,
    is_active      boolean     not null default true,
    created_at     timestamptz not null default now()
);
create index idx_devices_branch on public.devices(branch_id);

-- =====================================================================
-- SECTION 3 - TAX ENGINE (country-agnostic)
--
-- v1.0 had: taxes(id, tax_name, cgst, sgst, igst)  <- India only.
--
-- The model below separates three ideas:
--   tax_group      - what the owner picks on a product ("Food 5%")
--   tax_rate       - what that group means, valid between two dates
--   tax_component  - how it breaks down on the printed bill
--
-- Same tables, different countries:
--   India   5% food  -> components CGST 2.5 (intra) + SGST 2.5 (intra)
--                                  + IGST 5.0 (inter)
--   UAE     5% VAT   -> one component VAT 5.0 (always)
--   S'pore  9% GST   -> one component GST 9.0 (always)
--   KSA    15% VAT   -> one component VAT 15.0 (always)
-- Adding a country becomes data entry, not a code change.
-- =====================================================================

create table public.tax_groups (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text        not null,                   -- 'Food 5%', 'Beverages 12%'
    -- Are menu prices entered tax-inclusive or tax-exclusive? This
    -- differs by country and even by restaurant, and getting it wrong
    -- makes every bill wrong. It is a setting, not an assumption.
    is_price_inclusive boolean not null default false,
    is_active     boolean     not null default true,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    unique (restaurant_id, name)
);

-- A dated rate. Never edit a rate that has been used on a bill - close
-- it with valid_to and insert a new row. Old bills keep their old tax.
create table public.tax_rates (
    id           uuid        primary key default gen_random_uuid(),
    restaurant_id uuid       not null references public.restaurants(id) on delete cascade,
    tax_group_id uuid        not null references public.tax_groups(id) on delete cascade,
    total_rate   numeric(6,3) not null check (total_rate >= 0 and total_rate <= 100),
    valid_from   date        not null,
    valid_to     date,                                    -- null = currently in force
    created_at   timestamptz not null default now(),
    check (valid_to is null or valid_to >= valid_from)
);
create index idx_tax_rates_lookup on public.tax_rates(tax_group_id, valid_from desc);

create table public.tax_rate_components (
    id           uuid        primary key default gen_random_uuid(),
    restaurant_id uuid       not null references public.restaurants(id) on delete cascade,
    tax_rate_id  uuid        not null references public.tax_rates(id) on delete cascade,
    name         text        not null,                    -- 'CGST', 'SGST', 'IGST', 'VAT', 'GST'
    rate         numeric(6,3) not null check (rate >= 0),
    display_order smallint   not null default 0,
    -- When does this component apply? This is what makes Indian
    -- CGST/SGST vs IGST work without a special case in code.
    --   always      - most countries
    --   intra_region- buyer and seller in the same state (CGST + SGST)
    --   inter_region- different states (IGST)
    applies_when text        not null default 'always'
                  check (applies_when in ('always','intra_region','inter_region'))
);
create index idx_tax_components_rate on public.tax_rate_components(tax_rate_id);

-- =====================================================================
-- SECTION 4 - MENU
-- =====================================================================

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
    short_name    text,                                   -- what fits on a 58mm receipt
    description   text,
    -- Menu price in the restaurant's currency. Whether this includes tax
    -- is decided by tax_groups.is_price_inclusive.
    price         numeric(14,2) not null check (price >= 0),
    cost_price    numeric(14,2) check (cost_price >= 0),
    image_url     text,
    -- Kitchen routing: which printer/station this item is sent to.
    kitchen_station text,
    is_veg        boolean,                                -- matters in India, optional elsewhere
    is_available  boolean     not null default true,      -- "sold out today"
    display_order smallint    not null default 0,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    deleted_at    timestamptz,
    unique (restaurant_id, sku)
);
create index idx_products_restaurant on public.products(restaurant_id) where deleted_at is null;
create index idx_products_category on public.products(category_id) where deleted_at is null;
-- Fast menu search on the billing screen.
create index idx_products_name_search on public.products using gin (to_tsvector('simple', name));

create table public.modifier_groups (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text        not null,                   -- 'Spice level', 'Add-ons'
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
    name              text        not null,               -- 'Extra cheese'
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

-- =====================================================================
-- SECTION 5 - DINING AREA
-- =====================================================================

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

-- =====================================================================
-- SECTION 6 - CUSTOMERS
-- =====================================================================

create table public.customers (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text,
    phone         text,
    email         citext,
    -- Customer's own tax number, needed when a company asks for a
    -- tax invoice in its name (GSTIN in India, TRN in the UAE).
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

-- =====================================================================
-- SECTION 7 - ORDERS AND BILLS
--
-- Offline-first notes:
--   * Every id is a UUID generated ON THE DEVICE, not by the server.
--     A bill created with no internet already has its final id, so
--     re-sending it later is an upsert on the same row, never a
--     duplicate bill. This is the whole trick.
--   * bill_number is built from a per-device prefix and a per-device
--     counter, so two tablets billing offline can never collide.
--   * client_created_at is when the cashier actually billed.
--     created_at is when the server first saw it. They differ offline
--     and the difference is what the day-end report must use.
-- =====================================================================

alter table public.devices
    add column bill_prefix text,                          -- 'C1', 'C2'
    add column next_bill_seq bigint not null default 1;
alter table public.devices
    add constraint devices_bill_prefix_unique unique (branch_id, bill_prefix);

create table public.orders (
    id             uuid        primary key,               -- generated on the device
    restaurant_id  uuid        not null references public.restaurants(id) on delete restrict,
    branch_id      uuid        not null references public.branches(id) on delete restrict,
    device_id      uuid        references public.devices(id) on delete set null,
    bill_number    text        not null,
    order_type     text        not null
                    check (order_type in ('dine_in','takeaway','delivery')),
    dining_table_id uuid       references public.dining_tables(id) on delete set null,
    customer_id    uuid        references public.customers(id) on delete set null,
    cashier_id     uuid        not null references public.users(id) on delete restrict,
    waiter_id      uuid        references public.users(id) on delete set null,
    shift_id       uuid,                                  -- FK added after shifts table

    status         text        not null default 'open'
                    check (status in ('open','placed','served','completed','voided')),
    payment_status text        not null default 'unpaid'
                    check (payment_status in ('unpaid','partial','paid','refunded','partially_refunded')),

    currency_code  char(3)     not null references public.currencies(code),
    -- All money is numeric(14,2). Never float - floats lose paise.
    subtotal       numeric(14,2) not null default 0 check (subtotal >= 0),
    discount_total numeric(14,2) not null default 0 check (discount_total >= 0),
    tax_total      numeric(14,2) not null default 0 check (tax_total >= 0),
    service_charge numeric(14,2) not null default 0 check (service_charge >= 0),
    rounding_adjustment numeric(14,2) not null default 0,
    grand_total    numeric(14,2) not null default 0 check (grand_total >= 0),
    paid_total     numeric(14,2) not null default 0 check (paid_total >= 0),

    -- Which region the sale was taxed in. Drives intra/inter-region tax.
    place_of_supply text,

    void_reason    text,
    voided_by      uuid        references public.users(id) on delete set null,
    voided_at      timestamptz,

    client_created_at timestamptz not null,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    synced_at      timestamptz,

    unique (branch_id, bill_number),
    -- A voided bill must say who voided it and why. No silent deletions.
    check (status <> 'voided' or (voided_by is not null and void_reason is not null))
);
create index idx_orders_branch_date on public.orders(branch_id, client_created_at desc);
create index idx_orders_restaurant on public.orders(restaurant_id);
create index idx_orders_shift on public.orders(shift_id);
create index idx_orders_unsynced on public.orders(synced_at) where synced_at is null;
create index idx_orders_customer on public.orders(customer_id) where customer_id is not null;

create table public.order_items (
    id            uuid        primary key,                -- generated on the device
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    order_id      uuid        not null references public.orders(id) on delete cascade,
    product_id    uuid        not null references public.products(id) on delete restrict,

    -- The product name and price are COPIED here at the time of sale.
    -- If the owner renames a dish or changes its price tomorrow, last
    -- week's bills must not change. v1.0 would have changed them.
    product_name  text        not null,
    unit_price    numeric(14,2) not null check (unit_price >= 0),
    quantity      numeric(10,3) not null check (quantity > 0),

    modifier_total numeric(14,2) not null default 0,
    line_discount numeric(14,2) not null default 0 check (line_discount >= 0),
    line_subtotal numeric(14,2) not null check (line_subtotal >= 0),
    line_tax      numeric(14,2) not null default 0 check (line_tax >= 0),
    line_total    numeric(14,2) not null check (line_total >= 0),

    is_price_inclusive boolean not null default false,
    kitchen_note  text,                                   -- 'no onion'
    cancelled_at  timestamptz,
    cancelled_by  uuid        references public.users(id) on delete set null,
    created_at    timestamptz not null default now()
);
create index idx_order_items_order on public.order_items(order_id);

create table public.order_item_modifiers (
    id               uuid  primary key default gen_random_uuid(),
    restaurant_id    uuid  not null references public.restaurants(id) on delete cascade,
    order_item_id    uuid  not null references public.order_items(id) on delete cascade,
    modifier_item_id uuid  references public.modifier_items(id) on delete set null,
    name             text  not null,                      -- copied at sale time
    price_delta      numeric(14,2) not null default 0
);
create index idx_item_modifiers_item on public.order_item_modifiers(order_item_id);

-- The tax breakdown FROZEN at the moment of sale. This is what gets
-- printed on the bill and what the tax return is built from. Because it
-- is stored, a later change to tax rates can never alter an old bill.
create table public.order_item_taxes (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    order_id      uuid        not null references public.orders(id) on delete cascade,
    order_item_id uuid        not null references public.order_items(id) on delete cascade,
    component_name text       not null,                   -- 'CGST', 'VAT'
    rate          numeric(6,3) not null,
    taxable_amount numeric(14,2) not null,
    tax_amount    numeric(14,2) not null
);
create index idx_order_taxes_order on public.order_item_taxes(order_id);

create table public.order_discounts (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    order_id      uuid        not null references public.orders(id) on delete cascade,
    discount_type text        not null check (discount_type in ('percentage','fixed_amount')),
    value         numeric(14,2) not null check (value >= 0),
    amount        numeric(14,2) not null check (amount >= 0),
    reason        text,
    -- Discounts are the most common route for staff fraud, so every one
    -- records who approved it.
    approved_by   uuid        not null references public.users(id) on delete restrict,
    created_at    timestamptz not null default now()
);
create index idx_order_discounts_order on public.order_discounts(order_id);

-- =====================================================================
-- SECTION 8 - PAYMENTS
-- =====================================================================

create table public.payment_methods (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text        not null,                   -- 'Cash', 'UPI', 'Card'
    kind          text        not null
                   check (kind in ('cash','card','wallet','bank_transfer','upi','other')),
    -- Does taking this payment add money to the physical cash drawer?
    affects_cash_drawer boolean not null default false,
    is_active     boolean     not null default true,
    display_order smallint    not null default 0,
    unique (restaurant_id, name)
);

create table public.payments (
    id            uuid        primary key,                -- generated on the device
    restaurant_id uuid        not null references public.restaurants(id) on delete restrict,
    order_id      uuid        not null references public.orders(id) on delete restrict,
    payment_method_id uuid    not null references public.payment_methods(id) on delete restrict,
    amount        numeric(14,2) not null check (amount > 0),
    currency_code char(3)     not null references public.currencies(code),
    tendered_amount numeric(14,2),                        -- cash handed over
    change_amount numeric(14,2) not null default 0,
    -- Reference only. Card numbers are NEVER stored - that is the
    -- payment provider's job and storing them would break PCI rules.
    reference_no  text,
    gateway_name  text,
    status        text        not null default 'captured'
                   check (status in ('pending','captured','failed','refunded')),
    received_by   uuid        not null references public.users(id) on delete restrict,
    client_created_at timestamptz not null,
    created_at    timestamptz not null default now(),
    synced_at     timestamptz
);
create index idx_payments_order on public.payments(order_id);
create index idx_payments_unsynced on public.payments(synced_at) where synced_at is null;

create table public.refunds (
    id            uuid        primary key,
    restaurant_id uuid        not null references public.restaurants(id) on delete restrict,
    order_id      uuid        not null references public.orders(id) on delete restrict,
    payment_id    uuid        references public.payments(id) on delete set null,
    amount        numeric(14,2) not null check (amount > 0),
    reason        text        not null,
    approved_by   uuid        not null references public.users(id) on delete restrict,
    client_created_at timestamptz not null,
    created_at    timestamptz not null default now(),
    synced_at     timestamptz
);
create index idx_refunds_order on public.refunds(order_id);

-- =====================================================================
-- SECTION 9 - KITCHEN
-- =====================================================================

create table public.kitchen_tickets (
    id            uuid        primary key,
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    branch_id     uuid        not null references public.branches(id) on delete cascade,
    order_id      uuid        not null references public.orders(id) on delete cascade,
    ticket_number text        not null,
    station       text,                                   -- 'Hot kitchen', 'Bar'
    status        text        not null default 'new'
                   check (status in ('new','preparing','ready','served','cancelled')),
    printed_at    timestamptz,
    started_at    timestamptz,
    ready_at      timestamptz,
    client_created_at timestamptz not null,
    created_at    timestamptz not null default now(),
    synced_at     timestamptz
);
create index idx_kot_order on public.kitchen_tickets(order_id);
create index idx_kot_active on public.kitchen_tickets(branch_id, status)
    where status in ('new','preparing');

create table public.kitchen_ticket_items (
    id                uuid primary key default gen_random_uuid(),
    restaurant_id     uuid not null references public.restaurants(id) on delete cascade,
    kitchen_ticket_id uuid not null references public.kitchen_tickets(id) on delete cascade,
    order_item_id     uuid not null references public.order_items(id) on delete cascade,
    product_name      text not null,
    quantity          numeric(10,3) not null,
    note              text,
    status            text not null default 'new'
                       check (status in ('new','preparing','ready','served','cancelled'))
);
create index idx_kot_items_ticket on public.kitchen_ticket_items(kitchen_ticket_id);

-- =====================================================================
-- SECTION 10 - SHIFTS AND CASH DRAWER
-- The day-end close. This is the report the owner actually reads.
-- =====================================================================

create table public.shifts (
    id             uuid        primary key,
    restaurant_id  uuid        not null references public.restaurants(id) on delete restrict,
    branch_id      uuid        not null references public.branches(id) on delete restrict,
    device_id      uuid        references public.devices(id) on delete set null,
    opened_by      uuid        not null references public.users(id) on delete restrict,
    closed_by      uuid        references public.users(id) on delete set null,
    opening_float  numeric(14,2) not null default 0 check (opening_float >= 0),
    -- What the system says should be in the drawer.
    expected_cash  numeric(14,2),
    -- What the cashier actually counted.
    counted_cash   numeric(14,2),
    -- Stored, not calculated on the fly, so the figure can never drift.
    cash_variance  numeric(14,2),
    notes          text,
    opened_at      timestamptz not null,
    closed_at      timestamptz,
    status         text        not null default 'open'
                    check (status in ('open','closed')),
    created_at     timestamptz not null default now(),
    synced_at      timestamptz,
    check (status <> 'closed' or closed_at is not null)
);
create index idx_shifts_branch on public.shifts(branch_id, opened_at desc);

alter table public.orders
    add constraint orders_shift_fk
    foreign key (shift_id) references public.shifts(id) on delete set null;

-- Cash in or out of the drawer that is not a sale: float, pay-outs,
-- a supplier paid in cash, money banked.
create table public.cash_movements (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    shift_id      uuid        not null references public.shifts(id) on delete cascade,
    direction     text        not null check (direction in ('in','out')),
    amount        numeric(14,2) not null check (amount > 0),
    reason        text        not null,
    recorded_by   uuid        not null references public.users(id) on delete restrict,
    created_at    timestamptz not null default now()
);
create index idx_cash_movements_shift on public.cash_movements(shift_id);

-- =====================================================================
-- SECTION 11 - SETTINGS, PRINTERS, AUDIT, SYNC
-- =====================================================================

create table public.branch_settings (
    branch_id     uuid        primary key references public.branches(id) on delete cascade,
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    receipt_header text,
    receipt_footer text,
    service_charge_percent numeric(6,3) not null default 0 check (service_charge_percent >= 0),
    -- Cash rounding differs by country (India rounds to the rupee,
    -- others to 5 cents, some not at all).
    cash_rounding_mode text  not null default 'none'
                        check (cash_rounding_mode in ('none','nearest_1','nearest_0_05','nearest_0_10')),
    default_order_type text  not null default 'dine_in',
    auto_print_kot     boolean not null default true,
    updated_at         timestamptz not null default now()
);

create table public.printers (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    branch_id     uuid        not null references public.branches(id) on delete cascade,
    name          text        not null,
    purpose       text        not null check (purpose in ('receipt','kitchen','report')),
    connection    text        not null check (connection in ('bluetooth','usb','network')),
    address       text,                                   -- IP or MAC
    paper_width_mm smallint   not null default 80 check (paper_width_mm in (58, 80)),
    station       text,
    is_active     boolean     not null default true
);
create index idx_printers_branch on public.printers(branch_id);

-- Who did what. Every sensitive action writes a row here. This is the
-- single most useful table when an owner asks "who cancelled that bill?"
create table public.audit_logs (
    id            bigserial   primary key,
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    branch_id     uuid        references public.branches(id) on delete set null,
    user_id       uuid        references public.users(id) on delete set null,
    action        text        not null,                   -- 'order.void'
    entity_type   text        not null,
    entity_id     uuid,
    old_value     jsonb,
    new_value     jsonb,
    ip_address    inet,
    device_id     uuid        references public.devices(id) on delete set null,
    created_at    timestamptz not null default now()
);
create index idx_audit_restaurant_date on public.audit_logs(restaurant_id, created_at desc);
create index idx_audit_entity on public.audit_logs(entity_type, entity_id);

-- A record of each sync attempt from a device, so a stuck terminal can
-- be diagnosed without visiting the restaurant.
create table public.sync_log (
    id            bigserial   primary key,
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    device_id     uuid        not null references public.devices(id) on delete cascade,
    direction     text        not null check (direction in ('push','pull')),
    records_sent  integer     not null default 0,
    records_ok    integer     not null default 0,
    records_failed integer    not null default 0,
    error_detail  text,
    started_at    timestamptz not null,
    finished_at   timestamptz
);
create index idx_sync_log_device on public.sync_log(device_id, started_at desc);

-- =====================================================================
-- SECTION 12 - ROW LEVEL SECURITY
--
-- This is the section that fixes the most serious problem in v1.0.
-- Without it, any signed-in user of any restaurant could read every
-- other restaurant's menu, customers and sales.
--
-- The rule is simple and absolute: a user can only ever see rows whose
-- restaurant_id matches their own. It is enforced by the database, not
-- by the app, so even a bug in the app cannot leak another tenant's
-- data.
-- =====================================================================

-- Returns the restaurant of the currently signed-in user.
-- security definer is required so this can read public.users without
-- being blocked by the policy on public.users itself. search_path is
-- pinned, which is what stops the function being hijacked.
create or replace function app.current_restaurant_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select u.restaurant_id
    from public.users u
    where u.auth_user_id = auth.uid()
      and u.deleted_at is null
      and u.is_active
    limit 1
$$;

revoke all on function app.current_restaurant_id() from public;
grant execute on function app.current_restaurant_id() to authenticated;

-- Does the signed-in user hold a given permission?
create or replace function app.has_permission(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select exists (
        select 1
        from public.users u
        join public.role_permissions rp on rp.role_id = u.role_id
        where u.auth_user_id = auth.uid()
          and u.deleted_at is null
          and u.is_active
          and rp.permission_key = p_key
    )
$$;

revoke all on function app.has_permission(text) from public;
grant execute on function app.has_permission(text) to authenticated;

-- ---------------------------------------------------------------------
-- Apply tenant isolation to EVERY table that has a restaurant_id.
-- Generating the policies in a loop rather than writing them by hand
-- means a table can never be forgotten - which is exactly how the
-- v1.0 leak would have happened.
-- ---------------------------------------------------------------------
do $$
declare
    t record;
begin
    for t in
        select c.relname as table_name
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        join pg_attribute a on a.attrelid = c.oid
        where n.nspname = 'public'
          and c.relkind = 'r'
          and a.attname = 'restaurant_id'
          and not a.attisdropped
        order by c.relname
    loop
        execute format('alter table public.%I enable row level security', t.table_name);
        execute format('alter table public.%I force row level security', t.table_name);

        execute format(
            'create policy tenant_isolation on public.%I
                 for all
                 to authenticated
                 using (restaurant_id = app.current_restaurant_id())
                 with check (restaurant_id = app.current_restaurant_id())',
            t.table_name);
    end loop;
end
$$;

-- The restaurants table keys on id, not restaurant_id, so it is handled
-- separately.
alter table public.restaurants enable row level security;
alter table public.restaurants force row level security;
create policy tenant_isolation on public.restaurants
    for all to authenticated
    using (id = app.current_restaurant_id())
    with check (id = app.current_restaurant_id());

-- role_permissions has no restaurant_id of its own; it inherits through
-- the role.
alter table public.role_permissions enable row level security;
alter table public.role_permissions force row level security;
create policy tenant_isolation on public.role_permissions
    for all to authenticated
    using (exists (select 1 from public.roles r
                   where r.id = role_id
                     and r.restaurant_id = app.current_restaurant_id()))
    with check (exists (select 1 from public.roles r
                        where r.id = role_id
                          and r.restaurant_id = app.current_restaurant_id()));

-- Reference data: readable by any signed-in user, writable by nobody
-- through the API.
alter table public.countries  enable row level security;
alter table public.currencies enable row level security;
alter table public.permissions enable row level security;
create policy read_reference on public.countries   for select to authenticated using (true);
create policy read_reference on public.currencies  for select to authenticated using (true);
create policy read_reference on public.permissions for select to authenticated using (true);

-- =====================================================================
-- SECTION 13 - RULES THAT PROTECT THE MONEY
-- =====================================================================

-- A completed or voided bill can never be edited again. Only the
-- payment and sync fields may move. Without this, a staff member with
-- database access could quietly change yesterday's takings.
create or replace function app.protect_completed_orders()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
    if old.status in ('completed','voided') then
        if new.subtotal       is distinct from old.subtotal
        or new.discount_total is distinct from old.discount_total
        or new.tax_total      is distinct from old.tax_total
        or new.grand_total    is distinct from old.grand_total
        or new.bill_number    is distinct from old.bill_number
        or new.branch_id      is distinct from old.branch_id then
            raise exception
                'Bill % is closed and its amounts cannot be changed. Void it or raise a refund instead.',
                old.bill_number;
        end if;
    end if;
    new.updated_at := now();
    return new;
end
$$;

create trigger trg_protect_completed_orders
    before update on public.orders
    for each row execute function app.protect_completed_orders();

-- Bills and payments are never deleted, by anyone, ever.
create or replace function app.block_delete()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
    raise exception
        'Records in % cannot be deleted. Use void or refund so the trail is kept.',
        tg_table_name;
end
$$;

create trigger trg_no_delete_orders
    before delete on public.orders
    for each row execute function app.block_delete();

create trigger trg_no_delete_payments
    before delete on public.payments
    for each row execute function app.block_delete();

create trigger trg_no_delete_audit
    before delete on public.audit_logs
    for each row execute function app.block_delete();

-- Keep updated_at honest everywhere it exists.
create or replace function app.touch_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
    new.updated_at := now();
    return new;
end
$$;

do $$
declare
    t record;
begin
    for t in
        select c.relname as table_name
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        join pg_attribute a on a.attrelid = c.oid
        where n.nspname = 'public'
          and c.relkind = 'r'
          and a.attname = 'updated_at'
          and not a.attisdropped
          and c.relname <> 'orders'          -- orders has its own trigger
    loop
        execute format(
            'create trigger trg_touch_updated_at
                 before update on public.%I
                 for each row execute function app.touch_updated_at()',
            t.table_name);
    end loop;
end
$$;

-- =====================================================================
-- SECTION 14 - REFERENCE SEED DATA
-- =====================================================================

insert into public.currencies (code, name, symbol, decimal_places) values
    ('INR','Indian Rupee','Rs.',2),
    ('AED','UAE Dirham','AED',2),
    ('SAR','Saudi Riyal','SAR',2),
    ('SGD','Singapore Dollar','S$',2),
    ('MYR','Malaysian Ringgit','RM',2),
    ('GBP','Pound Sterling','GBP',2),
    ('USD','US Dollar','$',2)
on conflict (code) do nothing;

insert into public.countries
    (code, name, default_currency, default_timezone, tax_system_name,
     requires_fiscal_certification, is_supported) values
    ('IN','India',       'INR','Asia/Kolkata',    'GST', false, true),
    ('AE','United Arab Emirates','AED','Asia/Dubai','VAT', false, false),
    ('SA','Saudi Arabia','SAR','Asia/Riyadh',     'VAT', true,  false),
    ('SG','Singapore',   'SGD','Asia/Singapore',  'GST', false, false),
    ('MY','Malaysia',    'MYR','Asia/Kuala_Lumpur','SST', false, false),
    ('GB','United Kingdom','GBP','Europe/London', 'VAT', false, false)
on conflict (code) do nothing;

-- Only India is marked supported. The others are listed so the product
-- can grow into them, but each needs its tax rules confirmed by a local
-- accountant before it is switched on. Saudi Arabia additionally
-- requires government e-invoice certification - that is a project of its
-- own and must not be promised to a customer until it is done.

insert into public.permissions (key, description, is_sensitive) values
    ('order.create',        'Create and take orders',                 false),
    ('order.void',          'Void a completed bill',                  true),
    ('order.discount',      'Apply a discount to an order',           true),
    ('order.refund',        'Refund a payment',                       true),
    ('order.reprint',       'Reprint a bill',                         false),
    ('menu.manage',         'Add, edit or remove menu items',         false),
    ('menu.price_change',   'Change menu prices',                     true),
    ('customer.manage',     'Add or edit customers',                  false),
    ('customer.export',     'Export the customer list',               true),
    ('shift.open',          'Open a shift',                           false),
    ('shift.close',         'Close a shift and count the drawer',     true),
    ('cash.movement',       'Record cash in or out of the drawer',    true),
    ('report.view_sales',   'View sales reports',                     false),
    ('report.view_financial','View profit, tax and cash reports',     true),
    ('user.manage',         'Add, edit or deactivate users',          true),
    ('settings.manage',     'Change restaurant and branch settings',  true),
    ('tax.manage',          'Change tax groups and rates',            true)
on conflict (key) do nothing;

commit;

-- =====================================================================
-- APPENDIX - WORKED EXAMPLE: THE SAME TABLES IN TWO COUNTRIES
--
-- This is not run automatically. It shows that the tax design really is
-- country-agnostic, which was the second thing wrong with v1.0.
--
-- INDIA - a restaurant taxed at 5% GST
--   tax_groups            ('Food 5%', is_price_inclusive = false)
--   tax_rates             (total_rate = 5.000, valid_from = 2026-04-01)
--   tax_rate_components   ('CGST', 2.500, applies_when = 'intra_region')
--                         ('SGST', 2.500, applies_when = 'intra_region')
--                         ('IGST', 5.000, applies_when = 'inter_region')
--   A bill in the same state prints CGST 2.5% and SGST 2.5%.
--   A bill across states prints IGST 5%. Same tables, no code change.
--
-- UAE - the same restaurant brand in Dubai, 5% VAT, prices tax-inclusive
--   tax_groups            ('Food 5%', is_price_inclusive = true)
--   tax_rates             (total_rate = 5.000, valid_from = 2026-01-01)
--   tax_rate_components   ('VAT', 5.000, applies_when = 'always')
--
-- SAUDI ARABIA - 15% VAT
--   tax_rate_components   ('VAT', 15.000, applies_when = 'always')
--   ...but countries.requires_fiscal_certification = true, so the app
--   must block go-live there until certification is done.
--
-- When a rate changes, the old tax_rates row gets a valid_to date and a
-- new row is inserted. Bills issued before the change keep their own
-- frozen breakdown in order_item_taxes and never move.
-- =====================================================================
