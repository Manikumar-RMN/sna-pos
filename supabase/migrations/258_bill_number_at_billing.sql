-- 258: the bill number is given when the bill is made (printed from Check, settled, charged to an account or made
-- complimentary), not when the first KOT is saved. Until then the order carries an internal reference (OPEN-00012) that is
-- never a bill number, and each KOT has its own running number per outlet per day (KOT-0001), like Winsar.

alter table public.orders add column if not exists billed_at timestamptz;
alter table public.orders disable trigger user;
update public.orders set billed_at = coalesce(created_at, now()) where billed_at is null;
alter table public.orders enable trigger user;

create table if not exists public.open_order_series (
  branch_id uuid primary key references public.branches(id) on delete cascade,
  next_seq bigint not null default 1 check (next_seq >= 1)
);
alter table public.open_order_series enable row level security;

create table if not exists public.kot_series (
  branch_id uuid not null references public.branches(id) on delete cascade,
  business_date date not null,
  next_seq int not null default 1 check (next_seq >= 1),
  primary key (branch_id, business_date)
);
alter table public.kot_series enable row level security;

-- The real allocators keep the old bodies under new names.
alter function app.next_bill_number(uuid) rename to take_bill_number;
alter function app.next_liquor_number(uuid) rename to take_liquor_number;

create or replace function app.open_order_ref(p_branch uuid, out device_id uuid, out bill_no text)
returns record language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_n bigint;
begin
  select d.id into device_id from public.devices d
   where d.branch_id = p_branch and d.is_active and d.device_type <> 'counter' order by d.created_at limit 1;
  if device_id is null then raise exception 'No billing device is set up for this branch.'; end if;
  insert into public.open_order_series as s (branch_id, next_seq) values (p_branch, 2)
  on conflict (branch_id) do update set next_seq = s.next_seq + 1
  returning s.next_seq - 1 into v_n;
  bill_no := 'OPEN-' || lpad(v_n::text, greatest(5, length(v_n::text)), '0');
end $$;

-- What every order starts with: an internal reference, not a bill number.
create or replace function app.next_bill_number(p_branch uuid, out device_id uuid, out bill_no text)
returns record language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  select r.device_id, r.bill_no into device_id, bill_no from app.open_order_ref(p_branch) r;
end $$;

create or replace function app.next_liquor_number(p_branch uuid, out device_id uuid, out bill_no text)
returns record language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
begin
  select r.device_id, r.bill_no into device_id, bill_no from app.open_order_ref(p_branch) r;
  perform set_config('app.liquor_bill', 'on', true);
end $$;

-- Gives the order its bill number, once. Safe to call again.
create or replace function app.ensure_billed(p_order uuid)
returns text language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare o public.orders%rowtype; v_no text; v_dev uuid;
begin
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found then return null; end if;
  if o.billed_at is not null or o.status = 'voided' then return o.bill_number; end if;
  if o.is_liquor then
    select n.device_id, n.bill_no into v_dev, v_no from app.take_liquor_number(o.branch_id) n;
    perform set_config('app.liquor_bill', '', true);
  else
    select n.device_id, n.bill_no into v_dev, v_no from app.take_bill_number(o.branch_id) n;
  end if;
  perform set_config('app.renumber', 'on', true);
  update public.orders set bill_number = v_no, billed_at = now() where id = o.id;
  perform set_config('app.renumber', '', true);
  perform app.audit('bill.numbered', 'orders', o.id, jsonb_build_object('bill_number', v_no, 'order_ref', o.bill_number));
  return v_no;
end $$;

-- Insert: an order with an internal reference is not billed yet; anything else (offline bills) already is.
create or replace function app.trg_bill_number_ins() returns trigger language plpgsql set search_path to 'public', 'pg_temp' as $$
begin
  if new.bill_number like 'OPEN-%' then new.billed_at := null; else new.billed_at := coalesce(new.billed_at, now()); end if;
  return new;
end $$;

-- Safety net: any path that takes money, charges an account or makes the bill complimentary numbers it.
create or replace function app.trg_bill_number_upd() returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_no text; v_dev uuid;
begin
  if old.billed_at is null and new.billed_at is null and new.status <> 'voided'
     and (new.payment_status in ('paid', 'partial') or new.paid_total > 0 or new.comp_kind is not null) then
    if new.is_liquor then
      select n.device_id, n.bill_no into v_dev, v_no from app.take_liquor_number(new.branch_id) n;
      perform set_config('app.liquor_bill', '', true);
    else
      select n.device_id, n.bill_no into v_dev, v_no from app.take_bill_number(new.branch_id) n;
    end if;
    new.bill_number := v_no;
    new.billed_at := now();
    perform set_config('app.renumber', 'on', true);
  end if;
  return new;
end $$;

drop trigger if exists trg_bill_number_ins on public.orders;
create trigger trg_bill_number_ins before insert on public.orders for each row execute function app.trg_bill_number_ins();
drop trigger if exists trg_bill_number on public.orders;
create trigger trg_bill_number before update on public.orders for each row execute function app.trg_bill_number_upd();

