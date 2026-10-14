-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260923075112, name 'sna_pos_03_row_level_security'. This is the SQL that actually ran.

-- SNA POS schema v2.0 — part 3 of 4: Row Level Security and the rules that protect the money.
--
-- The rule is simple and absolute: a user can only ever see rows whose
-- restaurant_id matches their own, enforced by the database rather than
-- the app, so even a bug in the app cannot leak another tenant's data.

-- Returns the restaurant of the currently signed-in user. security definer
-- is required so this can read public.users without being blocked by the
-- policy on public.users itself; search_path is pinned, which is what stops
-- the function being hijacked.
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

-- Apply tenant isolation to EVERY table that has a restaurant_id.
-- Generating the policies in a loop rather than by hand means a table can
-- never be forgotten - which is exactly how a leak would happen.
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

-- restaurants keys on id, not restaurant_id.
alter table public.restaurants enable row level security;
alter table public.restaurants force row level security;
create policy tenant_isolation on public.restaurants
    for all to authenticated
    using (id = app.current_restaurant_id())
    with check (id = app.current_restaurant_id());

-- role_permissions has no restaurant_id; it inherits through the role.
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

-- RULES THAT PROTECT THE MONEY

-- A completed or voided bill can never be edited again. Without this, a
-- staff member with database access could quietly change yesterday's takings.
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

-- Bills, payments and the audit trail are never deleted, by anyone, ever.
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
          and c.relname <> 'orders'
    loop
        execute format(
            'create trigger trg_touch_updated_at
                 before update on public.%I
                 for each row execute function app.touch_updated_at()',
            t.table_name);
    end loop;
end
$$;
