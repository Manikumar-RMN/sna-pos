-- 061: QR table ordering (guest orders from the phone, staff accept) and the shareable e-bill (WhatsApp).

-- ---------- QR codes on tables ----------
alter table public.dining_tables add column if not exists qr_token text;
create unique index if not exists dining_tables_qr_token_uq on public.dining_tables (qr_token) where qr_token is not null;

create or replace function app.new_token(p_bytes int default 18) returns text
language sql volatile set search_path = public, extensions, pg_temp as $$
  select translate(encode(extensions.gen_random_bytes(p_bytes), 'base64'), '+/=', '-_');
$$;

-- Makes sure every active table has a QR code and returns them (for printing the QR sheet).
create or replace function public.table_qr_codes() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  perform app.require_permission('settings.manage');
  perform app.require_feature('qr_ordering');
  update public.dining_tables set qr_token = app.new_token()
   where restaurant_id = v_rest and branch_id = v_branch and is_active and qr_token is null;
  return coalesce((select jsonb_agg(jsonb_build_object('table_id', t.id, 'table_number', t.table_number, 'token', t.qr_token)
                    order by length(t.table_number), t.table_number)
                     from public.dining_tables t where t.restaurant_id = v_rest and t.branch_id = v_branch and t.is_active), '[]'::jsonb);
end $$;

-- New code for one table (the old printed QR stops working).
create or replace function public.reset_table_qr(p_table uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('settings.manage');
  update public.dining_tables set qr_token = app.new_token()
   where id = p_table and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That table does not exist.'; end if;
  perform app.audit('table.qr_reset', 'dining_tables', p_table, '{}'::jsonb, null);
end $$;

-- ---------- Guest order requests ----------
create table if not exists public.qr_orders (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  branch_id uuid not null references public.branches(id),
  dining_table_id uuid not null references public.dining_tables(id),
  items jsonb not null,
  estimated_total numeric(14,2),
  guest_name text check (guest_name is null or length(guest_name) <= 60),
  guest_note text check (guest_note is null or length(guest_note) <= 200),
  guest_key text not null,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  order_id uuid references public.orders(id),
  decided_by uuid references public.users(id),
  decided_at timestamptz,
  reject_reason text,
  created_at timestamptz not null default now()
);
create index if not exists qr_orders_pending_idx on public.qr_orders (restaurant_id, branch_id, status, created_at);
alter table public.qr_orders enable row level security;
drop policy if exists tenant_read on public.qr_orders;
create policy tenant_read on public.qr_orders for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id()));
revoke all on public.qr_orders from anon;
revoke insert, update, delete on public.qr_orders from authenticated;
grant select on public.qr_orders to authenticated;

-- The table behind a QR code; refuses when the code is unknown or the add-on is off.
create or replace function app.qr_table(p_token text) returns public.dining_tables
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t public.dining_tables%rowtype;
begin
  if coalesce(length(p_token), 0) < 16 or length(p_token) > 64 then raise exception 'This QR code is not valid.'; end if;
  select * into t from public.dining_tables where qr_token = p_token and is_active;
  if not found or not app.feature_on(t.restaurant_id, 'qr_ordering') then
    raise exception 'This QR code is not active. Please ask the staff.';
  end if;
  return t;
end $$;

-- Menu for the guest's phone (no sign-in).
create or replace function public.qr_menu(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare t public.dining_tables%rowtype := app.qr_table(p_token); r record;
begin
  select res.trading_name, res.currency_code, res.second_language, b.name as branch_name
    into r from public.restaurants res join public.branches b on b.id = t.branch_id where res.id = t.restaurant_id;
  return jsonb_build_object(
    'restaurant', r.trading_name, 'outlet', r.branch_name, 'currency', r.currency_code,
    'second_language', r.second_language, 'table', t.table_number,
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items', c.items) order by c.display_order, c.name)
        from (
          select c.id, c.name, c.display_order,
                 jsonb_agg(jsonb_build_object(
                   'id', p.id, 'name', p.name, 'name_local', p.name_local, 'is_veg', p.is_veg,
                   'price', coalesce(bp.price, p.price),
                   'option_groups', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'id', mg.id, 'name', mg.name,
                              'min', greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end),
                              'max', coalesce(mg.max_select, 99),
                              'options', (select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price_delta', mi.price_delta)
                                                             order by mi.display_order, mi.name), '[]'::jsonb)
                                            from public.modifier_items mi where mi.modifier_group_id = mg.id and mi.is_active))
                            order by mg.is_required desc, mg.name)
                       from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id
                      where pmg.product_id = p.id and mg.is_active), '[]'::jsonb))
                   order by p.display_order, p.name) as items
            from public.categories c
            join public.products p on p.category_id = c.id and p.deleted_at is null
            left join public.branch_prices bp on bp.product_id = p.id and bp.branch_id = t.branch_id
           where c.restaurant_id = t.restaurant_id and c.deleted_at is null
             and p.is_available and coalesce(bp.is_available, true)
           group by c.id, c.name, c.display_order
        ) c), '[]'::jsonb));
