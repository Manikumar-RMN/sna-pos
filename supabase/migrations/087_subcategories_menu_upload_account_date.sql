-- 087: sub-categories, menu upload, account date
--
-- Founder's live-test feedback (12 Oct 2026):
--   * "we need to add option to create sub category under category"
--   * "No option to upload menu"
--   * "Need to show account date in right side top of screen"
--
-- 1. Categories can sit inside a main category, one level deep (Beverages > Hot drinks).
--    A category name now has to be unique only among its siblings, and a removed
--    category no longer blocks its name (the old rule counted removed ones too).
-- 2. public.import_menu: checks a whole menu sheet and, only if every row is right,
--    saves it in one go. Existing dishes (same name in the same category) are updated;
--    nothing is ever removed.
-- 3. public.account_date: the business date the next bill will carry, for the header.
-- 4. KOT first, bill later ("No option for kot ... first kot then bill"):
--    public.send_to_kitchen makes kitchen tickets for the order's items that have none yet
--    (also when the outlet's "send every bill to the Kitchen screen" is off: pressing KOT
--    asks for it), and public.claim_tickets_for_print marks tickets printed BEFORE they are
--    printed, so a second printer that asks a moment later does not print them again.
--
-- Replaces one rule (the category name rule), so this goes in through the Founder's
-- SQL-editor script, not the migration tool.

begin;

------------------------------------------------------------------
-- 1. Sub-categories
------------------------------------------------------------------
alter table public.categories add column parent_id uuid;
comment on column public.categories.parent_id is
  'The main category this one sits inside (one level only). Null for a main category.';

-- The parent must be in the same restaurant.
alter table public.categories
  add constraint categories_parent_same_rest foreign key (restaurant_id, parent_id)
  references public.categories (restaurant_id, id);
alter table public.categories
  add constraint categories_parent_not_self check (parent_id is null or parent_id <> id);
create index categories_parent_idx on public.categories (parent_id) where parent_id is not null;

-- Names: unique among siblings, live categories only, ignoring case and outer spaces.
alter table public.categories drop constraint categories_restaurant_id_name_key;
create unique index categories_name_uq on public.categories
  (restaurant_id, coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(btrim(name)))
  where deleted_at is null;

create function app.trg_category_parent() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if new.parent_id is not null and new.deleted_at is null then
    if exists (select 1 from public.categories where id = new.parent_id and parent_id is not null) then
      raise exception 'A sub-category cannot have sub-categories of its own. Choose a main category.';
    end if;
    if exists (select 1 from public.categories where id = new.parent_id and deleted_at is not null) then
      raise exception 'That main category has been removed.';
    end if;
    if exists (select 1 from public.categories where parent_id = new.id and deleted_at is null) then
      raise exception 'This category has sub-categories, so it cannot go inside another category.';
    end if;
  end if;
  if tg_op = 'UPDATE' and new.deleted_at is not null and old.deleted_at is null
     and exists (select 1 from public.categories where parent_id = new.id and deleted_at is null) then
    raise exception 'This category still has sub-categories. Remove or move them first.';
  end if;
  return new;
end $$;
revoke all on function app.trg_category_parent() from public, anon, authenticated;

create trigger trg_category_parent before insert or update of parent_id, deleted_at on public.categories
  for each row execute function app.trg_category_parent();

------------------------------------------------------------------
-- 2. Menu upload
------------------------------------------------------------------
-- p_rows: [{"row":2,"category":"Beverages","sub_category":"Hot drinks","name":"Masala tea","price":"20",
--           "tax_group":"GST 5%","veg":"Y","hsn":"","station":"","local_name":""}, ...]
-- p_apply = false: only check and say what would happen. true: check, then save if there is no error.
-- Returns {ok, applied, errors:[{row,message}], new_categories, new_items, updated_items, unchanged_items}.
create function public.import_menu(p_rows jsonb, p_apply boolean default false) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_rest uuid; v_country text; v_edition text; v_stations boolean;
  v_can_price boolean; v_can_tax boolean;
  r jsonb; v_row int; v_errs jsonb := '[]'::jsonb;
  v_cat text; v_sub text; v_name text; v_price numeric; v_tax text; v_veg text; v_hsn text; v_station text; v_local text;
  v_tax_id uuid; v_vegb boolean; v_one_tax uuid; v_tax_count int; v_tax_names text;
  v_main_id uuid; v_sub_id uuid; v_cat_id uuid; v_tmp uuid;
  v_pid uuid; v_pprice numeric; v_ptax uuid; v_pveg boolean; v_phsn text; v_pstation text; v_plocal text;
  v_seen jsonb := '{}'::jsonb; v_key text;
  v_new_cats int := 0; v_new_items int := 0; v_upd int := 0; v_same int := 0; v_live_items int;
  v_plan jsonb := '[]'::jsonb; p jsonb; v_order int;
  v_new_cat_keys jsonb := '{}'::jsonb;
