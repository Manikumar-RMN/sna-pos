# Migrations

`NNN_name.sql`, applied in file-name order. Files 001-111 are the 112 entries in the live database's own history
(Supabase project `lrtoktmfspnypkgrvnzg`); `086a_` sits between 086 and 087 because it was applied between them.
112 is already in effect live but is not recorded in that history table; 113 is not applied at all.

**These files rebuild the live database.** Run `supabase/verify/verify_rebuild.sh`: it replays 001-112 on a
throw-away PostgreSQL and compares the result object by object with `supabase/schema/03_live_baseline.sql`
(checked on 14 Oct 2026: identical, 3,088 objects). Run it after adding any migration, and re-export the baseline
when the live database changes.

## What is and is not rebuilt

- Structure, functions, triggers, policies, grants: yes, exactly.
- **Global reference data** (countries, currencies, modules, permissions): yes, seeded by these files and identical to live
  (the `created_at` stamps differ).
- Per-restaurant data (roles, role permissions, tax groups and rates, payment methods, tables, menu) is created by the app's
  setup functions (`create_restaurant_with_owner` and friends) when a restaurant is set up, not by migrations.
- Price list `plan_prices`: migrations seed 8 rows; live has 49, added through the SNA console.
- `app.secrets` gets a **new random** `pin_pepper` on a rebuild, so PINs stored before will not match. Vault secrets
  `push_secret` / `push_url` must be created by hand.

## History notes

- 112 was found live but in no migration (changed directly in the database); it is written here so a rebuild has it.
- 113 revokes direct write rights on money and permission tables. NOT yet applied to live: run `supabase/apply_112_113_on_live.sql` in the Supabase SQL editor (it also records 112 and 113).
- 066 was an empty stub in git; the real file (clock-in/clock-out functions) is restored.
- `086a_ai_employee_mvp_schema` created tables from another product by mistake; 088 removes them. Both are kept so history is true.
- `070-074_optional_shifts_sessions_README.md` describes 070-074, which are now present as files.

## Files

