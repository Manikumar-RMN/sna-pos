-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260925091922, name 'sna_pos_27_payment_modes_reference_settlement'. This is the SQL that actually ran.

alter table public.payment_methods
  add column if not exists collection_mode text not null default 'record',
  add column if not exists gateway_provider text,
  add column if not exists upi_id text,
  add column if not exists ask_reference boolean not null default false;
alter table public.payment_methods drop constraint if exists payment_methods_collection_mode_check;
alter table public.payment_methods add constraint payment_methods_collection_mode_check check (collection_mode in ('record', 'gateway'));
alter table public.payment_methods drop constraint if exists payment_methods_upi_id_check;
alter table public.payment_methods add constraint payment_methods_upi_id_check
  check (upi_id is null or upi_id ~ '^[A-Za-z0-9._-]{2,256}@[A-Za-z][A-Za-z0-9]{1,63}$');

-- Optional reference number (UPI transaction ID, card slip number) on each payment.
do $$
declare d text; sig text;
begin
  -- pay_order
  d := pg_get_functiondef('public.pay_order(uuid,uuid,numeric,numeric)'::regprocedure);
  d := replace(d, 'p_amount numeric DEFAULT NULL::numeric)', 'p_amount numeric DEFAULT NULL::numeric, p_reference text DEFAULT NULL::text)');
  d := replace(d, $x$change_amount, status, received_by, client_created_at, rounding_adjustment)
  values
    (gen_random_uuid(), o.restaurant_id, o.id, p_payment_method_id, v_amount, o.currency_code,
     p_tendered, v_change, 'captured', v_user, now(), v_round);$x$,
    $x$change_amount, status, received_by, client_created_at, rounding_adjustment, reference_no)
  values
    (gen_random_uuid(), o.restaurant_id, o.id, p_payment_method_id, v_amount, o.currency_code,
     p_tendered, v_change, 'captured', v_user, now(), v_round, nullif(left(trim(p_reference), 60), ''));$x$);
  if d not like '%p_reference text%' or d not like '%reference_no)%' then raise exception 'pay_order patch failed'; end if;
  drop function public.pay_order(uuid, uuid, numeric, numeric);
  execute d;

  -- create_order
  d := pg_get_functiondef('public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb)'::regprocedure);
  d := replace(d, 'p_senior jsonb DEFAULT NULL::jsonb)', 'p_senior jsonb DEFAULT NULL::jsonb, p_reference text DEFAULT NULL::text)');
  d := replace(d, $x$change_amount, status, received_by, client_created_at, rounding_adjustment)
    values
      (gen_random_uuid(), v_restaurant, v_order_id, p_payment_method_id, v_amount, v_currency,
       p_tendered, v_change, 'captured', v_user, now(), v_cash_round);$x$,
    $x$change_amount, status, received_by, client_created_at, rounding_adjustment, reference_no)
    values
      (gen_random_uuid(), v_restaurant, v_order_id, p_payment_method_id, v_amount, v_currency,
       p_tendered, v_change, 'captured', v_user, now(), v_cash_round, nullif(left(trim(p_reference), 60), ''));$x$);
  if d not like '%p_reference text%' or d not like '%reference_no)%' then raise exception 'create_order patch failed'; end if;
  drop function public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text, boolean, jsonb);
  execute d;
end $$;
grant execute on function public.pay_order(uuid, uuid, numeric, numeric, text),
  public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text, boolean, jsonb, text) to authenticated;
revoke execute on function public.pay_order(uuid, uuid, numeric, numeric, text),
  public.create_order(jsonb, text, uuid, uuid, uuid, numeric, numeric, text, boolean, jsonb, text) from anon, public;

-- Settlement: money actually received, by payment method and by the day it was
-- received (not the day the bill was made), with refunds and voided-bill returns.
create or replace function public.settlement_report(p_from date, p_to date)
 returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $$
declare v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_methods jsonb; v_rows jsonb;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;

  with pay as (
    select p.payment_method_id m, count(*) n, sum(p.amount) amt
      from public.payments p
     where p.restaurant_id = v_rest and p.created_at >= v_start and p.created_at < v_end
       and p.status in ('captured', 'refunded')
     group by 1),
  ref as (
    select p.payment_method_id m, sum(r.amount) amt
      from public.refunds r join public.payments p on p.id = r.payment_id
     where r.restaurant_id = v_rest and r.created_at >= v_start and r.created_at < v_end
     group by 1),
  voids as (
    select p.payment_method_id m, sum(p.amount) amt
      from public.payments p join public.orders o on o.id = p.order_id
     where o.restaurant_id = v_rest and o.status = 'voided' and o.voided_at >= v_start and o.voided_at < v_end
       and p.status = 'refunded'
     group by 1)
  select coalesce(jsonb_agg(jsonb_build_object(
           'method', pm.name, 'kind', pm.kind, 'mode', pm.collection_mode,
           'payments', coalesce(pay.n, 0), 'collected', coalesce(pay.amt, 0),
           'refunded', coalesce(ref.amt, 0), 'voided', coalesce(voids.amt, 0),
           'net', coalesce(pay.amt, 0) - coalesce(ref.amt, 0) - coalesce(voids.amt, 0))
         order by coalesce(pay.amt, 0) desc, pm.display_order), '[]'::jsonb)
    into v_methods
    from public.payment_methods pm
    left join pay on pay.m = pm.id left join ref on ref.m = pm.id left join voids on voids.m = pm.id
   where pm.restaurant_id = v_rest and (pay.m is not null or ref.m is not null or voids.m is not null);

  select coalesce(jsonb_agg(jsonb_build_object(
           'at', p.created_at, 'bill', o.bill_number, 'method', pm.name, 'amount', p.amount,
           'reference', p.reference_no, 'status', p.status, 'by', u.full_name) order by p.created_at), '[]'::jsonb)
    into v_rows
    from public.payments p
    join public.orders o on o.id = p.order_id
    join public.payment_methods pm on pm.id = p.payment_method_id
    left join public.users u on u.id = p.received_by
   where p.restaurant_id = v_rest and p.created_at >= v_start and p.created_at < v_end
     and p.status in ('captured', 'refunded');

  return jsonb_build_object('from', p_from, 'to', p_to, 'timezone', v_tz, 'methods', v_methods, 'payments', v_rows);
end $$;
grant execute on function public.settlement_report(date, date) to authenticated;
revoke execute on function public.settlement_report(date, date) from anon, public;