begin
  perform app.require_permission('menu.manage');
  v_rest := app.current_restaurant_id();
  select r2.country_code, r2.edition into v_country, v_edition from public.restaurants r2 where r2.id = v_rest;
  v_stations := app.feature_on(v_rest, 'kitchen_stations');
  v_can_price := app.has_permission('menu.price_change');
  v_can_tax := app.has_permission('tax.manage');

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'The file has no menu rows.';
  end if;
  if jsonb_array_length(p_rows) > 2000 then
    raise exception 'Up to 2,000 rows can be uploaded at once. Split the file.';
  end if;

  select count(*), min(id::text)::uuid, string_agg(name, ', ' order by name)
    into v_tax_count, v_one_tax, v_tax_names
    from public.tax_groups where restaurant_id = v_rest and is_active;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_row := coalesce(nullif(r->>'row', '')::int, 0);
    v_cat := btrim(coalesce(r->>'category', ''));
    v_sub := btrim(coalesce(r->>'sub_category', ''));
    v_name := btrim(coalesce(r->>'name', ''));
    v_tax := btrim(coalesce(r->>'tax_group', ''));
    v_veg := lower(btrim(coalesce(r->>'veg', '')));
    v_hsn := regexp_replace(coalesce(r->>'hsn', ''), '\s', '', 'g');
    v_station := btrim(coalesce(r->>'station', ''));
    v_local := btrim(coalesce(r->>'local_name', ''));
    v_tax_id := null; v_vegb := null; v_cat_id := null; v_main_id := null; v_sub_id := null; v_pid := null;

    -- a completely empty line is skipped
    if v_cat = '' and v_sub = '' and v_name = '' and btrim(coalesce(r->>'price', '')) = '' then continue; end if;

    if v_cat = '' then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Category is empty.'); continue; end if;
    if v_name = '' then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Item name is empty.'); continue; end if;
    if length(v_cat) > 80 or length(v_sub) > 80 then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Category names can be up to 80 characters.'); continue; end if;
    if length(v_name) > 120 then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Item name can be up to 120 characters.'); continue; end if;

    -- "1,250" is a thousands comma; "120,50" is a decimal comma (semicolon CSVs from Excel) and is refused,
    -- so a price can never come in 100 times too high.
    if btrim(coalesce(r->>'price', '')) ~ ',[0-9]{1,2}$' then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Write the price with a dot for paise, for example 120.50 (not 120,50).'); continue;
    end if;
    begin
      v_price := round(replace(replace(btrim(coalesce(r->>'price', '')), ',', ''), ' ', '')::numeric, 2);
    exception when others then v_price := null;
    end;
    if v_price is null or v_price < 0 or v_price > 10000000 then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Price must be a number, for example 120 or 120.50.'); continue;
    end if;

    if v_veg in ('y', 'yes', 'veg', 'v', 'true', '1') then v_vegb := true;
    elsif v_veg in ('n', 'no', 'non-veg', 'nonveg', 'non veg', 'nv', 'false', '0') then v_vegb := false;
    elsif v_veg <> '' then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Veg must be Y or N (or empty).'); continue;
    end if;

    -- Excel drops a leading zero (0902 becomes 902): HSN codes have 4, 6 or 8 digits, so one zero is put back.
    if v_hsn ~ '^[0-9]{3}$' or v_hsn ~ '^[0-9]{5}$' or v_hsn ~ '^[0-9]{7}$' then v_hsn := '0' || v_hsn; end if;
    if v_country = 'IN' and v_hsn <> '' and v_hsn !~ '^[0-9]{4,8}$' then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'HSN / SAC code is 4 to 8 digits, or leave it empty.'); continue;
    end if;
    if v_country <> 'IN' then v_hsn := ''; end if;
    if length(v_station) > 30 then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Kitchen station can be up to 30 characters.'); continue; end if;
    if not v_stations then v_station := ''; end if;
    if length(v_local) > 120 then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Name in second language can be up to 120 characters.'); continue; end if;

    if v_tax <> '' then
      select id into v_tax_id from public.tax_groups
       where restaurant_id = v_rest and is_active and lower(btrim(name)) = lower(v_tax) limit 1;
      if v_tax_id is null then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'message',
          format('Tax group "%s" is not set up. Use one of: %s.', v_tax, coalesce(v_tax_names, 'none set up yet')));
        continue;
      end if;
    end if;

    -- the main category
    select id into v_main_id from public.categories
     where restaurant_id = v_rest and deleted_at is null and parent_id is null and lower(btrim(name)) = lower(v_cat) limit 1;
    if v_main_id is null and exists (select 1 from public.categories where restaurant_id = v_rest and deleted_at is null
                                      and parent_id is not null and lower(btrim(name)) = lower(v_cat)) then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message',
        format('"%s" is a sub-category. Put its main category under Category and "%s" under Sub-category.', v_cat, v_cat));
      continue;
    end if;

    if v_sub <> '' then
      if lower(v_sub) = lower(v_cat) then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Sub-category has the same name as its category. Leave Sub-category empty.'); continue;
      end if;
      if v_main_id is not null then
        select id into v_sub_id from public.categories
         where restaurant_id = v_rest and deleted_at is null and parent_id = v_main_id and lower(btrim(name)) = lower(v_sub) limit 1;
      end if;
      v_cat_id := v_sub_id;
    else
      v_cat_id := v_main_id;
    end if;

    -- the same dish twice in the file
    v_key := lower(v_cat) || '|' || lower(v_sub) || '|' || lower(v_name);
    if v_seen ? v_key then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message',
        format('"%s" is already on row %s of this file.', v_name, v_seen->>v_key));
      continue;
    end if;
    v_seen := v_seen || jsonb_build_object(v_key, v_row);

    -- an existing dish (not the packing charge) with this name in this category
    if v_cat_id is not null then
      select id, price, tax_group_id, is_veg, hsn_code, kitchen_station, name_local
        into v_pid, v_pprice, v_ptax, v_pveg, v_phsn, v_pstation, v_plocal
        from public.products
       where restaurant_id = v_rest and category_id = v_cat_id and deleted_at is null and not coalesce(is_charge, false)
         and lower(btrim(name)) = lower(v_name)
       order by created_at limit 1;
    end if;

    if v_pid is null then
      if v_tax_id is null then
        if v_tax_count = 1 then v_tax_id := v_one_tax;
        else
          v_errs := v_errs || jsonb_build_object('row', v_row, 'message',
            format('Tax group is empty. Use one of: %s.', coalesce(v_tax_names, 'none set up yet')));
          continue;
        end if;
      end if;
      v_plan := v_plan || jsonb_build_object('op', 'add', 'row', v_row, 'cat', v_cat, 'sub', v_sub, 'name', v_name,
                  'price', v_price, 'tax', v_tax_id, 'veg', v_vegb, 'hsn', nullif(v_hsn, ''), 'station', nullif(v_station, ''),
                  'local', nullif(v_local, ''));
      v_new_items := v_new_items + 1;
      if v_main_id is null and not v_new_cat_keys ? lower(v_cat) then
        v_new_cat_keys := v_new_cat_keys || jsonb_build_object(lower(v_cat), true); v_new_cats := v_new_cats + 1;
      end if;
      if v_sub <> '' and v_sub_id is null and not v_new_cat_keys ? (lower(v_cat) || '|' || lower(v_sub)) then
        v_new_cat_keys := v_new_cat_keys || jsonb_build_object(lower(v_cat) || '|' || lower(v_sub), true); v_new_cats := v_new_cats + 1;
      end if;
    else
      if v_price <> v_pprice and not v_can_price then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'message', format('"%s" would change price, and your role cannot change prices.', v_name)); continue;
      end if;
      if v_tax_id is not null and v_tax_id <> v_ptax and not v_can_tax then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'message', format('"%s" would change tax group, and your role cannot change tax.', v_name)); continue;
      end if;
      if v_price = v_pprice
         and (v_tax_id is null or v_tax_id = v_ptax)
         and (v_vegb is null or v_vegb is not distinct from v_pveg)
         and (v_hsn = '' or v_hsn is not distinct from v_phsn)
         and (v_station = '' or v_station is not distinct from v_pstation)
         and (v_local = '' or v_local is not distinct from v_plocal) then
        v_same := v_same + 1;
      else
        v_plan := v_plan || jsonb_build_object('op', 'update', 'row', v_row, 'id', v_pid, 'price', v_price, 'tax', v_tax_id,
                    'veg', v_vegb, 'hsn', nullif(v_hsn, ''), 'station', nullif(v_station, ''), 'local', nullif(v_local, ''));
        v_upd := v_upd + 1;
      end if;
    end if;
  end loop;

  if jsonb_array_length(v_errs) = 0 and v_new_items = 0 and v_upd = 0 and v_same = 0 then
    v_errs := v_errs || jsonb_build_object('row', 0, 'message', 'The file has no menu rows.');
  end if;

  -- Basic edition: at most 300 dishes
  if v_edition = 'basic' and v_new_items > 0 then
    select count(*) into v_live_items from public.products where restaurant_id = v_rest and deleted_at is null;
    if v_live_items + v_new_items > 300 then
      v_errs := v_errs || jsonb_build_object('row', 0, 'message',
        format('The Basic edition allows up to 300 menu items. You have %s and the file adds %s.', v_live_items, v_new_items));
    end if;
  end if;

  if jsonb_array_length(v_errs) > 0 or not coalesce(p_apply, false) then
    return jsonb_build_object('ok', jsonb_array_length(v_errs) = 0, 'applied', false, 'errors', v_errs,
      'new_categories', v_new_cats, 'new_items', v_new_items, 'updated_items', v_upd, 'unchanged_items', v_same);
  end if;

  -- Save. Everything above was checked; this runs in one transaction.
  select coalesce(max(display_order), 0) into v_order from public.categories where restaurant_id = v_rest and display_order < 999;
  for p in select value from jsonb_array_elements(v_plan) loop
    if p->>'op' = 'add' then
      v_cat_id := null;
      select id into v_cat_id from public.categories
       where restaurant_id = v_rest and deleted_at is null and parent_id is null and lower(btrim(name)) = lower(p->>'cat') limit 1;
      if v_cat_id is null then
        v_order := least(v_order + 1, 998);
        insert into public.categories (restaurant_id, name, display_order) values (v_rest, p->>'cat', v_order) returning id into v_cat_id;
      end if;
      if coalesce(p->>'sub', '') <> '' then
        v_tmp := null;
        select id into v_tmp from public.categories
         where restaurant_id = v_rest and deleted_at is null and parent_id = v_cat_id and lower(btrim(name)) = lower(p->>'sub') limit 1;
        if v_tmp is null then
          v_order := least(v_order + 1, 998);
          insert into public.categories (restaurant_id, name, parent_id, display_order)
          values (v_rest, p->>'sub', v_cat_id, v_order) returning id into v_tmp;
        end if;
        v_cat_id := v_tmp;
      end if;
      insert into public.products (restaurant_id, category_id, tax_group_id, name, price, is_veg, hsn_code, kitchen_station, name_local)
      values (v_rest, v_cat_id, (p->>'tax')::uuid, p->>'name', (p->>'price')::numeric,
              (p->>'veg')::boolean, p->>'hsn', p->>'station', p->>'local');
    else
      update public.products set
        price = (p->>'price')::numeric,
        tax_group_id = coalesce((p->>'tax')::uuid, tax_group_id),
        is_veg = coalesce((p->>'veg')::boolean, is_veg),
        hsn_code = coalesce(p->>'hsn', hsn_code),
        kitchen_station = coalesce(p->>'station', kitchen_station),
        name_local = coalesce(p->>'local', name_local)
       where id = (p->>'id')::uuid and restaurant_id = v_rest;
    end if;
  end loop;

  perform app.audit('menu.imported', 'restaurant', v_rest,
    jsonb_build_object('new_categories', v_new_cats, 'new_items', v_new_items, 'updated_items', v_upd), null);

  return jsonb_build_object('ok', true, 'applied', true, 'errors', '[]'::jsonb,
    'new_categories', v_new_cats, 'new_items', v_new_items, 'updated_items', v_upd, 'unchanged_items', v_same);
