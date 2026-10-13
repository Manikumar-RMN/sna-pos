-- 105: Chains and franchises.
-- Outlets can be grouped into regions (South, North, Airports…). Head office can set one price for a dish in every
-- outlet of a region at once. A franchise outlet has a royalty percent; the chain report shows each outlet's sales,
-- tax and the royalty due, with region totals.

alter table public.branches
  add column region text check (region is null or length(btrim(region)) between 1 and 40),
  add column royalty_percent numeric(5,2) not null default 0 check (royalty_percent between 0 and 100);

-- Region and royalty for one outlet (settings.manage).
create or replace function public.outlet_set_region(p_branch uuid, p_region text, p_royalty numeric default 0)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('settings.manage');
begin
  perform app.require_feature('multi_outlet');
  if coalesce(p_royalty, 0) < 0 or coalesce(p_royalty, 0) > 100 then raise exception 'Royalty is 0 to 100 percent.'; end if;
  update public.branches set region = nullif(btrim(coalesce(p_region, '')), ''), royalty_percent = round(coalesce(p_royalty, 0), 2)
   where id = p_branch and restaurant_id = app.current_restaurant_id() and deleted_at is null;
  if not found then raise exception 'Outlet not found.'; end if;
  perform app.audit('outlet.region', 'branches', p_branch, jsonb_build_object('region', p_region, 'royalty', p_royalty), null);
end $function$;

-- One price for a dish in every outlet of a region (null price = back to the main menu price there).
create or replace function public.region_set_price(p_region text, p_product uuid, p_price numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare b record; n int := 0;
begin
  perform app.require_permission('menu.price_change');
  for b in select br.id, bp.is_available from public.branches br
             left join public.branch_prices bp on bp.branch_id = br.id and bp.product_id = p_product
            where br.restaurant_id = app.current_restaurant_id() and br.deleted_at is null and lower(br.region) = lower(btrim(coalesce(p_region, ''))) loop
    perform public.set_outlet_price(p_product, b.id, p_price, b.is_available);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'No outlet is in the region %.', p_region; end if;
  return jsonb_build_object('outlets', n);
end $function$;

-- Sales per outlet with region totals and royalty due, for a date range.
create or replace function public.chain_report(p_from date, p_to date)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_rows jsonb;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end := (p_to + 1)::timestamp at time zone v_tz;
  select coalesce(jsonb_agg(jsonb_build_object('branch_id', b.id, 'outlet', b.name, 'code', b.code, 'region', coalesce(b.region, 'No region'),
           'royalty_percent', b.royalty_percent, 'bills', coalesce(x.bills, 0), 'sales', coalesce(x.sales, 0), 'tax', coalesce(x.tax, 0),
           'total', coalesce(x.total, 0), 'average_bill', case when coalesce(x.bills, 0) > 0 then round(x.total / x.bills, 2) else 0 end,
           'royalty', round(coalesce(x.sales, 0) * b.royalty_percent / 100, 2))
         order by coalesce(b.region, 'zzz'), b.name), '[]'::jsonb) into v_rows
    from public.branches b
    left join (select o.branch_id, count(*) bills, sum(o.subtotal - o.discount_total) sales, sum(o.tax_total) tax, sum(o.grand_total) total
                 from public.orders o
                where o.restaurant_id = v_rest and o.created_at >= v_start and o.created_at < v_end
                  and o.status = 'completed' and o.merged_into is null and o.comp_kind is null
                group by o.branch_id) x on x.branch_id = b.id
   where b.restaurant_id = v_rest and b.deleted_at is null and app.in_scope(b.id);
  return jsonb_build_object('from', p_from, 'to', p_to, 'outlets', v_rows,
    'regions', coalesce((select jsonb_agg(jsonb_build_object('region', g.region, 'outlets', g.n, 'bills', g.bills, 'sales', g.sales, 'total', g.total, 'royalty', g.royalty) order by g.region)
                           from (select r->>'region' region, count(*) n, sum((r->>'bills')::int) bills, sum((r->>'sales')::numeric) sales,
                                        sum((r->>'total')::numeric) total, sum((r->>'royalty')::numeric) royalty
                                   from jsonb_array_elements(v_rows) r group by r->>'region') g), '[]'::jsonb));
end $function$;

revoke all on function public.outlet_set_region(uuid, text, numeric), public.region_set_price(text, uuid, numeric), public.chain_report(date, date) from public, anon;
grant execute on function public.outlet_set_region(uuid, text, numeric), public.region_set_price(text, uuid, numeric), public.chain_report(date, date) to authenticated, service_role;
