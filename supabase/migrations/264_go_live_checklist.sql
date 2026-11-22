-- 264: the go-live checklist on each client's page in the SNA console.
-- Some items tick themselves from the client's own setup; the rest are ticked by SNA staff (who and when are kept).
-- "Mark as Live" now needs the whole checklist done. An admin can go Live with items open, but must write why.
-- Nothing here changes what a restaurant sees.

begin;

------------------------------------------------------------------
-- 1. Hand-ticked items
------------------------------------------------------------------
create table if not exists public.sna_golive_ticks (
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  item          text not null,
  ticked_by     uuid references public.sna_staff(id) on delete set null,
  ticked_at     timestamptz not null default now(),
  note          text,
  primary key (restaurant_id, item)
);
alter table public.sna_golive_ticks enable row level security;
revoke all on public.sna_golive_ticks from anon, authenticated;
comment on table public.sna_golive_ticks is 'Items on the go-live checklist that SNA staff ticked by hand, with who and when.';

------------------------------------------------------------------
-- 2. The list itself (one place). applies = business types it shows for; null = all.
------------------------------------------------------------------
create or replace function app.golive_items()
returns table(key text, grp text, seq int, title text, auto boolean, post boolean, note_label text, hint text, applies text[])
language sql immutable as $$
  select * from (values
    ('country',         'Set up',            1, 'Country and currency are set', true,  false, null::text, null::text, null::text[]),
    ('outlet',          'Set up',            2, 'At least one outlet exists', true,  false, null, null, null),
    ('taxes',           'Set up',            3, 'Taxes are set for the country', true,  false, null, null, null),
    ('billdetails',     'Set up',            4, 'Bill details filled in: legal name, tax number, address, bill footer', true,  false, null, null, null),
    ('menu',            'Set up',            5, 'Menu has items, and every item has a price and a tax group', true,  false, null, null, null),
    ('payment',         'Set up',            6, 'At least one payment method is on', true,  false, null, null, null),
    ('tables',          'Set up',            7, 'Tables are set up', true,  false, null, null, array['restaurant','fine_dine','chain','bar']),
    ('plan',            'Set up',            8, 'Plan, modules and licence dates match what was sold', false, false, null, null, null),
    ('owner_login',     'People',            9, 'Owner has signed in once with their own password', false, false, null, null, null),
    ('staff',           'People',           10, 'A manager and a cashier exist, each with the right security profile', false, false, null, null, null),
    ('training',        'People',           11, 'Staff training done', false, false, 'Trained by, and date', null, null),
    ('printer',         'Devices',          12, 'Bill printer is connected and a test print came out correctly', false, false, null, null, null),
    ('kitchen_printer', 'Devices',          13, 'Kitchen printer is connected and a test KOT print came out correctly', false, false, null, null, array['restaurant','fine_dine','chain']),
    ('phone',           'Devices',          14, 'Phone or tablet layout checked', false, false, null, null, array['restaurant','fine_dine','chain','bar']),
    ('test_sale',       'Test and handover',15, 'A full test sale was taken from order to payment, and the printed bill was checked', false, false, null, null, null),
    ('day_close',       'Test and handover',16, 'A day close was tested', false, false, null, null, array['restaurant','fine_dine','chain','bar']),
    ('support_contact', 'Test and handover',17, 'Owner has the SNA support contact and knows how to raise a request', false, false, null, null, null),
    ('erased',          'Test and handover',18, 'Training and test bills erased, so the first real bill starts clean', false, false, null, 'Do this on the Erase data section below. After Live it cannot be done.', null),
    ('first_bill',      'After going live', 19, 'First real bill made on the POS and checked with the owner', false, true,  'Bill number and date', null, null)
  ) as t(key, grp, seq, title, auto, post, note_label, hint, applies);
$$;

