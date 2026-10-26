# Customers and loyalty RPCs (WS-DB -> WS-C), migration 145 (+148 grants)

Rights: `customer.view` (list/detail/reports; Owner, Manager, Cashier and every role that has `customer.manage`), `customer.manage` (edit, delete), `loyalty.redeem` (use points on a bill), `settings.manage` (rules).
A missing right reads "Your role does not allow this action (customer.view)." (or the other key).

- `customer_list(p_q text null, p_filter text 'all', p_sort text 'last_visit', p_limit int 50, p_offset int 0) -> {total, rows:[{id,name,phone,visits,spend,avg_bill,first_visit_on,last_visit_on,points,marketing_consent}]}`
  filter: all | repeat (2+ visits) | new (exactly 1) | lapsed (last visit more than 60 days ago) | never (no visit); sort: last_visit | spend | visits | points | name; search needs 3+ characters (shorter is ignored);
  a phone search uses digits only. limit max 200. A **visit** = a bill with the guest, paid or part-refunded, not voided, not merged; **spend** = bill totals minus credit notes. Counted for the user's outlet scope (owner with All outlets: all).
- `customer_detail(p_customer) -> {profile{...}, stats{visits,spend,first_visit_on,last_visit_on,avg_bill}, points_balance, points_expire:false, points_note:"Points do not expire.", account_balance, bills:[last 50], ledger:[last 50]}`
- `find_customer(p_phone)` for the bill screen (see WS-A2 note).
- `update_customer(p_customer, p_name, p_email, p_notes, p_birthday date, p_consent boolean)` needs `customer.manage`; refuses a bad email / birthday; stamps `consent_given_at` when consent is newly given.
- `forget_customer(p_customer, p_reason)` needs `customer.manage` AND the owner's approval (`settings.manage`: "The owner must approve deleting a guest (settings.manage)."), reason of 3+ characters,
  refused while a credit-account balance is open. Name becomes "Deleted guest", phone/email/notes/birthday cleared, the phone/name on their bills cleared (also on closed days), points set to 0 by an adjust row,
  `deleted_at` set; bills and sales stay. Twice -> "This guest was already deleted."
- `save_loyalty_settings(p_spend_per_point, p_point_value, p_min_redeem)` (old, leaves the mode alone) and the 5-argument `save_loyalty_settings(..., p_mode text, p_max_percent numeric)` ('tender' | 'discount'; 1..100); needs `settings.manage`.
  GST note (plan 4.4): confirm with the tax adviser before a GST restaurant switches to 'discount'.
- Ledger kinds: earn, redeem, reverse, adjust, expire (no expiry job yet).
