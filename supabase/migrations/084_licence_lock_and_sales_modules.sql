-- 084: licence end date is enforced; renewal reminder; modules on a sale
--
-- Founder's rules (5 Oct 2026):
--   * From 15 days before the licence end date the restaurant sees a reminder.
--     SNA can switch the reminder off from the console once payment is in.
--   * After the end date the restaurant is read-only: no new bills and no new
--     items. Bills that are already open can still be paid, voided and the day
--     closed, so nobody is left with a guest who cannot be billed.
--   * There is no trial. A restaurant with no licence date is not limited; the
--     console lists it under "No licence date" until SNA sets one.
--   * Suspended and Cancelled make a restaurant read-only at once.
--   * A sale records the modules that were bought.
--
-- When exactly: the end date can be used in full. Read-only starts at 6 a.m.
-- (restaurant's own time) on the day after, so a late service is not cut off.
--
-- Additive only: two new columns, new functions, three new triggers. No
-- existing function is replaced. To take the lock away in a hurry, drop the
-- three triggers named trg_licence_*.

begin;

alter table public.sna_accounts add column reminder_off_for date;
comment on column public.sna_accounts.reminder_off_for is
  'The licence end date for which SNA switched the renewal reminder off. The reminder comes back by itself when the end date changes.';

alter table public.sna_sales add column modules text[] not null default '{}';
comment on column public.sna_sales.modules is
  'What was bought on this sale: basic, professional, or the keys of add-on modules.';

------------------------------------------------------------------
-- 1. Where a restaurant's licence stands at a given moment
------------------------------------------------------------------
create function app.licence_state(p_restaurant uuid, p_at timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_status text; v_tz text; v_end date; v_off date;
  v_local timestamp; v_today date; v_lock_at timestamptz;
begin
  select r.subscription_status, coalesce(r.timezone, 'Asia/Kolkata'), a.licence_expiry, a.reminder_off_for
    into v_status, v_tz, v_end, v_off
    from public.restaurants r left join public.sna_accounts a on a.restaurant_id = r.id
   where r.id = p_restaurant;
  if not found then return jsonb_build_object('state', 'ok'); end if;

  if v_status in ('suspended', 'cancelled') then
    return jsonb_build_object('state', 'locked', 'reason', v_status, 'ends', v_end);
  end if;
  if v_end is null then return jsonb_build_object('state', 'ok', 'ends', null); end if;

  v_local := p_at at time zone v_tz;
  v_today := v_local::date;
  v_lock_at := ((v_end + 1)::timestamp + interval '6 hours') at time zone v_tz;
  if p_at >= v_lock_at then
    return jsonb_build_object('state', 'locked', 'reason', 'ended', 'ends', v_end, 'lock_at', v_lock_at);
  end if;
  if v_end - v_today <= 15 then
    return jsonb_build_object('state', 'warn', 'ends', v_end, 'days_left', greatest(v_end - v_today, 0), 'lock_at', v_lock_at,
                              'remind', v_off is distinct from v_end);
  end if;
  return jsonb_build_object('state', 'ok', 'ends', v_end, 'days_left', v_end - v_today, 'lock_at', v_lock_at);
end $$;

create function app.licence_locked(p_restaurant uuid, p_at timestamptz default now()) returns boolean
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$ select (app.licence_state(p_restaurant, p_at)->>'state') = 'locked' $$;

revoke all on function app.licence_state(uuid, timestamptz), app.licence_locked(uuid, timestamptz) from public, anon, authenticated;

------------------------------------------------------------------
-- 2. The lock itself: no new bills, no new items, no guest orders
------------------------------------------------------------------

-- A new bill. Judged at the bill's own time, so a bill made offline before the
-- licence ended can still be sent up afterwards.
create function app.trg_licence_orders() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if app.licence_locked(new.restaurant_id, least(coalesce(new.created_at, now()), now())) then
    raise exception 'The SNA POS licence for this restaurant has ended, so new bills cannot be made. Bills that are already open can still be paid. Please contact SNA to renew.';
  end if;
  -- The lines of this same bill follow in this transaction; they need no second check.
  perform set_config('app.licence_ok_order', new.id::text, true);
  return new;
end $$;

-- A new line: part of a bill just allowed above, or items added to an older open bill.
create function app.trg_licence_order_items() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if new.order_id::text = current_setting('app.licence_ok_order', true) then return new; end if;
  if app.licence_locked(new.restaurant_id, now()) then
    raise exception 'The SNA POS licence for this restaurant has ended, so items cannot be added. Bills that are already open can still be paid. Please contact SNA to renew.';
  end if;
  return new;
end $$;

-- A guest ordering from the table QR.
create function app.trg_licence_qr_orders() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if app.licence_locked(new.restaurant_id, now()) then
    raise exception 'Ordering from the table is not available right now. Please ask the staff.';
  end if;
  return new;
end $$;

revoke all on function app.trg_licence_orders(), app.trg_licence_order_items(), app.trg_licence_qr_orders() from public, anon, authenticated;

create trigger trg_licence_orders before insert on public.orders
  for each row execute function app.trg_licence_orders();
create trigger trg_licence_order_items before insert on public.order_items
  for each row execute function app.trg_licence_order_items();
create trigger trg_licence_qr_orders before insert on public.qr_orders
  for each row execute function app.trg_licence_qr_orders();

------------------------------------------------------------------
-- 3. What the restaurant app asks
------------------------------------------------------------------
-- Where my own restaurant's licence stands. Any signed-in person of the restaurant.
create function public.my_licence() returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare v_rest uuid := app.current_restaurant_id();
begin
  if v_rest is null then return null; end if;
  return app.licence_state(v_rest, now());
end $$;

------------------------------------------------------------------
-- 4. Console: licence state and the reminder switch
------------------------------------------------------------------
create function public.sna_licence(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare a public.sna_accounts%rowtype;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  if not exists (select 1 from public.restaurants where id = p_id and deleted_at is null) then raise exception 'Restaurant not found.'; end if;
  select * into a from public.sna_accounts where restaurant_id = p_id;
  return app.licence_state(p_id, now())
      || jsonb_build_object('reminder_off', a.reminder_off_for is not null and a.reminder_off_for = a.licence_expiry);
end $$;

-- Switch the renewal reminder off (payment is in) or back on. Sales and admin only.
-- It is tied to the present end date: when that date changes the reminder is live again.
-- It does not move the end date: the restaurant still goes read-only when the date passes.
create function public.sna_set_reminder(p_restaurant uuid, p_on boolean) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid; v_end date;
begin
  v_me := app.sna_require(array['sales']);
  perform app.sna_account_row(p_restaurant);
  select licence_expiry into v_end from public.sna_accounts where restaurant_id = p_restaurant for update;
  if v_end is null then raise exception 'Set the licence end date first.'; end if;
  update public.sna_accounts
     set reminder_off_for = case when coalesce(p_on, true) then null else v_end end, updated_at = now(), updated_by = v_me
   where restaurant_id = p_restaurant;
  perform app.log_plan(p_restaurant, case when coalesce(p_on, true) then 'reminder.on' else 'reminder.off' end,
                       jsonb_build_object('licence_expiry', v_end));
end $$;

------------------------------------------------------------------
-- 5. Console: sales with the modules bought
------------------------------------------------------------------
-- The sales of one client with their modules, and what can be put on a sale.
create function public.sna_sales_list(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare r public.restaurants%rowtype;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_id and deleted_at is null;
  if not found then raise exception 'Restaurant not found.'; end if;
  return jsonb_build_object(
    'modules', (select coalesce(jsonb_object_agg(s.id, to_jsonb(s.modules)), '{}'::jsonb)
                  from public.sna_sales s where s.restaurant_id = p_id and cardinality(s.modules) > 0),
    'catalog', jsonb_build_array(
                 jsonb_build_object('key', 'basic', 'name', 'Basic edition', 'on', r.edition = 'basic'),
                 jsonb_build_object('key', 'professional', 'name', 'Professional edition', 'on', r.edition = 'professional'))
               || (select coalesce(jsonb_agg(jsonb_build_object('key', m.key, 'name', m.name, 'on', app.feature_on(r.id, m.key)) order by m.display_order), '[]'::jsonb)
                     from public.modules m where m.kind = 'addon'));
end $$;

-- Record a sale with the modules bought. Sales and admin only.
-- p_switch_on: also switch on what was bought (Professional edition, add-ons).
-- p_extend_licence: also move the licence end date to the end of the period sold.
create function public.sna_record_sale(
  p_restaurant uuid, p_kind text, p_description text, p_amount numeric, p_sale_date date,
  p_period_from date default null, p_period_to date default null, p_invoice_no text default null,
  p_paid_on date default null, p_note text default null, p_extend_licence boolean default false,
  p_modules text[] default '{}', p_switch_on boolean default false
) returns uuid
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_id uuid; v_key text; v_mods text[];
  v_why text := 'Sold' || coalesce(', invoice ' || nullif(trim(coalesce(p_invoice_no, '')), ''), '');
begin
  perform app.sna_require(array['sales']);
  select coalesce(array_agg(distinct k order by k), '{}') into v_mods from unnest(coalesce(p_modules, '{}')) k where k is not null and trim(k) <> '';
  foreach v_key in array v_mods loop
    if v_key not in ('basic', 'professional') and not exists (select 1 from public.modules where key = v_key and kind = 'addon') then
      raise exception 'Unknown module on the sale: %.', v_key;
    end if;
  end loop;
  if 'basic' = any(v_mods) and 'professional' = any(v_mods) then raise exception 'Choose Basic or Professional, not both.'; end if;

  v_id := public.sna_add_sale(p_restaurant, p_kind, p_description, p_amount, p_sale_date, p_period_from, p_period_to,
                              p_invoice_no, p_paid_on, p_note, p_extend_licence);
  update public.sna_sales set modules = v_mods where id = v_id;

  if coalesce(p_switch_on, false) then
    -- Edition first: an add-on is of no use without it. Moving down to Basic is never done from a sale.
    if 'professional' = any(v_mods) then perform public.sna_set_edition(p_restaurant, 'professional', v_why); end if;
    foreach v_key in array v_mods loop
      if v_key not in ('basic', 'professional') then perform public.sna_set_module(p_restaurant, v_key, true, v_why); end if;
    end loop;
  end if;
  return v_id;
end $$;

revoke all on function
  public.my_licence(), public.sna_licence(uuid), public.sna_set_reminder(uuid, boolean), public.sna_sales_list(uuid),
  public.sna_record_sale(uuid, text, text, numeric, date, date, date, text, date, text, boolean, text[], boolean)
from public, anon;
grant execute on function
  public.my_licence(), public.sna_licence(uuid), public.sna_set_reminder(uuid, boolean), public.sna_sales_list(uuid),
  public.sna_record_sale(uuid, text, text, numeric, date, date, date, text, date, text, boolean, text[], boolean)
to authenticated, service_role;

commit;
