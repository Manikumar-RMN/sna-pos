-- 109: Telling the online-ordering partner what happened to an order.
-- Each channel (swiggy, zomato, website…) can have the partner's address (https) and a shared secret. When staff
-- accept, reject or mark an online order ready, SNA POS sends the partner a short signed message:
--   {"event": "accepted"|"rejected"|"ready", "channel": …, "order_id": <partner's order number>, "bill_number": …, "reason": …, "at": …}
-- with the header X-SNA-Signature = hex HMAC-SHA256 of the body using the secret. The secret is shown once, when made.

create table public.online_channels (
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  channel text not null check (channel ~ '^[a-z0-9_]{2,20}$'),
  callback_url text check (callback_url is null or (callback_url ~ '^https://[^/\s]+' and length(callback_url) <= 300)),
  secret text not null,
  updated_at timestamptz not null default now(),
  primary key (restaurant_id, channel)
);
alter table public.online_channels enable row level security;
revoke all on public.online_channels from anon, authenticated;

alter table public.online_orders add column ready_at timestamptz;

-- Add or change a channel's partner address. Returns the secret only when it is new (made now or remade).
create or replace function public.online_channel_save(p_channel text, p_url text, p_new_secret boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id();
  v_ch text := lower(btrim(coalesce(p_channel, ''))); v_url text := nullif(btrim(coalesce(p_url, '')), ''); v_secret text; v_had boolean;
begin
  if v_ch !~ '^[a-z0-9_]{2,20}$' then raise exception 'The channel is a short name such as swiggy, zomato or website.'; end if;
  if v_url is not null and (v_url !~ '^https://[^/\s]+' or length(v_url) > 300
      or v_url ~* '^https://(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|\[)') then
    raise exception 'Enter the partner''s https address (for example https://partner.example.com/sna).';
  end if;
  select true into v_had from public.online_channels where restaurant_id = v_rest and channel = v_ch;
  if coalesce(v_had, false) and not coalesce(p_new_secret, false) then
    update public.online_channels set callback_url = v_url, updated_at = now() where restaurant_id = v_rest and channel = v_ch;
  else
    v_secret := 'snasec_' || app.new_token(32);
    insert into public.online_channels (restaurant_id, channel, callback_url, secret) values (v_rest, v_ch, v_url, v_secret)
    on conflict (restaurant_id, channel) do update set callback_url = excluded.callback_url, secret = excluded.secret, updated_at = now();
  end if;
  perform app.audit('online.channel', 'restaurants', v_rest, jsonb_build_object('channel', v_ch, 'url', v_url, 'new_secret', v_secret is not null), null);
  return jsonb_build_object('channel', v_ch, 'url', v_url, 'secret', v_secret);
end $function$;

create or replace function public.online_channels_list()
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('channel', c.channel, 'url', c.callback_url, 'updated_at', c.updated_at) order by c.channel), '[]'::jsonb)
    from public.online_channels c where c.restaurant_id = app.current_restaurant_id() and app.allowed('settings.manage')
$function$;

-- Marks an accepted online order ready for pickup by the partner's rider.
create or replace function public.online_order_mark_ready(p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('order.create');
begin
  update public.online_orders set ready_at = now()
   where id = p_id and restaurant_id = app.current_restaurant_id() and status = 'accepted' and ready_at is null;
  if not found then raise exception 'Only an accepted order that is not yet ready can be marked ready.'; end if;
end $function$;

-- The signed message to send to the partner for an event, or null when the channel has no partner address.
create or replace function public.online_order_callback(p_id uuid, p_event text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('order.create'); q public.online_orders; c public.online_channels; v_body text;
begin
  if p_event not in ('accepted', 'rejected', 'ready') then raise exception 'Unknown event.'; end if;
  select * into q from public.online_orders where id = p_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That online order was not found.'; end if;
  select * into c from public.online_channels where restaurant_id = q.restaurant_id and channel = q.channel;
  if not found or c.callback_url is null then return null; end if;
  v_body := jsonb_build_object('event', p_event, 'channel', q.channel, 'order_id', q.external_ref,
              'bill_number', (select bill_number from public.orders where id = q.order_id),
              'reason', case when p_event = 'rejected' then q.reject_reason end,
              'at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))::text;
  return jsonb_build_object('url', c.callback_url, 'body', v_body, 'signature', encode(extensions.hmac(v_body, c.secret, 'sha256'), 'hex'));
end $function$;

create or replace function public.online_orders_list()
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'channel', q.channel, 'external_ref', q.external_ref, 'status', q.status,
           'customer_name', q.customer_name, 'customer_phone', q.customer_phone, 'address', q.address, 'note', q.note,
           'paid_online', q.paid_online, 'partner_total', q.partner_total, 'created_at', q.created_at, 'reject_reason', q.reject_reason,
           'bill_number', o.bill_number, 'order_id', q.order_id, 'ready_at', q.ready_at,
           'items', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'qty', (i->>'qty')::numeric, 'note', nullif(i->>'note', ''))), '[]'::jsonb)
                       from jsonb_array_elements(q.items) i join public.products p on p.id = (i->>'product_id')::uuid))
         order by q.status <> 'pending', q.created_at desc), '[]'::jsonb)
    from public.online_orders q left join public.orders o on o.id = q.order_id
   where q.restaurant_id = app.current_restaurant_id() and q.branch_id = app.current_branch_id() and app.allowed('order.create')
     and (q.status = 'pending' or q.created_at > now() - interval '24 hours')
$function$;

revoke all on function public.online_channel_save(text, text, boolean), public.online_channels_list(), public.online_order_mark_ready(uuid), public.online_order_callback(uuid, text) from public, anon;
grant execute on function public.online_channel_save(text, text, boolean), public.online_channels_list(), public.online_order_mark_ready(uuid), public.online_order_callback(uuid, text) to authenticated, service_role;

-- Erasing a test restaurant also removes its partner addresses.
CREATE OR REPLACE FUNCTION app.erase_groups()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('online_orders', 'customer_ledger', 'batch_movements', 'pre_order_payments', 'pre_orders', 'order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('online_channels', 'product_batches', 'price_rules', 'product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'branch_prices',
            'products', 'categories', 'brands', 'dining_tables', 'floors', 'customers', 'riders'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$;
