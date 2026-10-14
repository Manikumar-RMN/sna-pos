-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260923075127, name 'sna_pos_04_reference_seed'. This is the SQL that actually ran.

-- SNA POS schema v2.0 — part 4 of 4: reference seed data

insert into public.currencies (code, name, symbol, decimal_places) values
    ('INR','Indian Rupee','Rs.',2),
    ('AED','UAE Dirham','AED',2),
    ('SAR','Saudi Riyal','SAR',2),
    ('SGD','Singapore Dollar','S$',2),
    ('MYR','Malaysian Ringgit','RM',2),
    ('GBP','Pound Sterling','GBP',2),
    ('USD','US Dollar','$',2)
on conflict (code) do nothing;

-- Only India is marked supported. The others are listed so the product can
-- grow into them, but each needs its tax rules confirmed by a local
-- accountant before it is switched on. Saudi Arabia additionally requires
-- government e-invoice certification - a project of its own, which must not
-- be promised to a customer until it is done.
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
