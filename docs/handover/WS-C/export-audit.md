# WS-C -> WS-DB: audit function for the customer export

Target file: supabase/migrations/145_customers_loyalty.sql (add next to customer_list), and database.types.ts (Functions).

The plan (4.1) says the CSV export is audited as `customer.export {rows, filter}`, but defines no function the app can call to write that row.
`app/src/app/(app)/customers/actions.ts` (exportCustomers) calls this, after reading the pages and before returning the file:

```sql
create or replace function public.log_customer_export(p_rows int, p_filter text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('customer.export');
  perform app.audit('customer.export', 'customers', null,
    jsonb_build_object('rows', p_rows, 'filter', left(coalesce(p_filter, 'all'), 20)), null);
end $$;
revoke all on function public.log_customer_export(int, text) from public, anon;
grant execute on function public.log_customer_export(int, text) to authenticated;
```

(Check the exact app.audit / app.require_permission signatures in MIG/064 and 138 and adapt.) Better still: have customer_list itself refuse
`p_limit = 200` pages without customer.export is NOT wanted; keep this separate function. Until it exists the export still works:
the app only tolerates "function not found" (PGRST202 / 42883); any other error stops the export.