end $$;

revoke all on function public.import_menu(jsonb, boolean) from public, anon;
grant execute on function public.import_menu(jsonb, boolean) to authenticated, service_role;

------------------------------------------------------------------
-- 3. Account date
------------------------------------------------------------------
-- The business date the next bill of this outlet will carry, without opening a day.
-- old_day = true when a previous day is still open and will keep taking bills
-- (unpaid bills, an open shift or a parked day stop it closing by itself).
create function public.account_date() returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare v_branch uuid := app.current_branch_id(); d public.business_days; v_today date; v_stuck boolean;
begin
  if app.current_user_id() is null or v_branch is null then return null; end if;
  v_today := app.business_today(v_branch);
  select * into d from public.business_days where branch_id = v_branch and status = 'open';
  if found then
    if d.business_date >= v_today then
      return jsonb_build_object('date', d.business_date, 'old_day', false);
    end if;
    v_stuck := exists (select 1 from public.business_days where branch_id = v_branch and status = 'parked')
      or exists (select 1 from public.orders where branch_id = v_branch and business_date = d.business_date and status = 'completed'
                   and payment_status in ('unpaid', 'partial') and merged_into is null)
      or (coalesce((select shifts_enabled from public.branch_settings where branch_id = v_branch), false)
          and exists (select 1 from public.shifts where branch_id = v_branch and status = 'open'));
    if v_stuck then return jsonb_build_object('date', d.business_date, 'old_day', true); end if;
  end if;
  return jsonb_build_object('date',
    (select greatest(v_today, coalesce(max(business_date) + 1, v_today)) from public.business_days
      where branch_id = v_branch and status <> 'open'), 'old_day', false);
