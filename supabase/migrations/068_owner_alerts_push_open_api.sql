-- 068: owner alerts (with phone push), and the open API (read-only v1 with API keys).

create extension if not exists pg_net;

-- ---------- Owner alerts ----------
create table if not exists public.owner_alerts (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  branch_id uuid references public.branches(id),
  kind text not null,
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);
create index if not exists owner_alerts_rest_idx on public.owner_alerts (restaurant_id, created_at desc);
alter table public.owner_alerts enable row level security;
drop policy if exists tenant_read on public.owner_alerts;
create policy tenant_read on public.owner_alerts for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()) and app.has_permission('report.view_sales'));
revoke all on public.owner_alerts from anon;
revoke insert, update, delete on public.owner_alerts from authenticated;
grant select on public.owner_alerts to authenticated;

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  user_id uuid not null references public.users(id),
  endpoint text not null unique check (endpoint like 'https://%' and length(endpoint) < 1000),
  p256dh text not null check (length(p256dh) < 200),
  auth text not null check (length(auth) < 100),
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
drop policy if exists own_read on public.push_subscriptions;
create policy own_read on public.push_subscriptions for select to authenticated using (user_id = (select app.current_user_id()));
revoke all on public.push_subscriptions from anon;
revoke insert, update, delete on public.push_subscriptions from authenticated;
grant select on public.push_subscriptions to authenticated;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_feature('owner_app');
  if not app.has_permission('report.view_sales') then raise exception 'Alerts are for owners and managers (report.view_sales).'; end if;
  insert into public.push_subscriptions (restaurant_id, user_id, endpoint, p256dh, auth)
  values (app.current_restaurant_id(), app.current_user_id(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set restaurant_id = excluded.restaurant_id, user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function public.remove_push_subscription(p_endpoint text) returns void
language sql security definer set search_path = public, pg_temp as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = app.current_user_id();
$$;

-- Audit events worth telling the owner about become alerts.
create or replace function app.audit_to_alert() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_title text; v_body text; v_who text; v_outlet text; v_cur text; n jsonb := coalesce(new.new_value, '{}'::jsonb); o jsonb := coalesce(new.old_value, '{}'::jsonb); v_bill text;
begin
  if new.restaurant_id is null or new.action not in ('order.void', 'credit_note.issue', 'day.close', 'day.reopen', 'shift.close', 'order.adjust',
      'order.cancel_item', 'payment.change_mode', 'approval.granted', 'menu.price_or_tax_changed') then
    return new;
  end if;
  if not app.feature_on(new.restaurant_id, 'owner_app') then return new; end if;
  if new.action = 'order.adjust' and coalesce((n->>'discount')::numeric, 0) = 0 then return new; end if;
  if new.action = 'shift.close' and coalesce((n->>'variance')::numeric, 0) = 0 then return new; end if;
  select full_name into v_who from public.users where id = new.user_id;
  select name into v_outlet from public.branches where id = new.branch_id;
  select currency_code into v_cur from public.restaurants where id = new.restaurant_id;
  if new.action = 'order.void' then select bill_number into v_bill from public.orders where id = new.entity_id; end if;
  v_title := case new.action
    when 'order.void' then 'Bill voided'
    when 'credit_note.issue' then 'Credit note (refund)'
    when 'day.close' then 'Day closed'
    when 'day.reopen' then 'Day reopened'
    when 'shift.close' then 'Cash short / over at shift close'
    when 'order.adjust' then 'Discount given'
    when 'order.cancel_item' then 'Item cancelled'
    when 'payment.change_mode' then 'Payment mode changed'
    when 'approval.granted' then 'Manager PIN used'
    else 'Price changed' end;
  v_body := concat_ws(' · ',
    case new.action
      when 'order.void' then concat('Bill ', v_bill, ' ', v_cur, ' ', o->>'grand_total', ' — ', n->>'reason')
      when 'credit_note.issue' then concat(n->>'number', ' on bill ', n->>'bill_number', ': ', v_cur, ' ', n->>'amount', ' — ', n->>'reason')
      when 'day.close' then concat(n->>'business_date', ': ', n->>'bills', ' bills, ', v_cur, ' ', n->>'total_billed')
      when 'day.reopen' then concat(n->>'business_date', ' — ', n->>'reason')
      when 'shift.close' then concat('Counted ', v_cur, ' ', n->>'counted_cash', ', expected ', n->>'expected_cash', ' (', n->>'variance', ')')
      when 'order.adjust' then concat('Bill ', n->>'bill_number', ': discount ', v_cur, ' ', n->>'discount', coalesce(' — ' || (n->>'reason'), ''))
      when 'order.cancel_item' then concat('Bill ', n->>'bill_number', ': ', n->>'qty', ' × ', n->>'item', ' — ', n->>'reason')
      when 'payment.change_mode' then concat('Bill ', n->>'bill_number', ': ', o->>'method', ' → ', n->>'method', ' — ', n->>'reason')
      when 'approval.granted' then concat(n->>'approver', ' approved ', n->>'permission')
      else concat(n->>'name', ': ', o->>'price', ' → ', n->>'price') end,
    v_who, v_outlet);
  insert into public.owner_alerts (restaurant_id, branch_id, kind, title, body) values (new.restaurant_id, new.branch_id, new.action, v_title, left(v_body, 300));
  return new;
end $$;
drop trigger if exists trg_audit_to_alert on public.audit_logs;
create trigger trg_audit_to_alert after insert on public.audit_logs for each row execute function app.audit_to_alert();

-- Each new alert is pushed to the phones of owners/managers who turned alerts on (sent by the app's /api/push).
create or replace function app.push_alert() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_subs jsonb; v_url text; v_secret text;
begin
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth))), '[]'::jsonb)
    into v_subs
    from public.push_subscriptions s
    join public.users u on u.id = s.user_id and u.is_active
    join public.role_permissions rp on rp.role_id = u.role_id and rp.permission_key = 'report.view_sales'
   where s.restaurant_id = new.restaurant_id;
  if jsonb_array_length(v_subs) = 0 then return new; end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_secret';
  if v_url is null or v_secret is null then return new; end if;
  perform net.http_post(url := v_url,
    body := jsonb_build_object('subscriptions', v_subs, 'title', new.title, 'body', new.body, 'url', '/owner'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    timeout_milliseconds := 5000);
  return new;
exception when others then
  return new;  -- an alert must never block the bill that caused it
end $$;
drop trigger if exists trg_push_alert on public.owner_alerts;
create trigger trg_push_alert after insert on public.owner_alerts for each row execute function app.push_alert();

-- The push sender reports phones that are gone (uninstalled app / alerts blocked) so they are removed.
create or replace function public.push_gone(p_secret text, p_endpoints text[]) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_secret is null or p_secret <> (select decrypted_secret from vault.decrypted_secrets where name = 'push_secret') then
    raise exception 'Not allowed.';
  end if;
  delete from public.push_subscriptions where endpoint = any(p_endpoints);
end $$;

-- ---------- Open API ----------
create table if not exists public.api_keys (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  name text not null check (length(name) between 1 and 60),
  prefix text not null,
  key_hash text not null unique,
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);
create table if not exists public.api_calls (
  id bigserial primary key,
  key_id uuid not null references public.api_keys(id),
  action text not null,
  at timestamptz not null default now()
);
create index if not exists api_calls_key_at on public.api_calls (key_id, at desc);
alter table public.api_keys enable row level security;
drop policy if exists tenant_read on public.api_keys;
create policy tenant_read on public.api_keys for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()) and app.has_permission('settings.manage'));
revoke all on public.api_keys from anon;
revoke insert, update, delete on public.api_keys from authenticated;
grant select on public.api_keys to authenticated;
alter table public.api_calls enable row level security;
revoke all on public.api_calls from anon, authenticated;

