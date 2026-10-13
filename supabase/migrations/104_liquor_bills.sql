-- 104: Bars — liquor on its own bills with its own number series.
-- In India liquor is not under GST: it is taxed by the state (VAT), and bars give it a separate bill.
-- A tax group can be marked "liquor". Dishes in such a group are billed only on liquor bills, which take their
-- numbers from the outlet's liquor series (e.g. BAR26-0001); food never goes on a liquor bill and liquor never on a
-- food bill. Pegs and bottles are ordinary dishes; their recipes in ml take them out of bottle stock.
-- Offline bills are not checked (they are made without the server).

alter table public.tax_groups add column separate_bill boolean not null default false;
alter table public.orders add column is_liquor boolean not null default false;

create table public.liquor_series (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null unique references public.branches(id) on delete cascade,
  prefix text not null check (prefix ~ '^[A-Za-z0-9/]{1,7}$'),
  next_seq integer not null default 1 check (next_seq >= 1),
  created_at timestamptz not null default now()
);
create unique index liquor_series_prefix_uq on public.liquor_series (restaurant_id, upper(prefix));
alter table public.liquor_series enable row level security;
create policy tenant_read on public.liquor_series for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
revoke all on public.liquor_series from anon;
grant select on public.liquor_series to authenticated;

-- The liquor series and the bill-number series must never share a prefix (the numbers would clash).
create or replace function app.trg_prefix_clash()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if tg_table_name = 'bill_series' then
    if exists (select 1 from public.liquor_series where restaurant_id = new.restaurant_id and upper(prefix) = upper(new.prefix)) then
      raise exception 'The prefix % is used for liquor bills. Choose another.', new.prefix;
    end if;
  else
    if exists (select 1 from public.bill_series where restaurant_id = new.restaurant_id and upper(prefix) = upper(new.prefix)) then
      raise exception 'The prefix % is used for ordinary bills. Choose another.', new.prefix;
    end if;
  end if;
  return new;
end $function$;
create trigger trg_prefix_clash before insert or update of prefix on public.bill_series for each row execute function app.trg_prefix_clash();
create trigger trg_prefix_clash before insert or update of prefix on public.liquor_series for each row execute function app.trg_prefix_clash();

-- Whether a list of bill items is liquor (true), food (false); a mix is refused.
create or replace function app.items_are_liquor(p_restaurant uuid, p_items jsonb)
returns boolean
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_liq int; v_food int;
begin
  if not exists (select 1 from public.tax_groups where restaurant_id = p_restaurant and separate_bill) then return false; end if;
  select count(*) filter (where tg.separate_bill), count(*) filter (where not tg.separate_bill) into v_liq, v_food
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
    join public.products p on p.id::text = x->>'product_id' and p.restaurant_id = p_restaurant
    join public.tax_groups tg on tg.id = p.tax_group_id
   where not p.is_charge;
  if v_liq > 0 and v_food > 0 then
    raise exception 'Liquor and food go on separate bills. Bill the drinks on their own, then the food.';
  end if;
  return v_liq > 0;
end $function$;

-- The outlet's liquor series, made on first use (prefix BAR + year, made unique if needed).
create or replace function app.next_liquor_number(p_branch uuid, out device_id uuid, out bill_no text)
returns record
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare s public.liquor_series; v_rest uuid; v_try text; n int := 1; v_base text;
begin
  select d.id into device_id from public.devices d where d.branch_id = p_branch and d.is_active and d.device_type <> 'counter' order by d.created_at limit 1;
  if device_id is null then raise exception 'No billing device is set up for this branch.'; end if;
  select * into s from public.liquor_series where branch_id = p_branch for update;
  if not found then
    perform pg_advisory_xact_lock(hashtext('liquor_series:' || p_branch::text));
    select restaurant_id into v_rest from public.branches where id = p_branch;
    v_base := 'BAR' || to_char(now(), 'YY'); v_try := v_base;
    while exists (select 1 from public.liquor_series where restaurant_id = v_rest and upper(prefix) = upper(v_try))
       or exists (select 1 from public.bill_series where restaurant_id = v_rest and upper(prefix) = upper(v_try)) loop
      n := n + 1; v_try := left(v_base, 7 - length(n::text)) || n;
    end loop;
    insert into public.liquor_series (restaurant_id, branch_id, prefix) values (v_rest, p_branch, v_try)
    on conflict (branch_id) do nothing;
    select * into s from public.liquor_series where branch_id = p_branch for update;
  end if;
  bill_no := s.prefix || '-' || lpad(s.next_seq::text, greatest(4, length(s.next_seq::text)), '0');
  if length(bill_no) > 16 then raise exception 'Liquor bill number % would be longer than 16 characters. Choose a shorter liquor prefix.', bill_no; end if;
  update public.liquor_series set next_seq = next_seq + 1 where id = s.id;
  perform set_config('app.liquor_bill', 'on', true);
end $function$;

-- A new bill numbered from the liquor series is a liquor bill.
create or replace function app.trg_order_liquor()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  new.is_liquor := coalesce(current_setting('app.liquor_bill', true), '') = 'on';
  perform set_config('app.liquor_bill', '', true);
  return new;
end $function$;
create trigger trg_order_liquor before insert on public.orders for each row execute function app.trg_order_liquor();

-- Liquor only on liquor bills, food only on food bills (adding to a bill, splitting and merging included).
create or replace function app.trg_item_liquor()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare o record; v_liq boolean; v_name text;
begin
  select is_liquor, bill_number into o from public.orders where id = new.order_id;
  if o.bill_number ~ '-X[0-9]+-' then return new; end if;
  select tg.separate_bill and not p.is_charge, p.name into v_liq, v_name
    from public.products p join public.tax_groups tg on tg.id = p.tax_group_id where p.id = new.product_id;
  if coalesce(v_liq, false) and not o.is_liquor then
    raise exception '% is liquor and goes on a separate liquor bill, not on bill %.', v_name, o.bill_number;
  elsif not coalesce(v_liq, false) and o.is_liquor and not exists (select 1 from public.products where id = new.product_id and is_charge) then
    raise exception '% is not liquor, so it cannot go on liquor bill %.', v_name, o.bill_number;
  end if;
  return new;