end $$;

revoke all on function public.account_date() from public, anon;
grant execute on function public.account_date() to authenticated, service_role;

------------------------------------------------------------------
-- 4. KOT: send to the kitchen, and claim tickets before printing
------------------------------------------------------------------
-- Kitchen tickets for every item of this bill that is not held, not cancelled, not a charge,
-- and has no ticket yet. Safe to call twice: the second call finds nothing new.
create function public.send_to_kitchen(p_order uuid) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare o public.orders%rowtype; v_ids uuid[];
begin
  perform app.require_permission('order.create');
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then return jsonb_build_object('sent', 0); end if;
  select array_agg(oi.id order by oi.created_at, oi.id) into v_ids
    from public.order_items oi
   where oi.order_id = o.id and not oi.held and oi.cancelled_at is null
     and not exists (select 1 from public.products cp where cp.id = oi.product_id and cp.is_charge)
     and not exists (select 1 from public.kitchen_ticket_items ki where ki.order_item_id = oi.id);
  if v_ids is null then return jsonb_build_object('sent', 0); end if;
  perform app.create_kitchen_ticket(o.id, v_ids);
  return jsonb_build_object('sent', array_length(v_ids, 1));
end $$;

-- Marks these tickets printed and returns only the ones that nobody had printed yet:
-- the caller prints exactly those. Another device asking a moment later gets none of them.
create function public.claim_tickets_for_print(p_ids uuid[]) returns uuid[]
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v uuid[];
begin
  if app.current_user_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  with upd as (
    update public.kitchen_tickets set printed_at = now()
     where id = any(coalesce(p_ids, '{}')) and restaurant_id = app.current_restaurant_id() and printed_at is null
    returning id)
  select coalesce(array_agg(id), '{}') into v from upd;
  return v;
end $$;

revoke all on function public.send_to_kitchen(uuid), public.claim_tickets_for_print(uuid[]) from public, anon;
grant execute on function public.send_to_kitchen(uuid), public.claim_tickets_for_print(uuid[]) to authenticated, service_role;

commit;