------------------------------------------------------------------
-- 3. The items that tick themselves
------------------------------------------------------------------
create or replace function app.golive_auto(p_restaurant uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  r public.restaurants%rowtype; v_out jsonb := '{}'::jsonb; v_n int; v_bad int; v_miss text[];
begin
  select * into r from public.restaurants where id = p_restaurant;

  v_miss := array_remove(array[
    case when coalesce(btrim(r.country_code), '') = '' then 'country' end,
    case when coalesce(btrim(r.currency_code), '') = '' then 'currency' end], null);
  v_out := v_out || jsonb_build_object('country', jsonb_build_object('ok', cardinality(v_miss) = 0, 'detail', case when cardinality(v_miss) > 0 then 'Missing: ' || array_to_string(v_miss, ', ') end));

  select count(*) into v_n from public.branches where restaurant_id = p_restaurant and deleted_at is null and is_active;
  v_out := v_out || jsonb_build_object('outlet', jsonb_build_object('ok', v_n > 0, 'detail', case when v_n = 0 then 'No outlet yet' end));

  select count(*) into v_n from public.tax_groups g where g.restaurant_id = p_restaurant and g.is_active
     and exists (select 1 from public.tax_rates t where t.tax_group_id = g.id);
  v_out := v_out || jsonb_build_object('taxes', jsonb_build_object('ok', v_n > 0, 'detail', case when v_n = 0 then 'No tax group with a rate yet' end));

  v_miss := array_remove(array[
    case when coalesce(btrim(r.legal_name), '') = '' then 'legal name' end,
    case when coalesce(btrim(r.tax_registration_no), '') = '' then 'tax number' end,
    case when not exists (select 1 from public.branches b where b.restaurant_id = p_restaurant and b.deleted_at is null and coalesce(btrim(b.address_line1), '') <> '') then 'address' end,
    case when not exists (select 1 from public.branch_settings s where s.restaurant_id = p_restaurant and coalesce(btrim(s.receipt_footer), '') <> '') then 'bill footer' end], null);
  v_out := v_out || jsonb_build_object('billdetails', jsonb_build_object('ok', cardinality(v_miss) = 0, 'detail', case when cardinality(v_miss) > 0 then 'Missing: ' || array_to_string(v_miss, ', ') end));

  select count(*), count(*) filter (where p.tax_group_id is null or p.price is null or (p.price <= 0 and not coalesce(p.is_open_price, false)))
    into v_n, v_bad
    from public.products p
   where p.restaurant_id = p_restaurant and p.deleted_at is null and not coalesce(p.is_charge, false)
     and not exists (select 1 from public.products c where c.parent_id = p.id and c.deleted_at is null);
  v_out := v_out || jsonb_build_object('menu', jsonb_build_object('ok', v_n > 0 and v_bad = 0,
    'detail', case when v_n = 0 then 'No menu items yet' when v_bad > 0 then v_bad || (case when v_bad = 1 then ' item has' else ' items have' end) || ' no price or no tax group' end));

  select count(*) into v_n from public.payment_methods where restaurant_id = p_restaurant and is_active;
  v_out := v_out || jsonb_build_object('payment', jsonb_build_object('ok', v_n > 0, 'detail', case when v_n = 0 then 'No payment method is on' end));

  select count(*) into v_n from public.dining_tables where restaurant_id = p_restaurant and is_active and not coalesce(is_kiosk, false);
  v_out := v_out || jsonb_build_object('tables', jsonb_build_object('ok', v_n > 0, 'detail', case when v_n = 0 then 'No tables yet' end));

  return v_out;
end $$;

------------------------------------------------------------------
-- 4. The checklist for one client
------------------------------------------------------------------
create or replace function app.golive_status(p_restaurant uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  r public.restaurants%rowtype; a public.sna_accounts%rowtype; v_bt text; v_auto jsonb; v_plan text;
  v_items jsonb; v_total int; v_done int; v_open text[];
begin
  select * into r from public.restaurants where id = p_restaurant and deleted_at is null;
  if not found then raise exception 'Client not found.'; end if;
  select * into a from public.sna_accounts where restaurant_id = p_restaurant;
  v_bt := coalesce(r.business_type, 'restaurant');
  v_auto := app.golive_auto(p_restaurant);
  v_plan := concat(initcap(coalesce(r.edition::text, '')), ' plan. Licence ',
                   coalesce(to_char(a.licence_start, 'FMDD Mon YYYY'), 'start not set'), ' to ', coalesce(to_char(a.licence_expiry, 'FMDD Mon YYYY'), 'end not set'),
                   '. Modules: ', coalesce((select string_agg(m.module_key, ', ' order by m.module_key) from public.restaurant_modules m where m.restaurant_id = p_restaurant), 'none'), '.');

  with it as (
    select i.*, t.restaurant_id is not null as ticked, t.ticked_at, t.note, s.full_name as ticked_by_name,
           case when i.auto then coalesce((v_auto -> i.key ->> 'ok')::boolean, false) else t.restaurant_id is not null end as ok
      from app.golive_items() i
      left join public.sna_golive_ticks t on t.restaurant_id = p_restaurant and t.item = i.key
      left join public.sna_staff s on s.id = t.ticked_by
     where i.applies is null or v_bt = any (i.applies))
  select jsonb_agg(jsonb_build_object(
           'key', key, 'group', grp, 'title', title, 'auto', auto, 'post', post, 'note_label', note_label,
           'hint', case when key = 'plan' then v_plan else hint end,
           'ok', ok, 'detail', case when auto then v_auto -> key ->> 'detail' end,
           'by', ticked_by_name, 'at', ticked_at, 'note', note) order by seq),
         count(*) filter (where not post), count(*) filter (where not post and ok),
         array_agg(key order by seq) filter (where not post and not ok)
    into v_items, v_total, v_done, v_open
    from it;

  return jsonb_build_object(
    'live', a.live_at is not null, 'live_at', a.live_at,
    'live_by', (select s.full_name from public.sna_staff s where s.id = a.live_by),
    'business_type', v_bt, 'total', coalesce(v_total, 0), 'done', coalesce(v_done, 0),
    'ready', coalesce(v_total, 0) > 0 and coalesce(v_done, 0) = coalesce(v_total, 0),
    'open', to_jsonb(coalesce(v_open, array[]::text[])), 'items', coalesce(v_items, '[]'::jsonb));
end $$;

revoke all on function app.golive_items(), app.golive_auto(uuid), app.golive_status(uuid) from public, anon, authenticated;

create or replace function public.sna_golive_status(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  return app.golive_status(p_id);
end $$;

-- Tick or untick one hand-ticked item.
create or replace function public.sna_golive_tick(p_restaurant uuid, p_item text, p_on boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid; v_st jsonb; v_it jsonb;
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  v_st := app.golive_status(p_restaurant);
  select e.value into v_it from jsonb_array_elements(v_st -> 'items') e where e.value ->> 'key' = p_item;
  if v_it is null then raise exception 'That item does not apply to this client.'; end if;
  if (v_it ->> 'auto')::boolean then raise exception 'This item ticks itself from the client''s setup.'; end if;
  if (v_st ->> 'live')::boolean and not (v_it ->> 'post')::boolean then raise exception 'This client is live, so this item can no longer be changed.'; end if;
  if not (v_st ->> 'live')::boolean and (v_it ->> 'post')::boolean then raise exception 'This item opens once the client is Live.'; end if;
  if coalesce(p_on, false) then
    insert into public.sna_golive_ticks (restaurant_id, item, ticked_by, ticked_at, note)
    values (p_restaurant, p_item, v_me, now(), left(nullif(btrim(coalesce(p_note, '')), ''), 200))
    on conflict (restaurant_id, item) do update set ticked_by = excluded.ticked_by, ticked_at = now(), note = excluded.note;
  else
    delete from public.sna_golive_ticks where restaurant_id = p_restaurant and item = p_item;
  end if;
end $$;

------------------------------------------------------------------
-- 5. Going Live now needs the checklist. A reason lets an admin go Live with items open.
------------------------------------------------------------------
create or replace function public.sna_set_live(p_restaurant uuid, p_live boolean, p_reason text default null) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid; v_was timestamptz; v_reason text := trim(coalesce(p_reason, '')); v_st jsonb; v_over boolean := false;
begin
  if coalesce(p_live, false) then
    if length(v_reason) > 0 then
      v_me := app.sna_require(array[]::text[]);
      if length(v_reason) < 5 then raise exception 'Write why this client goes Live with items still open.'; end if;
    else
      v_me := app.sna_require(array['sales', 'implementer', 'support']);
    end if;
  else
    -- Taking Live off opens the door to erasing real bills: admins only, with a reason.
    v_me := app.sna_require(array[]::text[]);
    if length(v_reason) < 5 then raise exception 'Write why this client is no longer live.'; end if;
  end if;
  perform app.sna_account_row(p_restaurant);
  select live_at into v_was from public.sna_accounts where restaurant_id = p_restaurant for update;
  if coalesce(p_live, false) = (v_was is not null) then return; end if;
  if coalesce(p_live, false) then
    v_st := app.golive_status(p_restaurant);
    if (v_st ->> 'ready')::boolean is not true then
      if length(v_reason) = 0 then
        raise exception 'The go-live checklist is not complete (% of % done).', v_st ->> 'done', v_st ->> 'total';
      end if;
      v_over := true;
    end if;
  end if;
  update public.sna_accounts
     set live_at = case when p_live then now() end, live_by = case when p_live then v_me end, updated_at = now(), updated_by = v_me
   where restaurant_id = p_restaurant;
  perform app.log_plan(p_restaurant, case when p_live then 'client.live' else 'client.not_live' end,
                       jsonb_strip_nulls(jsonb_build_object('reason', nullif(left(v_reason, 300), ''),
                         'override', case when v_over then true end,
                         'open', case when v_over then v_st -> 'open' end)));
end $$;

revoke all on function public.sna_golive_status(uuid), public.sna_golive_tick(uuid, text, boolean, text) from public, anon;
grant execute on function public.sna_golive_status(uuid), public.sna_golive_tick(uuid, text, boolean, text) to authenticated;

commit;
