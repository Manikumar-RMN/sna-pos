# Migrations 070–074 (optional shifts, day cutoff, meal sessions)

Applied to the live database on 28 Sep 2026, 23:22–23:25 IST, from a separate Claude session; reviewed, tested and adopted on 29 Sep.
The full SQL of each is stored in the database: `select statements from supabase_migrations.schema_migrations where name ~ '^07[0-4]'`.

- 070_optional_shifts_day_cutoff_sessions — branch_settings.shifts_enabled (default off) and day_cutoff (default 04:00);
  app.auto_shift (hidden drawer when shifts are off), app.close_auto_shifts, close_day(p_notes, p_counted_cash),
  app.business_today / try_auto_close_day / open_business_day use the cutoff; meal_sessions table, orders.session_id/session_name,
  trigger tags each bill at order open; save_meal_sessions (no overlaps), save_day_settings, session_report, z_report sessions;
  default sessions per country (India: Breakfast, Lunch, Hi-Tea, Evening snacks, Dinner).
- 071_auto_shift_id — auto_shift returns the new id reliably.
- 072_session_id_no_fk — bills keep their session even if sessions are edited later.
- 073_auto_close_keeps_auto_shift — automatic day roll-over leaves the automatic drawer running until a person counts it.
- 074_day_status_shifts_flag — day_status reports shifts_enabled and expected cash.
