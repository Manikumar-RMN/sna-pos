-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260923075047, name 'sna_pos_02_orders_payments'. This is the SQL that actually ran.

-- SNA POS schema v2.0 — part 2 of 4: orders, payments, kitchen, shifts, audit, sync
--
-- Offline-first notes:
--   * Every id is a UUID generated ON THE DEVICE, not by the server. A bill
--     created with no internet already has its final id, so re-sending it
--     later updates that same row and never creates a duplicate bill.
--   * bill_number uses a per-device prefix and counter, so two tablets
--     billing offline can never collide.
--   * client_created_at is when the cashier billed; created_at is when the
--     server first saw it. Offline these differ, and the day-end report
--     must use the first one.

alter table public.devices
    add column bill_prefix text,
    add column next_bill_seq bigint not null default 1;
alter table public.devices
    add constraint devices_bill_prefix_unique unique (branch_id, bill_prefix);

create table public.orders (
    id             uuid        primary key,
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
    shift_id       uuid,

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
    id            uuid        primary key,
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    order_id      uuid        not null references public.orders(id) on delete cascade,
    product_id    uuid        not null references public.products(id) on delete restrict,

    -- Name and price are COPIED here at the time of sale. If the owner
    -- renames a dish or changes a price tomorrow, last week's bills must
    -- not change.
    product_name  text        not null,
    unit_price    numeric(14,2) not null check (unit_price >= 0),
    quantity      numeric(10,3) not null check (quantity > 0),

    modifier_total numeric(14,2) not null default 0,
    line_discount numeric(14,2) not null default 0 check (line_discount >= 0),
    line_subtotal numeric(14,2) not null check (line_subtotal >= 0),
    line_tax      numeric(14,2) not null default 0 check (line_tax >= 0),
    line_total    numeric(14,2) not null check (line_total >= 0),

    is_price_inclusive boolean not null default false,
    kitchen_note  text,
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
    name             text  not null,
    price_delta      numeric(14,2) not null default 0
);
create index idx_item_modifiers_item on public.order_item_modifiers(order_item_id);

-- The tax breakdown FROZEN at the moment of sale. This is what prints on
-- the bill and what the tax return is built from, so a later change to a
-- rate can never alter an old bill.
create table public.order_item_taxes (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    order_id      uuid        not null references public.orders(id) on delete cascade,
    order_item_id uuid        not null references public.order_items(id) on delete cascade,
    component_name text       not null,
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

-- PAYMENTS
create table public.payment_methods (
    id            uuid        primary key default gen_random_uuid(),
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    name          text        not null,
    kind          text        not null
                   check (kind in ('cash','card','wallet','bank_transfer','upi','other')),
    affects_cash_drawer boolean not null default false,
    is_active     boolean     not null default true,
    display_order smallint    not null default 0,
    unique (restaurant_id, name)
);

create table public.payments (
    id            uuid        primary key,
    restaurant_id uuid        not null references public.restaurants(id) on delete restrict,
    order_id      uuid        not null references public.orders(id) on delete restrict,
    payment_method_id uuid    not null references public.payment_methods(id) on delete restrict,
    amount        numeric(14,2) not null check (amount > 0),
    currency_code char(3)     not null references public.currencies(code),
    tendered_amount numeric(14,2),
    change_amount numeric(14,2) not null default 0,
    -- Reference only. Card numbers are NEVER stored - that is the payment
    -- provider's job and storing them would break PCI rules.
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

-- KITCHEN
create table public.kitchen_tickets (
    id            uuid        primary key,
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    branch_id     uuid        not null references public.branches(id) on delete cascade,
    order_id      uuid        not null references public.orders(id) on delete cascade,
    ticket_number text        not null,
    station       text,
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

-- SHIFTS AND CASH DRAWER — the day-end close the owner actually reads.
create table public.shifts (
    id             uuid        primary key,
    restaurant_id  uuid        not null references public.restaurants(id) on delete restrict,
    branch_id      uuid        not null references public.branches(id) on delete restrict,
    device_id      uuid        references public.devices(id) on delete set null,
    opened_by      uuid        not null references public.users(id) on delete restrict,
    closed_by      uuid        references public.users(id) on delete set null,
    opening_float  numeric(14,2) not null default 0 check (opening_float >= 0),
    expected_cash  numeric(14,2),
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

-- SETTINGS, PRINTERS, AUDIT, SYNC
create table public.branch_settings (
    branch_id     uuid        primary key references public.branches(id) on delete cascade,
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    receipt_header text,
    receipt_footer text,
    service_charge_percent numeric(6,3) not null default 0 check (service_charge_percent >= 0),
    -- Cash rounding differs by country.
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
    address       text,
    paper_width_mm smallint   not null default 80 check (paper_width_mm in (58, 80)),
    station       text,
    is_active     boolean     not null default true
);
create index idx_printers_branch on public.printers(branch_id);

-- Who did what. The most useful table when an owner asks "who cancelled
-- that bill?"
create table public.audit_logs (
    id            bigserial   primary key,
    restaurant_id uuid        not null references public.restaurants(id) on delete cascade,
    branch_id     uuid        references public.branches(id) on delete set null,
    user_id       uuid        references public.users(id) on delete set null,
    action        text        not null,
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

-- A record of each sync attempt, so a stuck terminal can be diagnosed
-- without visiting the restaurant.
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
