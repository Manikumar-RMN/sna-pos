# Customer reports (WS-DB -> WS-R), migration 146

Both are read-only, outlet scope from the signed-in user (All outlets for an owner with all outlets), a range of at most 366 days ("Choose a range of one year or less." / "Choose a valid date range.").

- `report_customers(p_from date, p_to date)` needs `customer.view` AND `report.view_sales`. Money only for people who also have `report.view_financial` (`money:false` -> spend / avg_bill / by_day.spend / totals.spend are null).
  `{money, by_customer:[top 500: customer_id,name,phone,visits,spend,avg_bill,first_visit_on,last_visit_on,is_new], by_day:[{business_date,bills_with_customer,new_customers,repeat_customers,spend}],
    totals:{customers,new,repeat,repeat_rate,spend,bills_with_customer,bills_total,capture_rate}}`.
  New = first visit EVER (in the outlet scope) falls inside the range; repeat = every other guest who visited in the range. repeat_rate / capture_rate are percentages with one decimal.
  A visit is a bill with a guest, paid or part-refunded, not voided, not merged, on a business date in the range; spend = total minus credit notes.
- `report_loyalty_ledger(p_from date, p_to date)` needs `customer.view` and the loyalty add-on. `{by_day:[{business_date,earned,redeemed,reversed,adjusted}], rows:[newest first, max 2000: at,business_date,customer,kind,points,bill_number,outlet,user],
    truncated,row_limit,total_rows, totals:{earned,redeemed,reversed,adjusted,net}, liability:{points_outstanding,rupee_value,customers_with_points}}`.
  Rows with no bill (manual adjusts, data deletion) belong to the restaurant: they show only under All outlets, outlet "Manual". `redeemed` and `reversed` are positive numbers; `adjusted` is signed (adjust + expire).
  `liability` is as of now and restaurant-wide.
