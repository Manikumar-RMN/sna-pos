-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928092043, name '43_india_gst_basics'. This is the SQL that actually ran.

alter table public.restaurants add column fssai_no text, add column sac_code text;
alter table public.products add column hsn_code text check (hsn_code is null or hsn_code ~ '^[0-9]{4,8}$');
alter table public.orders add column buyer_gstin text, add column buyer_name text;
alter table public.devices add column bill_fy text;

-- Company settings: FSSAI licence number and SAC code (India).
do $$
declare d text;
begin
  d := pg_get_functiondef('public.update_settings(jsonb)'::regprocedure);
  d := replace(d, E'  update public.restaurants set\n',
    E'  if s ? ''fssai_no'' and nullif(trim(s->>''fssai_no''), '''') is not null and trim(s->>''fssai_no'') !~ ''^[0-9]{14}$'' then\n    raise exception ''The FSSAI licence number has 14 digits.'';\n  end if;\n  if s ? ''sac_code'' and nullif(trim(s->>''sac_code''), '''') is not null and trim(s->>''sac_code'') !~ ''^[0-9]{4,8}$'' then\n    raise exception ''The SAC / HSN code is 4 to 8 digits.'';\n  end if;\n\n  update public.restaurants set\n    fssai_no = case when s ? ''fssai_no'' then nullif(trim(s->>''fssai_no''), '''') else fssai_no end,\n    sac_code = case when s ? ''sac_code'' then nullif(trim(s->>''sac_code''), '''') else sac_code end,\n');
  if position('fssai_no = case' in d) = 0 then raise exception 'patch update_settings failed'; end if;
  execute d;
end $$;

-- Indian restaurants: bill numbers restart each financial year and carry it (e.g. MN-C1-2627-0001, 15 characters).
create or replace function app.next_bill_number(p_branch uuid, out device_id uuid, out bill_no text) returns record
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_prefix text; v_seq bigint; v_fy text; v_dev_fy text; v_country text; v_tz text; v_today date;
begin
  select d.id, d.bill_prefix, d.next_bill_seq, d.bill_fy into device_id, v_prefix, v_seq, v_dev_fy
    from public.devices d where d.branch_id = p_branch and d.is_active and d.device_type <> 'counter' order by d.created_at limit 1 for update;
  if device_id is null then raise exception 'No billing device is set up for this branch.'; end if;
  select r.country_code, coalesce(b.timezone, r.timezone) into v_country, v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = p_branch;
  if v_country = 'IN' then
    v_today := (now() at time zone coalesce(v_tz, 'Asia/Kolkata'))::date;
    v_fy := replace(app.fy_label('IN', v_today), '-', '');
    v_fy := substr(v_fy, 3, 2) || substr(v_fy, 5, 2);          -- 2026-27 -> 2627
    if v_dev_fy is distinct from v_fy then
      v_seq := 1;
      update public.devices set bill_fy = v_fy where id = device_id;
    end if;
    bill_no := (select b.code from public.branches b where b.id = p_branch)
               || '-' || coalesce(v_prefix, 'C1') || '-' || v_fy || '-' || lpad(v_seq::text, 4, '0');
  else
    bill_no := (select b.code from public.branches b where b.id = p_branch)
               || '-' || coalesce(v_prefix, 'C1') || '-' || lpad(v_seq::text, 4, '0');
  end if;
  update public.devices set next_bill_seq = v_seq + 1 where id = device_id;
end $$;

-- B2B bill: the customer's GSTIN and business name printed on the bill.
create or replace function public.set_bill_customer(p_order_id uuid, p_gstin text, p_name text) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; v_gstin text := upper(nullif(trim(coalesce(p_gstin, '')), '')); v_name text := nullif(left(trim(coalesce(p_name, '')), 120), '');
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if v_gstin is not null and v_gstin !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
    raise exception 'That GSTIN does not look right. It should be 15 characters, like 33AAACA0000A1Z5.';
  end if;
  if v_gstin is not null and v_name is null then raise exception 'Enter the business name that goes with the GSTIN.'; end if;
  update public.orders set buyer_gstin = v_gstin, buyer_name = v_name where id = o.id;
  perform app.audit('order.customer_tax_id', 'orders', o.id, jsonb_build_object('gstin', v_gstin, 'name', v_name),
                    jsonb_build_object('gstin', o.buyer_gstin, 'name', o.buyer_name));
  return jsonb_build_object('bill_number', o.bill_number, 'gstin', v_gstin, 'name', v_name);
end $$;
revoke all on function public.set_bill_customer(uuid,text,text) from public, anon;
grant execute on function public.set_bill_customer(uuid,text,text) to authenticated;

-- GST bill register (for the accountant / GSTR-1): one row per bill and per credit note.
create or replace function public.gst_register(p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_rest uuid; v_rows jsonb;
begin
  perform app.require_permission('report.view_financial');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  select coalesce(jsonb_agg(r order by r->>'date', r->>'number'), '[]'::jsonb) into v_rows from (
    select jsonb_build_object(
      'type', 'Bill', 'date', o.business_date, 'number', o.bill_number, 'status', o.status,
      'buyer_gstin', o.buyer_gstin, 'buyer_name', o.buyer_name,
      'taxable', coalesce((select sum(taxable_amount) from public.order_item_taxes t where t.order_id = o.id and t.component_name ilike 'CGST%'),
                          (select sum(net_amount) from public.order_items i where i.order_id = o.id and i.cancelled_at is null), 0),
      'cgst', coalesce((select sum(tax_amount) from public.order_item_taxes t where t.order_id = o.id and t.component_name ilike 'CGST%'), 0),
      'sgst', coalesce((select sum(tax_amount) from public.order_item_taxes t where t.order_id = o.id and (t.component_name ilike 'SGST%' or t.component_name ilike 'UTGST%')), 0),
      'igst', coalesce((select sum(tax_amount) from public.order_item_taxes t where t.order_id = o.id and t.component_name ilike 'IGST%'), 0),
      'rate', (select max(rate) * 2 from public.order_item_taxes t where t.order_id = o.id and t.component_name ilike 'CGST%'),
      'total', case when o.status = 'voided' then 0 else o.grand_total end) r
      from public.orders o
     where o.restaurant_id = v_rest and o.business_date between p_from and p_to and o.merged_into is null and o.status in ('completed', 'voided')
    union all
    select jsonb_build_object(
      'type', 'Credit note', 'date', cn.business_date, 'number', cn.number, 'status', 'issued',
      'against', (select bill_number from public.orders where id = cn.order_id),
      'buyer_gstin', (select buyer_gstin from public.orders where id = cn.order_id),
      'buyer_name', (select buyer_name from public.orders where id = cn.order_id),
      'taxable', -(cn.amount - cn.tax_amount),
      'cgst', -coalesce((select sum((t->>'amount')::numeric) from jsonb_array_elements(cn.taxes) t where t->>'name' ilike 'CGST%'), 0),
      'sgst', -coalesce((select sum((t->>'amount')::numeric) from jsonb_array_elements(cn.taxes) t where t->>'name' ilike 'SGST%' or t->>'name' ilike 'UTGST%'), 0),
      'igst', 0, 'rate', null, 'total', -cn.amount) r
      from public.credit_notes cn where cn.restaurant_id = v_rest and cn.business_date between p_from and p_to) x;
  return v_rows;
end $$;
revoke all on function public.gst_register(date,date) from public, anon;
grant execute on function public.gst_register(date,date) to authenticated;

update public.restaurants set sac_code = '996331' where country_code = 'IN' and sac_code is null;
