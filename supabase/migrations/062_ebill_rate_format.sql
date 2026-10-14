-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928142922, name '062_ebill_rate_format'. This is the SQL that actually ran.

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
revoke all on function public.public_receipt(text) from public;
grant execute on function public.public_receipt(text) to anon, authenticated;