create or replace function app.protect_completed_orders() returns trigger language plpgsql set search_path to 'public', 'pg_temp' as $$
begin
  if old.status in ('completed', 'voided') then
    if new.bill_number is distinct from old.bill_number
       and not (coalesce(current_setting('app.renumber', true), '') = 'on' and old.billed_at is null) then
      raise exception 'Bill % cannot be renumbered or moved to another branch.', old.bill_number;
    end if;
    if new.branch_id is distinct from old.branch_id
       and not (coalesce(current_setting('app.outlet_move', true), '') = 'on' and old.status = 'completed' and old.payment_status = 'unpaid') then
      raise exception 'Bill % cannot be renumbered or moved to another branch.', old.bill_number;
    end if;
    if new.subtotal is distinct from old.subtotal
    or new.discount_total is distinct from old.discount_total
    or new.tax_total is distinct from old.tax_total
    or new.tax_included is distinct from old.tax_included
    or new.tax_exempt_amount is distinct from old.tax_exempt_amount
    or new.service_charge is distinct from old.service_charge
    or new.grand_total is distinct from old.grand_total then
      if not (coalesce(current_setting('app.recalc', true), '') = 'on'
              and old.status = 'completed' and old.payment_status in ('unpaid', 'partial')) then
        raise exception 'Bill % is closed and its amounts cannot be changed. Void it or raise a refund instead.', old.bill_number;
      end if;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

-- KOT numbers: one running number per outlet per business day.
create or replace function app.create_kitchen_ticket(p_order uuid, p_items uuid[])
returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare o public.orders%rowtype; v_n int; v_id uuid; v_first uuid; st record;
begin
  select * into o from public.orders where id = p_order;
  for st in
    select case when app.feature_on(o.restaurant_id, 'kitchen_stations') then coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen') else 'Kitchen' end as station
      from public.order_items oi left join public.products p on p.id = oi.product_id
     where oi.id = any(p_items) and not oi.held
       and not exists (select 1 from public.products cp where cp.id = oi.product_id and cp.is_charge)
     group by 1 order by 1
  loop
    v_id := gen_random_uuid();
    insert into public.kot_series as ks (branch_id, business_date, next_seq)
    values (o.branch_id, coalesce(o.business_date, current_date), 2)
    on conflict (branch_id, business_date) do update set next_seq = ks.next_seq + 1
    returning ks.next_seq - 1 into v_n;
    insert into public.kitchen_tickets (id, restaurant_id, branch_id, order_id, ticket_number, station, status, client_created_at)
    values (v_id, o.restaurant_id, o.branch_id, o.id, 'KOT-' || lpad(v_n::text, greatest(4, length(v_n::text)), '0'), st.station, 'new', now());
    insert into public.kitchen_ticket_items (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note)
    select o.restaurant_id, v_id, oi.id,
           oi.product_name || coalesce(' (' || oi.options_text || ')', ''), oi.quantity, oi.kitchen_note
      from public.order_items oi left join public.products p on p.id = oi.product_id
     where oi.id = any(p_items) and not oi.held
       and not exists (select 1 from public.products cp where cp.id = oi.product_id and cp.is_charge)
       and case when app.feature_on(o.restaurant_id, 'kitchen_stations') then coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen') else 'Kitchen' end = st.station
     order by oi.created_at, oi.id;
    v_first := coalesce(v_first, v_id);
  end loop;
  return v_first;
end $$;

-- Patch the money paths so their messages and audit lines carry the real bill number.
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.pay_order'::regproc);
  n := regexp_replace(d, 'perform app\.require_feature\(''pos''\);', E'perform app.require_feature(''pos'');\n  perform app.ensure_billed(p_order_id);');
  if n = d then raise exception 'pay_order patch failed'; end if; execute n;

  d := pg_get_functiondef('public.account_charge'::regproc);
  n := regexp_replace(d, 'perform app\.require_feature\(''pos''\);', E'perform app.require_feature(''pos'');\n  perform app.ensure_billed(p_order);');
  if n = d then raise exception 'account_charge patch failed'; end if; execute n;

  d := pg_get_functiondef('public.make_complimentary'::regproc);
  n := regexp_replace(d, 'perform app\.require_feature\(''pos''\);', E'perform app.require_feature(''pos'');\n  perform app.ensure_billed(p_order_id);');
  if n = d then raise exception 'make_complimentary patch failed'; end if; execute n;

  d := pg_get_functiondef('public.create_order'::regproc);
  n := replace(d, 'perform app.audit(''order.create''', E'select bill_number into v_bill_no from public.orders where id = v_order_id;\n  perform app.audit(''order.create''');
  if n = d then raise exception 'create_order patch failed'; end if; execute n;

  d := pg_get_functiondef('public.log_print'::regproc);
  n := regexp_replace(d, 'if p_kind = ''bill'' then(\s+)select greatest', E'if p_kind = ''bill'' then\\1perform app.ensure_billed(o.id);\\1select * into o from public.orders where id = o.id;\\1select greatest');
  if n = d then raise exception 'log_print patch 1 failed'; end if;
  d := n;
  n := replace(d, '''reprint'', false, ''print_no'', 1)', '''reprint'', false, ''print_no'', 1, ''bill_number'', o.bill_number)');
  if n = d then raise exception 'log_print patch 2 failed'; end if;
  d := n;
  n := replace(d, '''reprint'', true, ''print_no'', v_prior + 1)', '''reprint'', true, ''print_no'', v_prior + 1, ''bill_number'', o.bill_number)');
  if n = d then raise exception 'log_print patch 3 failed'; end if; execute n;
end $$;
