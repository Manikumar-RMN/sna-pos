-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260923092805, name 'sna_pos_07_restaurant_bootstrap'. This is the SQL that actually ran.

-- SNA POS — turning a fresh signup into a working restaurant.
--
-- A new owner signs up through Supabase Auth and then has nothing: no
-- restaurant, no roles, no menu, no way to bill. This function creates the
-- whole starting state in one transaction, so a half-built restaurant can
-- never exist.
--
-- It is SECURITY DEFINER because it must write rows for a user who does not
-- yet pass any tenant policy (they have no restaurant to belong to). That
-- makes it the most security-sensitive function in the product, so it:
--   * refuses unless there is a signed-in user
--   * refuses if that user already belongs to a restaurant
--   * pins search_path so it cannot be hijacked
--   * takes the caller's identity from auth.uid(), never from an argument

create or replace function app.create_restaurant_with_owner(
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
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_auth_uid    uuid := auth.uid();
    v_country     public.countries%rowtype;
    v_restaurant  uuid;
    v_branch      uuid;
    v_owner_role  uuid;
    v_manager     uuid;
    v_cashier     uuid;
    v_waiter      uuid;
    v_chef        uuid;
    v_user        uuid;
    v_tz          text;
    v_food_group  uuid;
    v_pack_group  uuid;
    v_food_rate   uuid;
    v_pack_rate   uuid;
begin
    if v_auth_uid is null then
        raise exception 'You must be signed in to create a restaurant.';
    end if;

    if exists (select 1 from public.users u
               where u.auth_user_id = v_auth_uid and u.deleted_at is null) then
        raise exception 'This account already belongs to a restaurant.';
    end if;

    select * into v_country from public.countries where code = p_country_code;
    if not found then
        raise exception 'Unknown country code: %', p_country_code;
    end if;
    if not v_country.is_supported then
        raise exception
            'SNA POS is not available in % yet. Its tax rules must be confirmed locally first.',
            v_country.name;
    end if;

    v_tz := coalesce(p_timezone, v_country.default_timezone);

    insert into public.restaurants
        (legal_name, trading_name, country_code, currency_code, timezone, tax_registration_no)
    values
        (p_legal_name, p_trading_name, p_country_code, v_country.default_currency,
         v_tz, p_tax_registration_no)
    returning id into v_restaurant;

    insert into public.branches
        (restaurant_id, name, code, country_code, timezone)
    values
        (v_restaurant, p_branch_name, p_branch_code, p_country_code, v_tz)
    returning id into v_branch;

    -- Default roles. is_system marks the ones that cannot be deleted.
    insert into public.roles (restaurant_id, name, is_system) values
        (v_restaurant, 'Owner',   true)  returning id into v_owner_role;
    insert into public.roles (restaurant_id, name, is_system) values
        (v_restaurant, 'Manager', true)  returning id into v_manager;
    insert into public.roles (restaurant_id, name, is_system) values
        (v_restaurant, 'Cashier', true)  returning id into v_cashier;
    insert into public.roles (restaurant_id, name, is_system) values
        (v_restaurant, 'Waiter',  true)  returning id into v_waiter;
    insert into public.roles (restaurant_id, name, is_system) values
        (v_restaurant, 'Chef',    true)  returning id into v_chef;

    -- The Owner holds every permission that exists, including any added later
    -- by a future migration.
    insert into public.role_permissions (role_id, permission_key)
        select v_owner_role, key from public.permissions;

    -- A Manager runs the floor but cannot change the company's tax setup or
    -- reconfigure the AI agent.
    insert into public.role_permissions (role_id, permission_key)
        select v_manager, key from public.permissions
        where key not in ('tax.manage', 'settings.manage', 'agent.configure');

    -- A Cashier bills and takes money. They cannot void a bill, discount
    -- without approval, change a price, see profit, or export customers -
    -- the four routes by which till fraud usually happens.
    insert into public.role_permissions (role_id, permission_key) values
        (v_cashier, 'order.create'),
        (v_cashier, 'order.reprint'),
        (v_cashier, 'customer.manage'),
        (v_cashier, 'shift.open'),
        (v_cashier, 'report.view_sales'),
        (v_cashier, 'agent.use');

    insert into public.role_permissions (role_id, permission_key) values
        (v_waiter, 'order.create'),
        (v_waiter, 'customer.manage');

    -- A Chef only sees the kitchen display. No money permissions at all.
    insert into public.role_permissions (role_id, permission_key) values
        (v_chef, 'order.reprint');

    insert into public.users
        (restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
    values
        (v_restaurant, v_auth_uid, 'EMP001', p_owner_name, v_owner_role,
         (select email from auth.users where id = v_auth_uid))
    returning id into v_user;

    insert into public.user_branches (user_id, branch_id, restaurant_id)
    values (v_user, v_branch, v_restaurant);

    -- Tax setup, built from the country rather than hardcoded. India splits
    -- into CGST/SGST within a state and IGST across states; everywhere else
    -- starts with a single component named after that country's tax system.
    insert into public.tax_groups (restaurant_id, name, is_price_inclusive)
    values (v_restaurant, 'Food 5%', false) returning id into v_food_group;
    insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
    values (v_restaurant, v_food_group, 5.000, current_date) returning id into v_food_rate;

    insert into public.tax_groups (restaurant_id, name, is_price_inclusive)
    values (v_restaurant, 'Packaged 12%', false) returning id into v_pack_group;
    insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
    values (v_restaurant, v_pack_group, 12.000, current_date) returning id into v_pack_rate;

    if p_country_code = 'IN' then
        insert into public.tax_rate_components
            (restaurant_id, tax_rate_id, name, rate, applies_when, display_order) values
            (v_restaurant, v_food_rate, 'CGST', 2.500, 'intra_region', 1),
            (v_restaurant, v_food_rate, 'SGST', 2.500, 'intra_region', 2),
            (v_restaurant, v_food_rate, 'IGST', 5.000, 'inter_region', 3),
            (v_restaurant, v_pack_rate, 'CGST', 6.000, 'intra_region', 1),
            (v_restaurant, v_pack_rate, 'SGST', 6.000, 'intra_region', 2),
            (v_restaurant, v_pack_rate, 'IGST', 12.000,'inter_region', 3);
    else
        insert into public.tax_rate_components
            (restaurant_id, tax_rate_id, name, rate, applies_when, display_order) values
            (v_restaurant, v_food_rate, v_country.tax_system_name, 5.000,  'always', 1),
            (v_restaurant, v_pack_rate, v_country.tax_system_name, 12.000, 'always', 1);
    end if;

    insert into public.payment_methods
        (restaurant_id, name, kind, affects_cash_drawer, display_order) values
        (v_restaurant, 'Cash', 'cash', true,  1),
        (v_restaurant, 'UPI',  'upi',  false, 2),
        (v_restaurant, 'Card', 'card', false, 3);

    insert into public.branch_settings
        (branch_id, restaurant_id, receipt_header, cash_rounding_mode, auto_print_kot)
    values
        (v_branch, v_restaurant, p_trading_name,
         case when p_country_code = 'IN' then 'nearest_1' else 'none' end,
         true);

    insert into public.devices
        (restaurant_id, branch_id, name, device_type, bill_prefix)
    values
        (v_restaurant, v_branch, 'Counter 1', 'tablet', 'C1');

    insert into public.agent_settings (restaurant_id, is_enabled, preferred_language)
    values (v_restaurant, false,
            case when p_country_code = 'IN' then 'en' else 'en' end);

    insert into public.audit_logs
        (restaurant_id, branch_id, user_id, action, entity_type, entity_id,
         actor_type, new_value)
    values
        (v_restaurant, v_branch, v_user, 'restaurant.create', 'restaurants', v_restaurant,
         'user', jsonb_build_object('trading_name', p_trading_name, 'country', p_country_code));

    return v_restaurant;
end
$$;

revoke all on function app.create_restaurant_with_owner(
    text, text, char(2), text, text, text, text, text) from public;
grant execute on function app.create_restaurant_with_owner(
    text, text, char(2), text, text, text, text, text) to authenticated;

-- Convenience view for the app: who am I, which restaurant, which role,
-- and what am I allowed to do. Runs under the caller's own policies.
create or replace view public.v_current_user
with (security_invoker = true)
as
select
    u.id            as user_id,
    u.restaurant_id,
    u.full_name,
    u.email,
    u.employee_code,
    r.id            as role_id,
    r.name          as role_name,
    res.trading_name,
    res.country_code,
    res.currency_code,
    res.timezone,
    (select coalesce(array_agg(rp.permission_key order by rp.permission_key), '{}')
       from public.role_permissions rp where rp.role_id = r.id) as permissions
from public.users u
join public.roles r       on r.id = u.role_id
join public.restaurants res on res.id = u.restaurant_id
where u.auth_user_id = auth.uid()
  and u.deleted_at is null
  and u.is_active;

grant select on public.v_current_user to authenticated;
