-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928094010, name '51_accounting_journal'. This is the SQL that actually ran.

create or replace function public.accounting_journal(p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_rest uuid; v_rows jsonb;
begin
  perform app.require_permission('report.view_financial');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  with bills as (
    select o.* from public.orders o
     where o.restaurant_id = v_rest and o.business_date between p_from and p_to and o.status = 'completed' and o.merged_into is null
  ),
  lines as (
    -- Money received (debit), by payment method.
    select b.business_date d, 'Dr' side, pm.name account, sum(p.amount) amt, 1 ord
      from bills b join public.payments p on p.order_id = b.id and p.status = 'captured'
      join public.payment_methods pm on pm.id = p.payment_method_id group by 1, 3
    union all
    -- Unpaid balance still owed (only if a day was not closed).
    select b.business_date, 'Dr', 'Amount due from customers', sum(b.grand_total - app.order_covered(b.id)), 2
      from bills b where b.payment_status in ('unpaid', 'partial') group by 1 having sum(b.grand_total - app.order_covered(b.id)) <> 0
    union all
    select b.business_date, 'Cr', 'Sales', sum(i.net_amount), 3
      from bills b join public.order_items i on i.order_id = b.id and i.cancelled_at is null group by 1
    union all
    select b.business_date, 'Cr', 'Output ' || t.component_name || ' ' || trim(to_char(t.rate, 'FM990.###')) || '%', sum(t.tax_amount), 4
      from bills b join public.order_item_taxes t on t.order_id = b.id group by 1, t.component_name, t.rate
    union all
    select b.business_date, 'Cr', 'Service charge', sum(b.service_charge), 5 from bills b group by 1 having sum(b.service_charge) <> 0
    union all
    select b.business_date, 'Cr', 'Round off', sum(b.rounding_adjustment) + coalesce((select sum(p.rounding_adjustment) from public.payments p join bills b2 on b2.id = p.order_id
                                                  where b2.business_date = b.business_date and p.status = 'captured'), 0), 6
      from bills b group by 1
    union all
    -- Credit notes: sales returned and tax reversed (debit), money paid back (credit).
    select cn.business_date, 'Dr', 'Sales returns', sum(cn.amount - cn.tax_amount), 7
      from public.credit_notes cn where cn.restaurant_id = v_rest and cn.business_date between p_from and p_to group by 1
    union all
    select cn.business_date, 'Dr', 'Output ' || (t->>'name') || ' ' || trim(to_char((t->>'rate')::numeric, 'FM990.###')) || '%', sum((t->>'amount')::numeric), 8
      from public.credit_notes cn cross join jsonb_array_elements(cn.taxes) t
     where cn.restaurant_id = v_rest and cn.business_date between p_from and p_to group by 1, t->>'name', t->>'rate'
    union all
    select cn.business_date, 'Cr', pm.name, sum(cn.amount), 9
      from public.credit_notes cn join public.payment_methods pm on pm.id = cn.payment_method_id
     where cn.restaurant_id = v_rest and cn.business_date between p_from and p_to group by 1, 3
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', d, 'account', account,
           'debit', case when (side = 'Dr') = (amt >= 0) then abs(amt) else 0 end,
           'credit', case when (side = 'Cr') = (amt >= 0) then abs(amt) else 0 end,
           'narration', 'SNA POS sales ' || to_char(d, 'DD Mon YYYY'))
         order by d, ord, account), '[]'::jsonb)
    into v_rows from lines where amt <> 0;
  return v_rows;
end $$;
revoke all on function public.accounting_journal(date,date) from public, anon;
grant execute on function public.accounting_journal(date,date) to authenticated;
