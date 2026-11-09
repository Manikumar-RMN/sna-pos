-- Rate agreements (Winsar: Rate Agreement master, PO item rate variance).
-- An agreed price per ingredient with a supplier for a period. New deliveries start from the agreed rate,
-- and a report shows where the price paid was different from the agreed price.

create table if not exists public.supplier_rates (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  supplier_id   uuid not null,
  ingredient_id uuid not null,
  rate          numeric(12,4) not null check (rate >= 0 and rate <= 9999999),
  valid_from    date not null,
  valid_to      date,
  notes         text,
  created_by    uuid not null references public.users(id),
  created_at    timestamptz not null default now(),
  ended_at      timestamptz,
  check (valid_to is null or valid_to >= valid_from),
  foreign key (restaurant_id, supplier_id) references public.suppliers(restaurant_id, id) on delete cascade,
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id) on delete cascade
);
create index if not exists supplier_rates_lookup on public.supplier_rates (restaurant_id, supplier_id, ingredient_id) where ended_at is null;

alter table public.supplier_rates enable row level security;
revoke all on public.supplier_rates from anon, authenticated;
grant select on public.supplier_rates to authenticated;
drop policy if exists tenant_read on public.supplier_rates;
create policy tenant_read on public.supplier_rates for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id())
  and ((select app.has_permission('stock.view')) or (select app.has_permission('stock.manage'))));

-- The agreed rate for a supplier and ingredient on a day (null when there is none).
create or replace function app.agreed_rate(p_rest uuid, p_supplier uuid, p_ingredient uuid, p_day date) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select r.rate from public.supplier_rates r
   where r.restaurant_id = p_rest and r.supplier_id = p_supplier and r.ingredient_id = p_ingredient and r.ended_at is null
     and r.valid_from <= p_day and (r.valid_to is null or r.valid_to >= p_day)
   order by r.valid_from desc, r.created_at desc limit 1
$$;
revoke all on function app.agreed_rate(uuid, uuid, uuid, date) from public, anon, authenticated;

create or replace function public.save_supplier_rate(p_supplier uuid, p_ingredient uuid, p_rate numeric, p_from date, p_to date default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_id uuid := gen_random_uuid(); v_sn text; v_in text;
begin
  perform app.require_feature('stock');
  select name into v_sn from public.suppliers where id = p_supplier and restaurant_id = v_rest and is_active;
  if v_sn is null then raise exception 'Choose a supplier.'; end if;
  select name into v_in from public.ingredients where id = p_ingredient and restaurant_id = v_rest and is_active;
  if v_in is null then raise exception 'Choose an ingredient.'; end if;
  if p_rate is null or p_rate < 0 or p_rate > 9999999 then raise exception 'Enter the agreed rate (zero or more).'; end if;
  if p_from is null then raise exception 'Choose the date the rate starts.'; end if;
  if p_to is not null and p_to < p_from then raise exception 'The end date cannot be before the start date.'; end if;
  perform pg_advisory_xact_lock(hashtext('supplier_rate:' || v_rest::text || ':' || p_supplier::text || ':' || p_ingredient::text));
  if exists (select 1 from public.supplier_rates r where r.restaurant_id = v_rest and r.supplier_id = p_supplier and r.ingredient_id = p_ingredient and r.ended_at is null
               and r.valid_from <= coalesce(p_to, date '9999-12-31') and coalesce(r.valid_to, date '9999-12-31') >= p_from) then
    raise exception 'There is already an agreed rate for % from % that overlaps these dates. Stop it first, or change the dates.', v_in, v_sn;
  end if;
  insert into public.supplier_rates (id, restaurant_id, supplier_id, ingredient_id, rate, valid_from, valid_to, notes, created_by)
  values (v_id, v_rest, p_supplier, p_ingredient, round(p_rate, 4), p_from, p_to, nullif(left(trim(coalesce(p_notes, '')), 200), ''), v_user);
  perform app.audit('rate.agree', 'supplier_rates', v_id, jsonb_build_object('supplier', v_sn, 'item', v_in, 'rate', round(p_rate, 4), 'from', p_from, 'to', p_to));
  return v_id;
end $$;
revoke all on function public.save_supplier_rate(uuid, uuid, numeric, date, date, text) from public, anon;
grant execute on function public.save_supplier_rate(uuid, uuid, numeric, date, date, text) to authenticated;

create or replace function public.stop_supplier_rate(p_id uuid) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); r public.supplier_rates%rowtype;
begin
  perform app.require_feature('stock');
  select * into r from public.supplier_rates where id = p_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Rate agreement not found.'; end if;
  if r.ended_at is not null then return true; end if;
  update public.supplier_rates set ended_at = now() where id = p_id;
  perform app.audit('rate.stop', 'supplier_rates', p_id, jsonb_build_object('rate', r.rate));
  return true;
end $$;
revoke all on function public.stop_supplier_rate(uuid) from public, anon;
grant execute on function public.stop_supplier_rate(uuid) to authenticated;

-- Price paid (before tax) against the agreed price, per delivery line.
create or replace function public.report_rate_variance(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  return (
    with d as (
      select g.number, g.received_on, coalesce(b.name, '') as outlet, s.name as supplier, i.name as item, i.unit, l.qty,
             round(l.line_total / nullif(l.qty, 0), 4) as paid_rate,
             app.agreed_rate(v_rest, g.supplier_id, l.ingredient_id, g.received_on) as agreed_rate
        from public.goods_receipts g
        join public.goods_receipt_lines l on l.goods_receipt_id = g.id
        join public.ingredients i on i.id = l.ingredient_id
        join public.suppliers s on s.id = g.supplier_id
        left join public.branches b on b.id = g.branch_id
       where g.restaurant_id = v_rest and (v_rb is null or g.branch_id = v_rb) and g.status <> 'cancelled' and g.received_on between p_from and p_to),
    v as (select d.*, round((d.paid_rate - d.agreed_rate) * d.qty, 2) as variance from d where d.agreed_rate is not null),
    capped as (select * from v order by received_on desc, number desc, item limit 3000)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(to_jsonb(c) order by c.received_on desc, c.number desc, c.item) from capped c), '[]'::jsonb),
      'truncated', (select count(*) from v) > 3000, 'row_limit', 3000,
      'without_agreement', (select count(*) from d where agreed_rate is null),
      'totals', jsonb_build_object('lines', (select count(*) from v), 'variance', coalesce((select sum(variance) from v), 0),
        'over', coalesce((select sum(variance) from v where variance > 0), 0), 'under', coalesce((select sum(variance) from v where variance < 0), 0)))
  );
end $$;
revoke all on function public.report_rate_variance(date, date) from public, anon;
grant execute on function public.report_rate_variance(date, date) to authenticated;