| File | Live version | Status |
|---|---|---|
| `001_core.sql` | 20260923074950 | restored from the live migration history |
| `002_orders_payments.sql` | 20260923075047 | restored from the live migration history |
| `003_row_level_security.sql` | 20260923075112 | restored from the live migration history |
| `004_reference_seed.sql` | 20260923075127 | restored from the live migration history |
| `005_agent.sql` | 20260923075202 | restored from the live migration history |
| `006_move_citext_out_of_public.sql` | 20260923075228 | restored from the live migration history |
| `007_restaurant_bootstrap.sql` | 20260923092805 | restored from the live migration history |
| `008_grant_app_schema_usage.sql` | 20260923092831 | restored from the live migration history |
| `009_public_rpc_wrapper.sql` | 20260923093207 | restored from the live migration history |
| `010_create_order.sql` | 20260923125459 | restored from the live migration history |
| `011_menu_view.sql` | 20260923125635 | restored from the live migration history |
| `012_permission_aware_rls.sql` | 20260924095609 | restored from the live migration history |
| `013_billing_v2_shifts_void_refund.sql` | 20260924095728 | restored from the live migration history |
| `014_reports_staff_settings.sql` | 20260924095831 | restored from the live migration history |
| `015_pay_later_and_fixes.sql` | 20260924165305 | restored from the live migration history |
| `016_tax_rates_account_state.sql` | 20260924165452 | restored from the live migration history |
| `017_tax_engine_core.sql` | 20260924174602 | restored from the live migration history |
| `018_multicountry_tax.sql` | 20260924174949 | restored from the live migration history |
| `019_running_bills_split_pay_options.sql` | 20260925082605 | restored from the live migration history |
| `020_reports_partial_merged_cancelled.sql` | 20260925082616 | restored from the live migration history |
| `021_fix_empty_senior_marker.sql` | 20260925082707 | restored from the live migration history |
| `022_option_order_shift_merged.sql` | 20260925082820 | restored from the live migration history |
| `023_modifier_group_active.sql` | 20260925083134 | restored from the live migration history |
| `024_pin_login_counter_devices_password_reset.sql` | 20260925091715 | restored from the live migration history |
| `025_device_id_execute.sql` | 20260925091801 | restored from the live migration history |
| `026_hide_pin_hash.sql` | 20260925091846 | restored from the live migration history |
| `027_payment_modes_reference_settlement.sql` | 20260925091922 | restored from the live migration history |
| `028_fix_upi_check.sql` | 20260925091943 | restored from the live migration history |
| `029_revoke_direct_user_writes.sql` | 20260927043444 | restored from the live migration history |
| `030_pin_and_password_hardening.sql` | 20260927044332 | restored from the live migration history |
| `031_same_restaurant_links.sql` | 20260927111057 | restored from the live migration history |
| `032_hardening_menu_audit_refund_off.sql` | 20260927171736 | restored from the live migration history |
| `033_fix_product_guard_definer.sql` | 20260927171809 | restored from the live migration history |
| `034_security_profiles_take_payment.sql` | 20260928074757 | restored from the live migration history |
| `035_role_names_case_insensitive.sql` | 20260928080343 | restored from the live migration history |
| `036_adjust_open_bill_items_report.sql` | 20260928090242 | restored from the live migration history |
| `037_discount_cannot_exceed_bill.sql` | 20260928090408 | restored from the live migration history |
| `038_payment_methods_change_mode.sql` | 20260928090611 | restored from the live migration history |
| `039_business_days_and_payment_shift.sql` | 20260928091146 | restored from the live migration history |
| `040_day_close_reopen_credit_notes.sql` | 20260928091352 | restored from the live migration history |
| `041_manager_pin_approval.sql` | 20260928091519 | restored from the live migration history |
| `042_pin_approval_count_failures.sql` | 20260928091552 | restored from the live migration history |
| `043_india_gst_basics.sql` | 20260928092043 | restored from the live migration history |
| `044_default_sac_short_credit_note_numbers.sql` | 20260928092108 | restored from the live migration history |
| `045_kitchen_tickets_per_station.sql` | 20260928092352 | restored from the live migration history |
| `046_no_double_bill_or_payment.sql` | 20260928092741 | restored from the live migration history |
| `047_offline_billing.sql` | 20260928093244 | restored from the live migration history |
| `048_offline_sync_device_lookup.sql` | 20260928093255 | restored from the live migration history |
| `049_offline_price_check_fallback.sql` | 20260928093322 | restored from the live migration history |
| `050_stock_and_recipes.sql` | 20260928093811 | restored from the live migration history |
| `051_accounting_journal.sql` | 20260928094010 | restored from the live migration history |
| `052_hold_and_fire_courses.sql` | 20260928094100 | restored from the live migration history |
| `053_fire_held_items_fix.sql` | 20260928094110 | restored from the live migration history |
| `054_fy_label_search_path.sql` | 20260928094320 | restored from the live migration history |
| `055_editions_modules.sql` | 20260928102247 | replaced with the SQL that actually ran (the old text differed in code) |
| `056_feature_grants.sql` | 20260928102335 | restored from the live migration history |
| `057_multi_outlet.sql` | 20260928103339 | replaced with the SQL that actually ran (the old text differed in code) |
| `058_outlet_billing_device.sql` | 20260928103431 | restored from the live migration history |
| `059_menu_outlet_prices_view.sql` | 20260928103529 | restored from the live migration history |
| `060_second_language.sql` | 20260928104456 | restored from the live migration history |
| `061_qr_ordering_ebill.sql` | 20260928142807 | replaced with the SQL that actually ran (the old text differed in code) |
| `062_ebill_rate_format.sql` | 20260928142922 | restored from the live migration history |
| `063_qr_guest_note_to_kitchen.sql` | 20260928143330 | replaced with the SQL that actually ran (the old text differed in code) |
| `064_loyalty_giftcards_reservations_timesheets.sql` | 20260928143911 | already in git; same code as what ran (comments or begin/commit may differ) |
| `065_phone_numbers_international.sql` | 20260928144006 | already in git; same code as what ran (comments or begin/commit may differ) |
| `066_timesheet_clock_time.sql` | 20260928144111 | replaced with the SQL that actually ran (the old text differed in code) |
| `067_offline_snapshot_hide_redeem_methods.sql` | 20260928144220 | restored from the live migration history |
| `068_owner_alerts_push_open_api.sql` | 20260928145020 | replaced with the SQL that actually ran (the old text differed in code) |
| `069_push_gone_strict.sql` | 20260928145052 | restored from the live migration history |
| `070_optional_shifts_day_cutoff_sessions.sql` | 20260928175212 | restored from the live migration history |
| `071_auto_shift_id.sql` | 20260928175243 | restored from the live migration history |
| `072_session_id_no_fk.sql` | 20260928175309 | restored from the live migration history |
| `073_auto_close_keeps_auto_shift.sql` | 20260928175424 | restored from the live migration history |
| `074_day_status_shifts_flag.sql` | 20260928175531 | restored from the live migration history |
| `075_client_code_login.sql` | 20261004134704 | replaced with the SQL that actually ran (the old text differed in code) |
| `076_login_and_helper_hardening.sql` | 20261005071428 | already in git; same code as what ran (comments or begin/commit may differ) |
| `077_money_fixes.sql` | 20261005072701 | already in git; same code as what ran (comments or begin/commit may differ) |
| `078_guest_details_packing_tokens.sql` | 20261005072702 | already in git; same code as what ran (comments or begin/commit may differ) |
| `079_suppliers_and_purchasing.sql` | 20261005072703 | already in git; same code as what ran (comments or begin/commit may differ) |
| `080_bill_layout_and_logo.sql` | 20261005072704 | already in git; same code as what ran (comments or begin/commit may differ) |
| `081_report_schedules.sql` | 20261005091301 | already in git; same code as what ran (comments or begin/commit may differ) |
| `082_report_schedule_timer.sql` | 20261005091302 | already in git; same code as what ran (comments or begin/commit may differ) |
| `083_sna_console_crm.sql` | 20261005124437 | already in git; same code as what ran (comments or begin/commit may differ) |
| `084_licence_lock_and_sales_modules.sql` | 20261005131229 | already in git; same code as what ran (comments or begin/commit may differ) |
| `085_sna_creates_clients.sql` | 20261005160201 | already in git; same code as what ran (comments or begin/commit may differ) |
| `086_go_live_and_erase.sql` | 20261005165601 | already in git; same code as what ran (comments or begin/commit may differ) |
| `086a_ai_employee_mvp_schema.sql` | 20261007095103 | restored from the live migration history |
| `087_subcategories_menu_upload_account_date.sql` | 20261012102701 | already in git; same code as what ran (comments or begin/commit may differ) |
| `088_remove_foreign_ai_employee_tables.sql` | 20261012105501 | already in git; same code as what ran (comments or begin/commit may differ) |
| `089_complimentary_bills_outlet_codes.sql` | 20261012105702 | already in git; same code as what ran (comments or begin/commit may differ) |
| `090_bill_prefix.sql` | 20261012113903 | already in git; same code as what ran (comments or begin/commit may differ) |
| `091_subcategories_qr_api.sql` | 20261012160104 | already in git; same code as what ran (comments or begin/commit may differ) |
| `092_variants.sql` | 20261012160205 | already in git; same code as what ran (comments or begin/commit may differ) |
| `093_combos.sql` | 20261013043106 | already in git; same code as what ran (comments or begin/commit may differ) |
| `094_happy_hours.sql` | 20261013043107 | already in git; same code as what ran (comments or begin/commit may differ) |
| `095_business_type.sql` | 20261013043108 | already in git; same code as what ran (comments or begin/commit may differ) |
| `096_captain.sql` | 20261013043109 | already in git; same code as what ran (comments or begin/commit may differ) |
| `097_sell_by_weight.sql` | 20261013043110 | already in git; same code as what ran (comments or begin/commit may differ) |
| `098_pre_orders.sql` | 20261013043111 | already in git; same code as what ran (comments or begin/commit may differ) |
| `099_batches.sql` | 20261013043112 | already in git; same code as what ran (comments or begin/commit may differ) |
| `100_customer_accounts.sql` | 20261013043113 | already in git; same code as what ran (comments or begin/commit may differ) |
| `101_prepaid_cards.sql` | 20261013043114 | already in git; same code as what ran (comments or begin/commit may differ) |
| `102_brands.sql` | 20261013043115 | already in git; same code as what ran (comments or begin/commit may differ) |
| `103_riders.sql` | 20261013043116 | already in git; same code as what ran (comments or begin/commit may differ) |
| `104_liquor_bills.sql` | 20261013043117 | already in git; same code as what ran (comments or begin/commit may differ) |
| `105_chain_control.sql` | 20261013043118 | already in git; same code as what ran (comments or begin/commit may differ) |
| `106_kiosk.sql` | 20261013043119 | already in git; same code as what ran (comments or begin/commit may differ) |
| `107_online_orders.sql` | 20261013043120 | already in git; same code as what ran (comments or begin/commit may differ) |
| `108_tighten_new_table_grants.sql` | 20261013043521 | already in git; same code as what ran (comments or begin/commit may differ) |
| `109_online_partner_updates.sql` | 20261013045222 | already in git; same code as what ran (comments or begin/commit may differ) |
| `110_kiosk_auto_accept.sql` | 20261013045223 | already in git; same code as what ran (comments or begin/commit may differ) |
| `111_offline_liquor_bills.sql` | 20261013045224 | already in git; same code as what ran (comments or begin/commit may differ) |
| `112_whole_number_check_for_piece_items.sql` | not in history table | its change is already live (captured from the database) |
| `113_revoke_direct_writes_on_money_tables.sql` | not applied | written, tested on a scratch copy |
