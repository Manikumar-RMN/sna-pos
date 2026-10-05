-- 086: a client's "Live" switch, and erasing a client's test data before go-live
--
-- Founder's rules (5 Oct 2026):
--   * SNA staff can erase a client's data from the console, choosing the module
--     (POS, Stock) and the kind (Transactions, Masters).
--   * Only before go-live: once a client is marked Live the erase is refused, so
--     the tax bills a trading restaurant must keep cannot be wiped by mistake.
--   * Any SNA role may erase. Marking Live: any role. Taking Live off: admin only.
--
-- What each choice removes (always for ONE restaurant only):
--   POS transactions  : bills and their lines, payments, credit notes, kitchen
--                       tickets, shifts, cash in/out, day closes, guest QR orders,
--                       bookings, timesheets, loyalty points, gift cards, owner
--                       alerts, the activity log, and the stock used by those
--                       bills. Bill numbers start again at 0001.
--   POS masters       : menu (categories, dishes, options, outlet prices), tables,
--                       customers. Recipes of the erased dishes go with them.
--   Stock transactions: every stock movement, purchase orders, goods received,
--                       supplier payments. Stock goes back to zero.
--   Stock masters     : ingredients, recipes, suppliers.
--   Masters can only be erased together with the transactions of the same module.
--   Never touched: the restaurant itself, outlets, staff, roles, taxes, payment
--   methods, settings, printers, counter tablets, and SNA's own records.
--
-- Bills, payments and the like cannot normally be deleted (app.block_delete).
-- That stays true. The two blocking functions now let a delete through only
-- while sna_erase is running, and only for the restaurant it is erasing.

begin;

alter table public.sna_accounts add column live_at timestamptz;
alter table public.sna_accounts add column live_by uuid references public.sna_staff(id) on delete set null;
comment on column public.sna_accounts.live_at is
  'When SNA marked this client as live (trading for real). While it is set, the client''s data cannot be erased from the console.';

------------------------------------------------------------------
-- 1. The two "cannot be deleted" guards: unchanged, except during an erase
------------------------------------------------------------------
create or replace function app.block_delete() returns trigger
language plpgsql set search_path to 'public', 'pg_temp'
as $$
begin
  -- sna_erase sets this for its own transaction, to the one restaurant being erased.
  if tg_op = 'DELETE' and nullif(current_setting('app.erase_restaurant', true), '') is not null
     and (to_jsonb(old)->>'restaurant_id') = current_setting('app.erase_restaurant', true) then
    return old;
  end if;
    raise exception
        'Records in % cannot be deleted. Use void or refund so the trail is kept.',
        tg_table_name;
end
$$;

create or replace function app.block_update() returns trigger
language plpgsql set search_path to 'public', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' and nullif(current_setting('app.erase_restaurant', true), '') is not null
     and (to_jsonb(old)->>'restaurant_id') = current_setting('app.erase_restaurant', true) then
    return old;
  end if;
  raise exception '% records cannot be changed.', initcap(replace(tg_table_name, '_', ' '));
end $$;

------------------------------------------------------------------
-- 2. Which tables belong to which choice
------------------------------------------------------------------
-- Children before parents where it matters; app.erase_tables also retries, so the order is only a help.
create function app.erase_groups() returns jsonb
language sql immutable set search_path to 'public', 'pg_temp'
as $$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'branch_prices',
            'products', 'categories', 'dining_tables', 'floors', 'customers'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $$;

-- Deletes one restaurant's rows from the tables named. Returns how many rows went.
create function app.erase_tables(p_restaurant uuid, p_tables jsonb) returns bigint
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare t text; v_n bigint; v_total bigint := 0; v_left int; v_err text; v_pass int;
begin
  for v_pass in 1..8 loop
    v_left := 0;
    for t in select jsonb_array_elements_text(p_tables) loop
      begin
        execute format('delete from public.%I where restaurant_id = $1', t) using p_restaurant;
        get diagnostics v_n = row_count;
        v_total := v_total + v_n;
      exception when foreign_key_violation then
        -- Something else still points at these rows; it is later in the list. Try again on the next pass.
        v_left := v_left + 1; v_err := sqlerrm;
      end;
    end loop;
    exit when v_left = 0;
  end loop;
  if v_left > 0 then raise exception 'Could not erase everything, so nothing was erased: %', v_err; end if;
  return v_total;
end $$;

revoke all on function app.erase_groups(), app.erase_tables(uuid, jsonb) from public, anon, authenticated;

------------------------------------------------------------------
-- 3. Live switch
------------------------------------------------------------------
create function public.sna_set_live(p_restaurant uuid, p_live boolean, p_reason text default null) returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_me uuid; v_was timestamptz; v_reason text := trim(coalesce(p_reason, ''));
begin
  if coalesce(p_live, false) then
    v_me := app.sna_require(array['sales', 'implementer', 'support']);
  else
    -- Taking Live off opens the door to erasing real bills: admins only, with a reason.
    v_me := app.sna_require(array[]::text[]);
    if length(v_reason) < 5 then raise exception 'Write why this client is no longer live.'; end if;
  end if;
  perform app.sna_account_row(p_restaurant);
  select live_at into v_was from public.sna_accounts where restaurant_id = p_restaurant for update;
  if coalesce(p_live, false) = (v_was is not null) then return; end if;
  update public.sna_accounts
     set live_at = case when p_live then now() end, live_by = case when p_live then v_me end, updated_at = now(), updated_by = v_me
   where restaurant_id = p_restaurant;
  perform app.log_plan(p_restaurant, case when p_live then 'client.live' else 'client.not_live' end,
                       jsonb_strip_nulls(jsonb_build_object('reason', nullif(left(v_reason, 300), ''))));