end $$;

-- Guest sends the order. It waits for staff to accept; nothing reaches the kitchen or the bill before that.
create or replace function public.qr_place_order(p_token text, p_items jsonb, p_guest_name text default null, p_note text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare t public.dining_tables%rowtype := app.qr_table(p_token); v_in jsonb; v_total numeric; v_key text := app.new_token(); v_id uuid; v_items jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Your order is empty.'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Please send at most 30 lines at a time.'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) x
              where coalesce((x->>'qty')::numeric, 0) not between 1 and 20 or (x->>'qty')::numeric <> trunc((x->>'qty')::numeric)) then
    raise exception 'Each quantity must be a whole number from 1 to 20.';
  end if;
  if (select count(*) from public.qr_orders q where q.dining_table_id = t.id and q.status = 'pending') >= 3 then
    raise exception 'This table already has orders waiting. Please wait for the staff to accept them.';
  end if;
  if (select count(*) from public.qr_orders q where q.dining_table_id = t.id and q.created_at > now() - interval '10 minutes') >= 8 then
    raise exception 'Too many orders from this table. Please ask the staff.';
  end if;
  -- Keep only the fields staff billing uses; guests cannot hold items or set prices.
  select jsonb_agg(jsonb_build_object('product_id', x->>'product_id', 'qty', (x->>'qty')::int,
                                      'note', left(coalesce(x->>'note', ''), 120),
                                      'options', coalesce(case when jsonb_typeof(x->'options') = 'array' then x->'options' end, '[]'::jsonb)))
    into v_items from jsonb_array_elements(p_items) x;
  v_in := app.bill_input(t.restaurant_id, t.branch_id, v_items, 0, null, null);  -- checks items, options, sold out
  v_total := (app.calc_bill(v_in->'calc')->>'grand_total')::numeric;
  insert into public.qr_orders (restaurant_id, branch_id, dining_table_id, items, estimated_total, guest_name, guest_note, guest_key)
  values (t.restaurant_id, t.branch_id, t.id, v_items, v_total, nullif(left(trim(p_guest_name), 60), ''), nullif(left(trim(p_note), 200), ''), v_key)
  returning id into v_id;
  return jsonb_build_object('request_id', v_id, 'key', v_key, 'estimated_total', v_total);
end $$;