-- Makes a key; the full key is shown once and only its fingerprint is kept.
create or replace function public.create_api_key(p_name text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_key text := 'snapi_' || replace(replace(app.new_token(30), '-', 'x'), '_', 'y'); v_id uuid;
begin
  perform app.require_permission('settings.manage');
  perform app.require_feature('open_api');
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the key a name (e.g. Tally sync).'; end if;
  if (select count(*) from public.api_keys where restaurant_id = app.current_restaurant_id() and revoked_at is null) >= 10 then
    raise exception 'At most 10 active keys. Remove one first.';
  end if;
  insert into public.api_keys (restaurant_id, name, prefix, key_hash, created_by)
  values (app.current_restaurant_id(), left(trim(p_name), 60), left(v_key, 12), encode(extensions.digest(v_key, 'sha256'), 'hex'), app.current_user_id())
  returning id into v_id;
  perform app.audit('api_key.create', 'api_keys', v_id, jsonb_build_object('name', p_name, 'prefix', left(v_key, 12)), null);
  return jsonb_build_object('id', v_id, 'key', v_key);
end $$;

create or replace function public.revoke_api_key(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('settings.manage');
  update public.api_keys set revoked_at = now() where id = p_id and restaurant_id = app.current_restaurant_id() and revoked_at is null;
  if not found then raise exception 'Key not found.'; end if;
  perform app.audit('api_key.revoke', 'api_keys', p_id, '{}'::jsonb, null);
end $$;

-- Read-only API v1. Actions: menu, orders, sales, stock. Dates are business dates (YYYY-MM-DD), at most 31 days.
create or replace function public.api_v1(p_key text, p_action text, p_params jsonb default '{}'::jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare k public.api_keys%rowtype; v_rest uuid; v_from date; v_to date; v_calls int;
begin
  if coalesce(length(p_key), 0) < 20 or length(p_key) > 100 then raise exception 'Invalid API key.'; end if;
  select * into k from public.api_keys where key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex') and revoked_at is null;
  if not found then raise exception 'Invalid API key.'; end if;
  v_rest := k.restaurant_id;
  if not app.feature_on(v_rest, 'open_api') then raise exception 'The Open API is not switched on for this restaurant.'; end if;
  select count(*) into v_calls from public.api_calls where key_id = k.id and at > now() - interval '1 minute';
  if v_calls >= 60 then raise exception 'Too many requests: at most 60 per minute per key.'; end if;
  insert into public.api_calls (key_id, action) values (k.id, left(coalesce(p_action, ''), 20));
  update public.api_keys set last_used_at = now() where id = k.id;

  if p_action in ('orders', 'sales') then
    begin
      v_from := coalesce((p_params->>'from')::date, current_date);
      v_to := coalesce((p_params->>'to')::date, v_from);
    exception when others then raise exception 'Dates must look like 2026-09-28.';
    end;
    if v_to < v_from or v_to - v_from > 31 then raise exception 'Choose at most 31 days (from ≤ to).'; end if;
  end if;

  if p_action = 'menu' then
    return jsonb_build_object('categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items', (
        select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'name_local', p.name_local, 'price', p.price,
                 'is_veg', p.is_veg, 'available', p.is_available, 'tax_group', tg.name, 'price_includes_tax', tg.is_price_inclusive,
                 'kitchen_station', p.kitchen_station) order by p.display_order, p.name), '[]'::jsonb)
          from public.products p join public.tax_groups tg on tg.id = p.tax_group_id
         where p.category_id = c.id and p.deleted_at is null)) order by c.display_order, c.name)
        from public.categories c where c.restaurant_id = v_rest and c.deleted_at is null), '[]'::jsonb));
  elsif p_action = 'orders' then
    return jsonb_build_object('from', v_from, 'to', v_to, 'orders', coalesce((
      select jsonb_agg(x order by x->>'created_at') from (
        select jsonb_build_object('id', o.id, 'bill_number', o.bill_number, 'business_date', o.business_date, 'created_at', o.created_at,
                 'outlet', b.name, 'order_type', o.order_type, 'status', o.status, 'payment_status', o.payment_status,
                 'currency', o.currency_code, 'subtotal', o.subtotal, 'discount', o.discount_total, 'service_charge', o.service_charge,
                 'tax', o.tax_total, 'tax_included', o.tax_included, 'rounding', o.rounding_adjustment, 'grand_total', o.grand_total,
                 'paid', o.paid_total, 'buyer_gstin', o.buyer_gstin,
                 'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.product_name, 'qty', i.quantity, 'unit_price', i.unit_price,
                                'amount', i.line_subtotal, 'options', i.options_text, 'cancelled', i.cancelled_at is not null)), '[]'::jsonb)
                             from public.order_items i where i.order_id = o.id),
                 'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', pm.name, 'kind', pm.kind, 'amount', pa.amount, 'at', pa.created_at)), '[]'::jsonb)
                                from public.payments pa join public.payment_methods pm on pm.id = pa.payment_method_id
                               where pa.order_id = o.id and pa.status in ('captured', 'refunded'))) as x
          from public.orders o join public.branches b on b.id = o.branch_id
         where o.restaurant_id = v_rest and o.business_date between v_from and v_to
         order by o.created_at limit 5000) q), '[]'::jsonb));
  elsif p_action = 'sales' then
    return jsonb_build_object('from', v_from, 'to', v_to, 'days', coalesce((
      select jsonb_agg(jsonb_build_object('date', d, 'outlet', outlet, 'bills', bills, 'gross', gross, 'discount', disc, 'tax', tax,
                                          'total', total, 'voided_bills', voided) order by d, outlet)
        from (select o.business_date d, b.name outlet,
                     count(*) filter (where o.status <> 'voided') bills,
                     sum(o.subtotal) filter (where o.status <> 'voided') gross,
                     sum(o.discount_total) filter (where o.status <> 'voided') disc,
                     sum(o.tax_total + o.tax_included) filter (where o.status <> 'voided') tax,
                     sum(o.grand_total) filter (where o.status <> 'voided') total,
                     count(*) filter (where o.status = 'voided') voided
                from public.orders o join public.branches b on b.id = o.branch_id
               where o.restaurant_id = v_rest and o.business_date between v_from and v_to
               group by 1, 2) s), '[]'::jsonb),
      'credit_notes', coalesce((select jsonb_agg(jsonb_build_object('number', cn.number, 'date', cn.business_date, 'amount', cn.amount, 'tax', cn.tax_amount))
                                  from public.credit_notes cn where cn.restaurant_id = v_rest and cn.business_date between v_from and v_to), '[]'::jsonb));
  elsif p_action = 'stock' then
    if not app.feature_on(v_rest, 'stock') then raise exception 'Stock is not switched on for this restaurant.'; end if;
    return jsonb_build_object('ingredients', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'reorder_level', i.reorder_level,
               'by_outlet', (select coalesce(jsonb_agg(jsonb_build_object('outlet', b.name, 'stock', x.q)), '[]'::jsonb)
                               from (select m.branch_id, sum(m.qty) q from public.stock_movements m where m.ingredient_id = i.id group by 1) x
                               join public.branches b on b.id = x.branch_id)) order by i.name)
        from public.ingredients i where i.restaurant_id = v_rest and i.is_active), '[]'::jsonb));
  end if;
  raise exception 'Unknown action. Use menu, orders, sales or stock.';
end $$;

revoke all on function public.save_push_subscription(text, text, text), public.remove_push_subscription(text), public.push_gone(text, text[]),
  public.create_api_key(text), public.revoke_api_key(uuid), public.api_v1(text, text, jsonb) from public;
grant execute on function public.save_push_subscription(text, text, text), public.remove_push_subscription(text),
  public.create_api_key(text), public.revoke_api_key(uuid) to authenticated;
grant execute on function public.push_gone(text, text[]), public.api_v1(text, text, jsonb) to anon, authenticated;

-- (069) push_gone refuses when no secret is stored yet:
create or replace function public.push_gone(p_secret text, p_endpoints text[]) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v text;
begin
  select decrypted_secret into v from vault.decrypted_secrets where name = 'push_secret';
  if v is null or p_secret is null or p_secret is distinct from v then raise exception 'Not allowed.'; end if;
  delete from public.push_subscriptions where endpoint = any(p_endpoints);
end $$;