end $$;

------------------------------------------------------------------
-- 4. What an erase would remove
------------------------------------------------------------------
create function public.sna_erase_preview(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare r public.restaurants%rowtype; a public.sna_accounts%rowtype; g text; t text; v_n bigint; v_sum bigint; v_out jsonb := '{}'::jsonb; v_parts jsonb;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_id and deleted_at is null;
  if not found then raise exception 'Restaurant not found.'; end if;
  select * into a from public.sna_accounts where restaurant_id = p_id;
  for g in select jsonb_object_keys(app.erase_groups()) loop
    v_sum := 0; v_parts := '{}'::jsonb;
    for t in select jsonb_array_elements_text(app.erase_groups()->g) loop
      execute format('select count(*) from public.%I where restaurant_id = $1', t) into v_n using p_id;
      v_sum := v_sum + v_n;
      if v_n > 0 then v_parts := v_parts || jsonb_build_object(t, v_n); end if;
    end loop;
    v_out := v_out || jsonb_build_object(g, jsonb_build_object('rows', v_sum, 'tables', v_parts));
  end loop;
  return jsonb_build_object(
    'live', a.live_at is not null, 'live_at', a.live_at,
    'live_by', (select full_name from public.sna_staff where id = a.live_by),
    'client_code', r.client_code, 'trading_name', r.trading_name,
    'bills', (select count(*) from public.orders where restaurant_id = p_id),
    'groups', v_out);
end $$;

------------------------------------------------------------------
-- 5. The erase
------------------------------------------------------------------
create function public.sna_erase(
  p_restaurant uuid, p_pos_tx boolean, p_pos_master boolean, p_stock_tx boolean, p_stock_master boolean,
  p_client_code text, p_reason text
) returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare
  v_me uuid; r public.restaurants%rowtype; v_live timestamptz;
  v_reason text := trim(coalesce(p_reason, ''));
  v_pos_tx boolean := coalesce(p_pos_tx, false); v_pos_ms boolean := coalesce(p_pos_master, false);
  v_stk_tx boolean := coalesce(p_stock_tx, false); v_stk_ms boolean := coalesce(p_stock_master, false);
  v_g jsonb := app.erase_groups(); v_done jsonb := '{}'::jsonb; v_n bigint; v_more bigint;
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_restaurant and deleted_at is null for update;
  if not found then raise exception 'Restaurant not found.'; end if;
  if not (v_pos_tx or v_pos_ms or v_stk_tx or v_stk_ms) then raise exception 'Tick what to erase.'; end if;
  if v_pos_ms and not v_pos_tx then
    raise exception 'To erase POS masters, tick POS transactions too. The menu and tables cannot go while bills still point at them.';
  end if;
  if v_stk_ms and not v_stk_tx then
    raise exception 'To erase Stock masters, tick Stock transactions too. Ingredients and suppliers cannot go while stock entries still point at them.';
  end if;
  select live_at into v_live from public.sna_accounts where restaurant_id = p_restaurant;
  if v_live is not null then
    raise exception 'This client is live, so its data cannot be erased. These are real bills the restaurant must keep.';
  end if;
  if trim(coalesce(p_client_code, '')) is distinct from r.client_code then
    raise exception 'The client code does not match. Type % to confirm.', r.client_code;
  end if;
  if length(v_reason) < 5 then raise exception 'Write why this data is being erased.'; end if;

  -- From here to the end of this transaction, the "cannot be deleted" guards let this one restaurant through.
  perform set_config('app.erase_restaurant', p_restaurant::text, true);

  if v_pos_tx then
    v_n := app.erase_tables(p_restaurant, v_g->'pos_tx');
    -- The stock those bills used goes with them (sales and returns are stock entries tied to a bill).
    if not v_stk_tx then
      delete from public.stock_movements where restaurant_id = p_restaurant and order_id is not null;
      get diagnostics v_more = row_count;
      v_n := v_n + v_more;
    end if;
    update public.devices set next_bill_seq = 1 where restaurant_id = p_restaurant;
    update public.offline_series set next_seq = 1 where restaurant_id = p_restaurant;
    v_done := v_done || jsonb_build_object('pos_tx', v_n);
  end if;
  if v_stk_tx then
    v_done := v_done || jsonb_build_object('stock_tx', app.erase_tables(p_restaurant, v_g->'stock_tx'));
  end if;
  if v_pos_ms then
    -- The packing charge is a dish; the outlet setting that points at it is switched off.
    update public.branch_settings set packing_product_id = null where restaurant_id = p_restaurant and packing_product_id is not null;
    v_done := v_done || jsonb_build_object('pos_master', app.erase_tables(p_restaurant, v_g->'pos_master'));
  end if;
  if v_stk_ms then
    v_done := v_done || jsonb_build_object('stock_master', app.erase_tables(p_restaurant, v_g->'stock_master'));
  end if;

  perform set_config('app.erase_restaurant', '', true);
  perform app.log_plan(p_restaurant, 'data.erased', jsonb_build_object('rows', v_done, 'reason', left(v_reason, 300)));
  return jsonb_build_object('rows', v_done);
end $$;

revoke all on function public.sna_set_live(uuid, boolean, text), public.sna_erase_preview(uuid),
  public.sna_erase(uuid, boolean, boolean, boolean, boolean, text, text) from public, anon;
grant execute on function public.sna_set_live(uuid, boolean, text), public.sna_erase_preview(uuid),
  public.sna_erase(uuid, boolean, boolean, boolean, boolean, text, text) to authenticated, service_role;

commit;