-- Guest's phone checks whether the order was accepted.
create or replace function public.qr_order_status(p_request uuid, p_key text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('status', q.status, 'reason', q.reject_reason, 'estimated_total', q.estimated_total)
    from public.qr_orders q where q.id = p_request and q.guest_key = p_key;
$$;

-- Staff accept: items join the table's open bill (or start a new one) and go to the kitchen.
create or replace function public.accept_qr_order(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare q public.qr_orders%rowtype; v_order uuid; v_res jsonb; v_table text;
begin
  perform app.require_permission('order.create');
  perform app.require_feature('qr_ordering');
  select * into q from public.qr_orders where id = p_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That table order does not exist.'; end if;
  if q.status <> 'pending' then raise exception 'This table order was already %.', q.status; end if;
  if q.branch_id <> app.current_branch_id() then raise exception 'This order is for another outlet. Switch outlet first.'; end if;
  select o.id into v_order from public.orders o
   where o.dining_table_id = q.dining_table_id and o.restaurant_id = q.restaurant_id
     and o.payment_status in ('unpaid', 'partial') and o.status <> 'voided' and o.merged_into is null
   order by o.created_at desc limit 1;
  if v_order is not null then
    perform public.add_order_items(v_order, q.items);
    select bill_number into v_table from public.orders where id = v_order;
    v_res := jsonb_build_object('order_id', v_order, 'bill_number', v_table, 'added', true);
  else
    v_res := public.create_order(q.items, 'dine_in', q.dining_table_id, null, null, null, 0, null, null, null, null, null);
    v_order := (v_res->>'order_id')::uuid;
  end if;
  update public.qr_orders set status = 'accepted', order_id = v_order, decided_by = app.current_user_id(), decided_at = now() where id = p_id;
  perform app.audit('qr_order.accept', 'qr_orders', p_id, jsonb_build_object('order_id', v_order), null);
  return v_res;
end $$;

create or replace function public.reject_qr_order(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('order.create');
  update public.qr_orders set status = 'rejected', reject_reason = nullif(left(trim(p_reason), 120), ''),
         decided_by = app.current_user_id(), decided_at = now()
   where id = p_id and restaurant_id = app.current_restaurant_id() and status = 'pending';
  if not found then raise exception 'That table order is not waiting any more.'; end if;
  perform app.audit('qr_order.reject', 'qr_orders', p_id, jsonb_build_object('reason', p_reason), null);
end $$;

-- ---------- E-bill link (WhatsApp) ----------
alter table public.orders add column if not exists receipt_token text;
create unique index if not exists orders_receipt_token_uq on public.orders (receipt_token) where receipt_token is not null;

-- Makes (once) the private link for a bill and returns it with the customer's phone, if known.
create or replace function public.share_bill(p_order uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tok text; v_phone text;
begin
  perform app.require_permission('order.create');
  perform app.require_feature('whatsapp');
  update public.orders set receipt_token = coalesce(receipt_token, app.new_token())
   where id = p_order and restaurant_id = app.current_restaurant_id()
   returning receipt_token into v_tok;
  if v_tok is null then raise exception 'That bill does not exist.'; end if;
  select c.phone into v_phone from public.orders o join public.customers c on c.id = o.customer_id where o.id = p_order;
  perform app.audit('order.share', 'orders', p_order, '{}'::jsonb, null);
  return jsonb_build_object('token', v_tok, 'phone', v_phone);
end $$;

-- The e-bill page (no sign-in; the long random link is the key).
create or replace function public.public_receipt(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; r record;
begin
  if coalesce(length(p_token), 0) < 16 or length(p_token) > 64 then return null; end if;
  select * into o from public.orders where receipt_token = p_token;
  if not found then return null; end if;
  select res.legal_name, res.trading_name, res.tax_registration_no, res.fssai_no, res.timezone, res.country_code,
         c.tax_id_label, c.invoice_title, b.name as branch_name,
         concat_ws(', ', nullif(b.address_line1, ''), nullif(b.address_line2, ''), nullif(b.city, '')) as address,
         bs.receipt_footer
    into r from public.restaurants res
    join public.branches b on b.id = o.branch_id
    left join public.countries c on c.code = res.country_code
    left join public.branch_settings bs on bs.branch_id = o.branch_id
   where res.id = o.restaurant_id;
  return jsonb_build_object(
    'restaurant', r.trading_name, 'legal_name', r.legal_name, 'outlet', r.branch_name, 'address', nullif(r.address, ''),
    'tax_label', coalesce(r.tax_id_label, 'Tax no.'), 'tax_no', r.tax_registration_no, 'fssai', r.fssai_no,
    'title', coalesce(r.invoice_title, 'Tax invoice'), 'footer', r.receipt_footer,
    'bill_number', o.bill_number, 'date', to_char(o.created_at at time zone coalesce(r.timezone, 'UTC'), 'DD Mon YYYY, HH24:MI'),
    'currency', o.currency_code, 'status', o.status, 'payment_status', o.payment_status,
    'buyer_gstin', o.buyer_gstin, 'buyer_name', o.buyer_name,
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'local', i.product_name_local,
                                  'options', i.options_text, 'qty', i.quantity, 'amount', i.line_subtotal) order by i.created_at, i.id)
                        from public.order_items i where i.order_id = o.id and i.cancelled_at is null), '[]'::jsonb),
    'taxes', coalesce((select jsonb_agg(jsonb_build_object('name', x.n, 'amount', x.a) order by x.n)
                        from (select t.component_name || ' (' || rtrim(rtrim(to_char(t.rate, 'FM990.99'), '0'), '.') || '%)' as n, sum(t.tax_amount) as a
                                from public.order_item_taxes t where t.order_id = o.id group by 1 having sum(t.tax_amount) <> 0) x), '[]'::jsonb),
    'subtotal', o.subtotal, 'discount', o.discount_total, 'service_charge', o.service_charge,
    'rounding', o.rounding_adjustment, 'tax_included', o.tax_included, 'grand_total', o.grand_total, 'paid', o.paid_total);
end $$;

revoke all on function public.table_qr_codes(), public.reset_table_qr(uuid), public.qr_menu(text),
  public.qr_place_order(text, jsonb, text, text), public.qr_order_status(uuid, text), public.accept_qr_order(uuid),
  public.reject_qr_order(uuid, text), public.share_bill(uuid), public.public_receipt(text) from public;
grant execute on function public.qr_menu(text), public.qr_place_order(text, jsonb, text, text),
  public.qr_order_status(uuid, text), public.public_receipt(text) to anon, authenticated;
grant execute on function public.table_qr_codes(), public.reset_table_qr(uuid), public.accept_qr_order(uuid),
  public.reject_qr_order(uuid, text), public.share_bill(uuid) to authenticated;
revoke all on function app.qr_table(text), app.new_token(int) from public, anon, authenticated;