end $function$;
create trigger trg_item_liquor before insert or update of order_id on public.order_items for each row execute function app.trg_item_liquor();

-- Mark a tax group as liquor (separate bills) or not.
create or replace function public.tax_group_set_liquor(p_group uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('tax.manage');
begin
  update public.tax_groups set separate_bill = coalesce(p_on, false) where id = p_group and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That tax group was not found.'; end if;
  perform app.audit('tax.liquor', 'tax_groups', p_group, jsonb_build_object('liquor', p_on), null);
end $function$;

-- The liquor bill prefix of this outlet: see it and change it. A new prefix starts again at 0001.
create or replace function public.liquor_prefix_info()
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select jsonb_build_object('uses_liquor', exists (select 1 from public.tax_groups where restaurant_id = app.current_restaurant_id() and separate_bill),
    'prefix', s.prefix, 'next_number', case when s.id is not null then s.prefix || '-' || lpad(s.next_seq::text, greatest(4, length(s.next_seq::text)), '0') end)
    from (select 1) one left join public.liquor_series s on s.branch_id = app.current_branch_id()
   where app.allowed('order.create')
$function$;

create or replace function public.set_liquor_prefix(p_prefix text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_p text := btrim(coalesce(p_prefix, '')); s public.liquor_series;
begin
  if v_branch is null then raise exception 'No outlet chosen.'; end if;
  if v_p !~ '^[A-Za-z0-9/]{1,7}$' then raise exception 'The liquor bill prefix is 1 to 7 letters, digits or "/" (for example BAR26).'; end if;
  if exists (select 1 from public.liquor_series where restaurant_id = v_rest and upper(prefix) = upper(v_p) and branch_id <> v_branch) then
    raise exception 'The prefix % is used by another outlet. Choose another.', v_p;
  end if;
  if exists (select 1 from public.orders where branch_id = v_branch and upper(split_part(bill_number, '-', 1)) = upper(v_p)) then
    if not exists (select 1 from public.liquor_series where branch_id = v_branch and upper(prefix) = upper(v_p)) then
      raise exception 'Bills already exist with the prefix %. Choose a new one.', v_p;
    end if;
  end if;
  insert into public.liquor_series (restaurant_id, branch_id, prefix) values (v_rest, v_branch, v_p)
  on conflict (branch_id) do update set prefix = excluded.prefix,
       next_seq = case when upper(public.liquor_series.prefix) = upper(excluded.prefix) then public.liquor_series.next_seq else 1 end
  returning * into s;
  perform app.audit('settings.liquor_prefix', 'branches', v_branch, jsonb_build_object('prefix', s.prefix), null);
  return jsonb_build_object('prefix', s.prefix, 'next_number', s.prefix || '-' || lpad(s.next_seq::text, greatest(4, length(s.next_seq::text)), '0'));
end $function$;

revoke all on function public.tax_group_set_liquor(uuid, boolean), public.liquor_prefix_info(), public.set_liquor_prefix(text) from public, anon;
grant execute on function public.tax_group_set_liquor(uuid, boolean), public.liquor_prefix_info(), public.set_liquor_prefix(text) to authenticated, service_role;
revoke all on function app.items_are_liquor(uuid, jsonb), app.next_liquor_number(uuid) from public, anon, authenticated;

-- New bills and split-off bills take their number from the liquor series when they are liquor.
do $patch$
declare d text;
begin
  d := pg_get_functiondef('public.create_order'::regproc);
  if position('  select n.device_id, n.bill_no into v_device, v_bill_no from app.next_bill_number(v_branch) n;' in d) = 0 then
    raise exception 'create_order is not the expected version.';
  end if;
  d := replace(d, '  select n.device_id, n.bill_no into v_device, v_bill_no from app.next_bill_number(v_branch) n;',
    '  if app.items_are_liquor(v_restaurant, p_items) then
    select n.device_id, n.bill_no into v_device, v_bill_no from app.next_liquor_number(v_branch) n;
  else
    select n.device_id, n.bill_no into v_device, v_bill_no from app.next_bill_number(v_branch) n;
  end if;');
  execute d;
  d := pg_get_functiondef('public.split_order'::regproc);
  if position('  select n.device_id, n.bill_no into v_device, v_bill from app.next_bill_number(o.branch_id) n;' in d) = 0 then
    raise exception 'split_order is not the expected version.';
  end if;
  d := replace(d, '  select n.device_id, n.bill_no into v_device, v_bill from app.next_bill_number(o.branch_id) n;',
    '  if o.is_liquor then
    select n.device_id, n.bill_no into v_device, v_bill from app.next_liquor_number(o.branch_id) n;
  else
    select n.device_id, n.bill_no into v_device, v_bill from app.next_bill_number(o.branch_id) n;
  end if;');
  execute d;
  d := pg_get_functiondef('public.sna_erase'::regproc);
  if position('    update public.bill_series set next_seq = 1 where restaurant_id = p_restaurant;' in d) = 0 then
    raise exception 'sna_erase is not the expected version.';
  end if;
  d := replace(d, '    update public.bill_series set next_seq = 1 where restaurant_id = p_restaurant;',
    '    update public.bill_series set next_seq = 1 where restaurant_id = p_restaurant;
    update public.liquor_series set next_seq = 1 where restaurant_id = p_restaurant;');
  execute d;
end $patch$;
