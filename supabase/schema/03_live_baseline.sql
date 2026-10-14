-- =====================================================================
-- SNA POS: live database baseline
-- Snapshot of project lrtoktmfspnypkgrvnzg (SNA POS, Supabase, Postgres 17)
-- taken 2026-10-13 from the catalog (table grants refreshed 2026-10-14 after migration 113; sync_offline_bill and audit_to_alert refreshed after migration 114; v_menu and app.menu_price after 115) (pg_get_functiondef, pg_get_constraintdef,
-- pg_get_indexdef, pg_get_triggerdef, pg_get_viewdef, aclexplode).
--
-- WHAT THIS IS
--   The complete structure of the live database: 100 tables, 7 sequences,
--   331 functions (207 public, 124 app), 2 views, constraints, indexes,
--   triggers, Row Level Security, policies and grants. It is meant for
--   rebuilding an EMPTY Supabase project from git.
--
-- WHAT THIS IS NOT
--   * It is NOT a migration to run on the live database: every object here
--     already exists there and it would fail on the first CREATE.
--   * It holds NO DATA. Reference data (countries, currencies, permissions,
--     tax groups, modules, plan prices, ...) was seeded by the numbered
--     migrations and is not in this file.
--   * Secrets are not here and must be created again by hand:
--       - app.secrets row key='pin_pepper' (used to hash staff PINs; without
--         it PIN login and manager approval cannot work, and a DIFFERENT
--         value will not match PINs already stored);
--       - vault secrets 'push_secret' and 'push_url' (push notifications and
--         report e-mail; the Next.js push and report-email routes must use
--         the same push_secret).
--   * pg_net, pg_cron and supabase_vault are provided by Supabase; enable
--     them from the dashboard. Cron jobs found live are listed at the end as
--     comments, not created.
--
-- ORDER (so that each object only needs things created before it):
--   schemas, extensions, sequences, tables (bare columns), functions,
--   column defaults, keys, foreign keys, indexes, triggers, row level
--   security, policies, views, grants.
-- =====================================================================

SET check_function_bodies = off;
SET search_path = public, extensions;

-- The read-only role the SNA POS Agent connects as (NOLOGIN: it is reached by
-- SET ROLE from the service, never by password). Roles live outside the schema,
-- so it is created here before any GRANT names it.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sna_pos_agent') THEN
    CREATE ROLE sna_pos_agent NOLOGIN NOSUPERUSER NOBYPASSRLS INHERIT;
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
-- Enable from the Supabase dashboard if missing: pg_net (public), pg_cron, supabase_vault.


-- ---------------------------------------------------------------------
-- Sequences and tables (columns only; defaults and constraints follow)
-- ---------------------------------------------------------------------
CREATE SEQUENCE public.api_calls_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1;
CREATE SEQUENCE public.approval_failures_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1;
CREATE SEQUENCE public.audit_logs_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1;
CREATE SEQUENCE public.pin_attempts_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1;
CREATE SEQUENCE public.product_price_history_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1;
CREATE SEQUENCE public.restaurant_client_code_seq AS bigint START WITH 1000 INCREMENT BY 1 MINVALUE 1000 MAXVALUE 9223372036854775807 CACHE 1;
CREATE SEQUENCE public.sync_log_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1;
CREATE TABLE app.secrets (
  key text NOT NULL,
  value text NOT NULL
);
CREATE TABLE public.agent_actions (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  session_id uuid NOT NULL,
  action_type text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  proposed_change jsonb NOT NULL,
  rationale text,
  status text NOT NULL,
  reviewed_by uuid,
  reviewed_at timestamp with time zone,
  review_note text,
  applied_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.agent_messages (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  session_id uuid NOT NULL,
  role text NOT NULL,
  content text NOT NULL,
  executed_query text,
  rows_returned integer,
  input_tokens integer,
  output_tokens integer,
  latency_ms integer,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.agent_sessions (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid,
  user_id uuid NOT NULL,
  channel text NOT NULL,
  job text NOT NULL,
  started_at timestamp with time zone NOT NULL,
  ended_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.agent_settings (
  restaurant_id uuid NOT NULL,
  is_enabled boolean NOT NULL,
  allow_analyst boolean NOT NULL,
  allow_back_office boolean NOT NULL,
  allow_forecasting boolean NOT NULL,
  preferred_language text NOT NULL,
  monthly_question_cap integer NOT NULL,
  monthly_spend_cap numeric(14,2) NOT NULL,
  ai_processing_consent_at timestamp with time zone,
  ai_provider_name text,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL
);
CREATE TABLE public.agent_usage (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  period_month date NOT NULL,
  questions_asked integer NOT NULL,
  input_tokens bigint NOT NULL,
  output_tokens bigint NOT NULL,
  estimated_cost numeric(14,4) NOT NULL,
  currency_code character(3) NOT NULL,
  updated_at timestamp with time zone NOT NULL
);
CREATE TABLE public.api_calls (
  id bigint NOT NULL,
  key_id uuid NOT NULL,
  action text NOT NULL,
  at timestamp with time zone NOT NULL
);
CREATE TABLE public.api_keys (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  prefix text NOT NULL,
  key_hash text NOT NULL,
  created_by uuid,
  created_at timestamp with time zone NOT NULL,
  last_used_at timestamp with time zone,
  revoked_at timestamp with time zone
);
CREATE TABLE public.approval_failures (
  id bigint NOT NULL,
  restaurant_id uuid NOT NULL,
  user_id uuid NOT NULL,
  at timestamp with time zone NOT NULL
);
CREATE TABLE public.approvals (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  requested_by uuid NOT NULL,
  approved_by uuid NOT NULL,
  permission_key text NOT NULL,
  created_at timestamp with time zone NOT NULL,
  expires_at timestamp with time zone NOT NULL,
  used_at timestamp with time zone
);
CREATE TABLE public.audit_logs (
  id bigint NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid,
  user_id uuid,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  old_value jsonb,
  new_value jsonb,
  ip_address inet,
  device_id uuid,
  created_at timestamp with time zone NOT NULL,
  actor_type text NOT NULL,
  agent_session_id uuid
);
CREATE TABLE public.batch_movements (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  batch_id uuid NOT NULL,
  order_item_id uuid,
  qty numeric(12,3) NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.bill_series (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  prefix text NOT NULL,
  next_seq bigint NOT NULL,
  is_current boolean NOT NULL,
  created_at timestamp with time zone NOT NULL,
  created_by uuid
);
CREATE TABLE public.branch_prices (
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  product_id uuid NOT NULL,
  price numeric(12,2),
  is_available boolean,
  updated_at timestamp with time zone NOT NULL,
  updated_by uuid
);
CREATE TABLE public.branch_settings (
  branch_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  receipt_header text,
  receipt_footer text,
  service_charge_percent numeric(6,3) NOT NULL,
  cash_rounding_mode text NOT NULL,
  default_order_type text NOT NULL,
  auto_print_kot boolean NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  service_charge_taxable boolean NOT NULL,
  service_charge_default_on boolean NOT NULL,
  service_charge_label text NOT NULL,
  rounding_cash_only boolean NOT NULL,
  shifts_enabled boolean NOT NULL,
  day_cutoff time without time zone NOT NULL,
  token_numbers text NOT NULL,
  packing_product_id uuid,
  packing_per text NOT NULL,
  packing_takeaway boolean NOT NULL,
  packing_delivery boolean NOT NULL,
  bill_format jsonb NOT NULL,
  order_types text[] NOT NULL
);
CREATE TABLE public.branches (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  code text NOT NULL,
  address_line1 text,
  address_line2 text,
  city text,
  state_or_region text,
  postal_code text,
  country_code character(2) NOT NULL,
  phone text,
  timezone text NOT NULL,
  is_active boolean NOT NULL,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  deleted_at timestamp with time zone,
  is_central_kitchen boolean NOT NULL,
  region text,
  royalty_percent numeric(5,2) NOT NULL
);
CREATE TABLE public.brands (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  legal_name text,
  gstin text,
  commission_percent numeric(5,2) NOT NULL,
  is_active boolean NOT NULL,
  display_order smallint NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.business_days (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  business_date date NOT NULL,
  status text NOT NULL,
  opened_at timestamp with time zone NOT NULL,
  closed_at timestamp with time zone,
  closed_by uuid,
  close_notes text,
  z_report jsonb,
  reopen_count integer NOT NULL,
  created_at timestamp with time zone NOT NULL,
  last_token integer NOT NULL
);
CREATE TABLE public.cash_movements (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  shift_id uuid NOT NULL,
  direction text NOT NULL,
  amount numeric(14,2) NOT NULL,
  reason text NOT NULL,
  recorded_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.categories (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  image_url text,
  display_order smallint NOT NULL,
  is_active boolean NOT NULL,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  deleted_at timestamp with time zone,
  parent_id uuid,
  brand_id uuid
);
CREATE TABLE public.countries (
  code character(2) NOT NULL,
  name text NOT NULL,
  default_currency character(3) NOT NULL,
  default_timezone text NOT NULL,
  tax_system_name text NOT NULL,
  requires_fiscal_certification boolean NOT NULL,
  is_supported boolean NOT NULL,
  created_at timestamp with time zone NOT NULL,
  tax_id_label text,
  invoice_title text,
  has_senior_discount boolean NOT NULL,
  compliance_note text,
  dial_code text
);
CREATE TABLE public.credit_notes (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  order_id uuid NOT NULL,
  number text NOT NULL,
  business_date date NOT NULL,
  shift_id uuid,
  amount numeric(14,2) NOT NULL,
  tax_amount numeric(14,2) NOT NULL,
  taxes jsonb NOT NULL,
  reason text NOT NULL,
  payment_method_id uuid NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.currencies (
  code character(3) NOT NULL,
  name text NOT NULL,
  symbol text NOT NULL,
  decimal_places smallint NOT NULL
);
CREATE TABLE public.customer_ledger (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  kind text NOT NULL,
  amount numeric(14,2) NOT NULL,
  order_id uuid,
  payment_method_id uuid,
  shift_id uuid,
  note text,
  created_by uuid,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.customers (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text,
  phone text,
  email citext,
  tax_registration_no text,
  date_of_birth date,
  notes text,
  marketing_consent boolean NOT NULL,
  consent_given_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  deleted_at timestamp with time zone,
  credit_limit numeric(14,2),
  account_company text
);
CREATE TABLE public.devices (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  name text NOT NULL,
  device_type text NOT NULL,
  last_seen_at timestamp with time zone,
  is_active boolean NOT NULL,
  created_at timestamp with time zone NOT NULL,
  bill_prefix text,
  next_bill_seq bigint NOT NULL,
  auth_user_id uuid,
  bill_fy text
);
CREATE TABLE public.dining_tables (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  floor_id uuid,
  table_number text NOT NULL,
  seats smallint NOT NULL,
  status text NOT NULL,
  is_active boolean NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  qr_token text,
  is_kiosk boolean NOT NULL,
  kiosk_user_id uuid
);
CREATE TABLE public.floors (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  name text NOT NULL,
  display_order smallint NOT NULL
);
CREATE TABLE public.gift_card_ledger (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  gift_card_id uuid NOT NULL,
  order_id uuid,
  amount numeric(14,2) NOT NULL,
  kind text NOT NULL,
  created_by uuid,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.gift_cards (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  code text NOT NULL,
  value numeric(14,2) NOT NULL,
  expires_on date,
  customer_id uuid,
  sold_method_id uuid,
  sold_branch_id uuid,
  sold_shift_id uuid,
  issued_by uuid,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.goods_receipt_lines (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  goods_receipt_id uuid NOT NULL,
  ingredient_id uuid NOT NULL,
  qty numeric(14,3) NOT NULL,
  unit_cost numeric(14,4) NOT NULL,
  line_total numeric(14,2) NOT NULL,
  prev_cost numeric(14,4),
  new_cost numeric(14,4)
);
CREATE TABLE public.goods_receipts (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  supplier_id uuid NOT NULL,
  purchase_order_id uuid,
  number text NOT NULL,
  supplier_bill_no text,
  supplier_bill_date date,
  received_on date NOT NULL,
  subtotal numeric(14,2) NOT NULL,
  tax_amount numeric(14,2) NOT NULL,
  other_charges numeric(14,2) NOT NULL,
  total numeric(14,2) NOT NULL,
  paid_total numeric(14,2) NOT NULL,
  payment_status text NOT NULL,
  due_on date,
  notes text,
  status text NOT NULL,
  cancelled_at timestamp with time zone,
  cancelled_by uuid,
  cancel_reason text,
  received_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL,
  client_ref uuid
);
CREATE TABLE public.ingredients (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  unit text NOT NULL,
  cost_per_unit numeric(12,4) NOT NULL,
  reorder_level numeric(12,3) NOT NULL,
  is_active boolean NOT NULL,
  created_at timestamp with time zone NOT NULL,
  category text
);
CREATE TABLE public.kitchen_ticket_items (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  kitchen_ticket_id uuid NOT NULL,
  order_item_id uuid NOT NULL,
  product_name text NOT NULL,
  quantity numeric(10,3) NOT NULL,
  note text,
  status text NOT NULL,
  product_name_local text
);
CREATE TABLE public.kitchen_tickets (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  order_id uuid NOT NULL,
  ticket_number text NOT NULL,
  station text,
  status text NOT NULL,
  printed_at timestamp with time zone,
  started_at timestamp with time zone,
  ready_at timestamp with time zone,
  client_created_at timestamp with time zone NOT NULL,
  created_at timestamp with time zone NOT NULL,
  synced_at timestamp with time zone
);
CREATE TABLE public.liquor_series (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  prefix text NOT NULL,
  next_seq integer NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.loyalty_ledger (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  order_id uuid,
  points numeric(14,2) NOT NULL,
  kind text NOT NULL,
  note text,
  created_by uuid,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.loyalty_settings (
  restaurant_id uuid NOT NULL,
  spend_per_point numeric(14,2) NOT NULL,
  point_value numeric(14,4) NOT NULL,
  min_redeem integer NOT NULL,
  updated_at timestamp with time zone NOT NULL
);
CREATE TABLE public.meal_sessions (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid,
  name text NOT NULL,
  start_time time without time zone NOT NULL,
  end_time time without time zone NOT NULL,
  days smallint[] NOT NULL,
  display_order integer NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.modifier_groups (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  min_select smallint NOT NULL,
  max_select smallint NOT NULL,
  is_required boolean NOT NULL,
  created_at timestamp with time zone NOT NULL,
  is_active boolean NOT NULL
);
CREATE TABLE public.modifier_items (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  modifier_group_id uuid NOT NULL,
  name text NOT NULL,
  price_delta numeric(14,2) NOT NULL,
  display_order smallint NOT NULL,
  is_active boolean NOT NULL,
  product_id uuid
);
CREATE TABLE public.modules (
  key text NOT NULL,
  name text NOT NULL,
  description text NOT NULL,
  kind text NOT NULL,
  display_order smallint NOT NULL
);
CREATE TABLE public.offline_series (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  device_key text NOT NULL,
  prefix text NOT NULL,
  fy text,
  next_seq integer NOT NULL,
  created_at timestamp with time zone NOT NULL,
  last_sync_at timestamp with time zone,
  series_key text,
  liquor_next_seq integer NOT NULL
);
CREATE TABLE public.online_channels (
  restaurant_id uuid NOT NULL,
  channel text NOT NULL,
  callback_url text,
  secret text NOT NULL,
  updated_at timestamp with time zone NOT NULL
);
CREATE TABLE public.online_orders (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  channel text NOT NULL,
  external_ref text NOT NULL,
  items jsonb NOT NULL,
  customer_name text,
  customer_phone text,
  address text,
  note text,
  paid_online boolean NOT NULL,
  partner_total numeric(14,2),
  status text NOT NULL,
  order_id uuid,
  decided_by uuid,
  decided_at timestamp with time zone,
  reject_reason text,
  created_at timestamp with time zone NOT NULL,
  ready_at timestamp with time zone
);
CREATE TABLE public.order_discounts (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  order_id uuid NOT NULL,
  discount_type text NOT NULL,
  value numeric(14,2) NOT NULL,
  amount numeric(14,2) NOT NULL,
  reason text,
  approved_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.order_item_modifiers (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  order_item_id uuid NOT NULL,
  modifier_item_id uuid,
  name text NOT NULL,
  price_delta numeric(14,2) NOT NULL
);
CREATE TABLE public.order_item_taxes (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  order_id uuid NOT NULL,
  order_item_id uuid NOT NULL,
  component_name text NOT NULL,
  rate numeric(6,3) NOT NULL,
  taxable_amount numeric(14,2) NOT NULL,
  tax_amount numeric(14,2) NOT NULL
);
CREATE TABLE public.order_items (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  order_id uuid NOT NULL,
  product_id uuid NOT NULL,
  product_name text NOT NULL,
  unit_price numeric(14,2) NOT NULL,
  quantity numeric(10,3) NOT NULL,
  modifier_total numeric(14,2) NOT NULL,
  line_discount numeric(14,2) NOT NULL,
  line_subtotal numeric(14,2) NOT NULL,
  line_tax numeric(14,2) NOT NULL,
  line_total numeric(14,2) NOT NULL,
  is_price_inclusive boolean NOT NULL,
  kitchen_note text,
  cancelled_at timestamp with time zone,
  cancelled_by uuid,
  created_at timestamp with time zone NOT NULL,
  net_amount numeric(14,2) NOT NULL,
  service_charge numeric(14,2) NOT NULL,
  tax_included numeric(14,2) NOT NULL,
  tax_comps jsonb,
  options_text text,
  cancelled_qty numeric(10,3) NOT NULL,
  cancel_reason text,
  held boolean NOT NULL,
  product_name_local text,
  unit text,
  brand_id uuid
);
CREATE TABLE public.orders (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  device_id uuid,
  bill_number text NOT NULL,
  order_type text NOT NULL,
  dining_table_id uuid,
  customer_id uuid,
  cashier_id uuid NOT NULL,
  waiter_id uuid,
  shift_id uuid,
  status text NOT NULL,
  payment_status text NOT NULL,
  currency_code character(3) NOT NULL,
  subtotal numeric(14,2) NOT NULL,
  discount_total numeric(14,2) NOT NULL,
  tax_total numeric(14,2) NOT NULL,
  service_charge numeric(14,2) NOT NULL,
  rounding_adjustment numeric(14,2) NOT NULL,
  grand_total numeric(14,2) NOT NULL,
  paid_total numeric(14,2) NOT NULL,
  place_of_supply text,
  void_reason text,
  voided_by uuid,
  voided_at timestamp with time zone,
  client_created_at timestamp with time zone NOT NULL,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  synced_at timestamp with time zone,
  tax_included numeric(14,2) NOT NULL,
  tax_exempt_amount numeric(14,2) NOT NULL,
  exempt_sales numeric(14,2) NOT NULL,
  senior_details jsonb,
  calc_params jsonb,
  merged_into uuid,
  business_date date,
  buyer_gstin text,
  buyer_name text,
  client_ref uuid,
  offline_flags jsonb,
  receipt_token text,
  session_id uuid,
  session_name text,
  guest_name text,
  guest_phone text,
  delivery_address text,
  token_no integer,
  comp_kind text,
  comp_reason text,
  comp_by uuid,
  covers smallint,
  rider_id uuid,
  delivery_status text,
  out_at timestamp with time zone,
  delivered_at timestamp with time zone,
  is_liquor boolean NOT NULL,
  channel text
);
CREATE TABLE public.owner_alerts (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid,
  kind text NOT NULL,
  title text NOT NULL,
  body text NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.payment_methods (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  kind text NOT NULL,
  affects_cash_drawer boolean NOT NULL,
  is_active boolean NOT NULL,
  display_order smallint NOT NULL,
  collection_mode text NOT NULL,
  gateway_provider text,
  upi_id text,
  ask_reference boolean NOT NULL
);
CREATE TABLE public.payments (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  order_id uuid NOT NULL,
  payment_method_id uuid NOT NULL,
  amount numeric(14,2) NOT NULL,
  currency_code character(3) NOT NULL,
  tendered_amount numeric(14,2),
  change_amount numeric(14,2) NOT NULL,
  reference_no text,
  gateway_name text,
  status text NOT NULL,
  received_by uuid NOT NULL,
  client_created_at timestamp with time zone NOT NULL,
  created_at timestamp with time zone NOT NULL,
  synced_at timestamp with time zone,
  rounding_adjustment numeric(14,2) NOT NULL,
  shift_id uuid,
  client_ref uuid
);
CREATE TABLE public.permissions (
  key text NOT NULL,
  description text NOT NULL,
  is_sensitive boolean NOT NULL
);
CREATE TABLE public.pin_attempts (
  id bigint NOT NULL,
  device_id uuid NOT NULL,
  at timestamp with time zone NOT NULL,
  ok boolean NOT NULL
);
CREATE TABLE public.pin_sessions (
  device_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  user_id uuid NOT NULL,
  started_at timestamp with time zone NOT NULL,
  expires_at timestamp with time zone NOT NULL,
  last_activity_at timestamp with time zone NOT NULL
);
CREATE TABLE public.plan_prices (
  item text NOT NULL,
  currency_code character(3) NOT NULL,
  monthly_price numeric(12,2)
);
CREATE TABLE public.plan_requests (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  kind text NOT NULL,
  module_key text,
  outlet_name text,
  outlet_city text,
  note text,
  status text NOT NULL,
  requested_by_user uuid,
  requested_by_staff uuid,
  decided_by uuid,
  decided_at timestamp with time zone,
  decision_note text,
  done_by uuid,
  done_at timestamp with time zone,
  branch_id uuid,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.pre_order_payments (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  pre_order_id uuid NOT NULL,
  kind text NOT NULL,
  payment_method_id uuid NOT NULL,
  amount numeric(14,2) NOT NULL,
  reference text,
  shift_id uuid,
  created_by uuid,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.pre_orders (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  number integer NOT NULL,
  guest_name text NOT NULL,
  guest_phone text,
  due_at timestamp with time zone NOT NULL,
  order_type text NOT NULL,
  address text,
  note text,
  items jsonb NOT NULL,
  estimate numeric(14,2) NOT NULL,
  status text NOT NULL,
  order_id uuid,
  cancel_reason text,
  created_by uuid,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL
);
CREATE TABLE public.price_rules (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid,
  name text NOT NULL,
  days smallint[] NOT NULL,
  start_time time without time zone NOT NULL,
  end_time time without time zone NOT NULL,
  kind text NOT NULL,
  value numeric(14,2) NOT NULL,
  product_ids uuid[] NOT NULL,
  category_ids uuid[] NOT NULL,
  valid_from date,
  valid_to date,
  is_active boolean NOT NULL,
  created_at timestamp with time zone NOT NULL,
  created_by uuid
);
CREATE TABLE public.printers (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  name text NOT NULL,
  purpose text NOT NULL,
  connection text NOT NULL,
  address text,
  paper_width_mm smallint NOT NULL,
  station text,
  is_active boolean NOT NULL
);
CREATE TABLE public.product_batches (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  product_id uuid NOT NULL,
  made_on date NOT NULL,
  expires_on date NOT NULL,
  qty_made numeric(12,3) NOT NULL,
  qty_left numeric(12,3) NOT NULL,
  wasted numeric(12,3) NOT NULL,
  note text,
  created_by uuid,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.product_modifier_groups (
  product_id uuid NOT NULL,
  modifier_group_id uuid NOT NULL,
  restaurant_id uuid NOT NULL
);
CREATE TABLE public.product_price_history (
  id bigint NOT NULL,
  restaurant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  price numeric(12,2) NOT NULL,
  valid_from timestamp with time zone NOT NULL,
  valid_to timestamp with time zone
);
CREATE TABLE public.products (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  category_id uuid NOT NULL,
  tax_group_id uuid NOT NULL,
  sku text,
  barcode text,
  name text NOT NULL,
  short_name text,
  description text,
  price numeric(14,2) NOT NULL,
  cost_price numeric(14,2),
  image_url text,
  kitchen_station text,
  is_veg boolean,
  is_available boolean NOT NULL,
  display_order smallint NOT NULL,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  deleted_at timestamp with time zone,
  hsn_code text,
  name_local text,
  is_charge boolean NOT NULL,
  parent_id uuid,
  variant_name text,
  is_combo boolean NOT NULL,
  sold_by text NOT NULL,
  track_batches boolean NOT NULL
);
CREATE TABLE public.purchase_order_lines (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  purchase_order_id uuid NOT NULL,
  ingredient_id uuid NOT NULL,
  qty numeric(14,3) NOT NULL,
  unit_cost numeric(14,4) NOT NULL,
  received_qty numeric(14,3) NOT NULL
);
CREATE TABLE public.purchase_orders (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  supplier_id uuid NOT NULL,
  number text NOT NULL,
  status text NOT NULL,
  expected_on date,
  notes text,
  total numeric(14,2) NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL,
  ordered_at timestamp with time zone,
  closed_at timestamp with time zone
);
CREATE TABLE public.push_subscriptions (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  user_id uuid NOT NULL,
  endpoint text NOT NULL,
  p256dh text NOT NULL,
  auth text NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.qr_orders (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  dining_table_id uuid NOT NULL,
  items jsonb NOT NULL,
  estimated_total numeric(14,2),
  guest_name text,
  guest_note text,
  guest_key text NOT NULL,
  status text NOT NULL,
  order_id uuid,
  decided_by uuid,
  decided_at timestamp with time zone,
  reject_reason text,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.recipe_lines (
  restaurant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  ingredient_id uuid NOT NULL,
  qty numeric(12,4) NOT NULL
);
CREATE TABLE public.refunds (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  order_id uuid NOT NULL,
  payment_id uuid,
  amount numeric(14,2) NOT NULL,
  reason text NOT NULL,
  approved_by uuid NOT NULL,
  client_created_at timestamp with time zone NOT NULL,
  created_at timestamp with time zone NOT NULL,
  synced_at timestamp with time zone,
  shift_id uuid,
  payment_method_id uuid,
  credit_note_id uuid
);
CREATE TABLE public.report_schedules (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  send_time time without time zone NOT NULL,
  days smallint[] NOT NULL,
  emails text[] NOT NULL,
  phone_alert boolean NOT NULL,
  is_active boolean NOT NULL,
  last_run_on date,
  last_sent_at timestamp with time zone,
  last_for_date date,
  last_result text,
  last_email_result text,
  last_problem text,
  last_problem_at timestamp with time zone,
  created_by uuid,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL
);
CREATE TABLE public.report_send_days (
  scope text NOT NULL,
  day date NOT NULL,
  sends integer NOT NULL,
  tests integer NOT NULL,
  emails integer NOT NULL
);
CREATE TABLE public.request_refs (
  restaurant_id uuid NOT NULL,
  ref uuid NOT NULL,
  kind text NOT NULL,
  order_id uuid,
  result jsonb NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.reservations (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  guest_name text NOT NULL,
  phone text,
  party_size integer NOT NULL,
  reserved_for timestamp with time zone,
  dining_table_id uuid,
  status text NOT NULL,
  note text,
  created_by uuid,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  seated_at timestamp with time zone
);
CREATE TABLE public.restaurant_modules (
  restaurant_id uuid NOT NULL,
  module_key text NOT NULL,
  enabled_at timestamp with time zone NOT NULL,
  enabled_by uuid
);
CREATE TABLE public.restaurants (
  id uuid NOT NULL,
  legal_name text NOT NULL,
  trading_name text NOT NULL,
  country_code character(2) NOT NULL,
  currency_code character(3) NOT NULL,
  timezone text NOT NULL,
  tax_registration_no text,
  contact_email citext,
  contact_phone text,
  logo_url text,
  subscription_status text NOT NULL,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  deleted_at timestamp with time zone,
  fssai_no text,
  sac_code text,
  edition text NOT NULL,
  second_language text,
  client_code text NOT NULL,
  backup_phone text,
  business_type text NOT NULL
);
CREATE TABLE public.riders (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid,
  name text NOT NULL,
  phone text,
  is_active boolean NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.role_permissions (
  role_id uuid NOT NULL,
  permission_key text NOT NULL
);
CREATE TABLE public.roles (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  is_system boolean NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.shift_closings (
  shift_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  figures jsonb NOT NULL,
  unpaid_orders uuid[] NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.shifts (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  device_id uuid,
  opened_by uuid NOT NULL,
  closed_by uuid,
  opening_float numeric(14,2) NOT NULL,
  expected_cash numeric(14,2),
  counted_cash numeric(14,2),
  cash_variance numeric(14,2),
  notes text,
  opened_at timestamp with time zone NOT NULL,
  closed_at timestamp with time zone,
  status text NOT NULL,
  created_at timestamp with time zone NOT NULL,
  synced_at timestamp with time zone
);
CREATE TABLE public.sna_accounts (
  restaurant_id uuid NOT NULL,
  licence_start date,
  licence_expiry date,
  account_manager uuid,
  sales_person uuid,
  support_person uuid,
  last_contact date,
  next_contact date,
  updated_at timestamp with time zone NOT NULL,
  updated_by uuid,
  reminder_off_for date,
  live_at timestamp with time zone,
  live_by uuid
);
CREATE TABLE public.sna_contacts (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  kind text NOT NULL,
  full_name text NOT NULL,
  job_title text,
  phone text,
  email text,
  created_at timestamp with time zone NOT NULL,
  created_by uuid,
  removed_at timestamp with time zone
);
CREATE TABLE public.sna_notes (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  kind text NOT NULL,
  body text NOT NULL,
  staff_id uuid,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.sna_sales (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  sale_date date NOT NULL,
  kind text NOT NULL,
  description text NOT NULL,
  amount numeric(14,2) NOT NULL,
  currency_code character(3) NOT NULL,
  period_from date,
  period_to date,
  invoice_no text,
  paid_on date,
  note text,
  staff_id uuid,
  created_at timestamp with time zone NOT NULL,
  cancelled_at timestamp with time zone,
  cancelled_by uuid,
  cancel_reason text,
  modules text[] NOT NULL
);
CREATE TABLE public.sna_staff (
  id uuid NOT NULL,
  auth_user_id uuid NOT NULL,
  full_name text NOT NULL,
  email text NOT NULL,
  role text NOT NULL,
  is_active boolean NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.staff_invites (
  user_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  code_hash text NOT NULL,
  expires_at timestamp with time zone NOT NULL,
  created_by uuid,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.stock_movements (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  ingredient_id uuid NOT NULL,
  kind text NOT NULL,
  qty numeric(14,4) NOT NULL,
  unit_cost numeric(12,4),
  order_id uuid,
  order_item_id uuid,
  note text,
  created_by uuid,
  created_at timestamp with time zone NOT NULL,
  transfer_id uuid,
  goods_receipt_id uuid
);
CREATE TABLE public.subscription_events (
  id uuid NOT NULL,
  restaurant_id uuid,
  event text NOT NULL,
  details jsonb NOT NULL,
  staff_id uuid,
  user_id uuid,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.supplier_payments (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  supplier_id uuid NOT NULL,
  goods_receipt_id uuid NOT NULL,
  amount numeric(14,2) NOT NULL,
  method text NOT NULL,
  reference text,
  paid_on date NOT NULL,
  from_till boolean NOT NULL,
  cash_movement_id uuid,
  paid_by uuid NOT NULL,
  created_at timestamp with time zone NOT NULL,
  client_ref uuid,
  reverses_id uuid,
  reason text
);
CREATE TABLE public.suppliers (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  contact_person text,
  phone text,
  email text,
  tax_no text,
  address text,
  payment_days integer NOT NULL,
  notes text,
  is_active boolean NOT NULL,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.sync_log (
  id bigint NOT NULL,
  restaurant_id uuid NOT NULL,
  device_id uuid NOT NULL,
  direction text NOT NULL,
  records_sent integer NOT NULL,
  records_ok integer NOT NULL,
  records_failed integer NOT NULL,
  error_detail text,
  started_at timestamp with time zone NOT NULL,
  finished_at timestamp with time zone
);
CREATE TABLE public.tax_groups (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  name text NOT NULL,
  is_price_inclusive boolean NOT NULL,
  is_active boolean NOT NULL,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  separate_bill boolean NOT NULL
);
CREATE TABLE public.tax_rate_components (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  tax_rate_id uuid NOT NULL,
  name text NOT NULL,
  rate numeric(6,3) NOT NULL,
  display_order smallint NOT NULL,
  applies_when text NOT NULL,
  is_compound boolean NOT NULL
);
CREATE TABLE public.tax_rates (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  tax_group_id uuid NOT NULL,
  total_rate numeric(6,3) NOT NULL,
  valid_from date NOT NULL,
  valid_to date,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.time_entries (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  user_id uuid NOT NULL,
  clock_in timestamp with time zone NOT NULL,
  clock_out timestamp with time zone,
  edited_by uuid,
  edit_reason text,
  created_at timestamp with time zone NOT NULL
);
CREATE TABLE public.user_branches (
  user_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  restaurant_id uuid NOT NULL
);
CREATE TABLE public.users (
  id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  auth_user_id uuid,
  employee_code text NOT NULL,
  full_name text NOT NULL,
  email citext,
  phone text,
  role_id uuid NOT NULL,
  pin_hash text,
  pin_set_at timestamp with time zone,
  is_active boolean NOT NULL,
  last_login_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  deleted_at timestamp with time zone,
  must_change_password boolean NOT NULL,
  password_reset_hash text,
  current_branch_id uuid,
  all_outlets boolean NOT NULL,
  login_failed_count integer NOT NULL,
  login_locked_until timestamp with time zone
);

-- ---------------------------------------------------------------------
-- Functions: app schema
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.account_balance(p_customer uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(sum(amount), 0)::numeric(14,2) from public.customer_ledger where customer_id = p_customer
$function$
;

CREATE OR REPLACE FUNCTION app.account_method(p_rest uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v uuid;
begin
  select id into v from public.payment_methods where restaurant_id = p_rest and kind = 'account' order by display_order limit 1;
  if v is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order)
    values (p_rest, 'Customer account', 'account', false, false, 98) returning id into v;
  end if;
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION app.advance_method(p_rest uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v uuid;
begin
  select id into v from public.payment_methods where restaurant_id = p_rest and kind = 'advance' order by display_order limit 1;
  if v is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order)
    values (p_rest, 'Pre-order advance', 'advance', false, false, 99) returning id into v;
  end if;
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION app.allowed(p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid := app.current_user_id(); v_ap public.approvals%rowtype;
begin
  if app.has_permission(p_key) then return true; end if;
  if coalesce(current_setting('app.approved.' || replace(p_key, '.', '_'), true), '') = 'on' then return true; end if;
  if v_me is null then return false; end if;
  select * into v_ap from public.approvals
   where requested_by = v_me and permission_key = p_key and used_at is null and expires_at > now()
   order by created_at desc limit 1 for update skip locked;
  if not found then return false; end if;
  update public.approvals set used_at = now() where id = v_ap.id;
  perform set_config('app.approved.' || replace(p_key, '.', '_'), 'on', true);
  perform app.audit('approval.used', 'users', v_ap.approved_by, jsonb_build_object('permission', p_key, 'for_user', v_me));
  return true;
end $function$
;

CREATE OR REPLACE FUNCTION app.api_menu_items(p_category uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'name_local', p.name_local, 'price', p.price,
           'is_veg', p.is_veg, 'available', p.is_available, 'tax_group', tg.name, 'price_includes_tax', tg.is_price_inclusive,
           'kitchen_station', p.kitchen_station, 'variant_of', p.parent_id, 'variant', p.variant_name,
           'has_variants', exists (select 1 from public.products ch where ch.parent_id = p.id and ch.deleted_at is null))
           order by p.display_order, p.name), '[]'::jsonb)
    from public.products p join public.tax_groups tg on tg.id = p.tax_group_id
   where p.category_id = p_category and p.deleted_at is null
$function$
;

CREATE OR REPLACE FUNCTION app.audit(p_action text, p_entity text, p_entity_id uuid, p_new jsonb DEFAULT NULL::jsonb, p_old jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  insert into public.audit_logs
    (restaurant_id, branch_id, user_id, action, entity_type, entity_id,
     actor_type, old_value, new_value)
  values
    (app.current_restaurant_id(), app.current_branch_id(), app.current_user_id(),
     p_action, p_entity, p_entity_id, 'user', p_old, p_new)
$function$
;

CREATE OR REPLACE FUNCTION app.audit_to_alert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_title text; v_body text; v_who text; v_outlet text; v_cur text; n jsonb := coalesce(new.new_value, '{}'::jsonb); o jsonb := coalesce(new.old_value, '{}'::jsonb); v_bill text;
begin
  if new.restaurant_id is null or new.action not in ('order.void', 'credit_note.issue', 'day.close', 'day.reopen', 'shift.close', 'order.adjust',
      'order.cancel_item', 'payment.change_mode', 'approval.granted', 'menu.price_or_tax_changed', 'order.offline_flagged') then
    return new;
  end if;
  if not app.feature_on(new.restaurant_id, 'owner_app') then return new; end if;
  if new.action = 'order.adjust' and coalesce((n->>'discount')::numeric, 0) = 0 then return new; end if;
  if new.action = 'shift.close' and coalesce((n->>'variance')::numeric, 0) = 0 then return new; end if;
  select full_name into v_who from public.users where id = new.user_id;
  select name into v_outlet from public.branches where id = new.branch_id;
  select currency_code into v_cur from public.restaurants where id = new.restaurant_id;
  if new.action = 'order.void' then select bill_number into v_bill from public.orders where id = new.entity_id; end if;
  v_title := case new.action
    when 'order.void' then 'Bill voided'
    when 'credit_note.issue' then 'Credit note (refund)'
    when 'day.close' then 'Day closed'
    when 'day.reopen' then 'Day reopened'
    when 'shift.close' then 'Cash short / over at shift close'
    when 'order.adjust' then 'Discount given'
    when 'order.cancel_item' then 'Item cancelled'
    when 'payment.change_mode' then 'Payment mode changed'
    when 'approval.granted' then 'Manager PIN used'
    when 'order.offline_flagged' then 'Offline bill needs a look'
    else 'Price changed' end;
  v_body := concat_ws(' · ',
    case new.action
      when 'order.void' then concat('Bill ', v_bill, ' ', v_cur, ' ', o->>'grand_total', ' — ', n->>'reason')
      when 'credit_note.issue' then concat(n->>'number', ' on bill ', n->>'bill_number', ': ', v_cur, ' ', n->>'amount', ' — ', n->>'reason')
      when 'day.close' then concat(n->>'business_date', ': ', n->>'bills', ' bills, ', v_cur, ' ', n->>'total_billed')
      when 'day.reopen' then concat(n->>'business_date', ' — ', n->>'reason')
      when 'shift.close' then concat('Counted ', v_cur, ' ', n->>'counted_cash', ', expected ', n->>'expected_cash', ' (', n->>'variance', ')')
      when 'order.adjust' then concat('Bill ', n->>'bill_number', ': discount ', v_cur, ' ', n->>'discount', coalesce(' — ' || (n->>'reason'), ''))
      when 'order.cancel_item' then concat('Bill ', n->>'bill_number', ': ', n->>'qty', ' × ', n->>'item', ' — ', n->>'reason')
      when 'payment.change_mode' then concat('Bill ', n->>'bill_number', ': ', o->>'method', ' → ', n->>'method', ' — ', n->>'reason')
      when 'approval.granted' then concat(n->>'approver', ' approved ', n->>'permission')
      when 'order.offline_flagged' then concat('Bill ', n->>'bill_number', ': ', n->>'summary')
      else concat(n->>'name', ': ', o->>'price', ' → ', n->>'price') end,
    v_who, v_outlet);
  insert into public.owner_alerts (restaurant_id, branch_id, kind, title, body) values (new.restaurant_id, new.branch_id, new.action, v_title, left(v_body, 300));
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.auto_shift(p_branch uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v uuid; v_on boolean; v_rest uuid; v_user uuid;
begin
  select id into v from public.shifts where branch_id = p_branch and status = 'open' order by opened_at desc limit 1;
  if v is not null then return v; end if;
  select coalesce(bs.shifts_enabled, false), b.restaurant_id into v_on, v_rest
    from public.branches b left join public.branch_settings bs on bs.branch_id = b.id where b.id = p_branch;
  if v_rest is null or v_on then return null; end if;
  perform pg_advisory_xact_lock(hashtext('auto_shift:' || p_branch::text));
  select id into v from public.shifts where branch_id = p_branch and status = 'open' limit 1;
  if v is not null then return v; end if;
  v_user := coalesce(app.current_user_id(),
    (select u.id from public.users u join public.roles r on r.id = u.role_id
      where u.restaurant_id = v_rest and r.name = 'Owner' order by u.created_at limit 1));
  v := gen_random_uuid();
  insert into public.shifts (id, restaurant_id, branch_id, opened_by, opening_float, opened_at, status, notes)
  values (v, v_rest, p_branch, v_user, 0, now(), 'open', 'Automatic (shifts are off)');
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION app.basic_limits()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_ed text; v_n int;
begin
  select edition into v_ed from public.restaurants where id = new.restaurant_id;
  if v_ed <> 'basic' then return new; end if;
  if tg_table_name = 'products' then
    if new.deleted_at is not null then return new; end if;
    if tg_op = 'UPDATE' and old.deleted_at is null then return new; end if;
    select count(*) into v_n from public.products where restaurant_id = new.restaurant_id and deleted_at is null and id <> new.id;
    if v_n >= 300 then raise exception 'The Basic edition allows up to 300 menu items. Upgrade to Professional for more.'; end if;
  elsif tg_table_name = 'users' then
    if not new.is_active or new.deleted_at is not null then return new; end if;
    if tg_op = 'UPDATE' and old.is_active and old.deleted_at is null then return new; end if;
    select count(*) into v_n from public.users where restaurant_id = new.restaurant_id and is_active and deleted_at is null and id <> new.id;
    if v_n >= 10 then raise exception 'The Basic edition allows up to 10 active staff. Upgrade to Professional for more.'; end if;
  elsif tg_table_name = 'devices' then
    if not new.is_active or new.device_type <> 'counter' then return new; end if;
    if tg_op = 'UPDATE' and old.is_active then return new; end if;
    select count(*) into v_n from public.devices where restaurant_id = new.restaurant_id and is_active and device_type = 'counter' and id <> new.id;
    if v_n >= 2 then raise exception 'The Basic edition allows up to 2 counter tablets. Upgrade to Professional for more.'; end if;
  elsif tg_table_name = 'branches' then
    if new.deleted_at is not null then return new; end if;
    if tg_op = 'UPDATE' and old.deleted_at is null then return new; end if;
    select count(*) into v_n from public.branches where restaurant_id = new.restaurant_id and deleted_at is null and id <> new.id;
    if v_n >= 1 then raise exception 'The Basic edition has one outlet. Upgrade to Professional to add outlets.'; end if;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.batch_on_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_branch uuid; v_need numeric; b record; v_take numeric; m record; v_back numeric;
begin
  if not exists (select 1 from public.products where id = new.product_id and track_batches) then return new; end if;
  select branch_id into v_branch from public.orders where id = new.order_id;
  if tg_op = 'INSERT' then
    v_need := new.quantity;
    for b in select id, qty_left from public.product_batches
              where branch_id = v_branch and product_id = new.product_id and qty_left > 0 and expires_on >= app.local_today(new.restaurant_id)
              order by expires_on, made_on, created_at for update loop
      exit when v_need <= 0;
      v_take := least(v_need, b.qty_left);
      update public.product_batches set qty_left = qty_left - v_take where id = b.id;
      insert into public.batch_movements (restaurant_id, batch_id, order_item_id, qty) values (new.restaurant_id, b.id, new.id, -v_take);
      v_need := v_need - v_take;
    end loop;
  else
    v_back := coalesce(new.cancelled_qty, 0) - coalesce(old.cancelled_qty, 0);
    if v_back = 0 and new.cancelled_at is not null and old.cancelled_at is null then v_back := old.quantity - coalesce(old.cancelled_qty, 0); end if;
    if new.quantity < old.quantity and new.cancelled_at is null then v_back := old.quantity - new.quantity; end if;
    if v_back > 0 then
      -- put back to the newest batches this line took from, up to what it took
      for m in select bm.batch_id, -sum(bm.qty) as taken from public.batch_movements bm
                where bm.order_item_id = new.id group by bm.batch_id having -sum(bm.qty) > 0
                order by max(bm.created_at) desc loop
        exit when v_back <= 0;
        v_take := least(v_back, m.taken);
        update public.product_batches set qty_left = qty_left + v_take where id = m.batch_id;
        insert into public.batch_movements (restaurant_id, batch_id, order_item_id, qty) values (new.restaurant_id, m.batch_id, new.id, v_take);
        v_back := v_back - v_take;
      end loop;
    end if;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.bill_input(p_restaurant uuid, p_branch uuid, p_items jsonb, p_discount numeric, p_service_charge boolean, p_senior jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  bs record; v_country public.countries%rowtype; v_item jsonb; v_product public.products%rowtype;
  v_incl boolean; v_rate uuid; v_comps jsonb; v_lines jsonb := '[]'::jsonb; v_qty numeric; i int := 0;
  v_sc_on boolean; v_senior jsonb := null; v_cnt int; v_din int;
  v_req int; v_found int; v_opts jsonb; v_delta numeric; v_text text; g record; v_bp public.branch_prices%rowtype;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'The order is empty.';
  end if;
  if jsonb_array_length(p_items) > 200 then raise exception 'Too many lines on one bill.'; end if;

  select coalesce(s.service_charge_percent, 0) as sc_pct, coalesce(s.service_charge_taxable, false) as sc_tax,
         coalesce(s.service_charge_default_on, false) as sc_default, coalesce(s.service_charge_label, 'Service charge') as sc_label,
         coalesce(s.cash_rounding_mode, 'none') as rmode, coalesce(s.rounding_cash_only, false) as rcash
    into bs from public.branch_settings s where s.branch_id = p_branch;
  select c.* into v_country from public.restaurants r join public.countries c on c.code = r.country_code
   where r.id = p_restaurant;

  for v_item in select * from jsonb_array_elements(p_items) loop
    if coalesce(v_item->>'product_id', '') !~* '^[0-9a-f-]{36}$' then raise exception 'A menu item on the order no longer exists.'; end if;
    select * into v_product from public.products
     where id = (v_item->>'product_id')::uuid and restaurant_id = p_restaurant and deleted_at is null;
    if not found then raise exception 'A menu item on the order no longer exists.'; end if;
    select * into v_bp from public.branch_prices where branch_id = p_branch and product_id = v_product.id;
    if found then
      v_product.price := coalesce(v_bp.price, v_product.price);
      v_product.is_available := v_product.is_available and coalesce(v_bp.is_available, true);
    end if;
    if not v_product.is_available then raise exception '% is marked sold out.', v_product.name; end if;
    -- Happy hours / time-based prices (Settings → Happy hours): the lowest price a rule gives right now.
    v_product.price := app.rule_price(p_restaurant, p_branch, v_product.id, v_product.price, now());
    v_qty := coalesce((v_item->>'qty')::numeric, 1);
    if v_qty <= 0 then continue; end if;
    if v_qty > 999 then raise exception 'Quantity for % is too large.', v_product.name; end if;

    -- Options: every chosen option must belong to a group linked to this item,
    -- and each group's minimum / maximum must be met.
    v_opts := '[]'::jsonb; v_delta := 0; v_text := null;
    if jsonb_typeof(v_item->'options') = 'array' and jsonb_array_length(v_item->'options') > 0 then
      if jsonb_array_length(v_item->'options') > 30 then raise exception 'Too many options on %.', v_product.name; end if;
      if exists (select 1 from jsonb_array_elements_text(v_item->'options') x where x !~* '^[0-9a-f-]{36}$') then
        raise exception 'An option on % is no longer available.', v_product.name;
      end if;
      select count(distinct x) into v_req from jsonb_array_elements_text(v_item->'options') x;
      if v_req <> jsonb_array_length(v_item->'options') then raise exception 'An option was chosen twice on %.', v_product.name; end if;
      select count(*),
             coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price_delta', mi.price_delta, 'group', mg.name)
                                order by mg.is_required desc, mg.min_select desc, mg.name, mi.display_order, mi.name), '[]'::jsonb),
             coalesce(sum(mi.price_delta), 0),
             string_agg(mi.name, ', ' order by mg.is_required desc, mg.min_select desc, mg.name, mi.display_order, mi.name)
        into v_found, v_opts, v_delta, v_text
        from jsonb_array_elements_text(v_item->'options') x
        join public.modifier_items mi on mi.id = x::uuid and mi.restaurant_id = p_restaurant and mi.is_active
        join public.modifier_groups mg on mg.id = mi.modifier_group_id and mg.is_active
        join public.product_modifier_groups pmg on pmg.modifier_group_id = mg.id and pmg.product_id = v_product.id;
      if v_found <> v_req then raise exception 'An option on % is no longer available.', v_product.name; end if;
    end if;
    for g in
      select mg.name, greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end) as mn,
             coalesce(mg.max_select, 99) as mx,
             (select count(*) from jsonb_array_elements(v_opts) o
               join public.modifier_items mi on mi.id = (o->>'id')::uuid where mi.modifier_group_id = mg.id) as picked
        from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id
       where pmg.product_id = v_product.id and mg.is_active
    loop
      if g.picked < g.mn then
        raise exception 'Choose % for %.', case when g.mn > 1 then g.mn || ' from ' || g.name else g.name end, v_product.name;
      end if;
      if g.picked > g.mx then
        raise exception 'Choose at most % from % for %.', g.mx, g.name, v_product.name;
      end if;
    end loop;
    if v_product.price + v_delta < 0 then raise exception 'The options make % cost less than zero.', v_product.name; end if;

    select g2.is_price_inclusive into v_incl from public.tax_groups g2 where g2.id = v_product.tax_group_id;
    select tr.id into v_rate from public.tax_rates tr
     where tr.tax_group_id = v_product.tax_group_id and tr.valid_from <= app.local_today(p_restaurant)
       and (tr.valid_to is null or tr.valid_to >= app.local_today(p_restaurant))
     order by tr.valid_from desc limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'rate', rate, 'compound', is_compound)
                              order by display_order), '[]'::jsonb)
      into v_comps from public.tax_rate_components
     where tax_rate_id = v_rate and applies_when in ('always', 'intra_region');

    i := i + 1;
    v_lines := v_lines || jsonb_build_object(
      'key', i, 'product_id', v_product.id, 'name', v_product.name,
      'base_price', v_product.price, 'price', v_product.price + v_delta,
      'options', v_opts, 'options_text', v_text,
      'qty', v_qty, 'note', nullif(left(coalesce(v_item->>'note', ''), 200), ''), 'held', coalesce((v_item->>'hold')::boolean, false) and app.feature_on(p_restaurant, 'courses'),
      'inclusive', coalesce(v_incl, false), 'comps', v_comps);
  end loop;
  if i = 0 then raise exception 'The order is empty.'; end if;

  v_sc_on := coalesce(p_service_charge, bs.sc_default) and coalesce(bs.sc_pct, 0) > 0;

  if p_senior is not null and p_senior <> 'null'::jsonb then
    if not coalesce(v_country.has_senior_discount, false) then
      raise exception 'The senior citizen / PWD discount applies only in the Philippines.';
    end if;
    v_cnt := coalesce((p_senior->>'count')::int, 0);
    v_din := coalesce((p_senior->>'diners')::int, 0);
    if v_cnt < 1 or v_din < v_cnt then
      raise exception 'Enter how many senior citizens / PWDs and how many people in total.';
    end if;
    if coalesce(trim(p_senior->>'name'), '') = '' or coalesce(trim(p_senior->>'id_no'), '') = '' then
      raise exception 'Enter the senior citizen / PWD name and ID number.';
    end if;
    if coalesce(p_senior->>'kind', '') not in ('senior', 'pwd') then
      raise exception 'Choose senior citizen or PWD.';
    end if;
    v_senior := jsonb_build_object('share', round(v_cnt::numeric / v_din, 6), 'rate', 20,
      'kind', p_senior->>'kind', 'name', left(trim(p_senior->>'name'), 80),
      'id_no', left(trim(p_senior->>'id_no'), 40), 'count', v_cnt, 'diners', v_din);
  end if;

  return jsonb_build_object(
    'calc', jsonb_build_object(
      'lines', v_lines, 'discount', coalesce(p_discount, 0),
      'sc_percent', case when v_sc_on then bs.sc_pct else 0 end, 'sc_taxable', bs.sc_tax,
      'senior', v_senior,
      'rounding', case when bs.rcash then 'none' else bs.rmode end),
    'service_charge_available', coalesce(bs.sc_pct, 0) > 0, 'service_charge_on', v_sc_on,
    'service_charge_percent', bs.sc_pct, 'service_charge_label', bs.sc_label,
    'cash_rounding', case when bs.rcash then bs.rmode else 'none' end,
    'senior', v_senior);
end $function$
;

CREATE OR REPLACE FUNCTION app.block_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  -- sna_erase sets this for its own transaction, to the one restaurant being erased.
  if tg_op = 'DELETE' and nullif(current_setting('app.erase_restaurant', true), '') is not null
     and (to_jsonb(old)->>'restaurant_id') = current_setting('app.erase_restaurant', true) then
    return old;
  end if;
    raise exception
        'Records in % cannot be deleted. Use void or refund so the trail is kept.',
        tg_table_name;
end
$function$
;

CREATE OR REPLACE FUNCTION app.block_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if tg_op = 'DELETE' and nullif(current_setting('app.erase_restaurant', true), '') is not null
     and (to_jsonb(old)->>'restaurant_id') = current_setting('app.erase_restaurant', true) then
    return old;
  end if;
  raise exception '% records cannot be changed.', initcap(replace(tg_table_name, '_', ' '));
end $function$
;

CREATE OR REPLACE FUNCTION app.business_today(p_branch uuid)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select ((now() at time zone coalesce(b.timezone, r.timezone, 'UTC')) - coalesce(bs.day_cutoff, '04:00'::time)::interval)::date
    from public.branches b join public.restaurants r on r.id = b.restaurant_id
    left join public.branch_settings bs on bs.branch_id = b.id where b.id = p_branch;
$function$
;

CREATE OR REPLACE FUNCTION app.business_type_defaults(p_type text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case p_type
    when 'restaurant'    then '{"default_order_type":"dine_in","order_types":["dine_in","takeaway","delivery"],"token_numbers":"off"}'
    when 'fine_dine'     then '{"default_order_type":"dine_in","order_types":["dine_in","takeaway"],"token_numbers":"off"}'
    when 'bar'           then '{"default_order_type":"dine_in","order_types":["dine_in","takeaway"],"token_numbers":"off"}'
    when 'chain'         then '{"default_order_type":"dine_in","order_types":["dine_in","takeaway","delivery"],"token_numbers":"off"}'
    when 'cafe'          then '{"default_order_type":"takeaway","order_types":["dine_in","takeaway","delivery"],"token_numbers":"takeaway"}'
    when 'pizzeria'      then '{"default_order_type":"takeaway","order_types":["dine_in","takeaway","delivery"],"token_numbers":"takeaway"}'
    when 'qsr'           then '{"default_order_type":"takeaway","order_types":["dine_in","takeaway","delivery"],"token_numbers":"all"}'
    when 'desserts'      then '{"default_order_type":"takeaway","order_types":["dine_in","takeaway","delivery"],"token_numbers":"all"}'
    when 'food_court'    then '{"default_order_type":"takeaway","order_types":["takeaway"],"token_numbers":"all"}'
    when 'canteen'       then '{"default_order_type":"takeaway","order_types":["takeaway"],"token_numbers":"all"}'
    when 'bakery'        then '{"default_order_type":"takeaway","order_types":["takeaway","delivery"],"token_numbers":"off"}'
    when 'cloud_kitchen' then '{"default_order_type":"delivery","order_types":["takeaway","delivery"],"token_numbers":"off"}'
  end::jsonb
$function$
;

CREATE OR REPLACE FUNCTION app.calc_bill(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_lines   jsonb   := coalesce(p->'lines', '[]'::jsonb);
  n         int     := jsonb_array_length(coalesce(p->'lines', '[]'::jsonb));
  v_disc_in numeric := round(coalesce((p->>'discount')::numeric, 0), 2);
  v_sc_pct  numeric := coalesce((p->>'sc_percent')::numeric, 0);
  v_sc_tax  boolean := coalesce((p->>'sc_taxable')::boolean, false);
  v_share   numeric := coalesce((p->'senior'->>'share')::numeric, 0);
  v_s_pct   numeric := coalesce((p->'senior'->>'rate')::numeric, 20);
  v_round   text    := coalesce(p->>'rounding', 'none');

  subs numeric[] := '{}';
  discs numeric[] := '{}';
  v_subtotal numeric := 0;
  v_big int := 1;
  v_alloc numeric := 0;
  v_discount numeric;

  i int; k int; ln jsonb; comps jsonb; c jsonb;
  v_sub numeric; v_disc numeric; v_incl boolean; v_f numeric; v_rate numeric; v_cmp boolean;
  v_s_gross numeric; v_s_net numeric; v_s_disc numeric; v_s_removed numeric;
  v_r_amt numeric; v_net numeric; v_sc numeric;
  v_pi numeric; v_ps numeric; v_bi numeric; v_bs numeric; v_ai numeric; v_as numeric;
  ai numeric[]; bi numeric[];
  v_line_taxes jsonb; v_line_total numeric; v_line_tax numeric; v_line_incl numeric;
  o_lines jsonb := '[]'::jsonb;
  t_disc numeric := 0; t_sdisc numeric := 0; t_removed numeric := 0; t_sc numeric := 0;
  t_tax numeric := 0; t_incl numeric := 0; t_exempt numeric := 0; t_net numeric := 0;
  t_lines numeric := 0;
  v_before numeric; v_grand numeric;
  v_taxmap jsonb := '{}'::jsonb; v_key text; v_taxes jsonb;
  v_dc numeric; v_tc numeric; v_left int; v_best int;
  bases numeric[] := '{}'; rems numeric[] := '{}'; taken boolean[] := '{}';
begin
  if v_disc_in < 0 then raise exception 'A discount cannot be negative.'; end if;
  if v_share < 0 or v_share > 1 then raise exception 'The senior citizen / PWD share must be between 0 and 100%%.'; end if;
  if v_share > 0 and v_disc_in > 0 then
    raise exception 'A senior citizen / PWD discount cannot be combined with another discount.';
  end if;
  if v_sc_pct < 0 or v_sc_pct > 100 then raise exception 'The service charge must be between 0 and 100%%.'; end if;

  -- Pass 1: line subtotals at menu price.
  for i in 0 .. n - 1 loop
    ln := v_lines -> i;
    v_sub := round((ln->>'price')::numeric * (ln->>'qty')::numeric, 2);
    if v_sub < 0 then raise exception 'A line cannot be negative.'; end if;
    subs := subs || v_sub;
    v_subtotal := v_subtotal + v_sub;
    if v_sub > subs[v_big] then v_big := i + 1; end if;
  end loop;

  -- Pass 2: spread the bill discount by value; the largest line takes the
  -- rounding remainder so the parts always add up exactly.
  v_discount := least(v_disc_in, v_subtotal);
  for i in 1 .. n loop
    if i = v_big or v_subtotal = 0 then
      discs := discs || 0::numeric;
    else
      v_disc := round(v_discount * subs[i] / v_subtotal, 2);
      discs := discs || v_disc;
      v_alloc := v_alloc + v_disc;
    end if;
  end loop;
  if n > 0 then discs[v_big] := v_discount - v_alloc; end if;

  -- A small discount over many lines can leave the largest line with less than
  -- nothing (every small line rounds up to 0.01). When that happens, spread it
  -- again to the paisa by largest remainder: no line goes below zero or above
  -- its own value, and the parts still add up exactly.
  if n > 0 and v_subtotal > 0 and (discs[v_big] < 0 or discs[v_big] > subs[v_big]) then
    v_dc := v_discount * 100; v_tc := v_subtotal * 100; v_alloc := 0;
    for i in 1 .. n loop
      bases[i] := div(v_dc * (subs[i] * 100), v_tc);
      rems[i]  := mod(v_dc * (subs[i] * 100), v_tc);
      taken[i] := false;
      v_alloc  := v_alloc + bases[i];
    end loop;
    v_left := (v_dc - v_alloc)::int;
    while v_left > 0 loop
      v_best := 0;
      for i in 1 .. n loop
        if not taken[i] and (v_best = 0 or rems[i] > rems[v_best]) then v_best := i; end if;
      end loop;
      exit when v_best = 0;
      bases[v_best] := bases[v_best] + 1; taken[v_best] := true; v_left := v_left - 1;
    end loop;
    for i in 1 .. n loop discs[i] := round(bases[i] / 100, 2); end loop;
  end if;

  -- Pass 3: each line.
  for i in 0 .. n - 1 loop
    ln    := v_lines -> i;
    comps := coalesce(ln->'comps', '[]'::jsonb);
    v_incl := coalesce((ln->>'inclusive')::boolean, false);
    v_sub  := subs[i + 1];
    v_disc := discs[i + 1];

    -- Effective tax factor per 1.00 of net price (compound components apply on
    -- net + earlier components).
    v_f := 0;
    for k in 0 .. jsonb_array_length(comps) - 1 loop
      c := comps -> k;
      v_rate := coalesce((c->>'rate')::numeric, 0);
      v_cmp  := coalesce((c->>'compound')::boolean, false);
      v_f := v_f + v_rate / 100 * (1 + case when v_cmp then v_f else 0 end);
    end loop;

    -- Senior citizen / PWD share: VAT removed, then the percentage off.
    v_s_gross   := round(v_sub * v_share, 2);
    v_s_net     := case when v_incl then round(v_s_gross / (1 + v_f), 2) else v_s_gross end;
    v_s_removed := v_s_gross - v_s_net;
    v_s_disc    := round(v_s_net * v_s_pct / 100, 2);

    -- Regular (taxable) part of the line.
    v_r_amt := v_sub - v_s_gross - v_disc;
    v_net   := case when v_incl then round(v_r_amt / (1 + v_f), 2) else v_r_amt end;

    -- Item taxes.
    ai := '{}'; bi := '{}'; v_pi := 0;
    for k in 0 .. jsonb_array_length(comps) - 1 loop
      c := comps -> k;
      v_rate := coalesce((c->>'rate')::numeric, 0);
      v_cmp  := coalesce((c->>'compound')::boolean, false);
      v_bi := v_net + case when v_cmp then v_pi else 0 end;
      v_ai := round(v_bi * v_rate / 100, 2);
      ai := ai || v_ai; bi := bi || v_bi;
      v_pi := v_pi + v_ai;
    end loop;
    -- Inclusive price: whatever is not tax is the net, so the line is exact.
    if v_incl then v_net := v_r_amt - v_pi; end if;

    -- Service charge on the pre-discount-for-seniors net value.
    v_sc := round((v_net + v_s_net) * v_sc_pct / 100, 2);

    -- Tax on the service charge (added on top, never included).
    v_ps := 0; v_line_taxes := '[]'::jsonb;
    for k in 0 .. jsonb_array_length(comps) - 1 loop
      c := comps -> k;
      v_rate := coalesce((c->>'rate')::numeric, 0);
      v_cmp  := coalesce((c->>'compound')::boolean, false);
      if v_sc_tax then
        v_bs := v_sc + case when v_cmp then v_ps else 0 end;
        v_as := round(v_bs * v_rate / 100, 2);
      else
        v_bs := 0; v_as := 0;
      end if;
      v_ps := v_ps + v_as;
      v_line_taxes := v_line_taxes || jsonb_build_object(
        'name', c->>'name', 'rate', v_rate, 'compound', v_cmp,
        'taxable', bi[k + 1] + v_bs, 'amount', ai[k + 1] + v_as);
      v_key := (c->>'name') || '|' || v_rate::text;
      v_taxmap := jsonb_set(v_taxmap, array[v_key], jsonb_build_object(
        'name', c->>'name', 'rate', v_rate,
        'taxable', coalesce((v_taxmap->v_key->>'taxable')::numeric, 0) + bi[k + 1] + v_bs,
        'amount',  coalesce((v_taxmap->v_key->>'amount')::numeric, 0) + ai[k + 1] + v_as));
    end loop;

    v_line_tax   := v_pi + v_ps;
    v_line_incl  := case when v_incl then v_pi else 0 end;
    v_line_total := (case when v_incl then v_r_amt else v_net + v_pi end)
                    + (v_s_net - v_s_disc) + v_sc + v_ps;

    o_lines := o_lines || jsonb_build_object(
      'key', ln->'key', 'subtotal', v_sub, 'discount', v_disc,
      'senior_discount', v_s_disc, 'exempt_sales', v_s_net, 'tax_exempt_amount', v_s_removed,
      'net', v_net + v_s_net - v_s_disc, 'taxable_net', v_net,
      'service_charge', v_sc, 'tax', v_line_tax, 'tax_included', v_line_incl,
      'total', v_line_total, 'inclusive', v_incl, 'taxes', v_line_taxes);

    t_disc := t_disc + v_disc;          t_sdisc := t_sdisc + v_s_disc;
    t_removed := t_removed + v_s_removed; t_exempt := t_exempt + v_s_net;
    t_sc := t_sc + v_sc;                t_tax := t_tax + v_line_tax;
    t_incl := t_incl + v_line_incl;     t_net := t_net + v_net + v_s_net - v_s_disc;
    t_lines := t_lines + v_line_total;
  end loop;

  v_before := v_subtotal - t_disc - t_sdisc - t_removed + t_sc + t_tax - t_incl;

  -- Invariant: the bill must equal the sum of its lines. If it ever does not,
  -- refuse rather than print a wrong bill.
  if v_before <> t_lines then
    raise exception 'Internal check failed: bill total % does not equal line total %.', v_before, t_lines;
  end if;

  v_grand := app.round_cash(v_before, v_round);

  select coalesce(jsonb_agg(value order by (value->>'rate')::numeric, value->>'name'), '[]'::jsonb)
    into v_taxes from jsonb_each(v_taxmap);

  return jsonb_build_object(
    'lines', o_lines,
    'subtotal', v_subtotal, 'discount', t_disc, 'senior_discount', t_sdisc,
    'tax_exempt_amount', t_removed, 'exempt_sales', t_exempt,
    'service_charge', t_sc, 'tax_total', t_tax, 'tax_included', t_incl,
    'net_sales', t_net, 'before_round', v_before,
    'rounding', v_grand - v_before, 'grand_total', v_grand,
    'taxes', v_taxes);
end $function$
;

CREATE OR REPLACE FUNCTION app.can_use_branch(p_branch uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.branches b
     where b.id = p_branch and b.restaurant_id = app.current_restaurant_id() and b.deleted_at is null and b.is_active
       and (app.is_owner()
            or exists (select 1 from public.user_branches ub where ub.user_id = app.current_user_id() and ub.branch_id = b.id)
            or not exists (select 1 from public.user_branches ub where ub.user_id = app.current_user_id())))
$function$
;

CREATE OR REPLACE FUNCTION app.channel_method(p_restaurant uuid, p_channel text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_id uuid; v_name text := initcap(replace(p_channel, '_', ' ')) || ' (paid online)';
begin
  select id into v_id from public.payment_methods where restaurant_id = p_restaurant and kind = 'other' and name = v_name;
  if v_id is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order)
    values (p_restaurant, v_name, 'other', false, true, 90) returning id into v_id;
  end if;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION app.clean_bill_format(p jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_strip_nulls(jsonb_build_object(
    'paper',      case when p->>'paper' in ('58', '80') then p->>'paper' end,
    'text',       case when p->>'text' in ('small', 'normal', 'large') then p->>'text' end,
    'kot_text',   case when p->>'kot_text' in ('normal', 'large') then p->>'kot_text' end,
    'logo',       case when jsonb_typeof(p->'logo') = 'boolean' then p->'logo' end,
    'legal_name', case when jsonb_typeof(p->'legal_name') = 'boolean' then p->'legal_name' end,
    'branch',     case when jsonb_typeof(p->'branch') = 'boolean' then p->'branch' end,
    'address',    case when jsonb_typeof(p->'address') = 'boolean' then p->'address' end,
    'phone',      case when jsonb_typeof(p->'phone') = 'boolean' then p->'phone' end,
    'cashier',    case when jsonb_typeof(p->'cashier') = 'boolean' then p->'cashier' end,
    'guest',      case when jsonb_typeof(p->'guest') = 'boolean' then p->'guest' end,
    'rate',       case when jsonb_typeof(p->'rate') = 'boolean' then p->'rate' end,
    'upi_qr',     case when jsonb_typeof(p->'upi_qr') = 'boolean' then p->'upi_qr' end,
    'powered_by', case when jsonb_typeof(p->'powered_by') = 'boolean' then p->'powered_by' end))
$function$
;

CREATE OR REPLACE FUNCTION app.clean_phone(p text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare raw text := trim(coalesce(p, '')); d text; v_dial text;
begin
  d := regexp_replace(raw, '[^0-9]', '', 'g');
  if d = '' then return null; end if;
  if raw like '+%' then return d; end if;
  if d like '00%' then return substr(d, 3); end if;
  d := ltrim(d, '0');
  select c.dial_code into v_dial from public.restaurants r join public.countries c on c.code = r.country_code where r.id = app.current_restaurant_id();
  if length(d) <= 10 and v_dial is not null then return v_dial || d; end if;
  return d;
end $function$
;

CREATE OR REPLACE FUNCTION app.close_auto_shifts(p_branch uuid, p_counted numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s record; v_exp numeric(14,2);
begin
  if coalesce((select shifts_enabled from public.branch_settings where branch_id = p_branch), false) then return; end if;
  for s in select id from public.shifts where branch_id = p_branch and status = 'open' for update loop
    v_exp := (app.shift_figures(s.id)->>'expected_cash')::numeric;
    update public.shifts set status = 'closed', closed_at = now(), closed_by = app.current_user_id(), expected_cash = v_exp,
           counted_cash = round(p_counted, 2), cash_variance = case when p_counted is null then null else round(p_counted, 2) - v_exp end
     where id = s.id;
    if p_counted is not null then
      perform app.audit('shift.close', 'shifts', s.id,
        jsonb_build_object('expected_cash', v_exp, 'counted_cash', round(p_counted, 2), 'variance', round(p_counted, 2) - v_exp));
    end if;
  end loop;
end $function$
;

CREATE OR REPLACE FUNCTION app.country_preset(p_code text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case p_code
  when 'IN' then '{
    "prices_include_tax": false, "sc_taxable": false, "rounding": "nearest_1", "rounding_cash_only": false,
    "groups": [
      {"name":"Food 5%","comps":[{"name":"CGST","rate":2.5,"applies_when":"intra_region"},{"name":"SGST","rate":2.5,"applies_when":"intra_region"},{"name":"IGST","rate":5,"applies_when":"inter_region"}]},
      {"name":"Food 18% (hotel restaurants)","comps":[{"name":"CGST","rate":9,"applies_when":"intra_region"},{"name":"SGST","rate":9,"applies_when":"intra_region"},{"name":"IGST","rate":18,"applies_when":"inter_region"}]},
      {"name":"No GST","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"UPI","kind":"upi"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'AE' then '{
    "prices_include_tax": true, "sc_taxable": true, "rounding": "none", "rounding_cash_only": false,
    "groups": [
      {"name":"VAT 5%","comps":[{"name":"VAT","rate":5}]},
      {"name":"VAT 5% + municipality fee 7%","comps":[{"name":"Municipality fee","rate":7},{"name":"VAT","rate":5,"compound":true}]},
      {"name":"Zero-rated","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'SG' then '{
    "prices_include_tax": true, "sc_taxable": true, "rounding": "none", "rounding_cash_only": false,
    "groups": [{"name":"GST 9%","comps":[{"name":"GST","rate":9}]},{"name":"No GST","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"PayNow","kind":"wallet"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'MY' then '{
    "prices_include_tax": false, "sc_taxable": true, "rounding": "nearest_0_05", "rounding_cash_only": true,
    "groups": [{"name":"Service tax 6%","comps":[{"name":"Service Tax","rate":6}]},{"name":"No SST","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"DuitNow QR","kind":"wallet"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'TH' then '{
    "prices_include_tax": true, "sc_taxable": true, "rounding": "none", "rounding_cash_only": false,
    "groups": [{"name":"VAT 7%","comps":[{"name":"VAT","rate":7}]},{"name":"No VAT","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"PromptPay","kind":"wallet"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'ID' then '{
    "prices_include_tax": false, "sc_taxable": true, "rounding": "nearest_1", "rounding_cash_only": false,
    "groups": [{"name":"PBJT 10%","comps":[{"name":"PBJT","rate":10}]},{"name":"No tax","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"QRIS","kind":"wallet"},{"name":"Card","kind":"card"}]}'::jsonb
  when 'PH' then '{
    "prices_include_tax": true, "sc_taxable": true, "rounding": "none", "rounding_cash_only": false,
    "groups": [{"name":"VAT 12%","comps":[{"name":"VAT","rate":12}]},{"name":"VAT-exempt","comps":[]}],
    "payment_methods": [{"name":"Cash","kind":"cash"},{"name":"GCash","kind":"wallet"},{"name":"Maya","kind":"wallet"},{"name":"Card","kind":"card"}]}'::jsonb
  end
$function$
;

CREATE OR REPLACE FUNCTION app.create_kitchen_ticket(p_order uuid, p_items uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; v_n int; v_id uuid; v_first uuid; st record;
begin
  select * into o from public.orders where id = p_order;
  for st in
    select case when app.feature_on(o.restaurant_id, 'kitchen_stations') then coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen') else 'Kitchen' end as station
      from public.order_items oi left join public.products p on p.id = oi.product_id
     where oi.id = any(p_items) and not oi.held
       and not exists (select 1 from public.products cp where cp.id = oi.product_id and cp.is_charge)
     group by 1 order by 1
  loop
    v_id := gen_random_uuid();
    select count(*) + 1 into v_n from public.kitchen_tickets where order_id = p_order;
    insert into public.kitchen_tickets (id, restaurant_id, branch_id, order_id, ticket_number, station, status, client_created_at)
    values (v_id, o.restaurant_id, o.branch_id, o.id,
            'K-' || o.bill_number || case when v_n > 1 then '-' || v_n else '' end, st.station, 'new', now());
    insert into public.kitchen_ticket_items (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note)
    select o.restaurant_id, v_id, oi.id,
           oi.product_name || coalesce(' (' || oi.options_text || ')', ''), oi.quantity, oi.kitchen_note
      from public.order_items oi left join public.products p on p.id = oi.product_id
     where oi.id = any(p_items) and not oi.held
       and not exists (select 1 from public.products cp where cp.id = oi.product_id and cp.is_charge)
       and case when app.feature_on(o.restaurant_id, 'kitchen_stations') then coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen') else 'Kitchen' end = st.station
     order by oi.created_at, oi.id;
    v_first := coalesce(v_first, v_id);
  end loop;
  return v_first;
end $function$
;

CREATE OR REPLACE FUNCTION app.create_restaurant_with_owner(p_legal_name text, p_trading_name text, p_country_code character, p_owner_name text, p_branch_name text DEFAULT 'Main Branch'::text, p_branch_code text DEFAULT 'MN'::text, p_timezone text DEFAULT NULL::text, p_tax_registration_no text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_auth_uid uuid := auth.uid();
  v_country public.countries%rowtype;
  v_preset jsonb;
  v_restaurant uuid; v_branch uuid; v_owner_role uuid; v_manager uuid; v_cashier uuid;
  v_waiter uuid; v_chef uuid; v_user uuid; v_tz text; v_group uuid; g jsonb; pm jsonb; k int := 0;
begin
  if v_auth_uid is null then raise exception 'You must be signed in to create a restaurant.'; end if;
  if exists (select 1 from public.users u where u.auth_user_id = v_auth_uid and u.deleted_at is null) then
    raise exception 'This account already belongs to a restaurant.';
  end if;
  select * into v_country from public.countries where code = p_country_code;
  if not found then raise exception 'Unknown country code: %', p_country_code; end if;
  if not v_country.is_supported then
    raise exception 'SNA POS is not available in % yet. Its tax rules must be confirmed locally first.', v_country.name;
  end if;
  v_preset := app.country_preset(p_country_code);
  if v_preset is null then raise exception 'No tax setup exists for % yet.', v_country.name; end if;
  v_tz := coalesce(p_timezone, v_country.default_timezone);

  insert into public.restaurants (legal_name, trading_name, country_code, currency_code, timezone, tax_registration_no)
  values (p_legal_name, p_trading_name, p_country_code, v_country.default_currency, v_tz, nullif(upper(trim(p_tax_registration_no)), ''))
  returning id into v_restaurant;

  insert into public.branches (restaurant_id, name, code, country_code, timezone)
  values (v_restaurant, p_branch_name, p_branch_code, p_country_code, v_tz) returning id into v_branch;

  insert into public.roles (restaurant_id, name, is_system) values (v_restaurant, 'Owner', true) returning id into v_owner_role;
  insert into public.roles (restaurant_id, name, is_system) values (v_restaurant, 'Manager', true) returning id into v_manager;
  insert into public.roles (restaurant_id, name, is_system) values (v_restaurant, 'Cashier', true) returning id into v_cashier;
  insert into public.roles (restaurant_id, name, is_system) values (v_restaurant, 'Steward', true) returning id into v_waiter;
  insert into public.roles (restaurant_id, name, is_system) values (v_restaurant, 'Chef', true) returning id into v_chef;

  insert into public.role_permissions (role_id, permission_key) select v_owner_role, key from public.permissions;
  insert into public.role_permissions (role_id, permission_key)
    select v_manager, key from public.permissions where key not in ('tax.manage', 'settings.manage', 'agent.configure');
  insert into public.role_permissions (role_id, permission_key) values
    (v_cashier, 'order.create'), (v_cashier, 'payment.take'), (v_cashier, 'order.reprint'), (v_cashier, 'customer.manage'),
    (v_cashier, 'shift.open'), (v_cashier, 'report.view_sales'), (v_cashier, 'agent.use');
  insert into public.role_permissions (role_id, permission_key) values (v_waiter, 'order.create'), (v_waiter, 'customer.manage');
  insert into public.role_permissions (role_id, permission_key) values (v_chef, 'order.reprint');

  insert into public.users (restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
  values (v_restaurant, v_auth_uid, 'EMP001', p_owner_name, v_owner_role, (select email from auth.users where id = v_auth_uid))
  returning id into v_user;
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (v_user, v_branch, v_restaurant);

  -- Tax groups from the country preset.
  for g in select * from jsonb_array_elements(v_preset->'groups') loop
    insert into public.tax_groups (restaurant_id, name, is_price_inclusive)
    values (v_restaurant, g->>'name', (v_preset->>'prices_include_tax')::boolean) returning id into v_group;
    perform app.write_tax_group(v_restaurant, v_group, g->'comps');
  end loop;

  for pm in select * from jsonb_array_elements(v_preset->'payment_methods') loop
    k := k + 1;
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, display_order)
    values (v_restaurant, pm->>'name', pm->>'kind', pm->>'kind' = 'cash', k);
  end loop;

  insert into public.branch_settings
    (branch_id, restaurant_id, receipt_header, cash_rounding_mode, rounding_cash_only,
     service_charge_percent, service_charge_taxable, service_charge_default_on, auto_print_kot)
  values
    (v_branch, v_restaurant, p_trading_name, v_preset->>'rounding', (v_preset->>'rounding_cash_only')::boolean,
     0, (v_preset->>'sc_taxable')::boolean, false, true);

  insert into public.devices (restaurant_id, branch_id, name, device_type, bill_prefix)
  values (v_restaurant, v_branch, 'Counter 1', 'tablet', 'C1');

  insert into public.agent_settings (restaurant_id, is_enabled, preferred_language) values (v_restaurant, false, 'en');

  insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, actor_type, new_value)
  values (v_restaurant, v_branch, v_user, 'restaurant.create', 'restaurants', v_restaurant, 'user',
          jsonb_build_object('trading_name', p_trading_name, 'country', p_country_code));
  return v_restaurant;
end $function$
;

CREATE OR REPLACE FUNCTION app.current_bill_series(p_branch uuid)
 RETURNS bill_series
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s public.bill_series; v_rest uuid; v_p text; v_try text; n int := 1;
begin
  select * into s from public.bill_series where branch_id = p_branch and is_current for update;
  if found then return s; end if;
  perform pg_advisory_xact_lock(hashtext('bill_series:' || p_branch::text));
  select * into s from public.bill_series where branch_id = p_branch and is_current for update;
  if found then return s; end if;
  select restaurant_id into v_rest from public.branches where id = p_branch;
  if v_rest is null then raise exception 'Outlet not found.'; end if;
  v_p := app.default_bill_prefix(p_branch);
  v_try := v_p;
  while exists (select 1 from public.bill_series where restaurant_id = v_rest and upper(prefix) = upper(v_try)) loop
    n := n + 1;
    v_try := left(v_p, 7 - length(n::text)) || n;
  end loop;
  insert into public.bill_series (restaurant_id, branch_id, prefix) values (v_rest, p_branch, v_try) returning * into s;
  return s;
end $function$
;

CREATE OR REPLACE FUNCTION app.current_branch_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(
    (select d.branch_id from public.devices d where d.id = app.device_id()),
    (select u.current_branch_id from public.users u
      where u.id = app.current_user_id() and u.current_branch_id is not null and app.can_use_branch(u.current_branch_id)),
    (select b.id from public.branches b
      where b.restaurant_id = app.current_restaurant_id() and b.deleted_at is null and app.can_use_branch(b.id)
      order by b.created_at limit 1),
    (select b.id from public.branches b
      where b.restaurant_id = app.current_restaurant_id() and b.deleted_at is null
      order by b.created_at limit 1))
$function$
;

CREATE OR REPLACE FUNCTION app.current_restaurant_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select u.restaurant_id from public.users u where u.id = app.current_user_id()
$function$
;

CREATE OR REPLACE FUNCTION app.current_user_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case
    when app.device_id() is not null then
      (select ps.user_id from public.pin_sessions ps
         join public.users u on u.id = ps.user_id and u.is_active and u.deleted_at is null
        where ps.device_id = app.device_id() and ps.expires_at > now()
          and ps.last_activity_at > now() - interval '10 minutes'
          and u.restaurant_id = ps.restaurant_id)
    else
      (select u.id from public.users u
        where u.auth_user_id = auth.uid() and u.deleted_at is null and u.is_active
          and not coalesce(u.must_change_password, false) limit 1)
  end
$function$
;

CREATE OR REPLACE FUNCTION app.default_bill_prefix(p_branch uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_code text; v_country text; v_tz text; v_p text;
begin
  select upper(regexp_replace(b.code, '[^A-Za-z0-9]', '', 'g')), r.country_code, coalesce(b.timezone, r.timezone)
    into v_code, v_country, v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = p_branch;
  v_code := left(coalesce(nullif(v_code, ''), 'B'), 5);
  if v_country = 'IN' then
    v_p := v_code || substr(app.fy_label('IN', (now() at time zone coalesce(v_tz, 'Asia/Kolkata'))::date), 3, 2);
  else
    v_p := v_code;
  end if;
  return v_p;
end $function$
;

CREATE OR REPLACE FUNCTION app.default_sac()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.country_code = 'IN' and new.sac_code is null then new.sac_code := '996331'; end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.device_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select d.id from public.devices d where d.auth_user_id = auth.uid() and d.is_active limit 1
$function$
;

CREATE OR REPLACE FUNCTION app.effective_rate(p_comps jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare f numeric := 0; c jsonb;
begin
  for c in select * from jsonb_array_elements(coalesce(p_comps, '[]'::jsonb)) loop
    if coalesce(c->>'applies_when', 'always') in ('always', 'intra_region') then
      f := f + coalesce((c->>'rate')::numeric, 0) / 100
             * (1 + case when coalesce((c->>'compound')::boolean, false) then f else 0 end);
    end if;
  end loop;
  return round(f * 100, 3);
end $function$
;

CREATE OR REPLACE FUNCTION app.erase_groups()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select jsonb_build_object(
  'pos_tx', jsonb_build_array('online_orders', 'customer_ledger', 'batch_movements', 'pre_order_payments', 'pre_orders', 'order_item_modifiers', 'order_item_taxes', 'order_discounts', 'kitchen_ticket_items', 'kitchen_tickets',
            'refunds', 'credit_notes', 'payments', 'order_items', 'loyalty_ledger', 'gift_card_ledger', 'gift_cards', 'qr_orders', 'reservations',
            'orders', 'shift_closings', 'cash_movements', 'shifts', 'business_days', 'approvals', 'approval_failures', 'request_refs', 'sync_log',
            'owner_alerts', 'time_entries', 'audit_logs'),
  'pos_master', jsonb_build_array('online_channels', 'product_batches', 'price_rules', 'product_modifier_groups', 'modifier_items', 'modifier_groups', 'product_price_history', 'branch_prices',
            'products', 'categories', 'brands', 'dining_tables', 'floors', 'customers', 'riders'),
  'stock_tx', jsonb_build_array('goods_receipt_lines', 'purchase_order_lines', 'stock_movements', 'supplier_payments', 'goods_receipts', 'purchase_orders'),
  'stock_master', jsonb_build_array('recipe_lines', 'ingredients', 'suppliers')) $function$
;

CREATE OR REPLACE FUNCTION app.erase_tables(p_restaurant uuid, p_tables jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t text; v_n bigint; v_total bigint := 0; v_left int; v_err text; v_pass int;
begin
  for v_pass in 1..8 loop
    v_left := 0;
    for t in select jsonb_array_elements_text(p_tables) loop
      begin
        execute format('delete from public.%I where restaurant_id = $1', t) using p_restaurant;
        get diagnostics v_n = row_count;
        v_total := v_total + v_n;
      exception when foreign_key_violation then
        -- Something else still points at these rows; it is later in the list. Try again on the next pass.
        v_left := v_left + 1; v_err := sqlerrm;
      end;
    end loop;
    exit when v_left = 0;
  end loop;
  if v_left > 0 then raise exception 'Could not erase everything, so nothing was erased: %', v_err; end if;
  return v_total;
end $function$
;

CREATE OR REPLACE FUNCTION app.feature_on(p_restaurant uuid, p_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((
    select case m.kind
             when 'professional' then r.edition = 'professional'
             else exists (select 1 from public.restaurant_modules rm
                           where rm.restaurant_id = r.id and rm.module_key = m.key)
           end
      from public.modules m, public.restaurants r
     where m.key = p_key and r.id = p_restaurant), false)
$function$
;

CREATE OR REPLACE FUNCTION app.fill_local_name()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if tg_table_name = 'order_items' then
    if new.product_name_local is null and new.product_id is not null then
      select p.name_local into new.product_name_local from public.products p where p.id = new.product_id;
    end if;
  elsif tg_table_name = 'kitchen_ticket_items' then
    if new.product_name_local is null and new.order_item_id is not null then
      select oi.product_name_local into new.product_name_local from public.order_items oi where oi.id = new.order_item_id;
    end if;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.freeze_shift_figures()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare f jsonb;
begin
  if new.status = 'closed' and old.status = 'open' then
    f := app.shift_figures(old.id);
    insert into public.shift_closings (shift_id, restaurant_id, figures, unpaid_orders)
    values (old.id, old.restaurant_id,
            f || jsonb_build_object(
              'status', 'closed', 'closed_at', new.closed_at,
              'closed_by', (select full_name from public.users where id = new.closed_by),
              'expected_cash', coalesce(new.expected_cash, (f->>'expected_cash')::numeric),
              'counted_cash', new.counted_cash, 'variance', new.cash_variance, 'notes', new.notes),
            coalesce((select array_agg(o.id) from public.orders o
                       where o.shift_id = old.id and o.merged_into is null and o.status <> 'voided'
                         and o.payment_status in ('unpaid', 'partial')), '{}'))
    on conflict (shift_id) do update set figures = excluded.figures, unpaid_orders = excluded.unpaid_orders, created_at = now();
  elsif new.status = 'open' and old.status = 'closed' then
    delete from public.shift_closings where shift_id = old.id;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.fy_label(p_country text, p_date date)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case when p_country = 'IN'
    then case when extract(month from p_date) >= 4
              then extract(year from p_date)::int || '-' || lpad(((extract(year from p_date)::int + 1) % 100)::text, 2, '0')
              else (extract(year from p_date)::int - 1) || '-' || lpad((extract(year from p_date)::int % 100)::text, 2, '0') end
    else extract(year from p_date)::int::text end
$function$
;

CREATE OR REPLACE FUNCTION app.gift_balance(p_card uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(sum(amount), 0) from public.gift_card_ledger where gift_card_id = p_card;
$function$
;

CREATE OR REPLACE FUNCTION app.guard_closed_day()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_status text; v_order public.orders%rowtype;
begin
  if coalesce(current_setting('app.day_ok', true), '') = 'on' then return new; end if;
  if tg_table_name = 'orders' then
    select status into v_status from public.business_days where branch_id = old.branch_id and business_date = old.business_date;
    if v_status = 'closed' and (to_jsonb(new) - 'updated_at' - 'synced_at') is distinct from (to_jsonb(old) - 'updated_at' - 'synced_at') then
      raise exception 'The day % is closed, so bill % cannot be changed. Issue a credit note instead, or reopen the day.',
        to_char(old.business_date, 'DD Mon YYYY'), old.bill_number;
    end if;
  else
    select * into v_order from public.orders where id = new.order_id;
    select status into v_status from public.business_days where branch_id = v_order.branch_id and business_date = v_order.business_date;
    if v_status = 'closed' then
      raise exception 'The day % is closed, so bill % cannot be changed.', to_char(v_order.business_date, 'DD Mon YYYY'), v_order.bill_number;
    end if;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.guard_payment_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if coalesce(current_setting('app.pay_fix', true), '') = 'on'
     and old.status = 'captured' and new.status = 'captured'
     and (to_jsonb(new) - 'payment_method_id' - 'tendered_amount' - 'change_amount' - 'reference_no' - 'updated_at')
         is not distinct from
         (to_jsonb(old) - 'payment_method_id' - 'tendered_amount' - 'change_amount' - 'reference_no' - 'updated_at') then
    return new;
  end if;
  if (to_jsonb(new) - 'status' - 'updated_at') is distinct from (to_jsonb(old) - 'status' - 'updated_at')
     or not (old.status = 'captured' and new.status = 'refunded') then
    raise exception 'Payments cannot be changed.';
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.guard_product_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  -- no signed-in person (trusted server work); signed-in people without rights are already stopped by row security
  if app.current_user_id() is null then return new; end if;
  if tg_op = 'UPDATE' then
    if new.price is distinct from old.price and not app.has_permission('menu.price_change') then
      raise exception 'You do not have the right to change prices.';
    end if;
    if new.tax_group_id is distinct from old.tax_group_id and not app.has_permission('tax.manage') then
      raise exception 'You do not have the right to change the tax on an item.';
    end if;
    if new.price is distinct from old.price or new.tax_group_id is distinct from old.tax_group_id then
      perform app.audit('menu.price_or_tax_changed', 'product', new.id,
        jsonb_build_object('name', new.name, 'price', new.price, 'tax_group_id', new.tax_group_id),
        jsonb_build_object('price', old.price, 'tax_group_id', old.tax_group_id));
    end if;
  else
    perform app.audit('menu.item_added', 'product', new.id,
      jsonb_build_object('name', new.name, 'price', new.price, 'tax_group_id', new.tax_group_id));
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.guard_redeem_payment()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare k_new text; k_old text;
begin
  select kind into k_new from public.payment_methods where id = new.payment_method_id;
  if tg_op = 'INSERT' then
    if k_new in ('gift_card', 'loyalty') and coalesce(current_setting('app.redeem', true), '') <> 'on' then
      raise exception 'Use "Redeem gift card" or "Redeem points" on the bill for this payment.';
    end if;
    if k_new = 'advance' and coalesce(current_setting('app.advance', true), '') <> 'on' then
      raise exception 'A pre-order advance is applied with "Bill now" on the pre-order.';
    end if;
    if k_new = 'account' and coalesce(current_setting('app.account', true), '') <> 'on' then
      raise exception 'Use "Charge to account" on the bill for this payment.';
    end if;
  elsif new.payment_method_id is distinct from old.payment_method_id then
    select kind into k_old from public.payment_methods where id = old.payment_method_id;
    if k_new in ('gift_card', 'loyalty', 'advance', 'account') or k_old in ('gift_card', 'loyalty', 'advance', 'account') then
      raise exception 'A gift card, points, advance or account payment cannot be changed to another method, or the other way round.';
    end if;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.has_permission(p_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.users u join public.role_permissions rp on rp.role_id = u.role_id
     where u.id = app.current_user_id() and rp.permission_key = p_key)
$function$
;

CREATE OR REPLACE FUNCTION app.in_scope(p_branch uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select app.report_branch() is null or p_branch = app.report_branch()
$function$
;

CREATE OR REPLACE FUNCTION app.insert_order_lines(p_order uuid, p_restaurant uuid, p_lines jsonb)
 RETURNS uuid[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s jsonb; m jsonb; v_id uuid; v_ids uuid[] := '{}';
begin
  for s in select * from jsonb_array_elements(p_lines) loop
    v_id := gen_random_uuid();
    insert into public.order_items
      (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity, modifier_total,
       line_subtotal, line_discount, line_tax, line_total, is_price_inclusive, kitchen_note,
       net_amount, service_charge, tax_included, tax_comps, options_text, created_at, held)
    values
      (v_id, p_restaurant, p_order, (s->>'product_id')::uuid, s->>'name', (s->>'price')::numeric,
       (s->>'qty')::numeric, (s->>'price')::numeric - coalesce((s->>'base_price')::numeric, (s->>'price')::numeric),
       0, 0, 0, 0, coalesce((s->>'inclusive')::boolean, false), s->>'note',
       0, 0, 0, coalesce(s->'comps', '[]'::jsonb), nullif(s->>'options_text', ''), clock_timestamp(), coalesce((s->>'held')::boolean, false));
    for m in select * from jsonb_array_elements(coalesce(s->'options', '[]'::jsonb)) loop
      insert into public.order_item_modifiers (restaurant_id, order_item_id, modifier_item_id, name, price_delta)
      values (p_restaurant, v_id, (m->>'id')::uuid, m->>'name', coalesce((m->>'price_delta')::numeric, 0));
    end loop;
    v_ids := v_ids || v_id;
  end loop;
  return v_ids;
end $function$
;

CREATE OR REPLACE FUNCTION app.is_owner()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.users u join public.roles r on r.id = u.role_id
     where u.id = app.current_user_id() and r.name = 'Owner' and r.is_system)
$function$
;

CREATE OR REPLACE FUNCTION app.item_recipe(p_item uuid, p_product uuid)
 RETURNS TABLE(ingredient_id uuid, qty numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select x.ingredient_id, sum(x.qty)
    from (select rl.ingredient_id, rl.qty from public.recipe_lines rl where rl.product_id = p_product
          union all
          select rl.ingredient_id, rl.qty
            from public.order_item_modifiers om
            join public.modifier_items mi on mi.id = om.modifier_item_id
            join public.recipe_lines rl on rl.product_id = mi.product_id
           where om.order_item_id = p_item) x
   group by x.ingredient_id
$function$
;

CREATE OR REPLACE FUNCTION app.items_are_liquor(p_restaurant uuid, p_items jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_liq int; v_food int;
begin
  if not exists (select 1 from public.tax_groups where restaurant_id = p_restaurant and separate_bill) then return false; end if;
  select count(*) filter (where tg.separate_bill), count(*) filter (where not tg.separate_bill) into v_liq, v_food
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
    join public.products p on p.id::text = x->>'product_id' and p.restaurant_id = p_restaurant
    join public.tax_groups tg on tg.id = p.tax_group_id
   where not p.is_charge;
  if v_liq > 0 and v_food > 0 then
    raise exception 'Liquor and food go on separate bills. Bill the drinks on their own, then the food.';
  end if;
  return v_liq > 0;
end $function$
;

CREATE OR REPLACE FUNCTION app.kiosk_auto_accept(p_request uuid, p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_claims text := current_setting('request.jwt.claims', true); v_sub text := current_setting('request.jwt.claim.sub', true); v_auth uuid;
begin
  select auth_user_id into v_auth from public.users where id = p_user and is_active and deleted_at is null and not coalesce(must_change_password, false);
  if v_auth is null then return; end if;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_auth::text, true);
    perform public.accept_qr_order(p_request);
  exception when others then
    null;  -- stays on Table orders for the staff
  end;
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
end $function$
;

CREATE OR REPLACE FUNCTION app.licence_locked(p_restaurant uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$ select (app.licence_state(p_restaurant, p_at)->>'state') = 'locked' $function$
;

CREATE OR REPLACE FUNCTION app.licence_state(p_restaurant uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_status text; v_tz text; v_end date; v_off date;
  v_local timestamp; v_today date; v_lock_at timestamptz;
begin
  select r.subscription_status, coalesce(r.timezone, 'Asia/Kolkata'), a.licence_expiry, a.reminder_off_for
    into v_status, v_tz, v_end, v_off
    from public.restaurants r left join public.sna_accounts a on a.restaurant_id = r.id
   where r.id = p_restaurant;
  if not found then return jsonb_build_object('state', 'ok'); end if;

  if v_status in ('suspended', 'cancelled') then
    return jsonb_build_object('state', 'locked', 'reason', v_status, 'ends', v_end);
  end if;
  if v_end is null then return jsonb_build_object('state', 'ok', 'ends', null); end if;

  v_local := p_at at time zone v_tz;
  v_today := v_local::date;
  v_lock_at := ((v_end + 1)::timestamp + interval '6 hours') at time zone v_tz;
  if p_at >= v_lock_at then
    return jsonb_build_object('state', 'locked', 'reason', 'ended', 'ends', v_end, 'lock_at', v_lock_at);
  end if;
  if v_end - v_today <= 15 then
    return jsonb_build_object('state', 'warn', 'ends', v_end, 'days_left', greatest(v_end - v_today, 0), 'lock_at', v_lock_at,
                              'remind', v_off is distinct from v_end);
  end if;
  return jsonb_build_object('state', 'ok', 'ends', v_end, 'days_left', v_end - v_today, 'lock_at', v_lock_at);
end $function$
;

CREATE OR REPLACE FUNCTION app.local_day_start(p_restaurant uuid)
 returns timestamptz
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select (app.local_today(p_restaurant)::timestamp) at time zone coalesce(nullif(r.timezone, ''), 'UTC') from public.restaurants r where r.id = p_restaurant
$function$
;

CREATE OR REPLACE FUNCTION app.local_today(p_restaurant uuid)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select (now() at time zone coalesce(nullif(r.timezone, ''), 'UTC'))::date from public.restaurants r where r.id = p_restaurant
$function$
;

CREATE OR REPLACE FUNCTION app.log_plan(p_restaurant uuid, p_event text, p_details jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  insert into public.subscription_events (restaurant_id, event, details, staff_id, user_id)
  values (p_restaurant, p_event, coalesce(p_details, '{}'::jsonb), app.sna_staff_id(), app.current_user_id())
$function$
;

CREATE OR REPLACE FUNCTION app.loyalty_earn()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s public.loyalty_settings%rowtype; v_base numeric; v_pts numeric;
begin
  if new.payment_status <> 'paid' or new.customer_id is null or new.status = 'voided' then return new; end if;
  if not app.feature_on(new.restaurant_id, 'loyalty') then return new; end if;
  select * into s from public.loyalty_settings where restaurant_id = new.restaurant_id;
  if not found then return new; end if;
  if exists (select 1 from public.loyalty_ledger where order_id = new.id and kind = 'earn') then return new; end if;
  select new.grand_total - coalesce(sum(p.amount), 0) into v_base
    from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
   where p.order_id = new.id and p.status = 'captured' and pm.kind in ('loyalty', 'gift_card');
  v_pts := floor(greatest(v_base, 0) / s.spend_per_point);
  if v_pts > 0 then
    insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note)
    values (new.restaurant_id, new.customer_id, new.id, v_pts, 'earn', 'Bill ' || new.bill_number);
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.loyalty_reverse()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare e public.loyalty_ledger%rowtype; s public.loyalty_settings%rowtype; v_back numeric; v_done numeric;
begin
  select * into e from public.loyalty_ledger where order_id = new.order_id and kind = 'earn';
  if not found then return new; end if;
  select * into s from public.loyalty_settings where restaurant_id = new.restaurant_id;
  select coalesce(-sum(points), 0) into v_done from public.loyalty_ledger where order_id = new.order_id and kind = 'reverse';
  v_back := least(e.points - v_done, ceil(new.amount / coalesce(s.spend_per_point, 100)));
  if v_back > 0 then
    insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note)
    values (new.restaurant_id, e.customer_id, new.order_id, -v_back, 'reverse', 'Credit note ' || new.number);
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.monthly_charge(p_restaurant uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce((select monthly_price from public.plan_prices where item = r.edition and currency_code = r.currency_code), 0)
           * greatest((select count(*) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null), 1)
       + coalesce((select sum(pp.monthly_price) from public.restaurant_modules rm
                     join public.plan_prices pp on pp.item = rm.module_key and pp.currency_code = r.currency_code
                    where rm.restaurant_id = r.id), 0)
    from public.restaurants r where r.id = p_restaurant
$function$
;

CREATE OR REPLACE FUNCTION app.new_invite_code()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- 32 symbols, no 0/O/1/I
  v_code text := '';
  v_bytes bytea := extensions.gen_random_bytes(8);
begin
  for i in 0..7 loop
    v_code := v_code || substr(v_alpha, 1 + (get_byte(v_bytes, i) % 32), 1);
  end loop;
  return v_code;
end $function$
;

CREATE OR REPLACE FUNCTION app.new_token(p_bytes integer DEFAULT 18)
 RETURNS text
 LANGUAGE sql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  select translate(encode(extensions.gen_random_bytes(p_bytes), 'base64'), '+/=', '-_');
$function$
;

CREATE OR REPLACE FUNCTION app.next_bill_number(p_branch uuid, OUT device_id uuid, OUT bill_no text)
 RETURNS record
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s public.bill_series;
begin
  select d.id into device_id
    from public.devices d where d.branch_id = p_branch and d.is_active and d.device_type <> 'counter' order by d.created_at limit 1;
  if device_id is null then raise exception 'No billing device is set up for this branch.'; end if;
  s := app.current_bill_series(p_branch);
  bill_no := s.prefix || '-' || lpad(s.next_seq::text, greatest(4, length(s.next_seq::text)), '0');
  if length(bill_no) > 16 then
    raise exception 'Bill number % would be longer than 16 characters. Choose a shorter bill prefix in Settings → Billing.', bill_no;
  end if;
  update public.bill_series set next_seq = next_seq + 1 where id = s.id;
end $function$
;

CREATE OR REPLACE FUNCTION app.next_liquor_number(p_branch uuid, OUT device_id uuid, OUT bill_no text)
 RETURNS record
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s public.liquor_series; v_rest uuid; v_try text; n int := 1; v_base text;
begin
  select d.id into device_id from public.devices d where d.branch_id = p_branch and d.is_active and d.device_type <> 'counter' order by d.created_at limit 1;
  if device_id is null then raise exception 'No billing device is set up for this branch.'; end if;
  select * into s from public.liquor_series where branch_id = p_branch for update;
  if not found then
    perform pg_advisory_xact_lock(hashtext('liquor_series:' || p_branch::text));
    select restaurant_id into v_rest from public.branches where id = p_branch;
    v_base := 'BAR' || to_char(now(), 'YY'); v_try := v_base;
    while exists (select 1 from public.liquor_series where restaurant_id = v_rest and upper(prefix) = upper(v_try))
       or exists (select 1 from public.bill_series where restaurant_id = v_rest and upper(prefix) = upper(v_try)) loop
      n := n + 1; v_try := left(v_base, 7 - length(n::text)) || n;
    end loop;
    insert into public.liquor_series (restaurant_id, branch_id, prefix) values (v_rest, p_branch, v_try)
    on conflict (branch_id) do nothing;
    select * into s from public.liquor_series where branch_id = p_branch for update;
  end if;
  bill_no := s.prefix || '-' || lpad(s.next_seq::text, greatest(4, length(s.next_seq::text)), '0');
  if length(bill_no) > 16 then raise exception 'Liquor bill number % would be longer than 16 characters. Choose a shorter liquor prefix.', bill_no; end if;
  update public.liquor_series set next_seq = next_seq + 1 where id = s.id;
  perform set_config('app.liquor_bill', 'on', true);
end $function$
;

CREATE OR REPLACE FUNCTION app.offline_liquor_code(p_branch uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_p text; v_base text; v_try text; n int := 1;
begin
  select restaurant_id into v_rest from public.branches where id = p_branch;
  if not exists (select 1 from public.tax_groups where restaurant_id = v_rest and separate_bill) then return null; end if;
  select prefix into v_p from public.liquor_series where branch_id = p_branch;
  if v_p is not null then return v_p; end if;
  perform pg_advisory_xact_lock(hashtext('liquor_series:' || p_branch::text));
  v_base := 'BAR' || to_char(now(), 'YY'); v_try := v_base;
  while exists (select 1 from public.liquor_series where restaurant_id = v_rest and upper(prefix) = upper(v_try))
     or exists (select 1 from public.bill_series where restaurant_id = v_rest and upper(prefix) = upper(v_try)) loop
    n := n + 1; v_try := left(v_base, 7 - length(n::text)) || n;
  end loop;
  insert into public.liquor_series (restaurant_id, branch_id, prefix) values (v_rest, p_branch, v_try) on conflict (branch_id) do nothing;
  return (select prefix from public.liquor_series where branch_id = p_branch);
end $function$
;

CREATE OR REPLACE FUNCTION app.open_business_day(p_branch uuid)
 RETURNS business_days
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.business_days; v_rest uuid; v_date date; v_today date;
begin
  v_today := app.business_today(p_branch);
  select * into d from public.business_days where branch_id = p_branch and status = 'open';
  if found then
    if d.business_date >= v_today or not app.try_auto_close_day(d.id) then return d; end if;
  end if;
  select b.restaurant_id into v_rest from public.branches b where b.id = p_branch;
  if v_rest is null then raise exception 'Branch not found.'; end if;
  perform pg_advisory_xact_lock(hashtext('business_day:' || p_branch::text));
  select * into d from public.business_days where branch_id = p_branch and status = 'open';
  if found then return d; end if;
  select greatest(v_today, coalesce(max(business_date) + 1, v_today)) into v_date from public.business_days where branch_id = p_branch;
  insert into public.business_days (restaurant_id, branch_id, business_date) values (v_rest, p_branch, v_date)
  returning * into d;
  return d;
end $function$
;

CREATE OR REPLACE FUNCTION app.order_covered(p_order uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(sum(amount - coalesce(rounding_adjustment, 0)), 0)::numeric(14,2)
    from public.payments where order_id = p_order and status = 'captured';
$function$
;

CREATE OR REPLACE FUNCTION app.pay_goods_receipt(p_receipt uuid, p_amount numeric, p_method text, p_reference text, p_paid_on date, p_from_till boolean, p_user uuid, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  g public.goods_receipts%rowtype; v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_left numeric(14,2); v_shift uuid; v_move uuid; v_sup text; v_id uuid := gen_random_uuid(); v_today date;
begin
  select * into g from public.goods_receipts where id = p_receipt for update;
  if not found then raise exception 'Goods receipt not found.'; end if;
  if g.status = 'cancelled' then raise exception 'Receipt % was cancelled.', g.number; end if;
  if coalesce(p_method, '') not in ('cash', 'bank', 'upi', 'cheque', 'card', 'other') then
    raise exception 'Choose how the supplier was paid.';
  end if;
  v_left := g.total - g.paid_total;
  if v_left <= 0 then raise exception 'Receipt % is already fully paid.', g.number; end if;
  if v_amount <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  if v_amount > v_left then raise exception 'Only % is still owed on receipt %.', v_left, g.number; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = g.restaurant_id))::date;
  if p_paid_on is not null and p_paid_on > v_today then raise exception 'The payment date cannot be in the future.'; end if;
  select name into v_sup from public.suppliers where id = g.supplier_id;

  if coalesce(p_from_till, false) then
    if p_method <> 'cash' then raise exception 'Only a cash payment can come out of the till.'; end if;
    if not app.allowed('cash.movement') then
      raise exception 'Your role does not allow this action (cash.movement).';
    end if;
    select id into v_shift from public.shifts where branch_id = g.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(g.branch_id); end if;
    if v_shift is null then raise exception 'Open a shift before paying a supplier from the till.'; end if;
    v_move := gen_random_uuid();
    insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_move, g.restaurant_id, v_shift, 'out', v_amount, left('Paid supplier ' || v_sup || ' (' || g.number || ')', 200), p_user);
  end if;

  insert into public.supplier_payments (id, restaurant_id, branch_id, supplier_id, goods_receipt_id, amount, method, reference,
                                        paid_on, from_till, cash_movement_id, paid_by, client_ref)
  values (v_id, g.restaurant_id, g.branch_id, g.supplier_id, g.id, v_amount, p_method,
          nullif(left(trim(coalesce(p_reference, '')), 60), ''), coalesce(p_paid_on, v_today),
          coalesce(p_from_till, false), v_move, p_user, p_client_ref);
  update public.goods_receipts set paid_total = paid_total + v_amount,
         payment_status = case when paid_total + v_amount >= total then 'paid' else 'partial' end
   where id = g.id;
  perform app.audit('supplier.pay', 'goods_receipts', g.id,
    jsonb_build_object('number', g.number, 'supplier', v_sup, 'amount', v_amount, 'method', p_method, 'from_till', coalesce(p_from_till, false)));
  return jsonb_build_object('payment_id', v_id, 'amount', v_amount, 'balance', v_left - v_amount, 'paid', v_left - v_amount = 0);
end $function$
;

CREATE OR REPLACE FUNCTION app.pin_hash(p_restaurant uuid, p_pin text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select encode(extensions.hmac(p_restaurant::text || ':' || p_pin,
                (select value from app.secrets where key = 'pin_pepper'), 'sha256'), 'hex')
$function$
;

CREATE OR REPLACE FUNCTION app.points_balance(p_customer uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(sum(points), 0) from public.loyalty_ledger where customer_id = p_customer;
$function$
;

CREATE OR REPLACE FUNCTION app.pre_order_held(p_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(sum(case when kind = 'advance' then amount else -amount end), 0)::numeric(14,2)
    from public.pre_order_payments where pre_order_id = p_id
$function$
;

CREATE OR REPLACE FUNCTION app.protect_completed_orders()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if old.status in ('completed', 'voided') then
    if new.bill_number is distinct from old.bill_number or new.branch_id is distinct from old.branch_id then
      raise exception 'Bill % cannot be renumbered or moved to another branch.', old.bill_number;
    end if;
    if new.subtotal is distinct from old.subtotal
    or new.discount_total is distinct from old.discount_total
    or new.tax_total is distinct from old.tax_total
    or new.tax_included is distinct from old.tax_included
    or new.tax_exempt_amount is distinct from old.tax_exempt_amount
    or new.service_charge is distinct from old.service_charge
    or new.grand_total is distinct from old.grand_total then
      if not (coalesce(current_setting('app.recalc', true), '') = 'on'
              and old.status = 'completed' and old.payment_status in ('unpaid', 'partial')) then
        raise exception 'Bill % is closed and its amounts cannot be changed. Void it or raise a refund instead.', old.bill_number;
      end if;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.purchase_lines(p_rest uuid, p_lines jsonb)
 RETURNS TABLE(ingredient_id uuid, qty numeric, unit_cost numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare l jsonb; v_ing public.ingredients%rowtype; v_seen uuid[] := '{}';
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one ingredient.';
  end if;
  if jsonb_array_length(p_lines) > 200 then raise exception 'Too many lines. Split it into two.'; end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce(l->>'ingredient_id', '') !~* '^[0-9a-f-]{36}$' then raise exception 'An ingredient on the list no longer exists.'; end if;
    select * into v_ing from public.ingredients i where i.id = (l->>'ingredient_id')::uuid and i.restaurant_id = p_rest and i.is_active;
    if not found then raise exception 'An ingredient on the list no longer exists.'; end if;
    if v_ing.id = any(v_seen) then raise exception '% is on the list twice. Put it on one line.', v_ing.name; end if;
    v_seen := v_seen || v_ing.id;
    qty := round(coalesce((l->>'qty')::numeric, 0), 3);
    unit_cost := round(coalesce((l->>'unit_cost')::numeric, v_ing.cost_per_unit, 0), 4);
    if qty <= 0 then raise exception 'Enter a quantity for %.', v_ing.name; end if;
    if qty > 1000000 then raise exception 'The quantity for % is too large.', v_ing.name; end if;
    if unit_cost < 0 then raise exception 'The cost of % cannot be negative.', v_ing.name; end if;
    ingredient_id := v_ing.id;
    return next;
  end loop;
end $function$
;

CREATE OR REPLACE FUNCTION app.push_alert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_subs jsonb; v_url text; v_secret text;
begin
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth))), '[]'::jsonb)
    into v_subs
    from public.push_subscriptions s
    join public.users u on u.id = s.user_id and u.is_active
    join public.role_permissions rp on rp.role_id = u.role_id and rp.permission_key = 'report.view_sales'
   where s.restaurant_id = new.restaurant_id;
  if jsonb_array_length(v_subs) = 0 then return new; end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_secret';
  if v_url is null or v_secret is null then return new; end if;
  perform net.http_post(url := v_url,
    body := jsonb_build_object('subscriptions', v_subs, 'title', new.title, 'body', new.body, 'url', '/owner'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    timeout_milliseconds := 5000);
  return new;
exception when others then
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.qr_table(p_token text)
 RETURNS dining_tables
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.dining_tables%rowtype;
begin
  if coalesce(length(p_token), 0) < 16 or length(p_token) > 64 then raise exception 'This QR code is not valid.'; end if;
  select * into t from public.dining_tables where qr_token = p_token and is_active;
  if not found or not app.feature_on(t.restaurant_id, 'qr_ordering') then
    raise exception 'This QR code is not active. Please ask the staff.';
  end if;
  return t;
end $function$
;

CREATE OR REPLACE FUNCTION app.recalc_order(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  o public.orders%rowtype; p jsonb; r record; i int := 0; v_lines jsonb := '[]'::jsonb; v_map jsonb := '{}'::jsonb;
  v_c jsonb; l jsonb; t jsonb; v_id uuid; v_comps jsonb;
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Bill not found.'; end if;
  p := coalesce(o.calc_params, '{}'::jsonb);

  for r in select id, unit_price, quantity, is_price_inclusive, tax_comps
             from public.order_items where order_id = p_order and cancelled_at is null
            order by created_at, id loop
    i := i + 1;
    v_comps := coalesce(r.tax_comps,
      (select jsonb_agg(jsonb_build_object('name', component_name, 'rate', rate, 'compound', false) order by id)
         from public.order_item_taxes where order_item_id = r.id), '[]'::jsonb);
    v_lines := v_lines || jsonb_build_object('key', i, 'price', r.unit_price, 'qty', r.quantity,
                 'inclusive', coalesce(r.is_price_inclusive, false), 'comps', v_comps);
    v_map := v_map || jsonb_build_object(i::text, jsonb_build_object('id', r.id, 'comps', v_comps));
  end loop;
  if i = 0 then raise exception 'Bill % has no items left. Void it instead.', o.bill_number; end if;

  v_c := app.calc_bill(jsonb_build_object(
    'lines', v_lines, 'discount', coalesce((p->>'discount')::numeric, 0),
    'sc_percent', coalesce((p->>'sc_percent')::numeric, 0), 'sc_taxable', coalesce((p->>'sc_taxable')::boolean, false),
    'senior', case when p->'senior' is null or p->'senior' = 'null'::jsonb then null else p->'senior' end,
    'rounding', coalesce(p->>'rounding', 'none')));

  perform set_config('app.recalc', 'on', true);

  for l in select * from jsonb_array_elements(v_c->'lines') loop
    v_id := (v_map->(l->>'key')->>'id')::uuid;
    update public.order_items set
        line_subtotal = (l->>'subtotal')::numeric,
        line_discount = (l->>'discount')::numeric + (l->>'senior_discount')::numeric,
        line_tax = (l->>'tax')::numeric, line_total = (l->>'total')::numeric,
        net_amount = (l->>'net')::numeric, service_charge = (l->>'service_charge')::numeric,
        tax_included = (l->>'tax_included')::numeric, tax_comps = v_map->(l->>'key')->'comps'
     where id = v_id;
    delete from public.order_item_taxes where order_item_id = v_id;
    for t in select * from jsonb_array_elements(l->'taxes') loop
      insert into public.order_item_taxes (restaurant_id, order_id, order_item_id, component_name, rate, taxable_amount, tax_amount)
      values (o.restaurant_id, o.id, v_id, t->>'name', (t->>'rate')::numeric, (t->>'taxable')::numeric, (t->>'amount')::numeric);
    end loop;
  end loop;

  update public.order_items set line_subtotal = 0, line_discount = 0, line_tax = 0, line_total = 0,
         net_amount = 0, service_charge = 0, tax_included = 0
   where order_id = p_order and cancelled_at is not null and (line_total <> 0 or line_subtotal <> 0);
  delete from public.order_item_taxes
   where order_item_id in (select id from public.order_items where order_id = p_order and cancelled_at is not null);

  update public.order_discounts set amount = (v_c->>'discount')::numeric, value = (v_c->>'discount')::numeric
   where order_id = p_order and discount_type = 'fixed_amount';
  update public.order_discounts set amount = (v_c->>'senior_discount')::numeric
   where order_id = p_order and discount_type = 'senior_pwd';

  update public.orders set
      subtotal = (v_c->>'subtotal')::numeric,
      discount_total = (v_c->>'discount')::numeric + (v_c->>'senior_discount')::numeric,
      tax_total = (v_c->>'tax_total')::numeric,
      tax_included = (v_c->>'tax_included')::numeric,
      tax_exempt_amount = (v_c->>'tax_exempt_amount')::numeric,
      exempt_sales = (v_c->>'exempt_sales')::numeric,
      service_charge = (v_c->>'service_charge')::numeric,
      rounding_adjustment = (v_c->>'rounding')::numeric,
      grand_total = (v_c->>'grand_total')::numeric
   where id = p_order;

  perform set_config('app.recalc', 'off', true);
  return v_c;
end $function$
;

CREATE OR REPLACE FUNCTION app.report_branch()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case
    when app.device_id() is null
     and (select u.all_outlets from public.users u where u.id = app.current_user_id())
     and (app.is_owner() or not exists (select 1 from public.user_branches ub where ub.user_id = app.current_user_id()))
    then null
    else app.current_branch_id() end
$function$
;

CREATE OR REPLACE FUNCTION app.report_count(p_scope text, p_day date, p_sends integer, p_tests integer, p_emails integer)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  insert into public.report_send_days (scope, day, sends, tests, emails)
  values (p_scope, p_day, p_sends, p_tests, p_emails)
  on conflict (scope, day) do update
    set sends = public.report_send_days.sends + excluded.sends,
        tests = public.report_send_days.tests + excluded.tests,
        emails = public.report_send_days.emails + excluded.emails;
$function$
;

CREATE OR REPLACE FUNCTION app.report_day_back(p_branch uuid, p_time time without time zone)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case when mod(extract(epoch from p_time)::int
                       - extract(epoch from coalesce(bs.day_cutoff, '04:00'::time))::int + 86400, 86400) < 43200
              then 1 else 0 end
    from public.branches b
    left join public.branch_settings bs on bs.branch_id = b.id
   where b.id = p_branch;
$function$
;

CREATE OR REPLACE FUNCTION app.report_summary(p_branch uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  b public.branches%rowtype; r public.restaurants%rowtype; d public.business_days%rowtype;
  z jsonb := '{}'::jsonb; v_items jsonb; v_outlets int;
begin
  select * into b from public.branches where id = p_branch;
  if not found then return null; end if;
  select * into r from public.restaurants where id = b.restaurant_id;
  select count(*) into v_outlets from public.branches where restaurant_id = b.restaurant_id and deleted_at is null;

  select * into d from public.business_days where branch_id = p_branch and business_date = p_date;
  if found then
    -- A closed day keeps the report saved when it closed, exactly as the Day report screen shows it.
    z := case when d.status = 'closed' and d.z_report is not null then d.z_report else app.z_report(d.id) end;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('item', x.name, 'qty', x.q, 'amount', x.a) order by x.a desc, x.name), '[]'::jsonb)
    into v_items
    from (select oi.product_name as name, sum(oi.quantity) as q, sum(oi.line_subtotal) as a
            from public.order_items oi
            join public.orders o on o.id = oi.order_id
            left join public.products p on p.id = oi.product_id
           where o.branch_id = p_branch and o.business_date = p_date and o.status = 'completed'
             and o.merged_into is null and oi.cancelled_at is null and not coalesce(p.is_charge, false)
           group by oi.product_name
           order by 3 desc, 1
           limit 5) x;

  return jsonb_build_object(
    'restaurant', r.trading_name, 'outlet', b.name, 'several_outlets', v_outlets > 1,
    'currency', r.currency_code, 'business_date', p_date,
    'day_status', coalesce(d.status, 'none'),
    'bills', coalesce((z->>'bills')::int, 0),
    'total_billed', coalesce((z->>'total_billed')::numeric, 0),
    'discounts', coalesce((z->>'discounts')::numeric, 0),
    'complimentary_bills', coalesce((z->>'complimentary_bills')::int, 0),
    'complimentary_value', coalesce((z->>'complimentary_value')::numeric, 0),
    'staff_meal_bills', coalesce((z->>'staff_meal_bills')::int, 0),
    'staff_meal_value', coalesce((z->>'staff_meal_value')::numeric, 0),
    'tax', coalesce((z->>'tax')::numeric, 0),
    'service_charge', coalesce((z->>'service_charge')::numeric, 0),
    'voided_bills', coalesce((z->>'voided_bills')::int, 0),
    'voided_value', coalesce((z->>'voided_value')::numeric, 0),
    'unpaid_bills', coalesce((z->>'unpaid_bills')::int, 0),
    'unpaid_amount', coalesce((z->>'unpaid_amount')::numeric, 0),
    'refunds', coalesce((z->'credit_notes'->>'amount')::numeric, 0),
    'refund_count', coalesce((z->'credit_notes'->>'count')::int, 0),
    'payments', coalesce(z->'payments', '[]'::jsonb),
    'by_type', coalesce(z->'by_type', '[]'::jsonb),
    'top_items', v_items);
end $function$
;

CREATE OR REPLACE FUNCTION app.report_target(p_branch uuid, p_time time without time zone, p_due timestamp without time zone, OUT o_date date, OUT o_lagging boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_cut time; v_wanted date; d record;
begin
  select coalesce(bs.day_cutoff, '04:00'::time) into v_cut
    from public.branches b left join public.branch_settings bs on bs.branch_id = b.id where b.id = p_branch;
  v_wanted := (p_due - coalesce(v_cut, '04:00'::time)::interval)::date - app.report_day_back(p_branch, p_time);
  o_date := v_wanted; o_lagging := false;
  select business_date, status into d from public.business_days
   where branch_id = p_branch and business_date <= v_wanted
   order by business_date desc limit 1;
  if found and d.business_date < v_wanted and d.status <> 'closed' then
    o_date := d.business_date; o_lagging := true;
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION app.require_feature(p_key text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare m public.modules%rowtype;
begin
  if app.feature_on(app.current_restaurant_id(), p_key) then return; end if;
  select * into m from public.modules where key = p_key;
  if m.kind = 'professional' then
    raise exception '% needs the Professional edition. Ask for the upgrade in Settings → Plan and modules.', coalesce(m.name, p_key);
  end if;
  raise exception 'The % module is not switched on. Ask for it in Settings → Plan and modules.', coalesce(m.name, p_key);
end $function$
;

CREATE OR REPLACE FUNCTION app.require_permission(p_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if app.current_restaurant_id() is null then
    raise exception 'You are not signed in to a restaurant.';
  end if;
  if not app.allowed(p_key) then
    raise exception 'Your role does not allow this action (%).', p_key;
  end if;
  return app.current_user_id();
end $function$
;

CREATE OR REPLACE FUNCTION app.return_on_void()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare r record;
begin
  if new.status <> 'voided' or old.status = 'voided' then return new; end if;
  -- gift card money this bill used goes back to the same card
  for r in select l.gift_card_id, -sum(l.amount) as used
             from public.gift_card_ledger l
            where l.order_id = new.id and l.kind in ('redeem', 'void')
            group by l.gift_card_id having -sum(l.amount) > 0 loop
    insert into public.gift_card_ledger (restaurant_id, gift_card_id, order_id, amount, kind, created_by)
    values (new.restaurant_id, r.gift_card_id, new.id, r.used, 'void', new.voided_by);
  end loop;
  -- points: what the bill earned is taken back, what was spent on it is returned
  for r in select l.customer_id, sum(l.points) as net
             from public.loyalty_ledger l
            where l.order_id = new.id
            group by l.customer_id having sum(l.points) <> 0 loop
    insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note, created_by)
    values (new.restaurant_id, r.customer_id, new.id, -r.net, 'adjust', 'Bill ' || new.bill_number || ' voided', new.voided_by);
  end loop;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.round_cash(p_amount numeric, p_mode text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case coalesce(p_mode, 'none')
    when 'nearest_1'    then round(p_amount, 0)
    when 'nearest_0_05' then round(p_amount / 0.05) * 0.05
    when 'nearest_0_10' then round(p_amount / 0.10) * 0.10
    else round(p_amount, 2) end
$function$
;

CREATE OR REPLACE FUNCTION app.rule_price(p_restaurant uuid, p_branch uuid, p_product uuid, p_price numeric, p_at timestamp with time zone)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with p as (select pr.id, pr.parent_id, pr.category_id, pr.is_charge,
                    (select c.parent_id from public.categories c where c.id = pr.category_id) as main_category
               from public.products pr where pr.id = p_product),
       t as (select (p_at at time zone coalesce(nullif(b.timezone, ''), nullif(r.timezone, ''), 'Asia/Kolkata')) as lt
               from public.restaurants r left join public.branches b on b.id = p_branch where r.id = p_restaurant)
  select least(p_price, coalesce(min(case when x.kind = 'percent_off' then round(p_price * (100 - x.value) / 100, 2) else x.value end), p_price))
    from public.price_rules x, p, t
   where x.restaurant_id = p_restaurant and x.is_active and not p.is_charge
     and (x.branch_id is null or x.branch_id = p_branch)
     and (x.valid_from is null or t.lt::date >= x.valid_from)
     and (x.valid_to is null or t.lt::date <= x.valid_to)
     -- a rule that runs past midnight (10 p.m. to 1 a.m.) belongs to the day it started
     and extract(isodow from case when x.end_time < x.start_time and t.lt::time < x.end_time then t.lt - interval '1 day' else t.lt end)::smallint = any (x.days)
     and case when x.start_time < x.end_time then t.lt::time >= x.start_time and t.lt::time < x.end_time
              else t.lt::time >= x.start_time or t.lt::time < x.end_time end
     and ((cardinality(x.product_ids) = 0 and cardinality(x.category_ids) = 0)
          or p.id = any (x.product_ids) or p.parent_id = any (x.product_ids)
          or p.category_id = any (x.category_ids) or p.main_category = any (x.category_ids))
$function$
;

CREATE OR REPLACE FUNCTION app.run_report_schedules()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  s record; v_local timestamp; v_occ timestamp; v_day date; n int := 0;
begin
  for s in
    select rs.id, rs.branch_id, rs.send_time, rs.days, rs.last_run_on, coalesce(b.timezone, r.timezone, 'UTC') as tz
      from public.report_schedules rs
      join public.branches b on b.id = rs.branch_id
      join public.restaurants r on r.id = rs.restaurant_id
     where rs.is_active and b.deleted_at is null and b.is_active and r.deleted_at is null
       and r.subscription_status not in ('suspended', 'cancelled')
  loop
    v_day := null;
    begin
      v_local := now() at time zone s.tz;
      -- The most recent moment this schedule was due: today at its time, or yesterday's if today's is still to come.
      v_occ := v_local::date + s.send_time;
      if v_occ > v_local then v_occ := v_occ - interval '1 day'; end if;
      v_day := v_occ::date;
      continue when s.last_run_on is not null and s.last_run_on >= v_day;
      continue when not (extract(isodow from v_occ)::smallint = any (s.days));
      -- Claim it first, so two runs of the timer can never both send. The row stays locked until this run ends.
      update public.report_schedules set last_run_on = v_day
       where id = s.id and (last_run_on is null or last_run_on < v_day);
      continue when not found;
      if v_local - v_occ > interval '3 hours' then
        -- The system was not running at the time. A summary that arrives hours late is worse than none.
        update public.report_schedules
           set last_problem = 'Not sent: the system was not running at the set time.', last_problem_at = now() where id = s.id;
        continue;
      end if;
      -- An outlet has 5 schedules at most, each once a day. More than that in a day is not normal use.
      if coalesce((select sends from public.report_send_days where scope = 'b:' || s.branch_id and day = v_day), 0) >= 6 then
        update public.report_schedules
           set last_problem = 'Not sent: this outlet has already sent 6 scheduled summaries today, which is the most allowed.', last_problem_at = now()
         where id = s.id;
        continue;
      end if;
      perform app.send_report(s.id, false, v_occ);
      perform app.report_count('b:' || s.branch_id, v_day, 1, 0, 0);
      n := n + 1;
    exception when others then
      -- One bad schedule must not stop the others, and must not be tried again every 5 minutes:
      -- everything above was undone by the error, so mark the day as dealt with here.
      raise warning 'report schedule % could not be sent: %', s.id, sqlerrm;
      update public.report_schedules
         set last_problem = 'Not sent: something went wrong on our side. It will be tried again at the next set time.',
             last_problem_at = now(), last_run_on = coalesce(v_day, last_run_on)
       where id = s.id;
    end;
  end loop;
  -- The counts are only needed for the day they belong to.
  delete from public.report_send_days where day < current_date - 60;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION app.seed_sessions(p_rest uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_country text;
begin
  if exists (select 1 from public.meal_sessions where restaurant_id = p_rest) then return; end if;
  select country_code into v_country from public.restaurants where id = p_rest;
  if v_country = 'IN' then
    insert into public.meal_sessions (restaurant_id, name, start_time, end_time, display_order) values
      (p_rest, 'Breakfast', '06:00', '11:00', 1), (p_rest, 'Lunch', '11:00', '15:00', 2), (p_rest, 'Hi-Tea', '15:00', '17:00', 3),
      (p_rest, 'Evening snacks', '17:00', '19:00', 4), (p_rest, 'Dinner', '19:00', '04:00', 5);
  else
    insert into public.meal_sessions (restaurant_id, name, start_time, end_time, display_order) values
      (p_rest, 'Breakfast', '06:00', '11:00', 1), (p_rest, 'Lunch', '11:00', '15:00', 2), (p_rest, 'Afternoon', '15:00', '18:00', 3),
      (p_rest, 'Dinner', '18:00', '04:00', 4);
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION app.seed_sessions_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin perform app.seed_sessions(new.id); return new; end $function$
;

CREATE OR REPLACE FUNCTION app.send_report(p_schedule uuid, p_test boolean, p_due timestamp without time zone)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  s public.report_schedules%rowtype;
  v_date date; v_lag boolean; v_sum jsonb; v_url text; v_secret text; v_mail_url text;
  v_parts text[] := '{}'; v_text text; v_cur text; v_n int; v_utc date := (now() at time zone 'utc')::date;
begin
  select * into s from public.report_schedules where id = p_schedule;
  if not found then return null; end if;
  select o_date, o_lagging into v_date, v_lag from app.report_target(s.branch_id, s.send_time, p_due);
  v_sum := app.report_summary(s.branch_id, v_date);
  if v_sum is null then return null; end if;
  -- lagging: an older day that is still open and so holds every bill made since.
  -- ended: the day's own end time has passed, so nothing more is expected on it.
  v_sum := v_sum || jsonb_build_object('lagging', coalesce(v_lag, false), 'ended', v_date < app.business_today(s.branch_id));
  v_cur := v_sum->>'currency';

  if s.phone_alert and app.feature_on(s.restaurant_id, 'owner_app') then
    -- An owner alert: it shows in the owner app and goes to the phones that turned alerts on.
    insert into public.owner_alerts (restaurant_id, branch_id, kind, title, body)
    values (s.restaurant_id, s.branch_id, 'report.daily',
            case when p_test then 'Daily summary (test)' else 'Daily summary' end,
            left(concat(to_char(v_date, 'FMDD Mon'), ': ', v_sum->>'bills', ' bills, ', v_cur, ' ', v_sum->>'total_billed', ' billed',
                        case when (v_sum->>'unpaid_amount')::numeric > 0
                             then concat(', ', v_cur, ' ', v_sum->>'unpaid_amount', ' not yet paid') else '' end,
                        case when (v_sum->>'several_outlets')::boolean then concat(' · ', v_sum->>'outlet') else '' end), 300));
    v_parts := v_parts || 'phone alert sent'::text;
  end if;

  v_n := cardinality(s.emails);
  if v_n > 0 then
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_url';
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_secret';
    -- The app's address is stored once, for phone alerts; the email sender lives beside it.
    v_mail_url := regexp_replace(coalesce(v_url, ''), '/api/push/?$', '/api/report-email');
    if v_url is null or v_secret is null or v_mail_url = coalesce(v_url, '') then
      v_parts := v_parts || 'email could not be sent: sending is not set up yet'::text;
    elsif coalesce((select emails from public.report_send_days where scope = 'all' and day = v_utc), 0) + v_n > 500 then
      -- A ceiling for the whole system, so a fault or misuse cannot send without end.
      v_parts := v_parts || 'email could not be sent: the system has reached its limit for today'::text;
    else
      perform net.http_post(url := v_mail_url,
        body := jsonb_build_object('schedule_id', s.id, 'test', coalesce(p_test, false), 'to', to_jsonb(s.emails), 'summary', v_sum),
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
        timeout_milliseconds := 20000);
      perform app.report_count('all', v_utc, 0, 0, v_n);
      v_parts := v_parts || concat('email on its way to ', v_n, case when v_n = 1 then ' address' else ' addresses' end);
    end if;
  end if;

  if cardinality(v_parts) = 0 then v_parts := v_parts || 'nothing was sent: the phone alert needs the Owner mobile app module'::text; end if;
  v_text := array_to_string(v_parts, '; ');
  v_text := upper(left(v_text, 1)) || substr(v_text, 2) || '.';
  update public.report_schedules
     set last_sent_at = now(), last_for_date = v_date, last_result = left(v_text, 200), last_email_result = null,
         last_problem = null, last_problem_at = null
   where id = s.id;
  return v_text;
end $function$
;

CREATE OR REPLACE FUNCTION app.session_at(p_branch uuid, p_at timestamp with time zone)
 RETURNS meal_sessions
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_local timestamp; t time; wd int; s public.meal_sessions; v_rest uuid; v_own boolean;
begin
  select b.restaurant_id, p_at at time zone coalesce(b.timezone, r.timezone, 'UTC') into v_rest, v_local
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = p_branch;
  t := v_local::time; wd := extract(isodow from v_local)::int;
  v_own := exists (select 1 from public.meal_sessions where branch_id = p_branch);
  select * into s from public.meal_sessions m
   where m.restaurant_id = v_rest and (case when v_own then m.branch_id = p_branch else m.branch_id is null end)
     and ((m.start_time < m.end_time and t >= m.start_time and t < m.end_time and wd = any(m.days))
       or (m.start_time > m.end_time and t >= m.start_time and wd = any(m.days))
       or (m.start_time > m.end_time and t < m.end_time and ((wd + 5) % 7 + 1) = any(m.days)))
   order by m.display_order limit 1;
  return s;
end $function$
;

CREATE OR REPLACE FUNCTION app.set_business_type(p_restaurant uuid, p_type text, p_apply boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d jsonb := app.business_type_defaults(p_type);
begin
  if d is null then raise exception 'Unknown business type.'; end if;
  update public.restaurants set business_type = p_type where id = p_restaurant;
  if not found then raise exception 'Restaurant not found.'; end if;
  if p_apply then
    update public.branch_settings
       set order_types = array(select jsonb_array_elements_text(d->'order_types')),
           default_order_type = d->>'default_order_type',
           token_numbers = d->>'token_numbers'
     where restaurant_id = p_restaurant;
  end if;
  return jsonb_build_object('business_type', p_type, 'applied', p_apply, 'defaults', d);
end $function$
;

CREATE OR REPLACE FUNCTION app.set_order_business_date()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  new.business_date := (app.open_business_day(new.branch_id)).business_date;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.set_order_session()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s public.meal_sessions;
begin
  if new.session_name is null then
    s := app.session_at(new.branch_id, coalesce(new.client_created_at, now()));
    new.session_id := s.id; new.session_name := s.name;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.set_payment_shift()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.shift_id is null then
    select s.id into new.shift_id from public.shifts s join public.orders o on o.branch_id = s.branch_id
     where o.id = new.order_id and s.status = 'open' order by s.opened_at desc limit 1;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.shift_figures(p_shift uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  s public.shifts%rowtype;
  v_cash_sales numeric(14,2); v_cash_refunds numeric(14,2);
  v_in numeric(14,2); v_out numeric(14,2);
  v_bills int; v_sales numeric(14,2); v_voided int; v_unpaid int; v_methods jsonb;
  v_due numeric(14,2); v_late int; v_late_value numeric(14,2);
  v_frozen jsonb; v_open_ids uuid[]; v_moved int; v_moved_value numeric(14,2);
begin
  select * into s from public.shifts where id = p_shift;
  if not found then return null; end if;

  -- A closed shift's report is the one taken when it closed. Bills voided
  -- afterwards are listed beside it instead of silently changing it.
  if s.status = 'closed' then
    select c.figures, c.unpaid_orders into v_frozen, v_open_ids from public.shift_closings c where c.shift_id = s.id;
    if v_frozen is not null then
      select count(*), coalesce(sum(grand_total), 0) into v_late, v_late_value
        from public.orders
       where shift_id = s.id and status = 'voided' and merged_into is null and voided_at >= s.closed_at;
      -- A bill that was unpaid when this shift closed and was settled in a later
      -- shift is counted as that later shift's sale. Say so here, so the two
      -- shift reports are not read as two sales.
      select count(*), coalesce(sum(grand_total), 0) into v_moved, v_moved_value
        from public.orders
       where id = any(v_open_ids) and shift_id <> s.id and status <> 'voided' and merged_into is null;
      return v_frozen || jsonb_build_object('voided_after_close', v_late, 'voided_after_close_value', v_late_value,
                                            'paid_later', v_moved, 'paid_later_value', v_moved_value);
    end if;
  end if;

  select coalesce(sum(p.amount),0) into v_cash_sales
    from public.payments p
    join public.orders o on o.id = p.order_id
    join public.payment_methods pm on pm.id = p.payment_method_id
   where coalesce(p.shift_id, o.shift_id) = s.id and o.status <> 'voided'
     and pm.affects_cash_drawer and p.status = 'captured';

  select coalesce(sum(r.amount),0) into v_cash_refunds
    from public.refunds r
    left join public.payments p on p.id = r.payment_id
    join public.payment_methods pm on pm.id = coalesce(r.payment_method_id, p.payment_method_id)
   where pm.affects_cash_drawer
     and (r.shift_id = s.id
          or (r.shift_id is null and r.restaurant_id = s.restaurant_id
              and exists (select 1 from public.orders o2 where o2.id = r.order_id and o2.branch_id = s.branch_id)
              and r.created_at >= s.opened_at and (s.closed_at is null or r.created_at <= s.closed_at)));

  select coalesce(sum(amount) filter (where direction='in'),0),
         coalesce(sum(amount) filter (where direction='out'),0)
    into v_in, v_out from public.cash_movements where shift_id = s.id;

  select count(*) filter (where status <> 'voided'),
         coalesce(sum(grand_total) filter (where status <> 'voided'),0),
         count(*) filter (where status = 'voided'),
         count(*) filter (where status <> 'voided' and payment_status in ('unpaid', 'partial'))
    into v_bills, v_sales, v_voided, v_unpaid
    from public.orders where shift_id = s.id and merged_into is null;

  select coalesce(sum(o.grand_total - app.order_covered(o.id)), 0) into v_due
    from public.orders o
   where o.shift_id = s.id and o.merged_into is null and o.status <> 'voided'
     and o.payment_status in ('unpaid', 'partial');

  select coalesce(jsonb_agg(jsonb_build_object('method', m.name, 'bills', m.n, 'amount', m.amt)
                            order by m.amt desc), '[]'::jsonb)
    into v_methods
    from (select pm.name, count(*) n, sum(p.amount) amt
            from public.payments p
            join public.orders o on o.id = p.order_id
            join public.payment_methods pm on pm.id = p.payment_method_id
           where coalesce(p.shift_id, o.shift_id) = s.id and o.status <> 'voided' and p.status = 'captured'
           group by pm.name) m;

  return jsonb_build_object(
    'shift_id', s.id, 'status', s.status, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
    'opened_by', (select full_name from public.users where id = s.opened_by),
    'closed_by', (select full_name from public.users where id = s.closed_by),
    'opening_float', s.opening_float,
    'bills', v_bills, 'sales', v_sales, 'voided', v_voided, 'unpaid', v_unpaid, 'unpaid_amount', v_due,
    'cash_sales', v_cash_sales, 'cash_refunds', v_cash_refunds,
    'cash_in', v_in, 'cash_out', v_out,
    'expected_cash', case when s.status = 'closed' and s.expected_cash is not null
                          then s.expected_cash
                          else s.opening_float + v_cash_sales - v_cash_refunds + v_in - v_out end,
    'counted_cash', s.counted_cash, 'variance', s.cash_variance, 'notes', s.notes,
    'by_method', v_methods);
end $function$
;

CREATE OR REPLACE FUNCTION app.sna_account_row(p_restaurant uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not exists (select 1 from public.restaurants where id = p_restaurant and deleted_at is null) then
    raise exception 'Restaurant not found.';
  end if;
  insert into public.sna_accounts (restaurant_id) values (p_restaurant) on conflict (restaurant_id) do nothing;
end $function$
;

CREATE OR REPLACE FUNCTION app.sna_require(p_roles text[])
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s public.sna_staff%rowtype;
begin
  select * into s from public.sna_staff where auth_user_id = auth.uid() and is_active;
  if not found then raise exception 'Only SNA staff can do this.'; end if;
  if s.role <> 'admin' and not (s.role = any(p_roles)) then
    raise exception 'Your SNA role (%) cannot do this.', s.role;
  end if;
  return s.id;
end $function$
;

CREATE OR REPLACE FUNCTION app.sna_staff_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select s.id from public.sna_staff s where s.auth_user_id = auth.uid() and s.is_active
$function$
;

CREATE OR REPLACE FUNCTION app.sna_today()
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select (now() at time zone 'Asia/Kolkata')::date $function$
;

CREATE OR REPLACE FUNCTION app.stock_on_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_branch uuid; v_qty numeric;
begin
  -- Recipe of the dish and of any dishes chosen in it (combos). When a line is first saved its choices are not
  -- saved yet; trg_stock_on_item_option takes those out as each choice is saved.
  if not exists (select 1 from app.item_recipe(new.id, new.product_id)) then return new; end if;
  select branch_id into v_branch from public.orders where id = new.order_id;
  if tg_op = 'INSERT' then
    v_qty := new.quantity;
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id)
    select new.restaurant_id, v_branch, r.ingredient_id, 'sale', -(r.qty * v_qty), new.order_id, new.id
      from app.item_recipe(new.id, new.product_id) r;
  elsif tg_op = 'UPDATE' then
    -- Item cancelled (fully or partly): return what was cancelled this time.
    v_qty := coalesce(new.cancelled_qty, 0) - coalesce(old.cancelled_qty, 0);
    if v_qty = 0 and new.cancelled_at is not null and old.cancelled_at is null then v_qty := old.quantity; end if;
    if new.quantity < old.quantity and new.cancelled_at is null then v_qty := old.quantity - new.quantity; end if;
    if v_qty > 0 then
      insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id, note)
      select new.restaurant_id, v_branch, r.ingredient_id, 'returned', r.qty * v_qty, new.order_id, new.id, 'Item cancelled'
        from app.item_recipe(new.id, new.product_id) r;
    end if;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.stock_on_item_option()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare it public.order_items; v_pid uuid; v_branch uuid; v_qty numeric;
begin
  if new.modifier_item_id is null then return new; end if;
  select product_id into v_pid from public.modifier_items where id = new.modifier_item_id;
  if v_pid is null or not exists (select 1 from public.recipe_lines where product_id = v_pid) then return new; end if;
  select * into it from public.order_items where id = new.order_item_id;
  if it.cancelled_at is not null then return new; end if;
  v_qty := it.quantity - coalesce(it.cancelled_qty, 0);
  if v_qty <= 0 then return new; end if;
  select branch_id into v_branch from public.orders where id = it.order_id;
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id)
  select it.restaurant_id, v_branch, rl.ingredient_id, 'sale', -(rl.qty * v_qty), it.order_id, it.id
    from public.recipe_lines rl where rl.product_id = v_pid;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.stock_on_void()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.status = 'voided' and old.status <> 'voided' then
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, note)
    select new.restaurant_id, new.branch_id, sm.ingredient_id, 'returned', -sum(sm.qty), new.id, 'Bill voided'
      from public.stock_movements sm where sm.order_id = new.id and sm.kind in ('sale', 'returned')
     group by sm.ingredient_id having sum(sm.qty) < 0;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.system_method(p_restaurant uuid, p_kind text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v uuid;
begin
  select id into v from public.payment_methods where restaurant_id = p_restaurant and kind = p_kind limit 1;
  if v is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order)
    values (p_restaurant, case p_kind when 'gift_card' then 'Gift card' else 'Loyalty points' end, p_kind, false, true, 90)
    returning id into v;
  end if;
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION app.test_money()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  r jsonb; fails text := ''; n int := 0;
  gst5  jsonb := '[{"name":"CGST","rate":2.5},{"name":"SGST","rate":2.5}]';
  gst12 jsonb := '[{"name":"CGST","rate":6},{"name":"SGST","rate":6}]';
  procedure_dummy int;
begin
  -- helper via inline checks
  -- T1 India: 2x40 @5% + 1x20 @12%, round to rupee -> 106
  r := app.calc_bill(jsonb_build_object('rounding','nearest_1','lines', jsonb_build_array(
        jsonb_build_object('key',1,'price',40,'qty',2,'comps',gst5),
        jsonb_build_object('key',2,'price',20,'qty',1,'comps',gst12))));
  n := n + 1; if (r->>'tax_total')::numeric <> 6.40 or (r->>'grand_total')::numeric <> 106 or (r->>'rounding')::numeric <> -0.40 then fails := fails || 'T1 India ' || r::text || E'\n'; end if;

  -- T2 Singapore "++": 100 + 10% service = 110, 9% GST on 110 = 9.90 -> 119.90
  r := app.calc_bill('{"sc_percent":10,"sc_taxable":true,"lines":[{"key":1,"price":100,"qty":1,"comps":[{"name":"GST","rate":9}]}]}');
  n := n + 1; if (r->>'service_charge')::numeric <> 10 or (r->>'tax_total')::numeric <> 9.90 or (r->>'grand_total')::numeric <> 119.90 then fails := fails || 'T2 Singapore ' || r::text || E'\n'; end if;

  -- T3 UAE tax-inclusive: 105 incl 5% VAT -> net 100, VAT 5 included, total 105
  r := app.calc_bill('{"lines":[{"key":1,"price":105,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":5}]}]}');
  n := n + 1; if (r->>'net_sales')::numeric <> 100 or (r->>'tax_included')::numeric <> 5 or (r->>'grand_total')::numeric <> 105 then fails := fails || 'T3 UAE inclusive ' || r::text || E'\n'; end if;

  -- T4 Dubai tax on tax: 112.35 incl; 7% municipality fee, then 5% VAT on (net + fee)
  r := app.calc_bill('{"lines":[{"key":1,"price":112.35,"qty":1,"inclusive":true,"comps":[{"name":"Municipality fee","rate":7},{"name":"VAT","rate":5,"compound":true}]}]}');
  n := n + 1; if (r->>'net_sales')::numeric <> 100 or (r->>'tax_total')::numeric <> 12.35 or (r->>'grand_total')::numeric <> 112.35
     or (r->'lines'->0->'taxes'->1->>'amount')::numeric <> 5.35 then fails := fails || 'T4 Dubai compound ' || r::text || E'\n'; end if;

  -- T5 Philippines senior, whole bill: 500 incl 12% -> exempt 446.43, 20% = 89.29, pays 357.14
  r := app.calc_bill('{"senior":{"share":1},"lines":[{"key":1,"price":500,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":12}]}]}');
  n := n + 1; if (r->>'exempt_sales')::numeric <> 446.43 or (r->>'senior_discount')::numeric <> 89.29
     or (r->>'tax_exempt_amount')::numeric <> 53.57 or (r->>'tax_total')::numeric <> 0 or (r->>'grand_total')::numeric <> 357.14
     then fails := fails || 'T5 PH senior ' || r::text || E'\n'; end if;

  -- T6 Philippines shared platter: 1000 incl, 1 senior of 4 -> 928.57
  r := app.calc_bill('{"senior":{"share":0.25},"lines":[{"key":1,"price":1000,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":12}]}]}');
  n := n + 1; if (r->>'exempt_sales')::numeric <> 223.21 or (r->>'senior_discount')::numeric <> 44.64
     or (r->>'tax_total')::numeric <> 80.36 or (r->>'grand_total')::numeric <> 928.57
     then fails := fails || 'T6 PH shared ' || r::text || E'\n'; end if;

  -- T7 Malaysia: 100 + 10% service; 6% service tax on 110 -> 116.60
  r := app.calc_bill('{"sc_percent":10,"sc_taxable":true,"lines":[{"key":1,"price":100,"qty":1,"comps":[{"name":"SST","rate":6}]}]}');
  n := n + 1; if (r->>'tax_total')::numeric <> 6.60 or (r->>'grand_total')::numeric <> 116.60 then fails := fails || 'T7 Malaysia ' || r::text || E'\n'; end if;
  -- T7b Malaysia 5-sen cash rounding (Bank Negara rule)
  n := n + 1; if app.round_cash(116.62,'nearest_0_05') <> 116.60 or app.round_cash(116.63,'nearest_0_05') <> 116.65
     or app.round_cash(116.67,'nearest_0_05') <> 116.65 or app.round_cash(116.68,'nearest_0_05') <> 116.70
     then fails := fails || 'T7b 5-sen rounding' || E'\n'; end if;

  -- T8 Thailand net pricing: 107 incl 7% VAT + 10% service; VAT also on service -> 117.70
  r := app.calc_bill('{"sc_percent":10,"sc_taxable":true,"lines":[{"key":1,"price":107,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":7}]}]}');
  n := n + 1; if (r->>'service_charge')::numeric <> 10 or (r->>'tax_total')::numeric <> 7.70 or (r->>'tax_included')::numeric <> 7
     or (r->>'grand_total')::numeric <> 117.70 then fails := fails || 'T8 Thailand ' || r::text || E'\n'; end if;

  -- T9 Indonesia (Jakarta rule): PBJT 10% on (100 - 10 discount + 5% service) -> 103.95
  r := app.calc_bill('{"discount":10,"sc_percent":5,"sc_taxable":true,"lines":[{"key":1,"price":100,"qty":1,"comps":[{"name":"PBJT","rate":10}]}]}');
  n := n + 1; if (r->>'service_charge')::numeric <> 4.50 or (r->>'tax_total')::numeric <> 9.45 or (r->>'grand_total')::numeric <> 103.95
     then fails := fails || 'T9 Indonesia ' || r::text || E'\n'; end if;

  -- T10 discount split is exact: 10 off 20+40+40
  r := app.calc_bill('{"discount":10,"lines":[{"key":1,"price":20,"qty":1},{"key":2,"price":40,"qty":1},{"key":3,"price":40,"qty":1}]}');
  n := n + 1; if (select sum((l->>'discount')::numeric) from jsonb_array_elements(r->'lines') l) <> 10
     or (r->>'grand_total')::numeric <> 90 then fails := fails || 'T10 discount split ' || r::text || E'\n'; end if;

  -- T10b awkward split: 10 off three equal lines of 33.33
  r := app.calc_bill('{"discount":10,"lines":[{"key":1,"price":33.33,"qty":1},{"key":2,"price":33.33,"qty":1},{"key":3,"price":33.33,"qty":1}]}');
  n := n + 1; if (select sum((l->>'discount')::numeric) from jsonb_array_elements(r->'lines') l) <> 10
     or (r->>'grand_total')::numeric <> 89.99 then fails := fails || 'T10b awkward split ' || r::text || E'\n'; end if;

  -- T11 India with a voluntary service charge that is NOT taxed: 100 + 10 + 5 = 115
  r := app.calc_bill(jsonb_build_object('sc_percent',10,'sc_taxable',false,'lines',jsonb_build_array(
        jsonb_build_object('key',1,'price',100,'qty',1,'comps',gst5))));
  n := n + 1; if (r->>'service_charge')::numeric <> 10 or (r->>'tax_total')::numeric <> 5 or (r->>'grand_total')::numeric <> 115
     then fails := fails || 'T11 India service charge ' || r::text || E'\n'; end if;

  -- T12 inclusive with awkward cents: 3 x 99.99 incl 9% -> tax 24.77, total unchanged
  r := app.calc_bill('{"lines":[{"key":1,"price":99.99,"qty":3,"inclusive":true,"comps":[{"name":"GST","rate":9}]}]}');
  n := n + 1; if (r->>'tax_included')::numeric <> 24.77 or (r->>'net_sales')::numeric <> 275.20 or (r->>'grand_total')::numeric <> 299.97
     then fails := fails || 'T12 inclusive cents ' || r::text || E'\n'; end if;

  -- T13 discount larger than the bill is capped at the bill
  r := app.calc_bill('{"discount":500,"lines":[{"key":1,"price":100,"qty":1,"comps":[{"name":"VAT","rate":5}]}]}');
  n := n + 1; if (r->>'discount')::numeric <> 100 or (r->>'grand_total')::numeric <> 0 then fails := fails || 'T13 discount cap ' || r::text || E'\n'; end if;

  -- T14 guards: senior + discount together is refused
  n := n + 1;
  begin
    perform app.calc_bill('{"discount":5,"senior":{"share":1},"lines":[{"key":1,"price":100,"qty":1}]}');
    fails := fails || 'T14 senior+discount was allowed' || E'\n';
  exception when others then null; end;

  -- T15 mixed inclusive + exclusive lines on one bill
  r := app.calc_bill('{"lines":[{"key":1,"price":105,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":5}]},{"key":2,"price":100,"qty":1,"comps":[{"name":"VAT","rate":5}]}]}');
  n := n + 1; if (r->>'tax_total')::numeric <> 10 or (r->>'tax_included')::numeric <> 5 or (r->>'grand_total')::numeric <> 210
     then fails := fails || 'T15 mixed ' || r::text || E'\n'; end if;

  -- T16 a small discount over many lines: no line goes below zero, the parts add up
  r := app.calc_bill(jsonb_build_object('discount', 0.20, 'lines',
        (select jsonb_agg(jsonb_build_object('key', g, 'price', 10, 'qty', 1)) from generate_series(1, 30) g)));
  n := n + 1; if (select min((l->>'discount')::numeric) from jsonb_array_elements(r->'lines') l) < 0
     or (select sum((l->>'discount')::numeric) from jsonb_array_elements(r->'lines') l) <> 0.20
     or (r->>'grand_total')::numeric <> 299.80 then fails := fails || 'T16 small discount, many lines ' || r::text || E'\n'; end if;
  if fails <> '' then
    raise exception 'MONEY TESTS FAILED:%', E'\n' || fails;
  end if;
  return 'All ' || n || ' money tests passed';
end $function$
;

CREATE OR REPLACE FUNCTION app.touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
    new.updated_at := now();
    return new;
end
$function$
;

CREATE OR REPLACE FUNCTION app.track_price()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if tg_op = 'INSERT' or new.price is distinct from old.price then
    update public.product_price_history set valid_to = now() where product_id = new.id and valid_to is null;
    insert into public.product_price_history (restaurant_id, product_id, price) values (new.restaurant_id, new.id, new.price);
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_category_brand()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.parent_id is not null then
    select brand_id into new.brand_id from public.categories where id = new.parent_id;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_category_brand_follow()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.brand_id is distinct from old.brand_id then
    update public.categories set brand_id = new.brand_id where parent_id = new.id and brand_id is distinct from new.brand_id;
  end if;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_category_parent()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.parent_id is not null and new.deleted_at is null then
    if exists (select 1 from public.categories where id = new.parent_id and parent_id is not null) then
      raise exception 'A sub-category cannot have sub-categories of its own. Choose a main category.';
    end if;
    if exists (select 1 from public.categories where id = new.parent_id and deleted_at is not null) then
      raise exception 'That main category has been removed.';
    end if;
    if exists (select 1 from public.categories where parent_id = new.id and deleted_at is null) then
      raise exception 'This category has sub-categories, so it cannot go inside another category.';
    end if;
  end if;
  if tg_op = 'UPDATE' and new.deleted_at is not null and old.deleted_at is null
     and exists (select 1 from public.categories where parent_id = new.id and deleted_at is null) then
    raise exception 'This category still has sub-categories. Remove or move them first.';
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_delivery_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.order_type = 'delivery' and new.delivery_status is null then new.delivery_status := 'waiting'; end if;
  if new.order_type <> 'delivery' then new.delivery_status := null; new.rider_id := null; end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_item_liquor()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o record; v_liq boolean; v_name text;
begin
  select is_liquor, bill_number into o from public.orders where id = new.order_id;
  if o.bill_number ~ '-X[0-9]+-' then return new; end if;
  select tg.separate_bill and not p.is_charge, p.name into v_liq, v_name
    from public.products p join public.tax_groups tg on tg.id = p.tax_group_id where p.id = new.product_id;
  if coalesce(v_liq, false) and not o.is_liquor then
    raise exception '% is liquor and goes on a separate liquor bill, not on bill %.', v_name, o.bill_number;
  elsif not coalesce(v_liq, false) and o.is_liquor and not exists (select 1 from public.products where id = new.product_id and is_charge) then
    raise exception '% is not liquor, so it cannot go on liquor bill %.', v_name, o.bill_number;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_licence_order_items()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.order_id::text = current_setting('app.licence_ok_order', true) then return new; end if;
  if app.licence_locked(new.restaurant_id, now()) then
    raise exception 'The SNA POS licence for this restaurant has ended, so items cannot be added. Bills that are already open can still be paid. Please contact SNA to renew.';
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_licence_orders()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if app.licence_locked(new.restaurant_id, least(coalesce(new.created_at, now()), now())) then
    raise exception 'The SNA POS licence for this restaurant has ended, so new bills cannot be made. Bills that are already open can still be paid. Please contact SNA to renew.';
  end if;
  -- The lines of this same bill follow in this transaction; they need no second check.
  perform set_config('app.licence_ok_order', new.id::text, true);
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_licence_qr_orders()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if app.licence_locked(new.restaurant_id, now()) then
    raise exception 'Ordering from the table is not available right now. Please ask the staff.';
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_modifier_item_dish()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare p public.products;
begin
  if new.product_id is null then return new; end if;
  select * into p from public.products where id = new.product_id;
  if p.is_combo then raise exception 'A combo cannot be a choice inside another combo.'; end if;
  if p.is_charge then raise exception 'The packing charge cannot be a choice.'; end if;
  if exists (select 1 from public.products s where s.parent_id = p.id and s.deleted_at is null) then
    raise exception '% is sold in sizes. Choose one of its sizes instead.', p.name;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_order_item_brand()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.brand_id is null then
    select c.brand_id into new.brand_id from public.products p join public.categories c on c.id = p.category_id where p.id = new.product_id;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_order_item_needs_size()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_name text;
begin
  if exists (select 1 from public.products c where c.parent_id = new.product_id and c.deleted_at is null) then
    select name into v_name from public.products where id = new.product_id;
    raise exception 'Choose a size for %.', v_name;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_order_item_unit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_by text;
begin
  select sold_by into v_by from public.products where id = new.product_id;
  if v_by = 'weight' then
    new.unit := 'kg';
    if new.quantity < 0.005 then raise exception 'Weigh % again: the weight is too small.', new.product_name; end if;
  else
    new.unit := null;
    if new.quantity <> trunc(new.quantity) then
      raise exception '% is sold by the piece: enter a whole number.', new.product_name;
    end if;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_order_liquor()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  new.is_liquor := coalesce(current_setting('app.liquor_bill', true), '') = 'on';
  perform set_config('app.liquor_bill', '', true);
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_prefix_clash()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if tg_table_name = 'bill_series' then
    if exists (select 1 from public.liquor_series where restaurant_id = new.restaurant_id and upper(prefix) = upper(new.prefix)) then
      raise exception 'The prefix % is used for liquor bills. Choose another.', new.prefix;
    end if;
  else
    if exists (select 1 from public.bill_series where restaurant_id = new.restaurant_id and upper(prefix) = upper(new.prefix)) then
      raise exception 'The prefix % is used for ordinary bills. Choose another.', new.prefix;
    end if;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_product_combo_flag()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.is_combo and not coalesce(old.is_combo, false)
     and exists (select 1 from public.modifier_items mi where mi.product_id = new.id and mi.is_active) then
    raise exception '% is a choice inside a combo, so it cannot be a combo itself.', new.name;
  end if;
  if new.is_combo and new.parent_id is not null then
    raise exception 'A size cannot be a combo. Make the combo a dish of its own.';
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_product_variant()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare par public.products;
begin
  if new.parent_id is not null then
    new.variant_name := btrim(new.variant_name);
    select * into par from public.products where id = new.parent_id;
    if not found or par.restaurant_id <> new.restaurant_id then raise exception 'That dish was not found.'; end if;
    if par.parent_id is not null then raise exception 'A size cannot have sizes of its own.'; end if;
    if par.deleted_at is not null and new.deleted_at is null then raise exception 'The dish % has been removed.', par.name; end if;
    if tg_op = 'UPDATE' and old.parent_id is null and exists (select 1 from public.products c where c.parent_id = new.id and c.deleted_at is null) then
      raise exception '% has sizes, so it cannot become a size itself.', new.name;
    end if;
    new.category_id := par.category_id;
    new.name := left(par.name || ' (' || new.variant_name || ')', 200);
  elsif tg_op = 'UPDATE' and old.parent_id is not null then
    raise exception 'A size cannot be turned back into a separate dish. Remove it and add the dish again.';
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_product_variant_follow()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.parent_id is not null then return null; end if;
  if new.name is distinct from old.name or new.category_id is distinct from old.category_id then
    update public.products c set name = left(new.name || ' (' || c.variant_name || ')', 200), category_id = new.category_id
     where c.parent_id = new.id;
  end if;
  if new.deleted_at is not null and old.deleted_at is null then
    update public.products c set deleted_at = new.deleted_at where c.parent_id = new.id and c.deleted_at is null;
  end if;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION app.trg_variant_options()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if tg_table_name = 'products' then
    if new.parent_id is not null then
      insert into public.product_modifier_groups (product_id, modifier_group_id, restaurant_id)
      select new.id, l.modifier_group_id, l.restaurant_id from public.product_modifier_groups l where l.product_id = new.parent_id
      on conflict do nothing;
    end if;
    return null;
  end if;
  if tg_op = 'INSERT' then
    insert into public.product_modifier_groups (product_id, modifier_group_id, restaurant_id)
    select c.id, new.modifier_group_id, new.restaurant_id from public.products c where c.parent_id = new.product_id
    on conflict do nothing;
  else
    delete from public.product_modifier_groups l
     using public.products c where c.parent_id = old.product_id and l.product_id = c.id and l.modifier_group_id = old.modifier_group_id;
  end if;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION app.try_auto_close_day(p_day uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.business_days; v_z jsonb;
begin
  select * into d from public.business_days where id = p_day and status = 'open' for update;
  if not found then return false; end if;
  if exists (select 1 from public.business_days where branch_id = d.branch_id and status = 'parked') then return false; end if;
  if exists (select 1 from public.orders where branch_id = d.branch_id and business_date = d.business_date and status = 'completed'
               and payment_status in ('unpaid', 'partial') and merged_into is null) then return false; end if;
  if coalesce((select shifts_enabled from public.branch_settings where branch_id = d.branch_id), false)
     and exists (select 1 from public.shifts where branch_id = d.branch_id and status = 'open') then return false; end if;
  update public.business_days set status = 'closed', closed_at = now(), closed_by = null,
         close_notes = 'Closed automatically at the day cutoff' where id = d.id;
  v_z := app.z_report(d.id);
  update public.business_days set z_report = v_z where id = d.id;
  insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, actor_type, new_value)
  values (d.restaurant_id, d.branch_id, null, 'day.close', 'business_days', d.id, 'system',
          jsonb_build_object('business_date', d.business_date, 'total_billed', v_z->'total_billed', 'bills', v_z->'bills', 'automatic', true));
  return true;
end $function$
;

CREATE OR REPLACE FUNCTION app.write_tax_components(p_restaurant uuid, p_rate_id uuid, p_total numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_country char(2); v_sys text;
begin
  select r.country_code, c.tax_system_name into v_country, v_sys
    from public.restaurants r join public.countries c on c.code = r.country_code
   where r.id = p_restaurant;
  delete from public.tax_rate_components where tax_rate_id = p_rate_id;
  if v_country = 'IN' then
    insert into public.tax_rate_components (restaurant_id, tax_rate_id, name, rate, applies_when, display_order) values
      (p_restaurant, p_rate_id, 'CGST', round(p_total / 2, 3), 'intra_region', 1),
      (p_restaurant, p_rate_id, 'SGST', round(p_total / 2, 3), 'intra_region', 2),
      (p_restaurant, p_rate_id, 'IGST', p_total,               'inter_region', 3);
  else
    insert into public.tax_rate_components (restaurant_id, tax_rate_id, name, rate, applies_when, display_order)
    values (p_restaurant, p_rate_id, coalesce(v_sys, 'Tax'), p_total, 'always', 1);
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION app.write_tax_group(p_restaurant uuid, p_group uuid, p_comps jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare cur public.tax_rates%rowtype; v_has boolean; v_rate uuid; c jsonb; k int := 0;
begin
  select * into cur from public.tax_rates
   where tax_group_id = p_group and valid_from <= app.local_today(p_restaurant)
     and (valid_to is null or valid_to >= app.local_today(p_restaurant))
   order by valid_from desc limit 1 for update;
  v_has := found;
  if v_has and cur.valid_from = app.local_today(p_restaurant) then
    update public.tax_rates set total_rate = app.effective_rate(p_comps) where id = cur.id;
    v_rate := cur.id;
    delete from public.tax_rate_components where tax_rate_id = cur.id;
  else
    if v_has then update public.tax_rates set valid_to = app.local_today(p_restaurant) - 1 where id = cur.id; end if;
    insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
    values (p_restaurant, p_group, app.effective_rate(p_comps), app.local_today(p_restaurant)) returning id into v_rate;
  end if;
  for c in select * from jsonb_array_elements(coalesce(p_comps, '[]'::jsonb)) loop
    k := k + 1;
    insert into public.tax_rate_components
      (restaurant_id, tax_rate_id, name, rate, applies_when, display_order, is_compound)
    values (p_restaurant, v_rate, left(trim(c->>'name'), 40), (c->>'rate')::numeric,
            coalesce(c->>'applies_when', 'always'), k, coalesce((c->>'compound')::boolean, false));
  end loop;
end $function$
;

CREATE OR REPLACE FUNCTION app.z_report(p_day uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.business_days; v jsonb; v_pay jsonb; v_tax jsonb; v_cn jsonb; v_shifts jsonb; v_types jsonb;
begin
  select * into d from public.business_days where id = p_day;
  if not found then return null; end if;
  select jsonb_build_object(
      'bills', count(*) filter (where status = 'completed' and comp_kind is null),
      'first_bill', min(bill_number) filter (where status <> 'voided'),
      'last_bill', max(bill_number) filter (where status <> 'voided'),
      'gross_sales', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind is null), 0),
      'discounts', coalesce(sum(discount_total) filter (where status = 'completed' and comp_kind is null), 0),
      'complimentary_bills', count(*) filter (where status = 'completed' and comp_kind = 'complimentary'),
      'complimentary_value', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind = 'complimentary'), 0),
      'staff_meal_bills', count(*) filter (where status = 'completed' and comp_kind = 'staff_meal'),
      'staff_meal_value', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind = 'staff_meal'), 0),
      'service_charge', coalesce(sum(service_charge) filter (where status = 'completed'), 0),
      'tax', coalesce(sum(tax_total) filter (where status = 'completed'), 0),
      'tax_included', coalesce(sum(tax_included) filter (where status = 'completed'), 0),
      'rounding', coalesce(sum(rounding_adjustment) filter (where status = 'completed'), 0),
      'total_billed', coalesce(sum(grand_total) filter (where status = 'completed'), 0),
      'voided_bills', count(*) filter (where status = 'voided'),
      'voided_value', coalesce(sum(grand_total) filter (where status = 'voided'), 0),
      'unpaid_bills', count(*) filter (where status = 'completed' and payment_status in ('unpaid', 'partial')),
      'unpaid_amount', coalesce(sum(grand_total - app.order_covered(id)) filter (where status = 'completed' and payment_status in ('unpaid', 'partial')), 0))
    into v from public.orders
   where branch_id = d.branch_id and business_date = d.business_date and merged_into is null;

  select coalesce(jsonb_agg(jsonb_build_object('method', name, 'count', n, 'amount', a) order by a desc), '[]'::jsonb)
    into v_pay from (
      select pm.name, count(*) n, sum(p.amount) a from public.payments p
        join public.orders o on o.id = p.order_id join public.payment_methods pm on pm.id = p.payment_method_id
       where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status <> 'voided' and p.status = 'captured'
       group by pm.name) x;
  select coalesce(jsonb_agg(jsonb_build_object('component', c, 'rate', r, 'taxable', tx, 'tax', ta) order by r, c), '[]'::jsonb)
    into v_tax from (
      select t.component_name c, t.rate r, sum(t.taxable_amount) tx, sum(t.tax_amount) ta
        from public.order_item_taxes t join public.orders o on o.id = t.order_id
       where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status = 'completed'
       group by 1, 2) x;
  select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0), 'tax', coalesce(sum(tax_amount), 0),
           'list', coalesce(jsonb_agg(jsonb_build_object('number', number, 'amount', amount, 'bill',
                     (select bill_number from public.orders where id = cn.order_id), 'reason', reason) order by number), '[]'::jsonb))
    into v_cn from public.credit_notes cn where cn.branch_id = d.branch_id and cn.business_date = d.business_date;
  select coalesce(jsonb_agg(app.shift_figures(s.id) order by s.opened_at), '[]'::jsonb) into v_shifts
    from public.shifts s where s.branch_id = d.branch_id
     and exists (select 1 from public.orders o where o.shift_id = s.id and o.business_date = d.business_date
                 union all select 1 from public.payments p join public.orders o on o.id = p.order_id
                  where p.shift_id = s.id and o.business_date = d.business_date);
  select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'bills', n, 'total', t) order by t desc), '[]'::jsonb) into v_types
    from (select order_type, count(*) n, sum(grand_total) t from public.orders
           where branch_id = d.branch_id and business_date = d.business_date and status = 'completed' and merged_into is null
           group by 1) x;

  return v || jsonb_build_object(
    'business_date', d.business_date, 'branch', (select name from public.branches where id = d.branch_id),
    'status', d.status, 'opened_at', d.opened_at, 'closed_at', d.closed_at,
    'closed_by', (select full_name from public.users where id = d.closed_by),
    'payments', v_pay, 'taxes', v_tax, 'credit_notes', v_cn, 'shifts', v_shifts, 'by_type', v_types, 'sessions', (select coalesce(jsonb_agg(jsonb_build_object('session', sn, 'bills', c, 'total', t) order by first_at), '[]'::jsonb) from (select coalesce(o.session_name, 'Other') sn, count(*) c, sum(o.grand_total) t, min(o.created_at) first_at from public.orders o where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status = 'completed' and o.merged_into is null group by 1) ss),
    'net_sales_after_credit_notes', (v->>'total_billed')::numeric - (v_cn->>'amount')::numeric,
    'reopen_count', d.reopen_count);
end $function$
;

CREATE OR REPLACE FUNCTION app.menu_price(p_product uuid, p_price numeric)
 returns numeric
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select app.rule_price(app.current_restaurant_id(), app.current_branch_id(), p_product, p_price, now())
$function$;

-- ---------------------------------------------------------------------
-- Functions: public schema
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.accept_qr_order(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare q public.qr_orders%rowtype; v_order uuid; v_res jsonb; v_table text;
begin
  perform app.require_permission('order.create');
  perform app.require_feature('qr_ordering');
  select * into q from public.qr_orders where id = p_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That table order does not exist.'; end if;
  if q.status <> 'pending' then raise exception 'This table order was already %.', q.status; end if;
  if q.branch_id <> app.current_branch_id() then raise exception 'This order is for another outlet. Switch outlet first.'; end if;
  if q.guest_note is not null then
    q.items := jsonb_set(q.items, '{0,note}', to_jsonb(left(concat_ws(' · ', nullif(q.items->0->>'note', ''), 'Guest: ' || q.guest_note), 200)));
  end if;
  if not coalesce((select is_kiosk from public.dining_tables where id = q.dining_table_id), false) then
  select o.id into v_order from public.orders o
   where o.dining_table_id = q.dining_table_id and o.restaurant_id = q.restaurant_id
     and o.payment_status in ('unpaid', 'partial') and o.status <> 'voided' and o.merged_into is null
   order by o.created_at desc limit 1;
  end if;
  if v_order is not null then
    perform public.add_order_items(v_order, q.items);
    select bill_number into v_table from public.orders where id = v_order;
    v_res := jsonb_build_object('order_id', v_order, 'bill_number', v_table, 'added', true);
  else
    if coalesce((select is_kiosk from public.dining_tables where id = q.dining_table_id), false) then
      v_res := public.create_order(q.items, 'takeaway', null, null, null, null, 0, null, null, null, null, null);
    else
      v_res := public.create_order(q.items, 'dine_in', q.dining_table_id, null, null, null, 0, null, null, null, null, null);
    end if;
    v_order := (v_res->>'order_id')::uuid;
  end if;
  update public.qr_orders set status = 'accepted', order_id = v_order, decided_by = app.current_user_id(), decided_at = now() where id = p_id;
  perform app.audit('qr_order.accept', 'qr_orders', p_id, jsonb_build_object('order_id', v_order), null);
  return v_res;
end $function$
;

CREATE OR REPLACE FUNCTION public.account_charge(p_order uuid, p_customer uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id();
  o public.orders; c public.customers; v_due numeric(14,2); v_bal numeric(14,2); v_shift uuid;
begin
  select * into o from public.orders where id = p_order and restaurant_id = v_rest for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', o.bill_number; end if;
  select * into c from public.customers where id = p_customer and restaurant_id = v_rest and deleted_at is null;
  if not found then raise exception 'Customer not found.'; end if;
  if c.credit_limit is null then raise exception '% has no credit account.', c.name; end if;
  v_due := o.grand_total - app.order_covered(o.id);
  if v_due <= 0 then raise exception 'Bill % has nothing left to pay.', o.bill_number; end if;
  v_bal := app.account_balance(c.id);
  if v_bal + v_due > c.credit_limit then
    raise exception '% owes % already; this bill (%) would go over the credit limit of %.', c.name, v_bal, v_due, c.credit_limit;
  end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  perform set_config('app.account', 'on', true);
  insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, status, received_by, client_created_at, reference_no)
  values (gen_random_uuid(), o.restaurant_id, o.id, app.account_method(v_rest), v_due, o.currency_code, 'captured', v_user, now(), left('Account: ' || c.name, 60));
  perform set_config('app.account', 'off', true);
  update public.orders set paid_total = paid_total + v_due, payment_status = 'paid',
         customer_id = coalesce(customer_id, c.id), shift_id = coalesce(shift_id, v_shift)
   where id = o.id;
  insert into public.customer_ledger (restaurant_id, customer_id, kind, amount, order_id, shift_id, note, created_by)
  values (v_rest, c.id, 'charge', v_due, o.id, v_shift, nullif(left(btrim(coalesce(p_note, '')), 200), ''), v_user);
  perform app.audit('account.charge', 'orders', o.id, jsonb_build_object('bill_number', o.bill_number, 'customer', c.name, 'amount', v_due), null);
  return jsonb_build_object('charged', v_due, 'balance', v_bal + v_due);
end $function$
;

CREATE OR REPLACE FUNCTION public.account_date()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_branch uuid := app.current_branch_id(); d public.business_days; v_today date; v_stuck boolean;
begin
  if app.current_user_id() is null or v_branch is null then return null; end if;
  v_today := app.business_today(v_branch);
  select * into d from public.business_days where branch_id = v_branch and status = 'open';
  if found then
    if d.business_date >= v_today then
      return jsonb_build_object('date', d.business_date, 'old_day', false);
    end if;
    v_stuck := exists (select 1 from public.business_days where branch_id = v_branch and status = 'parked')
      or exists (select 1 from public.orders where branch_id = v_branch and business_date = d.business_date and status = 'completed'
                   and payment_status in ('unpaid', 'partial') and merged_into is null)
      or (coalesce((select shifts_enabled from public.branch_settings where branch_id = v_branch), false)
          and exists (select 1 from public.shifts where branch_id = v_branch and status = 'open'));
    if v_stuck then return jsonb_build_object('date', d.business_date, 'old_day', true); end if;
  end if;
  return jsonb_build_object('date',
    (select greatest(v_today, coalesce(max(business_date) + 1, v_today)) from public.business_days
      where branch_id = v_branch and status <> 'open'), 'old_day', false);
end $function$
;

CREATE OR REPLACE FUNCTION public.account_save(p_customer uuid, p_name text, p_phone text, p_limit numeric, p_company text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('customer.manage'); v_rest uuid := app.current_restaurant_id(); v uuid := p_customer;
  v_phone text := app.clean_phone(p_phone);
begin
  if p_limit is not null and (p_limit < 0 or p_limit > 100000000) then raise exception 'Enter a credit limit of 0 or more.'; end if;
  if v is null then
    if coalesce(btrim(p_name), '') = '' then raise exception 'Enter the customer''s name.'; end if;
    if v_phone is not null then
      select id into v from public.customers where restaurant_id = v_rest and phone = v_phone;
      if v is not null then update public.customers set deleted_at = null where id = v; end if;
    end if;
    if v is null then
      insert into public.customers (restaurant_id, name, phone) values (v_rest, left(btrim(p_name), 80), v_phone) returning id into v;
    end if;
  end if;
  update public.customers set credit_limit = round(p_limit, 2), account_company = nullif(left(btrim(coalesce(p_company, '')), 80), ''),
         name = case when coalesce(btrim(p_name), '') <> '' then left(btrim(p_name), 80) else name end
   where id = v and restaurant_id = v_rest and deleted_at is null;
  if not found then raise exception 'Customer not found.'; end if;
  perform app.audit('account.save', 'customers', v, jsonb_build_object('limit', p_limit), null);
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION public.account_settle(p_customer uuid, p_method uuid, p_amount numeric, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  c public.customers; v_kind text; v_drawer boolean; v_shift uuid; v_amt numeric(14,2) := round(coalesce(p_amount, 0), 2); v_bal numeric(14,2);
begin
  select * into c from public.customers where id = p_customer and restaurant_id = v_rest for update;
  if not found then raise exception 'Customer not found.'; end if;
  if v_amt <= 0 then raise exception 'Enter the amount received.'; end if;
  v_bal := app.account_balance(c.id);
  if v_amt > v_bal then raise exception '% owes only %.', c.name, v_bal; end if;
  select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_method and restaurant_id = v_rest and is_active;
  if not found or v_kind in ('gift_card', 'loyalty', 'advance', 'account') then raise exception 'Choose how the customer paid.'; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift before taking a payment.'; end if;
  insert into public.customer_ledger (restaurant_id, customer_id, kind, amount, payment_method_id, shift_id, note, created_by)
  values (v_rest, c.id, 'settlement', -v_amt, p_method, v_shift, nullif(left(btrim(coalesce(p_note, '')), 200), ''), v_user);
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', v_amt, left('Account payment: ' || c.name, 200), v_user);
  end if;
  perform app.audit('account.settle', 'customers', c.id, jsonb_build_object('amount', v_amt, 'method', v_kind), null);
  return jsonb_build_object('balance', v_bal - v_amt);
end $function$
;

CREATE OR REPLACE FUNCTION public.account_statement(p_customer uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id(); c public.customers; v_open numeric(14,2); v_tz text;
begin
  select * into c from public.customers where id = p_customer and restaurant_id = v_rest;
  if not found then raise exception 'Customer not found.'; end if;
  select coalesce(nullif(timezone, ''), 'Asia/Kolkata') into v_tz from public.restaurants where id = v_rest;
  select coalesce(sum(amount), 0) into v_open from public.customer_ledger
   where customer_id = c.id and (created_at at time zone v_tz)::date < p_from;
  return jsonb_build_object('customer', jsonb_build_object('name', c.name, 'phone', c.phone, 'company', c.account_company, 'limit', c.credit_limit),
    'from', p_from, 'to', p_to, 'opening', v_open,
    'entries', coalesce((select jsonb_agg(jsonb_build_object('at', x.created_at, 'kind', x.kind, 'amount', x.amount, 'note', x.note,
               'bill', (select bill_number from public.orders where id = x.order_id), 'order_id', x.order_id,
               'method', (select name from public.payment_methods where id = x.payment_method_id),
               'balance', v_open + x.running)
               order by x.created_at, x.id)
          from (select l.*, sum(l.amount) over (order by l.created_at, l.id) as running
                  from public.customer_ledger l
                 where l.customer_id = c.id and (l.created_at at time zone v_tz)::date between p_from and p_to) x), '[]'::jsonb),
    'closing', v_open + coalesce((select sum(amount) from public.customer_ledger where customer_id = c.id
                                  and (created_at at time zone v_tz)::date between p_from and p_to), 0));
end $function$
;

CREATE OR REPLACE FUNCTION public.accounting_journal(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_rows jsonb;
begin
  perform app.require_feature('accounting');
  perform app.require_permission('report.view_financial');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  with bills as (
    select o.* from public.orders o
     where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.business_date between p_from and p_to and o.status = 'completed' and o.merged_into is null
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
      from public.credit_notes cn where cn.restaurant_id = v_rest and app.in_scope(cn.branch_id) and cn.business_date between p_from and p_to group by 1
    union all
    select cn.business_date, 'Dr', 'Output ' || (t->>'name') || ' ' || trim(to_char((t->>'rate')::numeric, 'FM990.###')) || '%', sum((t->>'amount')::numeric), 8
      from public.credit_notes cn cross join jsonb_array_elements(cn.taxes) t
     where cn.restaurant_id = v_rest and app.in_scope(cn.branch_id) and cn.business_date between p_from and p_to group by 1, t->>'name', t->>'rate'
    union all
    select cn.business_date, 'Cr', pm.name, sum(cn.amount), 9
      from public.credit_notes cn join public.payment_methods pm on pm.id = cn.payment_method_id
     where cn.restaurant_id = v_rest and app.in_scope(cn.branch_id) and cn.business_date between p_from and p_to group by 1, 3
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', d, 'account', account,
           'debit', case when (side = 'Dr') = (amt >= 0) then abs(amt) else 0 end,
           'credit', case when (side = 'Cr') = (amt >= 0) then abs(amt) else 0 end,
           'narration', 'SNA POS sales ' || to_char(d, 'DD Mon YYYY'))
         order by d, ord, account), '[]'::jsonb)
    into v_rows from lines where amt <> 0;
  return v_rows;
end $function$
;

CREATE OR REPLACE FUNCTION public.accounts_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'company', c.account_company,
            'limit', c.credit_limit, 'balance', app.account_balance(c.id),
            'last', (select max(created_at) from public.customer_ledger l where l.customer_id = c.id)) order by c.name)
     from public.customers c
    where c.restaurant_id = v_rest and c.deleted_at is null
      and (c.credit_limit is not null or exists (select 1 from public.customer_ledger l where l.customer_id = c.id))), '[]'::jsonb);
end $function$
;

CREATE OR REPLACE FUNCTION public.add_order_items(p_order_id uuid, p_items jsonb, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid;
  o public.orders%rowtype; v_in jsonb; v_ids uuid[]; v_c jsonb; v_auto boolean; v_before numeric(14,2);
  v_seen record; v_out jsonb;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen
      from public.request_refs rr where rr.restaurant_id = app.current_restaurant_id() and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'add_items' or v_seen.order_id is distinct from p_order_id then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  v_user := app.require_permission('order.create');
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then
    raise exception 'Bill % is already paid. Start a new bill for more items.', o.bill_number;
  end if;
  perform app.auto_shift(o.branch_id); if not exists (select 1 from public.shifts where branch_id = o.branch_id and status = 'open') then
    raise exception 'Open a shift before taking bills.';
  end if;
  v_before := o.grand_total;
  v_in := app.bill_input(o.restaurant_id, o.branch_id, p_items, 0, null, null);
  v_ids := app.insert_order_lines(o.id, o.restaurant_id, v_in->'calc'->'lines');
  v_c := app.recalc_order(o.id);

  select coalesce(bs.auto_print_kot, true) into v_auto from public.branch_settings bs where bs.branch_id = o.branch_id;
  if coalesce(v_auto, true) then perform app.create_kitchen_ticket(o.id, v_ids); end if;

  perform app.audit('order.add_items', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'lines_added', coalesce(array_length(v_ids, 1), 0),
                       'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', v_before));
  v_out := jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number,
    'grand_total', (v_c->>'grand_total')::numeric,
    'balance', (v_c->>'grand_total')::numeric - app.order_covered(o.id));
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result)
    values (app.current_restaurant_id(), p_client_ref, 'add_items', p_order_id, v_out);
    -- Request ids only matter for a retry within minutes; old ones are cleared as new ones arrive.
    delete from public.request_refs
     where restaurant_id = app.current_restaurant_id() and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $function$
;

CREATE OR REPLACE FUNCTION public.adjust_order(p_order_id uuid, p_discount_amount numeric, p_discount_reason text DEFAULT NULL::text, p_service_charge boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; p jsonb; bs record;
  v_old_disc numeric(14,2); v_new_disc numeric(14,2) := round(coalesce(p_discount_amount, 0), 2);
  v_old_sc boolean; v_new_sc boolean; v_c jsonb; v_before numeric(14,2);
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment, so its discount or service charge cannot be changed.', o.bill_number;
  end if;
  if v_new_disc < 0 then raise exception 'A discount cannot be negative.'; end if;

  p := coalesce(o.calc_params, '{}'::jsonb);
  v_old_disc := coalesce((p->>'discount')::numeric, 0);
  v_old_sc := coalesce((p->>'sc_percent')::numeric, 0) > 0;

  select coalesce(s.service_charge_percent, 0) as pct, coalesce(s.service_charge_taxable, false) as taxable
    into bs from public.branch_settings s where s.branch_id = o.branch_id;
  v_new_sc := coalesce(p_service_charge, v_old_sc) and coalesce(bs.pct, 0) > 0;

  if v_new_disc > 0 and p->'senior' is not null and p->'senior' <> 'null'::jsonb then
    raise exception 'This bill has a senior citizen / PWD discount; another discount cannot be added.';
  end if;
  if v_new_disc > v_old_disc and not app.allowed('order.discount') then
    raise exception 'A manager must approve a discount (order.discount).';
  end if;
  if v_old_sc and not v_new_sc and not app.allowed('order.discount') then
    raise exception 'A manager must approve removing the service charge (order.discount).';
  end if;
  if v_new_disc = v_old_disc and v_new_sc = v_old_sc then
    return jsonb_build_object('order_id', o.id, 'grand_total', o.grand_total, 'changed', false);
  end if;

  v_before := o.grand_total;
  perform set_config('app.recalc', 'on', true);
  update public.orders set calc_params = p
      || jsonb_build_object('discount', v_new_disc,
                            'sc_percent', case when v_new_sc then bs.pct else 0 end,
                            'sc_taxable', coalesce(bs.taxable, false))
   where id = o.id;
  v_c := app.recalc_order(o.id);
  if (v_c->>'discount')::numeric < v_new_disc then
    raise exception 'The discount (%) is more than the bill (%).', v_new_disc, (v_c->>'subtotal')::numeric;
  end if;

  delete from public.order_discounts where order_id = o.id and discount_type = 'fixed_amount';
  if (v_c->>'discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (o.restaurant_id, o.id, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric,
            nullif(left(trim(coalesce(p_discount_reason, '')), 200), ''), v_user);
  end if;

  perform app.audit('order.adjust', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'discount', (v_c->>'discount')::numeric,
                       'service_charge_on', v_new_sc, 'grand_total', (v_c->>'grand_total')::numeric,
                       'reason', nullif(trim(coalesce(p_discount_reason, '')), '')),
    jsonb_build_object('discount', v_old_disc, 'service_charge_on', v_old_sc, 'grand_total', v_before));
  return jsonb_build_object('order_id', o.id, 'grand_total', (v_c->>'grand_total')::numeric, 'changed', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_reset_password(p_user_id uuid, p_new_password text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid := app.require_permission('user.manage'); u public.users%rowtype; v_role text; v_hash text;
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  if u.id = v_me then raise exception 'To change your own password, use Change password.'; end if;
  if u.auth_user_id is null then
    raise exception '% signs in with a PIN only. Pick a new PIN instead.', u.full_name;
  end if;
  select name into v_role from public.roles where id = u.role_id;
  if v_role = 'Owner' and not app.is_owner() then raise exception 'Only an owner can reset another owner''s password.'; end if;
  if length(coalesce(p_new_password, '')) < 8 then raise exception 'Use a password of at least 8 characters.'; end if;
  if length(p_new_password) > 72 then raise exception 'Use a password of at most 72 characters.'; end if;
  v_hash := extensions.crypt(p_new_password, extensions.gen_salt('bf', 10));
  update auth.users set encrypted_password = v_hash, updated_at = now() where id = u.auth_user_id;
  delete from auth.sessions where user_id = u.auth_user_id;
  update public.users set must_change_password = true, password_reset_hash = v_hash where id = u.id;
  perform app.audit('user.password_reset', 'users', u.id, jsonb_build_object('full_name', u.full_name));
end $function$
;

CREATE OR REPLACE FUNCTION public.api_v1(p_key text, p_action text, p_params jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare k public.api_keys%rowtype; v_rest uuid; v_from date; v_to date; v_calls int;
begin
  if coalesce(length(p_key), 0) < 20 or length(p_key) > 100 then raise exception 'Invalid API key.'; end if;
  select * into k from public.api_keys where key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex') and revoked_at is null;
  if not found then raise exception 'Invalid API key.'; end if;
  v_rest := k.restaurant_id;
  if not app.feature_on(v_rest, 'open_api') then raise exception 'The Open API is not switched on for this restaurant.'; end if;
  select count(*) into v_calls from public.api_calls where key_id = k.id and at > now() - interval '1 minute';
  if v_calls >= 60 then raise exception 'Too many requests: at most 60 per minute per key.'; end if;
  insert into public.api_calls (key_id, action) values (k.id, left(coalesce(p_action, ''), 20));
  update public.api_keys set last_used_at = now() where id = k.id;

  if p_action in ('orders', 'sales') then
    begin
      v_from := coalesce((p_params->>'from')::date, app.local_today(v_rest));
      v_to := coalesce((p_params->>'to')::date, v_from);
    exception when others then raise exception 'Dates must look like 2026-09-28.';
    end;
    if v_to < v_from or v_to - v_from > 31 then raise exception 'Choose at most 31 days (from ≤ to).'; end if;
  end if;

  if p_action = 'menu' then
    -- Main categories, each with its own dishes and its sub-categories (each with their dishes).
    return jsonb_build_object('categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items', app.api_menu_items(c.id),
               'sub_categories', coalesce((
                 select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'items', app.api_menu_items(s.id)) order by s.display_order, s.name)
                   from public.categories s where s.parent_id = c.id and s.deleted_at is null), '[]'::jsonb)) order by c.display_order, c.name)
        from public.categories c where c.restaurant_id = v_rest and c.deleted_at is null and c.parent_id is null), '[]'::jsonb));
  elsif p_action = 'orders' then
    return jsonb_build_object('from', v_from, 'to', v_to, 'orders', coalesce((
      select jsonb_agg(x order by x->>'created_at') from (
        select jsonb_build_object('id', o.id, 'bill_number', o.bill_number, 'business_date', o.business_date, 'created_at', o.created_at,
                 'outlet', b.name, 'order_type', o.order_type, 'status', o.status, 'payment_status', o.payment_status,
                 'currency', o.currency_code, 'subtotal', o.subtotal, 'discount', o.discount_total, 'service_charge', o.service_charge,
                 'tax', o.tax_total, 'tax_included', o.tax_included, 'rounding', o.rounding_adjustment, 'grand_total', o.grand_total,
                 'paid', o.paid_total, 'buyer_gstin', o.buyer_gstin,
                 'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.product_name, 'qty', i.quantity, 'unit_price', i.unit_price,
                                'amount', i.line_subtotal, 'options', i.options_text, 'cancelled', i.cancelled_at is not null)), '[]'::jsonb)
                             from public.order_items i where i.order_id = o.id),
                 'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', pm.name, 'kind', pm.kind, 'amount', pa.amount, 'at', pa.created_at)), '[]'::jsonb)
                                from public.payments pa join public.payment_methods pm on pm.id = pa.payment_method_id
                               where pa.order_id = o.id and pa.status in ('captured', 'refunded'))) as x
          from public.orders o join public.branches b on b.id = o.branch_id
         where o.restaurant_id = v_rest and o.business_date between v_from and v_to
         order by o.created_at limit 5000) q), '[]'::jsonb));
  elsif p_action = 'sales' then
    return jsonb_build_object('from', v_from, 'to', v_to, 'days', coalesce((
      select jsonb_agg(jsonb_build_object('date', d, 'outlet', outlet, 'bills', bills, 'gross', gross, 'discount', disc, 'tax', tax,
                                          'total', total, 'voided_bills', voided) order by d, outlet)
        from (select o.business_date d, b.name outlet,
                     count(*) filter (where o.status <> 'voided') bills,
                     sum(o.subtotal) filter (where o.status <> 'voided') gross,
                     sum(o.discount_total) filter (where o.status <> 'voided') disc,
                     sum(o.tax_total + o.tax_included) filter (where o.status <> 'voided') tax,
                     sum(o.grand_total) filter (where o.status <> 'voided') total,
                     count(*) filter (where o.status = 'voided') voided
                from public.orders o join public.branches b on b.id = o.branch_id
               where o.restaurant_id = v_rest and o.business_date between v_from and v_to
               group by 1, 2) s), '[]'::jsonb),
      'credit_notes', coalesce((select jsonb_agg(jsonb_build_object('number', cn.number, 'date', cn.business_date, 'amount', cn.amount, 'tax', cn.tax_amount))
                                  from public.credit_notes cn where cn.restaurant_id = v_rest and cn.business_date between v_from and v_to), '[]'::jsonb));
  elsif p_action = 'stock' then
    if not app.feature_on(v_rest, 'stock') then raise exception 'Stock is not switched on for this restaurant.'; end if;
    return jsonb_build_object('ingredients', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'reorder_level', i.reorder_level,
               'by_outlet', (select coalesce(jsonb_agg(jsonb_build_object('outlet', b.name, 'stock', x.q)), '[]'::jsonb)
                               from (select m.branch_id, sum(m.qty) q from public.stock_movements m where m.ingredient_id = i.id group by 1) x
                               join public.branches b on b.id = x.branch_id)) order by i.name)
        from public.ingredients i where i.restaurant_id = v_rest and i.is_active), '[]'::jsonb));
  end if;
  raise exception 'Unknown action. Use menu, orders, sales or stock.';
end $function$
;

CREATE OR REPLACE FUNCTION public.approve_with_pin(p_pin text, p_permission text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.current_user_id(); v_rest uuid := app.current_restaurant_id(); v_approver public.users%rowtype; v_fails int;
begin
  if v_me is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if not exists (select 1 from public.permissions where key = p_permission) then raise exception 'Unknown right.'; end if;
  select count(*) into v_fails from public.approval_failures where user_id = v_me and at > now() - interval '10 minutes';
  if v_fails >= 5 then
    return jsonb_build_object('ok', false, 'error', 'Too many wrong PINs. Wait 10 minutes and try again.');
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then
    return jsonb_build_object('ok', false, 'error', 'Enter the 4 or 6 digit PIN.');
  end if;
  select u.* into v_approver from public.users u
   where u.restaurant_id = v_rest and u.is_active and u.deleted_at is null and u.pin_hash is not null
     and u.pin_hash = app.pin_hash(v_rest, p_pin) limit 1;
  if not found or not exists (select 1 from public.role_permissions rp where rp.role_id = v_approver.role_id and rp.permission_key = p_permission) then
    -- Recorded (and not rolled back) so repeated guessing locks the approval screen.
    insert into public.approval_failures (restaurant_id, user_id) values (v_rest, v_me);
    return jsonb_build_object('ok', false, 'error', 'That PIN cannot approve this. Ask a manager to enter their own PIN.');
  end if;
  if v_approver.id = v_me then return jsonb_build_object('ok', false, 'error', 'You already have this right; no approval is needed.'); end if;
  insert into public.approvals (restaurant_id, requested_by, approved_by, permission_key)
  values (v_rest, v_me, v_approver.id, p_permission);
  perform app.audit('approval.granted', 'users', v_approver.id,
    jsonb_build_object('permission', p_permission, 'for_user', v_me, 'approver', v_approver.full_name));
  return jsonb_build_object('ok', true, 'approver', v_approver.full_name, 'permission', p_permission, 'valid_seconds', 120);
end $function$
;

CREATE OR REPLACE FUNCTION public.attach_customer(p_order uuid, p_phone text, p_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id(); v_phone text := app.clean_phone(p_phone); v_cust uuid; v_name text; o public.orders%rowtype;
begin
  perform app.require_permission('order.create');
  if v_phone is null or length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 7 then raise exception 'Enter the guest''s phone number.'; end if;
  select * into o from public.orders where id = p_order and restaurant_id = v_rest for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  select id, name into v_cust, v_name from public.customers where restaurant_id = v_rest and phone = v_phone and deleted_at is null;
  if v_cust is null then
    insert into public.customers (restaurant_id, name, phone) values (v_rest, coalesce(nullif(left(trim(p_name), 80), ''), 'Guest'), v_phone)
    returning id, name into v_cust, v_name;
  elsif nullif(trim(p_name), '') is not null and v_name = 'Guest' then
    update public.customers set name = left(trim(p_name), 80) where id = v_cust returning name into v_name;
  end if;
  update public.orders set customer_id = v_cust where id = p_order;
  perform app.audit('order.customer', 'orders', p_order, jsonb_build_object('customer_id', v_cust), null);
  return jsonb_build_object('customer_id', v_cust, 'name', v_name, 'phone', v_phone, 'points', app.points_balance(v_cust));
end $function$
;

CREATE OR REPLACE FUNCTION public.batch_add(p_product uuid, p_qty numeric, p_expires_on date, p_made_on date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v uuid;
  v_made date := coalesce(p_made_on, app.local_today(v_rest));
begin
  if not exists (select 1 from public.products where id = p_product and restaurant_id = v_rest and deleted_at is null and track_batches) then
    raise exception 'That dish is not tracked in batches. Tick "Track in batches" on the dish first.';
  end if;
  if coalesce(p_qty, 0) <= 0 or p_qty > 100000 then raise exception 'Enter how many were made.'; end if;
  if p_expires_on is null or p_expires_on < v_made then raise exception 'Best before must be on or after the day it was made.'; end if;
  if v_made > app.local_today(v_rest) then raise exception 'The day made cannot be in the future.'; end if;
  insert into public.product_batches (restaurant_id, branch_id, product_id, made_on, expires_on, qty_made, qty_left, note, created_by)
  values (v_rest, v_branch, p_product, v_made, p_expires_on, round(p_qty, 3), round(p_qty, 3), nullif(left(btrim(coalesce(p_note, '')), 200), ''), v_user)
  returning id into v;
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION public.batch_stock()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(jsonb_object_agg(p.id, coalesce((select sum(qty_left) from public.product_batches b
           where b.product_id = p.id and b.branch_id = app.current_branch_id() and b.expires_on >= app.local_today(app.current_restaurant_id())), 0)), '{}'::jsonb)
    from public.products p where p.restaurant_id = app.current_restaurant_id() and p.track_batches and p.deleted_at is null
$function$
;

CREATE OR REPLACE FUNCTION public.batch_write_off(p_batch uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); b public.product_batches;
begin
  select * into b from public.product_batches where id = p_batch and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Batch not found.'; end if;
  if b.qty_left <= 0 then return 0; end if;
  update public.product_batches set wasted = wasted + qty_left, qty_left = 0 where id = b.id;
  perform app.audit('batch.write_off', 'product_batches', b.id, jsonb_build_object('qty', b.qty_left), null);
  return b.qty_left;
end $function$
;

CREATE OR REPLACE FUNCTION public.batches_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  return jsonb_build_object(
    'batches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'product_id', b.product_id, 'product', p.name, 'made_on', b.made_on,
                 'expires_on', b.expires_on, 'qty_made', b.qty_made, 'qty_left', b.qty_left, 'wasted', b.wasted, 'note', b.note,
                 'expired', b.expires_on < app.local_today(v_rest)) order by b.expires_on, p.name)
        from public.product_batches b join public.products p on p.id = b.product_id
       where b.branch_id = v_branch and (b.qty_left > 0 or b.created_at > now() - interval '2 days')), '[]'::jsonb),
    'dishes', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name,
                 'left', coalesce((select sum(qty_left) from public.product_batches b where b.product_id = p.id and b.branch_id = v_branch and b.expires_on >= app.local_today(v_rest)), 0),
                 -- sold without a batch to take from (more sold than recorded as made)
                 'short', coalesce((select sum(oi.quantity - coalesce(oi.cancelled_qty, 0)) from public.order_items oi join public.orders o on o.id = oi.order_id
                                     where oi.product_id = p.id and o.branch_id = v_branch and oi.created_at >= app.local_day_start(v_rest) and oi.cancelled_at is null), 0)
                          - coalesce((select -sum(bm.qty) from public.batch_movements bm join public.order_items oi on oi.id = bm.order_item_id join public.orders o on o.id = oi.order_id
                                     where oi.product_id = p.id and o.branch_id = v_branch and oi.created_at >= app.local_day_start(v_rest)), 0))
             order by p.name)
        from public.products p where p.restaurant_id = v_rest and p.track_batches and p.deleted_at is null), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.bill_prefix_info()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_branch uuid := app.current_branch_id(); s public.bill_series;
begin
  perform app.require_permission('order.create');
  if v_branch is null then raise exception 'No outlet chosen.'; end if;
  s := app.current_bill_series(v_branch);
  return jsonb_build_object(
    'prefix', s.prefix,
    'next_number', s.prefix || '-' || lpad(s.next_seq::text, greatest(4, length(s.next_seq::text)), '0'),
    'bills_in_series', s.next_seq - 1,
    'since', s.created_at,
    'earlier', coalesce((select jsonb_agg(jsonb_build_object('prefix', x.prefix, 'last_number',
                          case when x.next_seq > 1 then x.prefix || '-' || lpad((x.next_seq - 1)::text, greatest(4, length((x.next_seq - 1)::text)), '0') end) order by x.created_at desc)
                           from public.bill_series x where x.branch_id = v_branch and not x.is_current), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.brand_save(p_id uuid, p_name text, p_commission numeric DEFAULT 0, p_legal_name text DEFAULT NULL::text, p_gstin text DEFAULT NULL::text, p_active boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id(); v_id uuid;
  v_name text := btrim(coalesce(p_name, '')); v_gstin text := nullif(upper(btrim(coalesce(p_gstin, ''))), '');
begin
  if v_name = '' then raise exception 'Enter the brand or stall name.'; end if;
  if length(v_name) > 60 then raise exception 'The name is too long (60 letters at most).'; end if;
  if coalesce(p_commission, 0) < 0 or coalesce(p_commission, 0) > 100 then raise exception 'Commission is 0 to 100 percent.'; end if;
  if v_gstin is not null and v_gstin !~ '^[0-9A-Z]{15}$' then raise exception 'A GSTIN has 15 letters and digits.'; end if;
  if exists (select 1 from public.brands where restaurant_id = v_rest and lower(btrim(name)) = lower(v_name) and id is distinct from p_id) then
    raise exception 'There is already a brand called %.', v_name;
  end if;
  if p_id is null then
    insert into public.brands (restaurant_id, name, legal_name, gstin, commission_percent, is_active, display_order)
    values (v_rest, v_name, nullif(btrim(coalesce(p_legal_name, '')), ''), v_gstin, round(coalesce(p_commission, 0), 2), coalesce(p_active, true),
            coalesce((select max(display_order) + 1 from public.brands where restaurant_id = v_rest), 0))
    returning id into v_id;
  else
    update public.brands set name = v_name, legal_name = nullif(btrim(coalesce(p_legal_name, '')), ''), gstin = v_gstin,
           commission_percent = round(coalesce(p_commission, 0), 2), is_active = coalesce(p_active, true)
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'That brand was not found.'; end if;
  end if;
  perform app.audit('brand.save', 'brands', v_id, jsonb_build_object('name', v_name, 'commission', p_commission), null);
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.brand_settlement(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end := (p_to + 1)::timestamp at time zone v_tz;
  return jsonb_build_object('from', p_from, 'to', p_to, 'brands', coalesce((
    select jsonb_agg(jsonb_build_object('brand_id', x.brand_id, 'brand', coalesce(b.name, 'No brand'), 'gstin', b.gstin,
             'bills', x.bills, 'qty', x.qty, 'sales', x.sales, 'tax', x.tax, 'billed', x.sales + x.tax,
             'commission_percent', coalesce(b.commission_percent, 0),
             'commission', round(x.sales * coalesce(b.commission_percent, 0) / 100, 2),
             'payable', x.sales + x.tax - round(x.sales * coalesce(b.commission_percent, 0) / 100, 2))
           order by b.display_order nulls last, b.name)
      from (select oi.brand_id, count(distinct o.id) bills, sum(oi.quantity) qty,
                   sum(oi.net_amount) sales, sum(oi.line_tax + oi.tax_included) tax
              from public.order_items oi join public.orders o on o.id = oi.order_id
             where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.created_at >= v_start and o.created_at < v_end
               and o.status = 'completed' and o.merged_into is null and o.comp_kind is null and oi.cancelled_at is null
               and not exists (select 1 from public.products p where p.id = oi.product_id and p.is_charge)
             group by oi.brand_id) x
      left join public.brands b on b.id = x.brand_id), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.cancel_goods_receipt(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('stock.manage');
  g public.goods_receipts%rowtype; l record; v_po_status text; v_cost numeric; v_kept text[] := '{}';
begin
  perform app.require_feature('stock');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for cancelling the receipt.'; end if;
  select * into g from public.goods_receipts
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Goods receipt not found.'; end if;
  if g.status = 'cancelled' then raise exception 'Receipt % is already cancelled.', g.number; end if;
  if g.paid_total > 0 then
    raise exception 'Receipt % has a payment recorded against it, so it cannot be cancelled. Undo the payment first.', g.number;
  end if;
  -- Stock entries are never edited: the quantities go back out as their own entries.
  for l in select * from public.goods_receipt_lines where goods_receipt_id = g.id order by ingredient_id loop
    perform pg_advisory_xact_lock(hashtext('stock:' || g.branch_id::text || ':' || l.ingredient_id::text));
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, goods_receipt_id)
    values (g.restaurant_id, g.branch_id, l.ingredient_id, 'adjust', -l.qty, l.unit_cost, left(g.number || ' cancelled: ' || trim(p_reason), 200), v_user, g.id);
    -- The delivery also moved the ingredient's cost. If nothing else has changed
    -- the cost since, put back what it was; otherwise leave it and say so.
    select i.cost_per_unit into v_cost from public.ingredients i where i.id = l.ingredient_id;
    if l.prev_cost is not null and v_cost is not distinct from l.new_cost then
      update public.ingredients set cost_per_unit = l.prev_cost where id = l.ingredient_id and cost_per_unit is distinct from l.prev_cost;
    elsif v_cost is distinct from l.prev_cost then
      v_kept := v_kept || (select i.name from public.ingredients i where i.id = l.ingredient_id);
    end if;
    if g.purchase_order_id is not null then
      update public.purchase_order_lines set received_qty = greatest(0, received_qty - l.qty)
       where purchase_order_id = g.purchase_order_id and ingredient_id = l.ingredient_id;
    end if;
  end loop;
  update public.goods_receipts set status = 'cancelled', cancelled_at = now(), cancelled_by = v_user,
         cancel_reason = left(trim(p_reason), 300)
   where id = g.id;
  if g.purchase_order_id is not null then
    select case when not exists (select 1 from public.purchase_order_lines where purchase_order_id = g.purchase_order_id and received_qty > 0) then 'ordered'
                when exists (select 1 from public.purchase_order_lines where purchase_order_id = g.purchase_order_id and received_qty < qty) then 'part_received'
                else 'received' end into v_po_status;
    update public.purchase_orders set status = v_po_status, closed_at = case when v_po_status = 'received' then closed_at else null end
     where id = g.purchase_order_id and status <> 'cancelled';
  end if;
  perform app.audit('goods.cancel', 'goods_receipts', g.id, jsonb_build_object('number', g.number, 'reason', left(trim(p_reason), 300)),
                    jsonb_build_object('total', g.total));
  return jsonb_build_object('id', g.id, 'number', g.number, 'status', 'cancelled', 'cost_not_restored', to_jsonb(v_kept));
end $function$
;

CREATE OR REPLACE FUNCTION public.cancel_invite(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('user.manage');
  u public.users%rowtype;
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  if u.auth_user_id is not null then raise exception '% has already joined; deactivate them instead.', u.full_name; end if;
  if (select name from public.roles where id = u.role_id) = 'Owner' and not app.is_owner() then
    raise exception 'Only an owner can manage another owner.';
  end if;
  delete from public.staff_invites where user_id = u.id;
  update public.users set deleted_at = now(), is_active = false where id = u.id;
  perform app.audit('user.invite_cancelled', 'users', u.id, null);
end $function$
;

CREATE OR REPLACE FUNCTION public.cancel_order_item(p_order_item_id uuid, p_qty numeric, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.void');
  it public.order_items%rowtype; o public.orders%rowtype; v_q numeric; v_c jsonb; v_before numeric(14,2);
begin
  if coalesce(trim(p_reason), '') = '' then raise exception 'A reason is required to cancel an item.'; end if;
  select * into it from public.order_items where id = p_order_item_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That item is not on the bill.'; end if;
  select * into o from public.orders where id = it.order_id for update;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then
    raise exception 'Bill % is already paid. Use a refund instead.', o.bill_number;
  end if;
  if it.cancelled_at is not null then raise exception '% is already cancelled.', it.product_name; end if;
  v_q := coalesce(p_qty, it.quantity);
  if v_q <= 0 or v_q > it.quantity then
    raise exception 'Enter a quantity between 1 and % for %.', trim_scale(it.quantity), it.product_name;
  end if;
  v_before := o.grand_total;

  if v_q = it.quantity then
    if (select count(*) from public.order_items where order_id = o.id and cancelled_at is null) = 1 then
      raise exception '% is the only item on bill %. Void the bill instead.', it.product_name, o.bill_number;
    end if;
    update public.order_items set cancelled_at = now(), cancelled_by = v_user, cancelled_qty = cancelled_qty + v_q,
           cancel_reason = left(trim(p_reason), 200) where id = it.id;
    update public.kitchen_ticket_items set status = 'cancelled' where order_item_id = it.id and status in ('new', 'preparing');
  else
    update public.order_items set quantity = quantity - v_q, cancelled_qty = cancelled_qty + v_q,
           cancel_reason = left(trim(p_reason), 200) where id = it.id;
    update public.kitchen_ticket_items set quantity = quantity - v_q
     where order_item_id = it.id and status in ('new', 'preparing') and quantity > v_q;
  end if;
  update public.kitchen_tickets kt set status = 'cancelled'
   where kt.order_id = o.id and kt.status in ('new', 'preparing')
     and not exists (select 1 from public.kitchen_ticket_items k where k.kitchen_ticket_id = kt.id and k.status <> 'cancelled');

  v_c := app.recalc_order(o.id);
  if (v_c->>'grand_total')::numeric < app.order_covered(o.id) then
    raise exception 'Bill % already has % paid, which is more than the new total. Refund after payment instead.',
      o.bill_number, app.order_covered(o.id);
  end if;
  -- What was already paid now covers the whole (smaller) bill: close it.
  if app.order_covered(o.id) > 0 and (v_c->>'grand_total')::numeric = app.order_covered(o.id) then
    update public.orders set payment_status = 'paid' where id = o.id;
  end if;

  perform app.audit('order.cancel_item', 'order_items', it.id,
    jsonb_build_object('bill_number', o.bill_number, 'item', it.product_name, 'qty', v_q,
                       'reason', left(trim(p_reason), 200), 'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', v_before, 'qty', it.quantity));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'grand_total', (v_c->>'grand_total')::numeric,
    'paid', app.order_covered(o.id) > 0 and (v_c->>'grand_total')::numeric = app.order_covered(o.id));
end $function$
;

CREATE OR REPLACE FUNCTION public.cancel_plan_request(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not app.is_owner() then raise exception 'Only the owner can cancel plan requests.'; end if;
  update public.plan_requests set status = 'cancelled'
   where id = p_id and restaurant_id = app.current_restaurant_id() and status = 'requested';
  if not found then raise exception 'This request can no longer be cancelled.'; end if;
  perform app.log_plan(app.current_restaurant_id(), 'request.cancelled', jsonb_build_object('request', p_id));
end $function$
;

CREATE OR REPLACE FUNCTION public.category_set_brand(p_category uuid, p_brand uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('menu.manage'); v_rest uuid := app.current_restaurant_id(); c public.categories;
begin
  select * into c from public.categories where id = p_category and restaurant_id = v_rest and deleted_at is null;
  if not found then raise exception 'That category was not found.'; end if;
  if c.parent_id is not null then raise exception 'A sub-category goes with its main category. Change the main category instead.'; end if;
  if p_brand is not null and not exists (select 1 from public.brands where id = p_brand and restaurant_id = v_rest) then
    raise exception 'That brand was not found.';
  end if;
  update public.categories set brand_id = p_brand where id = p_category;
end $function$
;

CREATE OR REPLACE FUNCTION public.chain_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.change_payment_method(p_payment_id uuid, p_method_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('payment.change_mode');
  p public.payments%rowtype; o public.orders%rowtype; v_old text; v_new text; v_new_kind text; v_shift_open boolean;
begin
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for the change.'; end if;
  select * into p from public.payments where id = p_payment_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Payment not found.'; end if;
  if p.status <> 'captured' then raise exception 'This payment was refunded and cannot be changed.'; end if;
  select * into o from public.orders where id = p.order_id for update;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  select s.status = 'open' into v_shift_open from public.shifts s where s.id = o.shift_id;
  if not coalesce(v_shift_open, false) then
    raise exception 'The shift for bill % is already closed, so the payment mode can no longer be changed.', o.bill_number;
  end if;
  if coalesce(p.rounding_adjustment, 0) <> 0 then
    raise exception 'This cash payment was rounded, so its mode cannot be changed. Void and re-bill instead.';
  end if;
  if p.payment_method_id = p_method_id then raise exception 'That is already the payment method.'; end if;
  select pm.name, pm.kind into v_new, v_new_kind from public.payment_methods pm
   where pm.id = p_method_id and pm.restaurant_id = p.restaurant_id and pm.is_active;
  if not found then raise exception 'That payment method is not available.'; end if;
  select name into v_old from public.payment_methods where id = p.payment_method_id;

  perform set_config('app.pay_fix', 'on', true);
  update public.payments set payment_method_id = p_method_id,
         tendered_amount = case when v_new_kind = 'cash' then amount else null end,
         change_amount = 0,
         reference_no = case when v_new_kind = 'cash' then null else reference_no end
   where id = p.id;
  perform set_config('app.pay_fix', 'off', true);

  perform app.audit('payment.change_mode', 'payments', p.id,
    jsonb_build_object('bill_number', o.bill_number, 'method', v_new, 'amount', p.amount, 'reason', left(trim(p_reason), 200)),
    jsonb_build_object('method', v_old));
  return jsonb_build_object('bill_number', o.bill_number, 'from', v_old, 'to', v_new);
end $function$
;

CREATE OR REPLACE FUNCTION public.claim_staff_invite(p_code text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_code text := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
  r record;
begin
  if v_uid is null then raise exception 'You must be signed in.'; end if;
  if exists (select 1 from public.devices where auth_user_id = v_uid) then
    raise exception 'This is a shared counter device. Staff unlock it with their PIN.';
  end if;
  if exists (select 1 from public.users where auth_user_id = v_uid and deleted_at is null) then
    raise exception 'This account already belongs to a restaurant.';
  end if;
  if length(v_code) <> 8 then raise exception 'An invite code is 8 letters and numbers.'; end if;
  select lower(email) into v_email from auth.users where id = v_uid;

  for r in
    select u.id, u.restaurant_id, i.code_hash
      from public.users u join public.staff_invites i on i.user_id = u.id
     where lower(u.email::text) = v_email and u.auth_user_id is null
       and u.deleted_at is null and u.is_active and i.expires_at > now()
  loop
    if extensions.crypt(v_code, r.code_hash) = r.code_hash then
      update public.users set auth_user_id = v_uid, last_login_at = now() where id = r.id;
      delete from public.staff_invites where user_id = r.id;
      insert into public.audit_logs (restaurant_id, user_id, action, entity_type, entity_id, actor_type)
      values (r.restaurant_id, r.id, 'user.join', 'users', r.id, 'user');
      return r.restaurant_id;
    end if;
  end loop;

  raise exception 'That invite code does not match this email, or it has expired. Ask your manager for a new code.';
end $function$
;

CREATE OR REPLACE FUNCTION public.claim_tickets_for_print(p_ids uuid[])
 RETURNS uuid[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v uuid[];
begin
  if app.current_user_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  with upd as (
    update public.kitchen_tickets set printed_at = now()
     where id = any(coalesce(p_ids, '{}')) and restaurant_id = app.current_restaurant_id() and printed_at is null
    returning id)
  select coalesce(array_agg(id), '{}') into v from upd;
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION public.clear_pin_lockout(p_device_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid := app.require_permission('settings.manage'); d public.devices%rowtype;
begin
  select * into d from public.devices where id = p_device_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'Counter device not found.'; end if;
  delete from public.pin_attempts where device_id = d.id and not ok;
  perform app.audit('device.clear_lockout', 'devices', d.id, jsonb_build_object('name', d.name));
end $function$
;

CREATE OR REPLACE FUNCTION public.clear_staff_pin(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid := app.require_permission('user.manage'); u public.users%rowtype; v_role text;
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id() and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  select name into v_role from public.roles where id = u.role_id;
  if v_role = 'Owner' and not app.is_owner() then raise exception 'Only an owner can change another owner.'; end if;
  update public.users set pin_hash = null, pin_set_at = null where id = u.id;
  delete from public.pin_sessions where user_id = u.id;
  perform app.audit('user.pin_removed', 'users', u.id, jsonb_build_object('full_name', u.full_name));
end $function$
;

CREATE OR REPLACE FUNCTION public.clock_in()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.current_user_id(); v_id uuid; v_at timestamptz := date_trunc('second', clock_timestamp());
begin
  perform app.require_feature('timesheets');
  if v_user is null then raise exception 'Not signed in.'; end if;
  if exists (select 1 from public.time_entries where user_id = v_user and clock_out is null) then raise exception 'You are already clocked in.'; end if;
  insert into public.time_entries (restaurant_id, branch_id, user_id, clock_in) values (app.current_restaurant_id(), app.current_branch_id(), v_user, v_at)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'clock_in', v_at);
end $function$
;

CREATE OR REPLACE FUNCTION public.clock_out()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.current_user_id(); e public.time_entries%rowtype;
begin
  perform app.require_feature('timesheets');
  update public.time_entries set clock_out = greatest(clock_timestamp(), clock_in + interval '1 second')
   where user_id = v_user and clock_out is null returning * into e;
  if e.id is null then raise exception 'You are not clocked in.'; end if;
  return jsonb_build_object('id', e.id, 'hours', round(extract(epoch from (e.clock_out - e.clock_in)) / 3600.0, 2));
end $function$
;

CREATE OR REPLACE FUNCTION public.close_day(p_notes text DEFAULT NULL::text, p_counted_cash numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('day.close');
  v_branch uuid := app.current_branch_id(); d public.business_days; v_list text; v_z jsonb;
begin
  select * into d from public.business_days where branch_id = v_branch and status = 'open' for update;
  if not found then raise exception 'There is no open day to close.'; end if;
  if p_counted_cash is not null and p_counted_cash < 0 then raise exception 'The counted cash cannot be negative.'; end if;
  select string_agg(bill_number, ', ' order by created_at) into v_list from (
    select bill_number, created_at from public.orders
     where branch_id = v_branch and business_date = d.business_date and status = 'completed'
       and payment_status in ('unpaid', 'partial') and merged_into is null limit 20) x;
  if v_list is not null then
    raise exception 'These bills are not paid yet: %. Take payment, put them on a pay-later account, or void them before closing the day.', v_list;
  end if;
  perform app.close_auto_shifts(v_branch, p_counted_cash);
  if exists (select 1 from public.shifts where branch_id = v_branch and status = 'open') then
    raise exception 'Close the open shift first (count the cash on the Shift screen), then close the day.';
  end if;
  update public.business_days set status = 'closed', closed_at = now(), closed_by = v_user,
         close_notes = nullif(left(trim(coalesce(p_notes, '')), 300), '')
   where id = d.id;
  v_z := app.z_report(d.id);
  update public.business_days set z_report = v_z where id = d.id;
  update public.business_days set status = 'open' where branch_id = v_branch and status = 'parked';
  perform app.audit('day.close', 'business_days', d.id,
    jsonb_build_object('business_date', d.business_date, 'total_billed', v_z->'total_billed', 'bills', v_z->'bills'));
  return v_z;
end $function$
;

CREATE OR REPLACE FUNCTION public.close_shift(p_counted_cash numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('shift.close');
  v_shift uuid;
  v_fig jsonb;
  v_expected numeric(14,2);
begin
  if p_counted_cash is null or p_counted_cash < 0 then
    raise exception 'Enter the cash you counted in the drawer.';
  end if;
  select id into v_shift from public.shifts
   where branch_id = app.current_branch_id() and status = 'open'
   limit 1 for update;
  if v_shift is null then raise exception 'There is no open shift to close.'; end if;

  v_fig := app.shift_figures(v_shift);
  v_expected := (v_fig->>'expected_cash')::numeric;

  update public.shifts set
    closed_by = v_user, closed_at = now(), status = 'closed',
    expected_cash = v_expected, counted_cash = round(p_counted_cash,2),
    cash_variance = round(p_counted_cash,2) - v_expected,
    notes = nullif(left(trim(p_notes),500),'')
  where id = v_shift;

  perform app.audit('shift.close', 'shifts', v_shift,
    jsonb_build_object('expected_cash', v_expected, 'counted_cash', round(p_counted_cash,2),
                       'variance', round(p_counted_cash,2) - v_expected));
  return app.shift_figures(v_shift);
end $function$
;

CREATE OR REPLACE FUNCTION public.create_api_key(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_key text := 'snapi_' || replace(replace(app.new_token(30), '-', 'x'), '_', 'y'); v_id uuid;
begin
  perform app.require_permission('settings.manage');
  perform app.require_feature('open_api');
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the key a name (e.g. Tally sync).'; end if;
  if (select count(*) from public.api_keys where restaurant_id = app.current_restaurant_id() and revoked_at is null) >= 10 then
    raise exception 'At most 10 active keys. Remove one first.';
  end if;
  insert into public.api_keys (restaurant_id, name, prefix, key_hash, created_by)
  values (app.current_restaurant_id(), left(trim(p_name), 60), left(v_key, 12), encode(extensions.digest(v_key, 'sha256'), 'hex'), app.current_user_id())
  returning id into v_id;
  perform app.audit('api_key.create', 'api_keys', v_id, jsonb_build_object('name', p_name, 'prefix', left(v_key, 12)), null);
  return jsonb_build_object('id', v_id, 'key', v_key);
end $function$
;

CREATE OR REPLACE FUNCTION public.create_order(p_items jsonb, p_order_type text DEFAULT 'dine_in'::text, p_table_id uuid DEFAULT NULL::uuid, p_customer_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_tendered numeric DEFAULT NULL::numeric, p_discount_amount numeric DEFAULT 0, p_discount_reason text DEFAULT NULL::text, p_service_charge boolean DEFAULT NULL::boolean, p_senior jsonb DEFAULT NULL::jsonb, p_reference text DEFAULT NULL::text, p_client_ref uuid DEFAULT NULL::uuid, p_extra jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_restaurant uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  v_in jsonb; v_c jsonb; v_currency char(3); v_auto_kot boolean; v_shift uuid; v_device uuid;
  v_bill_no text; v_order_id uuid := gen_random_uuid(); v_ids uuid[];
  v_method_kind text; v_grand numeric(14,2); v_amount numeric(14,2); v_cash_round numeric(14,2) := 0;
  v_change numeric(14,2) := 0; v_paid boolean := false; v_rmode text;
  v_gname text; v_gphone text; v_addr text; v_cust uuid := p_customer_id; v_gdel timestamptz;
  v_tok text; v_token int;
begin
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('order_ref:' || p_client_ref::text));
    select jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'grand_total', o.grand_total,
             'amount_paid', o.paid_total, 'cash_rounding', 0, 'change', 0, 'paid', o.payment_status = 'paid', 'repeat', true,
             'token_no', o.token_no)
      into v_in from public.orders o where o.restaurant_id = app.current_restaurant_id() and o.client_ref = p_client_ref;
    if v_in is not null then return v_in; end if;
  end if;
  if nullif(p_senior, 'null'::jsonb) is not null and not app.allowed('order.discount') then
    raise exception 'A manager must approve the senior citizen / PWD discount (order.discount).';
  end if;
  if coalesce(p_discount_amount, 0) < 0 then raise exception 'A discount cannot be negative.'; end if;
  if coalesce(p_discount_amount, 0) > 0 and not app.allowed('order.discount') then
    raise exception 'A manager must approve a discount (order.discount).';
  end if;
  if v_branch is null then raise exception 'No branch is set up for this restaurant.'; end if;
  if coalesce(p_order_type, '') not in ('dine_in', 'takeaway', 'delivery') then raise exception 'Unknown order type.'; end if;

  select s.id into v_shift from public.shifts s
   where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1; if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

  if p_payment_method_id is not null and not app.allowed('payment.take') then
    raise exception 'You do not have the right to take payment (payment.take). Save the bill and ask the cashier to settle it.';
  end if;
  if p_payment_method_id is not null then
    select pm.kind into v_method_kind from public.payment_methods pm
     where pm.id = p_payment_method_id and pm.restaurant_id = v_restaurant and pm.is_active;
    if not found then raise exception 'That payment method is not available.'; end if;
  end if;
  if p_table_id is not null and not exists (
      select 1 from public.dining_tables t where t.id = p_table_id and t.restaurant_id = v_restaurant and t.is_active) then
    raise exception 'That table does not exist.';
  end if;
  if p_customer_id is not null and not exists (
      select 1 from public.customers c where c.id = p_customer_id and c.restaurant_id = v_restaurant and c.deleted_at is null) then
    raise exception 'That customer does not exist.';
  end if;

  -- The guest's name, phone and delivery address, when the counter took them.
  -- A phone number also finds (or starts) that guest's customer record.
  if p_extra is not null and jsonb_typeof(p_extra) = 'object' then
    v_gname  := nullif(left(trim(coalesce(p_extra->>'guest_name', '')), 80), '');
    v_gphone := app.clean_phone(p_extra->>'guest_phone');
    v_addr   := nullif(left(trim(coalesce(p_extra->>'address', '')), 300), '');
    if v_gphone is not null and length(regexp_replace(p_extra->>'guest_phone', '[^0-9]', '', 'g')) < 7 then
      raise exception 'That phone number looks too short.';
    end if;
    if v_gphone is not null and v_cust is null then
      select c.id, c.deleted_at into v_cust, v_gdel from public.customers c
       where c.restaurant_id = v_restaurant and c.phone = v_gphone;
      if v_cust is null then
        insert into public.customers (restaurant_id, name, phone)
        values (v_restaurant, coalesce(v_gname, 'Guest'), v_gphone) returning id into v_cust;
      else
        update public.customers set deleted_at = null,
               name = case when v_gname is not null and (name is null or name = 'Guest' or v_gdel is not null) then v_gname else name end
         where id = v_cust and (v_gdel is not null or (v_gname is not null and (name is null or name = 'Guest')));
      end if;
    end if;
  end if;
  v_in := app.bill_input(v_restaurant, v_branch, p_items, p_discount_amount, p_service_charge, p_senior);
  v_rmode := v_in->>'cash_rounding';

  select r.currency_code into v_currency from public.restaurants r where r.id = v_restaurant;
  select coalesce(bs.auto_print_kot, true) into v_auto_kot from public.branch_settings bs where bs.branch_id = v_branch;
  v_auto_kot := coalesce(v_auto_kot, true);

  if app.items_are_liquor(v_restaurant, p_items) then
    select n.device_id, n.bill_no into v_device, v_bill_no from app.next_liquor_number(v_branch) n;
  else
    select n.device_id, n.bill_no into v_device, v_bill_no from app.next_bill_number(v_branch) n;
  end if;

  insert into public.orders
    (id, restaurant_id, branch_id, device_id, bill_number, order_type, dining_table_id, customer_id,
     cashier_id, shift_id, currency_code, status, payment_status, client_created_at, calc_params, senior_details,
     guest_name, guest_phone, delivery_address)
  values
    (v_order_id, v_restaurant, v_branch, v_device, v_bill_no, p_order_type, p_table_id, v_cust,
     v_user, v_shift, v_currency, 'open', 'unpaid', now(), (v_in->'calc') - 'lines', nullif(v_in->'senior', 'null'::jsonb),
     v_gname, v_gphone, case when p_order_type = 'delivery' then v_addr end);
  if p_client_ref is not null then update public.orders set client_ref = p_client_ref where id = v_order_id; end if;
  -- Captain app: number of guests at the table, and who took the order.
  if p_order_type = 'dine_in' and coalesce(p_extra->>'covers', '') ~ '^[0-9]{1,2}$' and (p_extra->>'covers')::int between 1 and 99 then
    update public.orders set covers = (p_extra->>'covers')::smallint, waiter_id = v_user where id = v_order_id;
  end if;
  -- Token number for the day (takeaway and delivery, or every bill), if the outlet uses tokens.
  select coalesce(bs.token_numbers, 'off') into v_tok from public.branch_settings bs where bs.branch_id = v_branch;
  if v_tok = 'all' or (v_tok = 'takeaway' and p_order_type <> 'dine_in') then
    update public.business_days d set last_token = d.last_token + 1
     where d.branch_id = v_branch
       and d.business_date = (select o.business_date from public.orders o where o.id = v_order_id)
    returning d.last_token into v_token;
    update public.orders set token_no = v_token where id = v_order_id;
  end if;
  v_ids := app.insert_order_lines(v_order_id, v_restaurant, v_in->'calc'->'lines');
  v_c := app.recalc_order(v_order_id);
  if (v_c->>'discount')::numeric < round(coalesce(p_discount_amount, 0), 2) then
    raise exception 'The discount (%) is more than the bill (%).', round(p_discount_amount, 2), (v_c->>'subtotal')::numeric;
  end if;
  v_grand := (v_c->>'grand_total')::numeric;

  if (v_c->>'discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (v_restaurant, v_order_id, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric,
            nullif(left(p_discount_reason, 200), ''), v_user);
  end if;
  if (v_c->>'senior_discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (v_restaurant, v_order_id, 'senior_pwd', 20, (v_c->>'senior_discount')::numeric,
            left(upper(v_in->'senior'->>'kind') || ': ' || (v_in->'senior'->>'name') || ', ID ' || (v_in->'senior'->>'id_no'), 200),
            v_user);
  end if;

  if p_payment_method_id is not null and v_grand > 0 then
    v_amount := v_grand;
    if v_method_kind = 'cash' and v_rmode <> 'none' then
      v_amount := app.round_cash(v_grand, v_rmode);
      if v_amount <= 0 then v_amount := v_grand; end if;
      v_cash_round := v_amount - v_grand;
    end if;
    if p_tendered is not null then
      if p_tendered < v_amount then
        raise exception 'Cash received (%) is less than the amount due (%).', p_tendered, v_amount;
      end if;
      v_change := p_tendered - v_amount;
    end if;
    insert into public.payments
      (id, restaurant_id, order_id, payment_method_id, amount, currency_code, tendered_amount,
       change_amount, status, received_by, client_created_at, rounding_adjustment, reference_no)
    values
      (gen_random_uuid(), v_restaurant, v_order_id, p_payment_method_id, v_amount, v_currency,
       p_tendered, v_change, 'captured', v_user, now(), v_cash_round, nullif(left(trim(p_reference), 60), ''));
    v_paid := true;
  end if;

  update public.orders set
      paid_total = case when v_paid then v_amount else 0 end,
      status = 'completed',
      payment_status = case when v_paid or v_grand = 0 then 'paid' else 'unpaid' end,
      synced_at = now()
  where id = v_order_id;

  if v_auto_kot then perform app.create_kitchen_ticket(v_order_id, v_ids); end if;

  perform app.audit('order.create', 'orders', v_order_id,
    jsonb_build_object('bill_number', v_bill_no, 'grand_total', v_grand,
                       'discount', (v_c->>'discount')::numeric, 'senior_discount', (v_c->>'senior_discount')::numeric));

  return jsonb_build_object('order_id', v_order_id, 'bill_number', v_bill_no,
    'grand_total', v_grand, 'amount_paid', case when v_paid then v_amount else 0 end,
    'cash_rounding', v_cash_round, 'change', v_change, 'paid', v_paid or v_grand = 0, 'token_no', v_token);
end $function$
;

CREATE OR REPLACE FUNCTION public.create_pin_staff(p_full_name text, p_role_id uuid, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('user.manage');
  v_rest uuid := app.current_restaurant_id(); v_role public.roles%rowtype; v_emp text; v_id uuid := gen_random_uuid(); v_pin jsonb;
begin
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Enter the staff member''s name.'; end if;
  select * into v_role from public.roles where id = p_role_id and restaurant_id = v_rest;
  if not found then raise exception 'Choose a role.'; end if;
  if v_role.name = 'Owner' then raise exception 'An owner needs an email sign-in, not only a PIN.'; end if;
  select 'EMP' || lpad((coalesce(max(nullif(regexp_replace(employee_code,'\D','','g'),'')::int),0) + 1)::text, 3, '0')
    into v_emp from public.users where restaurant_id = v_rest;
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, email, phone, role_id, is_active)
  values (v_id, v_rest, null, v_emp, left(trim(p_full_name), 120), null, nullif(trim(p_phone), ''), v_role.id, true);
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (v_id, app.current_branch_id(), v_rest);
  perform app.audit('user.create_pin_staff', 'users', v_id, jsonb_build_object('full_name', trim(p_full_name), 'role', v_role.name));
  v_pin := public.set_staff_pin(v_id, null);
  return jsonb_build_object('user_id', v_id, 'employee_code', v_emp, 'pin', v_pin->>'pin');
end $function$
;

CREATE OR REPLACE FUNCTION public.create_restaurant_with_owner(p_legal_name text, p_trading_name text, p_country_code character, p_owner_name text, p_branch_name text DEFAULT 'Main Branch'::text, p_branch_code text DEFAULT 'MN'::text, p_timezone text DEFAULT NULL::text, p_tax_registration_no text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if exists (select 1 from public.devices where auth_user_id = auth.uid()) then
    raise exception 'This is a shared counter device. Sign in on your own device to set up a restaurant.';
  end if;
  return app.create_restaurant_with_owner(p_legal_name, p_trading_name, p_country_code, p_owner_name,
    p_branch_name, p_branch_code, p_timezone, p_tax_registration_no);
end $function$
;

CREATE OR REPLACE FUNCTION public.create_tax_group(p_name text, p_total_rate numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('tax.manage');
  v_rest uuid := app.current_restaurant_id();
  v_group uuid;
  v_rate uuid;
  v_r numeric := round(p_total_rate, 3);
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a name for the tax group.'; end if;
  if v_r is null or v_r < 0 or v_r > 40 then
    raise exception 'Enter a tax rate between 0 and 40 percent.';
  end if;
  if exists (select 1 from public.tax_groups where restaurant_id = v_rest and lower(name) = lower(trim(p_name))) then
    raise exception 'A tax group with that name already exists.';
  end if;
  insert into public.tax_groups (restaurant_id, name, is_price_inclusive)
  values (v_rest, left(trim(p_name), 60), false) returning id into v_group;
  insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
  values (v_rest, v_group, v_r, app.local_today(v_rest)) returning id into v_rate;
  perform app.write_tax_components(v_rest, v_rate, v_r);
  perform app.audit('tax.group_create', 'tax_groups', v_group,
    jsonb_build_object('name', trim(p_name), 'rate', v_r));
  return v_group;
end $function$
;

CREATE OR REPLACE FUNCTION public.current_shift()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_shift uuid;
  v jsonb;
begin
  if app.current_restaurant_id() is null then
    raise exception 'You are not signed in to a restaurant.';
  end if;
  select id into v_shift from public.shifts
   where branch_id = app.current_branch_id() and status = 'open'
   order by opened_at desc limit 1;
  if v_shift is null then return null; end if;
  v := app.shift_figures(v_shift);
  if not (app.has_permission('shift.close') or app.has_permission('report.view_financial')) then
    v := jsonb_build_object('shift_id', v->'shift_id', 'status', v->'status',
           'opened_at', v->'opened_at', 'opened_by', v->'opened_by', 'bills', v->'bills');
  end if;
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION public.day_report(p_day_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.business_days;
begin
  perform app.require_permission('report.view_sales');
  select * into d from public.business_days where id = p_day_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'Day not found.'; end if;
  return case when d.status = 'closed' and d.z_report is not null then d.z_report else app.z_report(d.id) end;
end $function$
;

CREATE OR REPLACE FUNCTION public.day_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_branch uuid := app.current_branch_id(); d public.business_days; v_unpaid jsonb; v_shift boolean; v_days jsonb;
begin
  if app.current_user_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  select * into d from public.business_days where branch_id = v_branch and status = 'open';
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'bill_number', o.bill_number, 'total', o.grand_total,
            'balance', o.grand_total - app.order_covered(o.id)) order by o.created_at), '[]'::jsonb)
    into v_unpaid from public.orders o
   where d.id is not null and o.branch_id = v_branch and o.business_date = d.business_date
     and o.status = 'completed' and o.payment_status in ('unpaid', 'partial') and o.merged_into is null;
  select exists (select 1 from public.shifts where branch_id = v_branch and status = 'open')
       and coalesce((select shifts_enabled from public.branch_settings where branch_id = v_branch), false) into v_shift;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'business_date', business_date, 'status', status,
            'closed_at', closed_at, 'total', z_report->'total_billed') order by business_date desc), '[]'::jsonb)
    into v_days from (select * from public.business_days where branch_id = v_branch and status <> 'open'
                       order by business_date desc limit 14) x;
  return jsonb_build_object(
    'open_day', case when d.id is null then null else jsonb_build_object('id', d.id, 'business_date', d.business_date,
                  'opened_at', d.opened_at, 'bills', (select count(*) from public.orders where branch_id = v_branch
                    and business_date = d.business_date and status <> 'voided' and merged_into is null)) end,
    'unpaid', v_unpaid, 'shift_open', v_shift, 'recent', v_days,
    'shifts_enabled', coalesce((select shifts_enabled from public.branch_settings where branch_id = v_branch), false),
    'expected_cash', (select (app.shift_figures(s.id)->>'expected_cash')::numeric from public.shifts s where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1),
    'can_close', app.has_permission('day.close'), 'can_reopen', app.has_permission('day.reopen'));
end $function$
;

CREATE OR REPLACE FUNCTION public.delete_price_rule(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('menu.manage');
  delete from public.price_rules where id = p_id and restaurant_id = app.current_restaurant_id();
end $function$
;

CREATE OR REPLACE FUNCTION public.delete_role(p_role_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('user.manage');
  v_old public.roles;
  v_people int;
begin
  perform app.require_feature('custom_roles');
  if not app.is_owner() then raise exception 'Only an owner can remove roles.'; end if;
  select * into v_old from public.roles where id = p_role_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Role not found.'; end if;
  if v_old.name = 'Owner' and v_old.is_system then raise exception 'The Owner role cannot be removed.'; end if;
  select count(*) into v_people from public.users where role_id = p_role_id and deleted_at is null;
  if v_people > 0 then raise exception 'Move the % people with this role to another role first.', v_people; end if;
  delete from public.roles where id = p_role_id;
  perform app.audit('role.removed', 'role', p_role_id, null, jsonb_build_object('name', v_old.name));
end $function$
;

CREATE OR REPLACE FUNCTION public.deliveries_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id, 'bill_number', o.bill_number, 'token_no', o.token_no, 'status', o.delivery_status,
           'rider_id', o.rider_id, 'rider', r.name, 'guest_name', o.guest_name, 'guest_phone', o.guest_phone,
           'address', o.delivery_address, 'total', o.grand_total,
           'due', case when o.payment_status in ('unpaid', 'partial') then o.grand_total - app.order_covered(o.id) else 0 end,
           'created_at', o.created_at, 'out_at', o.out_at, 'delivered_at', o.delivered_at) order by o.created_at), '[]'::jsonb)
    from public.orders o left join public.riders r on r.id = o.rider_id
   where o.restaurant_id = app.current_restaurant_id() and o.branch_id = app.current_branch_id()
     and app.allowed('order.create') and o.order_type = 'delivery' and o.status <> 'voided' and o.merged_into is null
     and (o.delivery_status in ('waiting', 'out') or o.created_at > now() - interval '24 hours')
$function$
;

CREATE OR REPLACE FUNCTION public.delivery_update(p_order uuid, p_status text, p_rider uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); o public.orders;
begin
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found or o.order_type <> 'delivery' then raise exception 'That is not a delivery bill.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if p_status not in ('waiting', 'out', 'delivered', 'returned') then raise exception 'Unknown delivery status.'; end if;
  if p_status = 'out' then
    if p_rider is null and o.rider_id is null then raise exception 'Choose the rider.'; end if;
    if p_rider is not null and not exists (select 1 from public.riders where id = p_rider and restaurant_id = o.restaurant_id and is_active) then
      raise exception 'That rider was not found.';
    end if;
    update public.orders set delivery_status = 'out', rider_id = coalesce(p_rider, rider_id), out_at = now(), delivered_at = null where id = o.id;
  elsif p_status = 'delivered' then
    if o.rider_id is null and p_rider is null then raise exception 'Choose the rider who delivered it.'; end if;
    update public.orders set delivery_status = 'delivered', rider_id = coalesce(p_rider, rider_id), out_at = coalesce(out_at, now()), delivered_at = now() where id = o.id;
  elsif p_status = 'returned' then
    update public.orders set delivery_status = 'returned', delivered_at = null where id = o.id;
  else
    update public.orders set delivery_status = 'waiting', rider_id = null, out_at = null, delivered_at = null where id = o.id;
  end if;
  perform app.audit('delivery.' || p_status, 'orders', o.id, jsonb_build_object('rider', coalesce(p_rider, o.rider_id)), null);
  return jsonb_build_object('order_id', o.id, 'status', p_status);
end $function$
;

CREATE OR REPLACE FUNCTION public.fire_held_items(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); o public.orders%rowtype; v_ids uuid[];
begin
  perform app.require_feature('courses');
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  with upd as (
    update public.order_items set held = false
     where order_id = o.id and held and cancelled_at is null
    returning id)
  select array_agg(id) into v_ids from upd;
  if v_ids is null then raise exception 'Nothing is waiting to be sent to the kitchen.'; end if;
  perform app.create_kitchen_ticket(o.id, v_ids);
  perform app.audit('order.fire', 'orders', o.id, jsonb_build_object('bill_number', o.bill_number, 'items', array_length(v_ids, 1)));
  return jsonb_build_object('bill_number', o.bill_number, 'sent', array_length(v_ids, 1));
end $function$
;

CREATE OR REPLACE FUNCTION public.fix_time_entry(p_id uuid, p_in timestamp with time zone, p_out timestamp with time zone, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare old public.time_entries%rowtype;
begin
  perform app.require_permission('user.manage');
  if coalesce(trim(p_reason), '') = '' then raise exception 'Enter a reason for the change.'; end if;
  if p_out is not null and p_out <= p_in then raise exception 'Clock-out must be after clock-in.'; end if;
  select * into old from public.time_entries where id = p_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Entry not found.'; end if;
  update public.time_entries set clock_in = p_in, clock_out = p_out, edited_by = app.current_user_id(), edit_reason = left(trim(p_reason), 200)
   where id = p_id;
  perform app.audit('timesheet.fix', 'time_entries', p_id,
    jsonb_build_object('clock_in', p_in, 'clock_out', p_out, 'reason', p_reason),
    jsonb_build_object('clock_in', old.clock_in, 'clock_out', old.clock_out));
end $function$
;

CREATE OR REPLACE FUNCTION public.gift_card_history(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare g public.gift_cards%rowtype;
begin
  perform app.require_permission('order.create');
  select * into g from public.gift_cards where restaurant_id = app.current_restaurant_id() and code = upper(trim(p_code));
  if not found then raise exception 'No card with that code.'; end if;
  return jsonb_build_object('code', g.code, 'balance', app.gift_balance(g.id), 'expires_on', g.expires_on,
    'entries', coalesce((select jsonb_agg(jsonb_build_object('at', l.created_at, 'kind', l.kind, 'amount', l.amount, 'bill', o.bill_number) order by l.created_at desc)
                           from public.gift_card_ledger l left join public.orders o on o.id = l.order_id where l.gift_card_id = g.id), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.gift_card_lookup(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare g public.gift_cards%rowtype;
begin
  perform app.require_permission('order.create');
  select * into g from public.gift_cards where restaurant_id = app.current_restaurant_id() and code = upper(trim(p_code));
  if not found then raise exception 'No gift card with that code.'; end if;
  return jsonb_build_object('code', g.code, 'value', g.value, 'balance', app.gift_balance(g.id), 'expires_on', g.expires_on,
    'expired', g.expires_on is not null and g.expires_on < app.local_today(app.current_restaurant_id()));
end $function$
;

CREATE OR REPLACE FUNCTION public.gst_register(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
     where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.business_date between p_from and p_to and o.merged_into is null and o.status in ('completed', 'voided')
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
      from public.credit_notes cn where cn.restaurant_id = v_rest and app.in_scope(cn.branch_id) and cn.business_date between p_from and p_to) x;
  return v_rows;
end $function$
;

CREATE OR REPLACE FUNCTION public.import_menu(p_rows jsonb, p_apply boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rest uuid; v_country text; v_edition text; v_stations boolean;
  v_can_price boolean; v_can_tax boolean;
  r jsonb; v_row int; v_errs jsonb := '[]'::jsonb;
  v_cat text; v_sub text; v_name text; v_price numeric; v_tax text; v_veg text; v_hsn text; v_station text; v_local text;
  v_tax_id uuid; v_vegb boolean; v_one_tax uuid; v_tax_count int; v_tax_names text;
  v_main_id uuid; v_sub_id uuid; v_cat_id uuid; v_tmp uuid;
  v_pid uuid; v_pprice numeric; v_ptax uuid; v_pveg boolean; v_phsn text; v_pstation text; v_plocal text;
  v_seen jsonb := '{}'::jsonb; v_key text;
  v_new_cats int := 0; v_new_items int := 0; v_upd int := 0; v_same int := 0; v_live_items int;
  v_plan jsonb := '[]'::jsonb; p jsonb; v_order int;
  v_new_cat_keys jsonb := '{}'::jsonb;
begin
  perform app.require_permission('menu.manage');
  v_rest := app.current_restaurant_id();
  select r2.country_code, r2.edition into v_country, v_edition from public.restaurants r2 where r2.id = v_rest;
  v_stations := app.feature_on(v_rest, 'kitchen_stations');
  v_can_price := app.has_permission('menu.price_change');
  v_can_tax := app.has_permission('tax.manage');

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'The file has no menu rows.';
  end if;
  if jsonb_array_length(p_rows) > 2000 then
    raise exception 'Up to 2,000 rows can be uploaded at once. Split the file.';
  end if;

  select count(*), min(id::text)::uuid, string_agg(name, ', ' order by name)
    into v_tax_count, v_one_tax, v_tax_names
    from public.tax_groups where restaurant_id = v_rest and is_active;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_row := coalesce(nullif(r->>'row', '')::int, 0);
    v_cat := btrim(coalesce(r->>'category', ''));
    v_sub := btrim(coalesce(r->>'sub_category', ''));
    v_name := btrim(coalesce(r->>'name', ''));
    v_tax := btrim(coalesce(r->>'tax_group', ''));
    v_veg := lower(btrim(coalesce(r->>'veg', '')));
    v_hsn := regexp_replace(coalesce(r->>'hsn', ''), '\s', '', 'g');
    v_station := btrim(coalesce(r->>'station', ''));
    v_local := btrim(coalesce(r->>'local_name', ''));
    v_tax_id := null; v_vegb := null; v_cat_id := null; v_main_id := null; v_sub_id := null; v_pid := null;

    -- a completely empty line is skipped
    if v_cat = '' and v_sub = '' and v_name = '' and btrim(coalesce(r->>'price', '')) = '' then continue; end if;

    if v_cat = '' then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Category is empty.'); continue; end if;
    if v_name = '' then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Item name is empty.'); continue; end if;
    if length(v_cat) > 80 or length(v_sub) > 80 then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Category names can be up to 80 characters.'); continue; end if;
    if length(v_name) > 120 then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Item name can be up to 120 characters.'); continue; end if;

    -- "1,250" is a thousands comma; "120,50" is a decimal comma (semicolon CSVs from Excel) and is refused,
    -- so a price can never come in 100 times too high.
    if btrim(coalesce(r->>'price', '')) ~ ',[0-9]{1,2}$' then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Write the price with a dot for paise, for example 120.50 (not 120,50).'); continue;
    end if;
    begin
      v_price := round(replace(replace(btrim(coalesce(r->>'price', '')), ',', ''), ' ', '')::numeric, 2);
    exception when others then v_price := null;
    end;
    if v_price is null or v_price < 0 or v_price > 10000000 then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Price must be a number, for example 120 or 120.50.'); continue;
    end if;

    if v_veg in ('y', 'yes', 'veg', 'v', 'true', '1') then v_vegb := true;
    elsif v_veg in ('n', 'no', 'non-veg', 'nonveg', 'non veg', 'nv', 'false', '0') then v_vegb := false;
    elsif v_veg <> '' then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Veg must be Y or N (or empty).'); continue;
    end if;

    -- Excel drops a leading zero (0902 becomes 902): HSN codes have 4, 6 or 8 digits, so one zero is put back.
    if v_hsn ~ '^[0-9]{3}$' or v_hsn ~ '^[0-9]{5}$' or v_hsn ~ '^[0-9]{7}$' then v_hsn := '0' || v_hsn; end if;
    if v_country = 'IN' and v_hsn <> '' and v_hsn !~ '^[0-9]{4,8}$' then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'HSN / SAC code is 4 to 8 digits, or leave it empty.'); continue;
    end if;
    if v_country <> 'IN' then v_hsn := ''; end if;
    if length(v_station) > 30 then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Kitchen station can be up to 30 characters.'); continue; end if;
    if not v_stations then v_station := ''; end if;
    if length(v_local) > 120 then v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Name in second language can be up to 120 characters.'); continue; end if;

    if v_tax <> '' then
      select id into v_tax_id from public.tax_groups
       where restaurant_id = v_rest and is_active and lower(btrim(name)) = lower(v_tax) limit 1;
      if v_tax_id is null then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'message',
          format('Tax group "%s" is not set up. Use one of: %s.', v_tax, coalesce(v_tax_names, 'none set up yet')));
        continue;
      end if;
    end if;

    -- the main category
    select id into v_main_id from public.categories
     where restaurant_id = v_rest and deleted_at is null and parent_id is null and lower(btrim(name)) = lower(v_cat) limit 1;
    if v_main_id is null and exists (select 1 from public.categories where restaurant_id = v_rest and deleted_at is null
                                      and parent_id is not null and lower(btrim(name)) = lower(v_cat)) then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message',
        format('"%s" is a sub-category. Put its main category under Category and "%s" under Sub-category.', v_cat, v_cat));
      continue;
    end if;

    if v_sub <> '' then
      if lower(v_sub) = lower(v_cat) then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'message', 'Sub-category has the same name as its category. Leave Sub-category empty.'); continue;
      end if;
      if v_main_id is not null then
        select id into v_sub_id from public.categories
         where restaurant_id = v_rest and deleted_at is null and parent_id = v_main_id and lower(btrim(name)) = lower(v_sub) limit 1;
      end if;
      v_cat_id := v_sub_id;
    else
      v_cat_id := v_main_id;
    end if;

    -- the same dish twice in the file
    v_key := lower(v_cat) || '|' || lower(v_sub) || '|' || lower(v_name);
    if v_seen ? v_key then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'message',
        format('"%s" is already on row %s of this file.', v_name, v_seen->>v_key));
      continue;
    end if;
    v_seen := v_seen || jsonb_build_object(v_key, v_row);

    -- an existing dish (not the packing charge) with this name in this category
    if v_cat_id is not null then
      select id, price, tax_group_id, is_veg, hsn_code, kitchen_station, name_local
        into v_pid, v_pprice, v_ptax, v_pveg, v_phsn, v_pstation, v_plocal
        from public.products
       where restaurant_id = v_rest and category_id = v_cat_id and deleted_at is null and not coalesce(is_charge, false)
         and lower(btrim(name)) = lower(v_name)
       order by created_at limit 1;
    end if;

    if v_pid is null then
      if v_tax_id is null then
        if v_tax_count = 1 then v_tax_id := v_one_tax;
        else
          v_errs := v_errs || jsonb_build_object('row', v_row, 'message',
            format('Tax group is empty. Use one of: %s.', coalesce(v_tax_names, 'none set up yet')));
          continue;
        end if;
      end if;
      v_plan := v_plan || jsonb_build_object('op', 'add', 'row', v_row, 'cat', v_cat, 'sub', v_sub, 'name', v_name,
                  'price', v_price, 'tax', v_tax_id, 'veg', v_vegb, 'hsn', nullif(v_hsn, ''), 'station', nullif(v_station, ''),
                  'local', nullif(v_local, ''));
      v_new_items := v_new_items + 1;
      if v_main_id is null and not v_new_cat_keys ? lower(v_cat) then
        v_new_cat_keys := v_new_cat_keys || jsonb_build_object(lower(v_cat), true); v_new_cats := v_new_cats + 1;
      end if;
      if v_sub <> '' and v_sub_id is null and not v_new_cat_keys ? (lower(v_cat) || '|' || lower(v_sub)) then
        v_new_cat_keys := v_new_cat_keys || jsonb_build_object(lower(v_cat) || '|' || lower(v_sub), true); v_new_cats := v_new_cats + 1;
      end if;
    else
      if v_price <> v_pprice and not v_can_price then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'message', format('"%s" would change price, and your role cannot change prices.', v_name)); continue;
      end if;
      if v_tax_id is not null and v_tax_id <> v_ptax and not v_can_tax then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'message', format('"%s" would change tax group, and your role cannot change tax.', v_name)); continue;
      end if;
      if v_price = v_pprice
         and (v_tax_id is null or v_tax_id = v_ptax)
         and (v_vegb is null or v_vegb is not distinct from v_pveg)
         and (v_hsn = '' or v_hsn is not distinct from v_phsn)
         and (v_station = '' or v_station is not distinct from v_pstation)
         and (v_local = '' or v_local is not distinct from v_plocal) then
        v_same := v_same + 1;
      else
        v_plan := v_plan || jsonb_build_object('op', 'update', 'row', v_row, 'id', v_pid, 'price', v_price, 'tax', v_tax_id,
                    'veg', v_vegb, 'hsn', nullif(v_hsn, ''), 'station', nullif(v_station, ''), 'local', nullif(v_local, ''));
        v_upd := v_upd + 1;
      end if;
    end if;
  end loop;

  if jsonb_array_length(v_errs) = 0 and v_new_items = 0 and v_upd = 0 and v_same = 0 then
    v_errs := v_errs || jsonb_build_object('row', 0, 'message', 'The file has no menu rows.');
  end if;

  -- Basic edition: at most 300 dishes
  if v_edition = 'basic' and v_new_items > 0 then
    select count(*) into v_live_items from public.products where restaurant_id = v_rest and deleted_at is null;
    if v_live_items + v_new_items > 300 then
      v_errs := v_errs || jsonb_build_object('row', 0, 'message',
        format('The Basic edition allows up to 300 menu items. You have %s and the file adds %s.', v_live_items, v_new_items));
    end if;
  end if;

  if jsonb_array_length(v_errs) > 0 or not coalesce(p_apply, false) then
    return jsonb_build_object('ok', jsonb_array_length(v_errs) = 0, 'applied', false, 'errors', v_errs,
      'new_categories', v_new_cats, 'new_items', v_new_items, 'updated_items', v_upd, 'unchanged_items', v_same);
  end if;

  -- Save. Everything above was checked; this runs in one transaction.
  select coalesce(max(display_order), 0) into v_order from public.categories where restaurant_id = v_rest and display_order < 999;
  for p in select value from jsonb_array_elements(v_plan) loop
    if p->>'op' = 'add' then
      v_cat_id := null;
      select id into v_cat_id from public.categories
       where restaurant_id = v_rest and deleted_at is null and parent_id is null and lower(btrim(name)) = lower(p->>'cat') limit 1;
      if v_cat_id is null then
        v_order := least(v_order + 1, 998);
        insert into public.categories (restaurant_id, name, display_order) values (v_rest, p->>'cat', v_order) returning id into v_cat_id;
      end if;
      if coalesce(p->>'sub', '') <> '' then
        v_tmp := null;
        select id into v_tmp from public.categories
         where restaurant_id = v_rest and deleted_at is null and parent_id = v_cat_id and lower(btrim(name)) = lower(p->>'sub') limit 1;
        if v_tmp is null then
          v_order := least(v_order + 1, 998);
          insert into public.categories (restaurant_id, name, parent_id, display_order)
          values (v_rest, p->>'sub', v_cat_id, v_order) returning id into v_tmp;
        end if;
        v_cat_id := v_tmp;
      end if;
      insert into public.products (restaurant_id, category_id, tax_group_id, name, price, is_veg, hsn_code, kitchen_station, name_local)
      values (v_rest, v_cat_id, (p->>'tax')::uuid, p->>'name', (p->>'price')::numeric,
              (p->>'veg')::boolean, p->>'hsn', p->>'station', p->>'local');
    else
      update public.products set
        price = (p->>'price')::numeric,
        tax_group_id = coalesce((p->>'tax')::uuid, tax_group_id),
        is_veg = coalesce((p->>'veg')::boolean, is_veg),
        hsn_code = coalesce(p->>'hsn', hsn_code),
        kitchen_station = coalesce(p->>'station', kitchen_station),
        name_local = coalesce(p->>'local', name_local)
       where id = (p->>'id')::uuid and restaurant_id = v_rest;
    end if;
  end loop;

  perform app.audit('menu.imported', 'restaurant', v_rest,
    jsonb_build_object('new_categories', v_new_cats, 'new_items', v_new_items, 'updated_items', v_upd), null);

  return jsonb_build_object('ok', true, 'applied', true, 'errors', '[]'::jsonb,
    'new_categories', v_new_cats, 'new_items', v_new_items, 'updated_items', v_upd, 'unchanged_items', v_same);
end $function$
;

CREATE OR REPLACE FUNCTION public.invite_staff(p_full_name text, p_email text, p_role_id uuid, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('user.manage');
  v_rest uuid := app.current_restaurant_id();
  v_role public.roles%rowtype;
  v_email text := lower(trim(p_email));
  v_code text := app.new_invite_code();
  v_emp text;
  v_id uuid := gen_random_uuid();
begin
  if coalesce(trim(p_full_name),'') = '' then raise exception 'Enter the staff member''s name.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  select * into v_role from public.roles where id = p_role_id and restaurant_id = v_rest;
  if not found then raise exception 'Choose a role.'; end if;
  if v_role.name = 'Owner' and not app.is_owner() then
    raise exception 'Only an owner can add another owner.';
  end if;
  if exists (select 1 from public.users where restaurant_id = v_rest
             and lower(email::text) = v_email and deleted_at is null) then
    raise exception 'Someone with that email is already on your staff list.';
  end if;

  select 'EMP' || lpad((coalesce(max(nullif(regexp_replace(employee_code,'\D','','g'),'')::int),0) + 1)::text, 3, '0')
    into v_emp from public.users where restaurant_id = v_rest;

  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, email, phone, role_id, is_active)
  values (v_id, v_rest, null, v_emp, left(trim(p_full_name),120), v_email, nullif(trim(p_phone),''), v_role.id, true);

  insert into public.user_branches (user_id, branch_id, restaurant_id)
  values (v_id, app.current_branch_id(), v_rest);

  insert into public.staff_invites (user_id, restaurant_id, code_hash, expires_at, created_by)
  values (v_id, v_rest, extensions.crypt(v_code, extensions.gen_salt('bf')), now() + interval '7 days', v_me);

  perform app.audit('user.invite', 'users', v_id,
    jsonb_build_object('full_name', trim(p_full_name), 'email', v_email, 'role', v_role.name));
  return jsonb_build_object('user_id', v_id, 'employee_code', v_emp, 'invite_code', v_code,
                            'expires_at', now() + interval '7 days');
end $function$
;

CREATE OR REPLACE FUNCTION public.issue_credit_note(p_order_id uuid, p_amount numeric, p_method_id uuid, p_reason text, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid;
  o public.orders%rowtype; v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_done numeric(14,2); v_left numeric(14,2); v_country text; v_day public.business_days; v_shift uuid;
  v_kind text; v_ratio numeric; v_tax numeric(14,2); v_taxes jsonb; v_no text; v_seq int; v_fy text; v_code text;
  v_id uuid := gen_random_uuid(); v_deadline date;
  v_seen record; v_out jsonb;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen
      from public.request_refs rr where rr.restaurant_id = app.current_restaurant_id() and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'credit_note' or v_seen.order_id is distinct from p_order_id then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  v_user := app.require_permission('order.refund');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for the credit note.'; end if;
  if v_amount <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status <> 'completed' or o.merged_into is not null then raise exception 'Only a completed bill can get a credit note.'; end if;
  if o.payment_status in ('unpaid', 'partial') then
    raise exception 'Bill % is not fully paid. Cancel items or void it instead.', o.bill_number;
  end if;
  select coalesce(sum(amount), 0) into v_done from public.refunds where order_id = o.id;
  v_left := o.paid_total - v_done;
  if v_left <= 0 then raise exception 'Bill % has already been fully refunded.', o.bill_number; end if;
  if v_amount > v_left then raise exception 'The most that can be refunded on bill % is %.', o.bill_number, v_left; end if;

  select country_code into v_country from public.restaurants where id = o.restaurant_id;
  v_day := app.open_business_day(o.branch_id);
  if v_country = 'IN' then
    v_deadline := make_date(case when extract(month from o.business_date) >= 4 then extract(year from o.business_date)::int + 1
                                 else extract(year from o.business_date)::int end, 11, 30);
    if v_day.business_date > v_deadline then
      raise exception 'Under GST rules a credit note for bill % could only be issued until %.', o.bill_number, to_char(v_deadline, 'DD Mon YYYY');
    end if;
  end if;

  select pm.kind into v_kind from public.payment_methods pm where pm.id = p_method_id and pm.restaurant_id = o.restaurant_id and pm.is_active;
  if not found then raise exception 'Choose how the money is given back.'; end if;
  if v_kind in ('gift_card', 'loyalty', 'advance') then raise exception 'Money cannot be given back to a gift card, points or an advance. Choose cash, UPI, card or another payment mode.'; end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_kind = 'cash' and v_shift is null then raise exception 'Open a shift before giving cash back.'; end if;

  v_ratio := case when o.grand_total > 0 then v_amount / o.grand_total else 0 end;
  select coalesce(jsonb_agg(jsonb_build_object('name', c, 'rate', r, 'amount', round(a * v_ratio, 2)) order by r, c), '[]'::jsonb),
         coalesce(sum(round(a * v_ratio, 2)), 0)
    into v_taxes, v_tax
    from (select component_name c, rate r, sum(tax_amount) a from public.order_item_taxes where order_id = o.id group by 1, 2) x;

  perform pg_advisory_xact_lock(hashtext('credit_note:' || o.branch_id::text));
  v_fy := app.fy_label(v_country, v_day.business_date);
  if v_country = 'IN' then v_fy := substr(v_fy, 3, 2) || substr(v_fy, 6, 2); end if;  -- 2026-27 -> 2627 (GST: max 16 characters)
  select code into v_code from public.branches where id = o.branch_id;
  select count(*) + 1 into v_seq from public.credit_notes
   where branch_id = o.branch_id and number like 'CN-' || v_code || '-' || v_fy || '-%';
  v_no := 'CN-' || v_code || '-' || v_fy || '-' || lpad(v_seq::text, 4, '0');

  insert into public.credit_notes (id, restaurant_id, branch_id, order_id, number, business_date, shift_id, amount,
                                   tax_amount, taxes, reason, payment_method_id, created_by)
  values (v_id, o.restaurant_id, o.branch_id, o.id, v_no, v_day.business_date, v_shift, v_amount, v_tax, v_taxes,
          left(trim(p_reason), 300), p_method_id, v_user);
  insert into public.refunds (id, restaurant_id, order_id, payment_id, amount, reason, approved_by, client_created_at,
                              shift_id, payment_method_id, credit_note_id)
  values (gen_random_uuid(), o.restaurant_id, o.id, null, v_amount, left(trim(p_reason), 300), v_user, now(),
          v_shift, p_method_id, v_id);

  perform set_config('app.day_ok', 'on', true);
  update public.orders set payment_status = case when v_done + v_amount >= o.paid_total then 'refunded' else 'partially_refunded' end
   where id = o.id;
  perform set_config('app.day_ok', 'off', true);

  perform app.audit('credit_note.issue', 'credit_notes', v_id,
    jsonb_build_object('number', v_no, 'bill_number', o.bill_number, 'amount', v_amount, 'tax', v_tax,
                       'method_kind', v_kind, 'reason', left(trim(p_reason), 300)));
  v_out := jsonb_build_object('credit_note_id', v_id, 'number', v_no, 'amount', v_amount, 'tax', v_tax,
                            'remaining', v_left - v_amount);
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result)
    values (app.current_restaurant_id(), p_client_ref, 'credit_note', p_order_id, v_out);
    -- Request ids only matter for a retry within minutes; old ones are cleared as new ones arrive.
    delete from public.request_refs
     where restaurant_id = app.current_restaurant_id() and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $function$
;

CREATE OR REPLACE FUNCTION public.issue_gift_card(p_value numeric, p_method_id uuid, p_phone text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_valid_days integer DEFAULT 365)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_kind text; v_drawer boolean; v_shift uuid; v_code text; v_id uuid; v_cust uuid; v_phone text := app.clean_phone(p_phone);
begin
  perform app.require_feature('loyalty');
  if coalesce(p_value, 0) <= 0 or p_value > 1000000 then raise exception 'Enter the gift card value.'; end if;
  select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_method_id and restaurant_id = v_rest and is_active;
  if not found or v_kind in ('gift_card', 'loyalty') then raise exception 'Choose how the guest paid for the card.'; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift before selling a gift card.'; end if;
  loop
    v_code := 'GC' || upper(substr(regexp_replace(app.new_token(12), '[^A-Za-z0-9]', '', 'g'), 1, 8));
    exit when length(v_code) = 10 and not exists (select 1 from public.gift_cards where restaurant_id = v_rest and code = v_code);
  end loop;
  if v_phone is not null then
    select id into v_cust from public.customers where restaurant_id = v_rest and phone = v_phone and deleted_at is null;
    if v_cust is null then
      insert into public.customers (restaurant_id, name, phone) values (v_rest, coalesce(nullif(left(trim(p_name), 80), ''), 'Guest'), v_phone) returning id into v_cust;
    end if;
  end if;
  insert into public.gift_cards (restaurant_id, code, value, expires_on, customer_id, sold_method_id, sold_branch_id, sold_shift_id, issued_by)
  values (v_rest, v_code, round(p_value, 2), case when coalesce(p_valid_days, 0) > 0 then app.local_today(v_rest) + p_valid_days end,
          v_cust, p_method_id, v_branch, v_shift, v_user)
  returning id into v_id;
  insert into public.gift_card_ledger (restaurant_id, gift_card_id, amount, kind, created_by) values (v_rest, v_id, round(p_value, 2), 'issue', v_user);
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', round(p_value, 2), 'Gift card sold ' || v_code, v_user);
  end if;
  perform app.audit('giftcard.issue', 'gift_cards', v_id, jsonb_build_object('code', v_code, 'value', p_value, 'method', v_kind), null);
  return jsonb_build_object('id', v_id, 'code', v_code, 'value', round(p_value, 2),
    'expires_on', case when coalesce(p_valid_days, 0) > 0 then app.local_today(v_rest) + p_valid_days end);
end $function$
;

CREATE OR REPLACE FUNCTION public.kiosk_add(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_name text := btrim(coalesce(p_name, '')); v_id uuid; v_token text := app.new_token();
begin
  perform app.require_feature('qr_ordering');
  if v_name = '' or length(v_name) > 20 then raise exception 'Give the kiosk a short name, for example Kiosk 1.'; end if;
  if exists (select 1 from public.dining_tables where branch_id = v_branch and lower(table_number) = lower(v_name) and is_active) then
    raise exception 'There is already a table or kiosk called %.', v_name;
  end if;
  insert into public.dining_tables (restaurant_id, branch_id, table_number, seats, is_kiosk, qr_token)
  values (v_rest, v_branch, v_name, 1, true, v_token)
  on conflict (branch_id, table_number) do update set is_active = true, is_kiosk = true, qr_token = coalesce(public.dining_tables.qr_token, excluded.qr_token)
  returning id, qr_token into v_id, v_token;
  return jsonb_build_object('id', v_id, 'name', v_name, 'token', v_token);
end $function$
;

CREATE OR REPLACE FUNCTION public.kiosk_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.table_number, 'token', t.qr_token, 'auto_user', t.kiosk_user_id, 'auto_user_name', u.full_name)
         order by t.table_number), '[]'::jsonb)
    from public.dining_tables t left join public.users u on u.id = t.kiosk_user_id
   where t.restaurant_id = app.current_restaurant_id() and t.branch_id = app.current_branch_id() and t.is_kiosk and t.is_active
     and app.allowed('settings.manage')
$function$
;

CREATE OR REPLACE FUNCTION public.kiosk_remove(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('settings.manage');
begin
  update public.dining_tables set is_active = false where id = p_id and is_kiosk and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That kiosk was not found.'; end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.kiosk_set_auto(p_id uuid, p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id();
begin
  if not exists (select 1 from public.dining_tables where id = p_id and restaurant_id = v_rest and is_kiosk and is_active) then
    raise exception 'That kiosk was not found.';
  end if;
  if p_user is not null and not exists (
       select 1 from public.users u join public.role_permissions rp on rp.role_id = u.role_id
        where u.id = p_user and u.restaurant_id = v_rest and u.is_active and u.deleted_at is null and rp.permission_key = 'order.create'
          and u.auth_user_id is not null) then
    raise exception 'Choose an active staff login that signs in with email and is allowed to take orders.';
  end if;
  update public.dining_tables set kiosk_user_id = p_user where id = p_id;
  perform app.audit('kiosk.auto_accept', 'dining_tables', p_id, jsonb_build_object('user', p_user), null);
end $function$
;

CREATE OR REPLACE FUNCTION public.liquor_prefix_info()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('uses_liquor', exists (select 1 from public.tax_groups where restaurant_id = app.current_restaurant_id() and separate_bill),
    'prefix', s.prefix, 'next_number', case when s.id is not null then s.prefix || '-' || lpad(s.next_seq::text, greatest(4, length(s.next_seq::text)), '0') end)
    from (select 1) one left join public.liquor_series s on s.branch_id = app.current_branch_id()
   where app.allowed('order.create')
$function$
;

CREATE OR REPLACE FUNCTION public.login_staff(p_client_code text, p_username text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rest   uuid;
  v_user   record;
  v_stored text;
  v_wait   int;
begin
  if coalesce(trim(p_client_code), '') = ''
     or coalesce(trim(p_username), '') = ''
     or coalesce(p_password, '') = '' then
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  select id into v_rest
    from public.restaurants
   where client_code = trim(p_client_code);
  if not found then
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  select u.id, u.full_name, u.email::text as email, u.role_id, u.is_active,
         u.must_change_password, u.auth_user_id, u.login_locked_until
    into v_user
    from public.users u
   where u.restaurant_id = v_rest
     and lower(u.employee_code) = lower(trim(p_username))
     and u.deleted_at is null;
  if not found then
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  if v_user.login_locked_until is not null
     and v_user.login_locked_until > now() then
    v_wait := ceil(extract(epoch from (v_user.login_locked_until - now())) / 60.0);
    return jsonb_build_object('error', 'locked', 'minutes', greatest(v_wait, 1));
  end if;

  -- PIN-only counter staff have no password sign-in. Answer exactly as for a
  -- wrong password, so the reply never says whether a username exists.
  if v_user.auth_user_id is null or v_user.email is null then
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  select a.encrypted_password into v_stored
    from auth.users a
   where a.id = v_user.auth_user_id;

  if v_stored is null
     or v_stored <> extensions.crypt(p_password, v_stored) then
    update public.users
       set login_failed_count = case
             when login_failed_count + 1 >= 5 then 0
             else login_failed_count + 1
           end,
           login_locked_until = case
             when login_failed_count + 1 >= 5 then now() + interval '5 minutes'
             else login_locked_until
           end
     where id = v_user.id;
    return jsonb_build_object('error', 'invalid_credentials');
  end if;

  if not v_user.is_active then
    return jsonb_build_object('error', 'inactive');
  end if;

  update public.users
     set login_failed_count = 0,
         login_locked_until = null
   where id = v_user.id;

  return jsonb_build_object(
    'email',                v_user.email,
    'user_id',              v_user.id,
    'restaurant_id',        v_rest,
    'full_name',            v_user.full_name,
    'must_change_password', coalesce(v_user.must_change_password, false)
  );
exception when others then
  return jsonb_build_object('error', 'invalid_credentials');
end $function$
;

CREATE OR REPLACE FUNCTION public.make_complimentary(p_order_id uuid, p_kind text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; p jsonb; v_c jsonb; v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 200), '');
  v_label text;
begin
  if p_kind is null or p_kind not in ('complimentary', 'staff_meal') then
    raise exception 'Choose complimentary or staff meal.';
  end if;
  v_label := case p_kind when 'complimentary' then 'complimentary' else 'a staff meal' end;
  if v_reason is null or length(v_reason) < 3 then
    raise exception 'Write a short reason (for example the guest''s name or the staff member''s name).';
  end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.comp_kind is not null then raise exception 'Bill % is already marked %.', o.bill_number, replace(o.comp_kind, '_', ' '); end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment, so it cannot be made %.', o.bill_number, v_label;
  end if;
  p := coalesce(o.calc_params, '{}'::jsonb);
  if p->'senior' is not null and p->'senior' <> 'null'::jsonb then
    raise exception 'Bill % has a senior citizen / PWD discount. Remove it first.', o.bill_number;
  end if;
  if not exists (select 1 from public.order_items where order_id = o.id and cancelled_at is null) or coalesce(o.subtotal, 0) <= 0 then
    raise exception 'Bill % has no items.', o.bill_number;
  end if;
  if not app.allowed('order.discount') then
    raise exception 'A manager must approve a complimentary bill or staff meal (order.discount).';
  end if;

  -- The whole bill comes off as one discount, the service charge is removed, and the total is worked out again.
  perform set_config('app.recalc', 'on', true);
  update public.orders set calc_params = p || jsonb_build_object('discount', o.subtotal, 'sc_percent', 0) where id = o.id;
  v_c := app.recalc_order(o.id);
  if (v_c->>'grand_total')::numeric <> 0 then
    raise exception 'Bill % could not be brought to zero (total %). Nothing was changed.', o.bill_number, (v_c->>'grand_total')::numeric;
  end if;

  delete from public.order_discounts where order_id = o.id and discount_type = 'fixed_amount';
  insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
  values (o.restaurant_id, o.id, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric,
          left(case p_kind when 'complimentary' then 'Complimentary: ' else 'Staff meal: ' end || v_reason, 200), v_user);

  update public.orders set payment_status = 'paid', comp_kind = p_kind, comp_reason = v_reason, comp_by = v_user
   where id = o.id;

  perform app.audit('order.complimentary', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'kind', p_kind, 'reason', v_reason,
                       'value', o.subtotal, 'grand_total', 0),
    jsonb_build_object('grand_total', o.grand_total, 'discount', coalesce((p->>'discount')::numeric, 0)));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'kind', p_kind, 'value', o.subtotal, 'grand_total', 0);
end $function$
;

CREATE OR REPLACE FUNCTION public.mark_tickets_printed(p_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n int;
begin
  if app.current_user_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  update public.kitchen_tickets set printed_at = coalesce(printed_at, now())
   where id = any(p_ids) and restaurant_id = app.current_restaurant_id();
  get diagnostics n = row_count;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.merge_orders(p_target_id uuid, p_source_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  t public.orders%rowtype; s public.orders%rowtype; v_c jsonb; r record;
begin
  perform app.require_feature('merge');
  if p_target_id = p_source_id then raise exception 'Choose two different bills to merge.'; end if;
  -- Lock in a fixed order so two people merging at once cannot deadlock.
  for r in select id from public.orders where id in (p_target_id, p_source_id)
            and restaurant_id = app.current_restaurant_id() order by id for update loop
  end loop;
  select * into t from public.orders where id = p_target_id and restaurant_id = app.current_restaurant_id();
  select * into s from public.orders where id = p_source_id and restaurant_id = app.current_restaurant_id();
  if t.id is null or s.id is null then raise exception 'Bill not found.'; end if;
  if t.branch_id <> s.branch_id then raise exception 'Only bills from the same branch can be merged.'; end if;
  if t.status = 'voided' or s.status = 'voided' then raise exception 'A voided bill cannot be merged.'; end if;
  if t.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', t.bill_number; end if;
  if s.payment_status <> 'unpaid' or app.order_covered(s.id) > 0 then
    raise exception 'Bill % already has a payment, so it cannot be merged into another bill.', s.bill_number;
  end if;
  if coalesce((s.calc_params->>'discount')::numeric, 0) > 0 or nullif(s.senior_details, 'null'::jsonb) is not null
     or exists (select 1 from public.order_discounts where order_id = s.id) then
    raise exception 'Bill % has a discount, so it cannot be merged.', s.bill_number;
  end if;

  update public.order_items set order_id = t.id where order_id = s.id;
  update public.order_item_taxes set order_id = t.id where order_id = s.id;
  update public.kitchen_tickets set order_id = t.id where order_id = s.id;

  perform set_config('app.recalc', 'on', true);
  update public.orders set status = 'voided', voided_by = v_user, voided_at = now(),
         void_reason = 'Merged into bill ' || t.bill_number, merged_into = t.id,
         subtotal = 0, discount_total = 0, tax_total = 0, tax_included = 0, tax_exempt_amount = 0,
         exempt_sales = 0, service_charge = 0, rounding_adjustment = 0, grand_total = 0
   where id = s.id;
  v_c := app.recalc_order(t.id);

  perform app.audit('order.merge', 'orders', t.id,
    jsonb_build_object('bill_number', t.bill_number, 'merged_from', s.bill_number, 'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', t.grand_total, 'source_total', s.grand_total));
  return jsonb_build_object('order_id', t.id, 'bill_number', t.bill_number, 'merged_from', s.bill_number,
                            'grand_total', (v_c->>'grand_total')::numeric);
end $function$
;

CREATE OR REPLACE FUNCTION public.move_order_table(p_order_id uuid, p_table_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; v_to text; v_from text; v_busy text;
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', o.bill_number; end if;
  select table_number into v_to from public.dining_tables
   where id = p_table_id and restaurant_id = o.restaurant_id and is_active;
  if not found then raise exception 'That table does not exist.'; end if;
  if o.dining_table_id = p_table_id then raise exception 'Bill % is already on table %.', o.bill_number, v_to; end if;
  select bill_number into v_busy from public.orders
   where dining_table_id = p_table_id and id <> o.id and status <> 'voided' and payment_status in ('unpaid', 'partial') limit 1;
  if v_busy is not null then
    raise exception 'Table % already has bill %. Use Merge to put the two bills together.', v_to, v_busy;
  end if;
  select table_number into v_from from public.dining_tables where id = o.dining_table_id;
  update public.orders set dining_table_id = p_table_id, order_type = 'dine_in' where id = o.id;
  perform app.audit('order.move_table', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'table', v_to), jsonb_build_object('table', v_from));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'table', v_to);
end $function$
;

CREATE OR REPLACE FUNCTION public.my_account_state()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case
    when auth.uid() is null then 'signed_out'
    when app.device_id() is not null then case when app.current_user_id() is null then 'device_locked' else 'active' end
    when exists (select 1 from public.devices where auth_user_id = auth.uid()) then 'device_removed'
    when exists (select 1 from public.users where auth_user_id = auth.uid() and deleted_at is null and is_active
                   and coalesce(must_change_password, false)) then 'must_change_password'
    when exists (select 1 from public.users where auth_user_id = auth.uid() and deleted_at is null and is_active) then 'active'
    when exists (select 1 from public.users where auth_user_id = auth.uid() and deleted_at is null) then 'deactivated'
    else 'new' end
$function$
;

CREATE OR REPLACE FUNCTION public.my_device_state()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case when d.id is null then jsonb_build_object('is_device', false)
  else jsonb_build_object('is_device', true, 'device_name', d.name, 'restaurant', r.trading_name,
    'unlocked_as', (select u.full_name from public.users u where u.id = app.current_user_id()))
  end
  from (select 1) one
  left join public.devices d on d.id = app.device_id()
  left join public.restaurants r on r.id = d.restaurant_id
$function$
;

CREATE OR REPLACE FUNCTION public.my_licence()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  if v_rest is null then return null; end if;
  return app.licence_state(v_rest, now());
end $function$
;

CREATE OR REPLACE FUNCTION public.my_outlets()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'current', app.current_branch_id(),
    'all_outlets', app.report_branch() is null,
    'can_all', app.device_id() is null and (app.is_owner() or not exists (select 1 from public.user_branches ub where ub.user_id = app.current_user_id())),
    'fixed', app.device_id() is not null,
    'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'city', b.city,
                   'central_kitchen', b.is_central_kitchen) order by b.created_at), '[]'::jsonb)
                  from public.branches b where b.restaurant_id = app.current_restaurant_id() and b.deleted_at is null and app.can_use_branch(b.id)))
$function$
;

CREATE OR REPLACE FUNCTION public.my_plan()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_r public.restaurants%rowtype;
begin
  select * into v_r from public.restaurants where id = app.current_restaurant_id();
  if not found then raise exception 'You are not signed in to a restaurant.'; end if;
  return jsonb_build_object(
    'edition', v_r.edition,
    'currency', v_r.currency_code,
    'prices', (select coalesce(jsonb_object_agg(item, monthly_price), '{}'::jsonb)
                 from public.plan_prices where currency_code = v_r.currency_code),
    'modules', (select jsonb_agg(jsonb_build_object('key', m.key, 'name', m.name, 'description', m.description,
                                   'kind', m.kind, 'on', app.feature_on(v_r.id, m.key)) order by m.display_order)
                  from public.modules m),
    'outlets', (select count(*) from public.branches where restaurant_id = v_r.id and deleted_at is null),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'module_key', q.module_key,
                   'outlet_name', q.outlet_name, 'status', q.status, 'created_at', q.created_at,
                   'decision_note', q.decision_note) order by q.created_at desc), '[]'::jsonb)
                   from (select * from public.plan_requests where restaurant_id = v_r.id order by created_at desc limit 20) q));
end $function$
;

CREATE OR REPLACE FUNCTION public.offline_snapshot(p_device_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_country text; v_tz text; ser public.offline_series; v_n int; v_menu jsonb; v_methods jsonb; v_bs record; v_r record; v_fy text;
begin
  if coalesce(p_device_key, '') !~ '^[0-9a-f-]{36}$' then raise exception 'Bad device key.'; end if;
  select r.*, coalesce(b.timezone, r.timezone) as tz into v_r from public.restaurants r join public.branches b on b.id = v_branch where r.id = v_rest;
  v_country := v_r.country_code; v_tz := v_r.tz;
  select * into ser from public.offline_series where branch_id = v_branch and device_key = p_device_key;
  if not found then
    perform pg_advisory_xact_lock(hashtext('offline_series:' || v_branch::text));
    select count(*) + 1 into v_n from public.offline_series where branch_id = v_branch;
    if v_n > 99 then raise exception 'Too many offline devices for this branch.'; end if;
    insert into public.offline_series (restaurant_id, branch_id, device_key, prefix)
    values (v_rest, v_branch, p_device_key, 'X' || lpad(v_n::text, 2, '0')) returning * into ser;
  end if;
  -- Offline bills follow the outlet's bill prefix: BILL26-X1-0001. A new prefix starts them again from 1.
  v_fy := (app.current_bill_series(v_branch)).prefix;
  if v_fy is distinct from ser.series_key then
    update public.offline_series set series_key = v_fy, fy = null, next_seq = 1 where id = ser.id returning * into ser;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'short_name', p.short_name, 'price', coalesce((select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = p.id), p.price), 'category_id', p.category_id,
      'category_name', c.name, 'is_veg', p.is_veg, 'station', coalesce(nullif(trim(p.kitchen_station), ''), 'Kitchen'),
      'inclusive', coalesce(g.is_price_inclusive, false),
      'comps', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'rate', t.rate, 'compound', t.is_compound) order by t.display_order)
                           from public.tax_rate_components t
                          where t.tax_rate_id = (select tr.id from public.tax_rates tr where tr.tax_group_id = p.tax_group_id
                                                   and tr.valid_from <= app.local_today(v_rest) and (tr.valid_to is null or tr.valid_to >= app.local_today(v_rest))
                                                 order by tr.valid_from desc limit 1)
                            and t.applies_when in ('always', 'intra_region')), '[]'::jsonb),
      'groups', coalesce((select jsonb_agg(jsonb_build_object('id', mg.id, 'name', mg.name,
                    'min', greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end), 'max', coalesce(mg.max_select, 99),
                    'options', (select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price', mi.price_delta) order by mi.display_order, mi.name), '[]'::jsonb)
                                  from public.modifier_items mi where mi.modifier_group_id = mg.id and mi.is_active)) order by mg.name)
                    from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id and mg.is_active
                   where pmg.product_id = p.id), '[]'::jsonb))
      order by c.display_order, c.name, p.display_order, p.name), '[]'::jsonb)
    into v_menu
    from public.products p join public.categories c on c.id = p.category_id
    left join public.tax_groups g on g.id = p.tax_group_id
   where p.restaurant_id = v_rest and p.deleted_at is null and p.is_available and c.deleted_at is null and coalesce((select bp.is_available from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = p.id), true);

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind, 'ask_reference', ask_reference, 'upi_id', upi_id) order by display_order), '[]'::jsonb)
    into v_methods from public.payment_methods where restaurant_id = v_rest and is_active and kind not in ('gift_card', 'loyalty');
  select coalesce(s.service_charge_percent, 0) pct, coalesce(s.service_charge_taxable, false) tx, coalesce(s.service_charge_default_on, false) def_on,
         coalesce(s.service_charge_label, 'Service charge') lbl, coalesce(s.cash_rounding_mode, 'none') rmode, coalesce(s.rounding_cash_only, false) rcash,
         s.receipt_header, s.receipt_footer, s.bill_format, s.packing_product_id, s.packing_per, s.packing_takeaway, s.packing_delivery
    into v_bs from public.branch_settings s where s.branch_id = v_branch;

  return jsonb_build_object(
    'taken_at', now(), 'device_key', p_device_key, 'user_id', v_user,
    'series', jsonb_build_object('prefix', 'X' || (substr(ser.prefix, 2)::int), 'fy', null, 'next_seq', ser.next_seq,
                                 'branch_code', ser.series_key, 'key', ser.series_key,
                                 'liquor_code', app.offline_liquor_code(v_branch), 'liquor_next_seq', ser.liquor_next_seq),
    'rights', jsonb_build_object('discount', app.has_permission('order.discount'), 'pay', app.has_permission('payment.take')),
    'menu', v_menu, 'methods', v_methods,
    'settings', jsonb_build_object('sc_percent', v_bs.pct, 'sc_taxable', v_bs.tx, 'sc_default_on', v_bs.def_on, 'sc_label', v_bs.lbl,
                                   'rounding', case when v_bs.rcash then 'none' else v_bs.rmode end,
                                   'cash_rounding', case when v_bs.rcash then v_bs.rmode else 'none' end,
                                   'packing', case when v_bs.packing_product_id is not null then jsonb_build_object(
                                     'product_id', v_bs.packing_product_id, 'per', v_bs.packing_per,
                                     'takeaway', v_bs.packing_takeaway, 'delivery', v_bs.packing_delivery) end),
    'receipt', jsonb_build_object('header', coalesce(v_bs.receipt_header, v_r.trading_name), 'legal_name', v_r.legal_name,
                                  'tax_id', v_r.tax_registration_no, 'tax_id_label', (select tax_id_label from public.countries where code = v_country),
                                  'fssai_no', case when v_country = 'IN' then v_r.fssai_no end, 'footer', v_bs.receipt_footer,
                                  'currency', v_r.currency_code, 'timezone', v_tz, 'country', v_country,
                                  'invoice_title', (select invoice_title from public.countries where code = v_country),
                                  'format', coalesce(v_bs.bill_format, '{}'::jsonb), 'logo', v_r.logo_url));
end $function$
;

CREATE OR REPLACE FUNCTION public.online_channel_save(p_channel text, p_url text, p_new_secret boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id();
  v_ch text := lower(btrim(coalesce(p_channel, ''))); v_url text := nullif(btrim(coalesce(p_url, '')), ''); v_secret text; v_had boolean;
begin
  if v_ch !~ '^[a-z0-9_]{2,20}$' then raise exception 'The channel is a short name such as swiggy, zomato or website.'; end if;
  if v_url is not null and (v_url !~ '^https://[^/\s]+' or length(v_url) > 300
      or v_url ~* '^https://(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|\[)') then
    raise exception 'Enter the partner''s https address (for example https://partner.example.com/sna).';
  end if;
  select true into v_had from public.online_channels where restaurant_id = v_rest and channel = v_ch;
  if coalesce(v_had, false) and not coalesce(p_new_secret, false) then
    update public.online_channels set callback_url = v_url, updated_at = now() where restaurant_id = v_rest and channel = v_ch;
  else
    v_secret := 'snasec_' || app.new_token(32);
    insert into public.online_channels (restaurant_id, channel, callback_url, secret) values (v_rest, v_ch, v_url, v_secret)
    on conflict (restaurant_id, channel) do update set callback_url = excluded.callback_url, secret = excluded.secret, updated_at = now();
  end if;
  perform app.audit('online.channel', 'restaurants', v_rest, jsonb_build_object('channel', v_ch, 'url', v_url, 'new_secret', v_secret is not null), null);
  return jsonb_build_object('channel', v_ch, 'url', v_url, 'secret', v_secret);
end $function$
;

CREATE OR REPLACE FUNCTION public.online_channels_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('channel', c.channel, 'url', c.callback_url, 'updated_at', c.updated_at) order by c.channel), '[]'::jsonb)
    from public.online_channels c where c.restaurant_id = app.current_restaurant_id() and app.allowed('settings.manage')
$function$
;

CREATE OR REPLACE FUNCTION public.online_order_accept(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare q public.online_orders; v_res jsonb; v_order uuid; v_due numeric;
begin
  perform app.require_permission('order.create');
  select * into q from public.online_orders where id = p_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'That online order was not found.'; end if;
  if q.status <> 'pending' then raise exception 'This online order was already %.', q.status; end if;
  if q.branch_id <> app.current_branch_id() then raise exception 'This order is for another outlet. Switch outlet first.'; end if;
  if q.note is not null then
    q.items := jsonb_set(q.items, '{0,note}', to_jsonb(left(concat_ws(' · ', nullif(q.items->0->>'note', ''), 'Customer: ' || q.note), 200)));
  end if;
  v_res := public.create_order(q.items, 'delivery', null, null, null, null, 0, null, null, null, null, null,
             jsonb_build_object('guest_name', q.customer_name, 'guest_phone', q.customer_phone, 'address', q.address));
  v_order := (v_res->>'order_id')::uuid;
  update public.orders set channel = q.channel where id = v_order;
  if q.paid_online then
    perform app.require_permission('payment.take');
    v_due := (select grand_total from public.orders where id = v_order) - app.order_covered(v_order);
    if v_due > 0 then perform public.pay_order(v_order, app.channel_method(q.restaurant_id, q.channel), v_due, v_due, q.channel || ' ' || q.external_ref, null); end if;
  end if;
  update public.online_orders set status = 'accepted', order_id = v_order, decided_by = app.current_user_id(), decided_at = now() where id = q.id;
  perform app.audit('online_order.accept', 'online_orders', q.id, jsonb_build_object('order_id', v_order, 'channel', q.channel), null);
  return v_res || jsonb_build_object('channel', q.channel);
end $function$
;

CREATE OR REPLACE FUNCTION public.online_order_callback(p_id uuid, p_event text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); q public.online_orders; c public.online_channels; v_body text;
begin
  if p_event not in ('accepted', 'rejected', 'ready') then raise exception 'Unknown event.'; end if;
  select * into q from public.online_orders where id = p_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That online order was not found.'; end if;
  select * into c from public.online_channels where restaurant_id = q.restaurant_id and channel = q.channel;
  if not found or c.callback_url is null then return null; end if;
  v_body := jsonb_build_object('event', p_event, 'channel', q.channel, 'order_id', q.external_ref,
              'bill_number', (select bill_number from public.orders where id = q.order_id),
              'reason', case when p_event = 'rejected' then q.reject_reason end,
              'at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))::text;
  return jsonb_build_object('url', c.callback_url, 'body', v_body, 'signature', encode(extensions.hmac(v_body, c.secret, 'sha256'), 'hex'));
end $function$
;

CREATE OR REPLACE FUNCTION public.online_order_mark_ready(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create');
begin
  update public.online_orders set ready_at = now()
   where id = p_id and restaurant_id = app.current_restaurant_id() and status = 'accepted' and ready_at is null;
  if not found then raise exception 'Only an accepted order that is not yet ready can be marked ready.'; end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.online_order_receive(p_key text, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare k public.api_keys%rowtype; v_rest uuid; v_branch uuid; v_calls int; v_channel text; v_ref text; v_items jsonb := '[]'::jsonb;
  x jsonb; v_prod uuid; v_id uuid; v_existing public.online_orders;
begin
  if coalesce(length(p_key), 0) < 20 or length(p_key) > 100 then raise exception 'Invalid API key.'; end if;
  select * into k from public.api_keys where key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex') and revoked_at is null;
  if not found then raise exception 'Invalid API key.'; end if;
  v_rest := k.restaurant_id;
  if not app.feature_on(v_rest, 'open_api') then raise exception 'The Open API is not switched on for this restaurant.'; end if;
  select count(*) into v_calls from public.api_calls where key_id = k.id and at > now() - interval '1 minute';
  if v_calls >= 120 then raise exception 'Too many requests: at most 120 per minute per key.'; end if;
  insert into public.api_calls (key_id, action) values (k.id, 'online_order');
  update public.api_keys set last_used_at = now() where id = k.id;

  v_channel := lower(btrim(coalesce(p->>'channel', '')));
  v_ref := btrim(coalesce(p->>'order_id', ''));
  if v_channel !~ '^[a-z0-9_]{2,20}$' then raise exception 'channel must be a short name such as swiggy, zomato or website.'; end if;
  if v_ref = '' or length(v_ref) > 60 then raise exception 'order_id (the partner''s order number) is needed.'; end if;
  select * into v_existing from public.online_orders where restaurant_id = v_rest and channel = v_channel and external_ref = v_ref;
  if found then return jsonb_build_object('id', v_existing.id, 'status', v_existing.status, 'repeat', true); end if;

  if nullif(btrim(coalesce(p->>'outlet_code', '')), '') is not null then
    select id into v_branch from public.branches where restaurant_id = v_rest and deleted_at is null and upper(code) = upper(btrim(p->>'outlet_code'));
    if v_branch is null then raise exception 'No outlet with the code %.', p->>'outlet_code'; end if;
  else
    select id into v_branch from public.branches where restaurant_id = v_rest and deleted_at is null order by created_at limit 1;
  end if;

  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'The order has no items.'; end if;
  if jsonb_array_length(p->'items') > 50 then raise exception 'At most 50 lines per order.'; end if;
  for x in select * from jsonb_array_elements(p->'items') loop
    v_prod := null;
    if coalesce(x->>'product_id', '') ~* '^[0-9a-f-]{36}$' then
      select id into v_prod from public.products where id = (x->>'product_id')::uuid and restaurant_id = v_rest and deleted_at is null;
    elsif nullif(x->>'item_code', '') is not null then
      select id into v_prod from public.products where restaurant_id = v_rest and barcode = x->>'item_code' and deleted_at is null;
    end if;
    if v_prod is null then raise exception 'Item % is not on the menu. Send product_id or item_code from GET /api/v1/menu.', coalesce(x->>'product_id', x->>'item_code', '?'); end if;
    if coalesce((x->>'qty')::numeric, 0) <= 0 or (x->>'qty')::numeric > 99 then raise exception 'Each qty must be 1 to 99.'; end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object('product_id', v_prod, 'qty', (x->>'qty')::numeric,
                 'note', left(coalesce(x->>'note', ''), 120),
                 'options', coalesce(case when jsonb_typeof(x->'options') = 'array' then x->'options' end, '[]'::jsonb)));
  end loop;
  -- The items and options must be valid now (sold-out dishes, required choices…).
  perform app.bill_input(v_rest, v_branch, v_items, 0, null, null);

  insert into public.online_orders (restaurant_id, branch_id, channel, external_ref, items, customer_name, customer_phone, address, note, paid_online, partner_total)
  values (v_rest, v_branch, v_channel, v_ref, v_items,
          nullif(left(btrim(coalesce(p->'customer'->>'name', '')), 80), ''), nullif(left(btrim(coalesce(p->'customer'->>'phone', '')), 20), ''),
          nullif(left(btrim(coalesce(p->'customer'->>'address', '')), 300), ''), nullif(left(btrim(coalesce(p->>'note', '')), 200), ''),
          coalesce((p->>'paid_online')::boolean, false), case when coalesce(p->>'total', '') ~ '^[0-9]+(\.[0-9]{1,2})?$' then (p->>'total')::numeric end)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'status', 'pending', 'repeat', false);
end $function$
;

CREATE OR REPLACE FUNCTION public.online_order_reject(p_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create');
begin
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Give a reason, for example Item not available.'; end if;
  update public.online_orders set status = 'rejected', reject_reason = left(btrim(p_reason), 200), decided_by = v_user, decided_at = now()
   where id = p_id and restaurant_id = app.current_restaurant_id() and status = 'pending';
  if not found then raise exception 'That online order is not waiting.'; end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.online_orders_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'channel', q.channel, 'external_ref', q.external_ref, 'status', q.status,
           'customer_name', q.customer_name, 'customer_phone', q.customer_phone, 'address', q.address, 'note', q.note,
           'paid_online', q.paid_online, 'partner_total', q.partner_total, 'created_at', q.created_at, 'reject_reason', q.reject_reason,
           'bill_number', o.bill_number, 'order_id', q.order_id, 'ready_at', q.ready_at,
           'items', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'qty', (i->>'qty')::numeric, 'note', nullif(i->>'note', ''))), '[]'::jsonb)
                       from jsonb_array_elements(q.items) i join public.products p on p.id = (i->>'product_id')::uuid))
         order by q.status <> 'pending', q.created_at desc), '[]'::jsonb)
    from public.online_orders q left join public.orders o on o.id = q.order_id
   where q.restaurant_id = app.current_restaurant_id() and q.branch_id = app.current_branch_id() and app.allowed('order.create')
     and (q.status = 'pending' or q.created_at > now() - interval '24 hours')
$function$
;

CREATE OR REPLACE FUNCTION public.open_shift(p_opening_float numeric DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('shift.open');
  v_branch uuid := app.current_branch_id();
  v_id uuid := gen_random_uuid();
begin
  if coalesce(p_opening_float,0) < 0 then
    raise exception 'The opening cash cannot be negative.';
  end if;
  perform 1 from public.shifts where branch_id = v_branch and status = 'open' for update;
  if found then
    raise exception 'A shift is already open. Close it before opening a new one.';
  end if;
  insert into public.shifts
    (id, restaurant_id, branch_id, device_id, opened_by, opening_float, opened_at, status)
  values
    (v_id, app.current_restaurant_id(), v_branch,
     (select id from public.devices where branch_id = v_branch and is_active order by created_at limit 1),
     v_user, coalesce(p_opening_float,0), now(), 'open');
  perform app.audit('shift.open', 'shifts', v_id,
    jsonb_build_object('opening_float', coalesce(p_opening_float,0)));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.outlet_comparison(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  perform app.require_permission('report.view_sales');
  perform app.require_feature('multi_outlet');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a valid date range (one year or less).'; end if;
  return (select coalesce(jsonb_agg(x order by (x->>'total')::numeric desc), '[]'::jsonb) from (
    select jsonb_build_object('outlet', b.name, 'code', b.code,
      'bills', count(o.id) filter (where o.status = 'completed'),
      'total', coalesce(sum(o.grand_total) filter (where o.status = 'completed'), 0),
      'average', coalesce(round(avg(o.grand_total) filter (where o.status = 'completed'), 2), 0),
      'discounts', coalesce(sum(o.discount_total) filter (where o.status = 'completed'), 0),
      'voids', count(o.id) filter (where o.status = 'voided'),
      'void_value', coalesce(sum(o.grand_total) filter (where o.status = 'voided'), 0)) x
      from public.branches b
      left join public.orders o on o.branch_id = b.id and o.merged_into is null and o.business_date between p_from and p_to
     where b.restaurant_id = v_rest and b.deleted_at is null and app.can_use_branch(b.id)
     group by b.id, b.name, b.code) z);
end $function$
;

CREATE OR REPLACE FUNCTION public.outlet_set_region(p_branch uuid, p_region text, p_royalty numeric DEFAULT 0)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('settings.manage');
begin
  perform app.require_feature('multi_outlet');
  if coalesce(p_royalty, 0) < 0 or coalesce(p_royalty, 0) > 100 then raise exception 'Royalty is 0 to 100 percent.'; end if;
  update public.branches set region = nullif(btrim(coalesce(p_region, '')), ''), royalty_percent = round(coalesce(p_royalty, 0), 2)
   where id = p_branch and restaurant_id = app.current_restaurant_id() and deleted_at is null;
  if not found then raise exception 'Outlet not found.'; end if;
  perform app.audit('outlet.region', 'branches', p_branch, jsonb_build_object('region', p_region, 'royalty', p_royalty), null);
end $function$
;

CREATE OR REPLACE FUNCTION public.password_changed()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare u public.users%rowtype; v_now text;
begin
  select * into u from public.users where auth_user_id = auth.uid() and deleted_at is null;
  if u.id is null then return; end if;
  select encrypted_password into v_now from auth.users where id = auth.uid();
  if u.password_reset_hash is not null and v_now is not distinct from u.password_reset_hash then
    raise exception 'Choose a new password first.';
  end if;
  update public.users set must_change_password = false, password_reset_hash = null where id = u.id;
  insert into public.audit_logs (restaurant_id, user_id, action, entity_type, entity_id, actor_type)
  values (u.restaurant_id, u.id, 'user.password_changed', 'users', u.id, 'user');
end $function$
;

CREATE OR REPLACE FUNCTION public.pay_back_gift_card(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.refund'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  g public.gift_cards%rowtype; v_bal numeric; v_shift uuid;
begin
  perform app.require_feature('loyalty');
  select * into g from public.gift_cards where restaurant_id = v_rest and code = upper(trim(p_code)) for update;
  if not found then raise exception 'No card with that code.'; end if;
  v_bal := app.gift_balance(g.id);
  if v_bal <= 0 then raise exception 'Card % has no balance to pay back.', g.code; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift first.'; end if;
  insert into public.gift_card_ledger (restaurant_id, gift_card_id, amount, kind, created_by) values (v_rest, g.id, -v_bal, 'payback', v_user);
  insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
  values (v_rest, v_shift, 'out', v_bal, 'Card balance paid back ' || g.code, v_user);
  perform app.audit('giftcard.payback', 'gift_cards', g.id, jsonb_build_object('code', g.code, 'amount', v_bal), null);
  return jsonb_build_object('code', g.code, 'paid_back', v_bal, 'balance', 0);
end $function$
;

CREATE OR REPLACE FUNCTION public.pay_order(p_order_id uuid, p_payment_method_id uuid, p_tendered numeric DEFAULT NULL::numeric, p_amount numeric DEFAULT NULL::numeric, p_reference text DEFAULT NULL::text, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('payment.take');
  o public.orders%rowtype; v_kind text; v_shift uuid; v_rmode text; v_rcash boolean;
  v_balance numeric(14,2); v_amount numeric(14,2); v_round numeric(14,2) := 0; v_change numeric(14,2) := 0; v_full boolean;
begin
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('pay_ref:' || p_client_ref::text));
    select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id();
    if exists (select 1 from public.payments p where p.restaurant_id = app.current_restaurant_id() and p.client_ref = p_client_ref) then
      return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'amount', 0, 'cash_rounding', 0, 'change', 0,
        'paid', o.payment_status = 'paid', 'balance', o.grand_total - app.order_covered(o.id), 'repeat', true);
    end if;
  end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status not in ('unpaid', 'partial') then raise exception 'Bill % is already paid.', o.bill_number; end if;
  select pm.kind into v_kind from public.payment_methods pm
   where pm.id = p_payment_method_id and pm.restaurant_id = o.restaurant_id and pm.is_active;
  if not found then raise exception 'That payment method is not available.'; end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_shift is null then raise exception 'Open a shift before taking payments.'; end if;

  v_balance := o.grand_total - app.order_covered(o.id);
  if v_balance <= 0 then raise exception 'Bill % has nothing left to pay.', o.bill_number; end if;

  if p_amount is null or round(p_amount, 2) = v_balance then
    v_full := true;
    v_amount := v_balance;
    select coalesce(cash_rounding_mode, 'none'), coalesce(rounding_cash_only, false) into v_rmode, v_rcash
      from public.branch_settings where branch_id = o.branch_id;
    if v_kind = 'cash' and coalesce(v_rcash, false) and coalesce(v_rmode, 'none') <> 'none' then
      v_amount := app.round_cash(v_balance, v_rmode);
      if v_amount <= 0 then v_amount := v_balance; end if;
      v_round := v_amount - v_balance;
    end if;
  else
    if round(p_amount, 2) <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
    if round(p_amount, 2) > v_balance then
      raise exception 'Only % is left to pay on bill %. For cash, enter the cash received below to work out the change.', v_balance, o.bill_number;
    end if;
    v_full := false;
    v_amount := round(p_amount, 2);
  end if;

  if p_tendered is not null then
    if p_tendered < v_amount then
      raise exception 'Cash received (%) is less than the amount due (%).', p_tendered, v_amount;
    end if;
    v_change := p_tendered - v_amount;
  end if;

  insert into public.payments
    (id, restaurant_id, order_id, payment_method_id, amount, currency_code, tendered_amount,
     change_amount, status, received_by, client_created_at, rounding_adjustment, reference_no, client_ref)
  values
    (gen_random_uuid(), o.restaurant_id, o.id, p_payment_method_id, v_amount, o.currency_code,
     p_tendered, v_change, 'captured', v_user, now(), v_round, nullif(left(trim(p_reference), 60), ''), p_client_ref);

  update public.orders set paid_total = paid_total + v_amount,
      payment_status = case when v_full then 'paid' else 'partial' end,
      shift_id = case when exists (select 1 from public.shifts s where s.id = o.shift_id and s.status = 'open')
                      then o.shift_id else v_shift end
   where id = o.id;

  perform app.audit('order.pay', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'amount', v_amount, 'method_kind', v_kind, 'full', v_full));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'amount', v_amount,
                            'cash_rounding', v_round, 'change', v_change, 'paid', v_full,
                            'balance', case when v_full then 0 else v_balance - v_amount end);
end $function$
;

CREATE OR REPLACE FUNCTION public.pay_supplier(p_receipt_id uuid, p_amount numeric, p_method text, p_reference text DEFAULT NULL::text, p_paid_on date DEFAULT NULL::date, p_from_till boolean DEFAULT false, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('stock.manage'); v_seen jsonb;
begin
  perform app.require_feature('stock');
  if not exists (select 1 from public.goods_receipts g where g.id = p_receipt_id
                    and g.restaurant_id = app.current_restaurant_id() and g.branch_id = app.current_branch_id()) then
    raise exception 'Goods receipt not found.';
  end if;
  -- The same request sent twice (a second tap, a retry on a bad connection) pays once.
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('supplier_pay_ref:' || p_client_ref::text));
    select jsonb_build_object('payment_id', sp.id, 'amount', sp.amount, 'balance', g.total - g.paid_total,
                              'paid', g.total - g.paid_total = 0, 'repeat', true)
      into v_seen
      from public.supplier_payments sp join public.goods_receipts g on g.id = sp.goods_receipt_id
     where sp.restaurant_id = app.current_restaurant_id() and sp.client_ref = p_client_ref;
    if v_seen is not null then
      if not exists (select 1 from public.supplier_payments sp where sp.restaurant_id = app.current_restaurant_id()
                        and sp.client_ref = p_client_ref and sp.goods_receipt_id = p_receipt_id) then
        raise exception 'This request was already used for another receipt. Close the form, open it again and try once more.';
      end if;
      return v_seen;
    end if;
  end if;
  return app.pay_goods_receipt(p_receipt_id, p_amount, p_method, p_reference, p_paid_on, p_from_till, v_user, p_client_ref);
end $function$
;

CREATE OR REPLACE FUNCTION public.pin_lock()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  delete from public.pin_sessions where device_id = app.device_id();
$function$
;

CREATE OR REPLACE FUNCTION public.pin_touch()
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with t as (
    update public.pin_sessions set last_activity_at = now()
     where device_id = app.device_id() and expires_at > now()
       and last_activity_at > now() - interval '10 minutes'
    returning 1)
  select exists (select 1 from t)
$function$
;

CREATE OR REPLACE FUNCTION public.pin_unlock(p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_dev uuid := app.device_id(); d public.devices%rowtype; v_fail int; v_fail_day int; u public.users%rowtype; v_role text;
begin
  if v_dev is null then raise exception 'This device is not set up as a counter.'; end if;
  select * into d from public.devices where id = v_dev;
  delete from public.pin_attempts where at < now() - interval '1 day';
  select count(*) filter (where at > now() - interval '5 minutes'), count(*)
    into v_fail, v_fail_day from public.pin_attempts where device_id = v_dev and not ok;
  if v_fail_day >= 15 then
    return jsonb_build_object('ok', false, 'error',
      'Too many wrong PINs today. A manager must clear the lock in Settings → Counter tablets.');
  end if;
  if v_fail >= 5 then
    return jsonb_build_object('ok', false, 'error', 'Too many wrong PINs. Wait 5 minutes, then try again.');
  end if;
  if coalesce(p_pin, '') ~ '^\d{4,6}$' then
    select * into u from public.users
     where restaurant_id = d.restaurant_id and deleted_at is null and is_active
       and pin_hash = app.pin_hash(d.restaurant_id, p_pin);
  end if;
  if u.id is null then
    insert into public.pin_attempts (device_id, ok) values (v_dev, false);
    if v_fail_day + 1 >= 15 then
      insert into public.audit_logs (restaurant_id, branch_id, action, entity_type, entity_id, actor_type, new_value)
      values (d.restaurant_id, d.branch_id, 'device.pin_lockout', 'devices', v_dev, 'system', jsonb_build_object('device', d.name));
      return jsonb_build_object('ok', false, 'error',
        'Wrong PIN. This tablet is now locked. A manager must clear it in Settings → Counter tablets.');
    end if;
    return jsonb_build_object('ok', false, 'error',
      case when v_fail + 1 >= 5 then 'Wrong PIN. Too many tries — wait 5 minutes.'
           else 'Wrong PIN. ' || (5 - v_fail - 1) || ' tries left.' end);
  end if;
  insert into public.pin_attempts (device_id, ok) values (v_dev, true);
  insert into public.pin_sessions (device_id, restaurant_id, user_id, started_at, expires_at, last_activity_at)
  values (v_dev, d.restaurant_id, u.id, now(), now() + interval '12 hours', now())
  on conflict (device_id) do update set user_id = excluded.user_id, restaurant_id = excluded.restaurant_id,
    started_at = excluded.started_at, expires_at = excluded.expires_at, last_activity_at = excluded.last_activity_at;
  update public.users set last_login_at = now() where id = u.id;
  update public.devices set last_seen_at = now() where id = v_dev;
  select name into v_role from public.roles where id = u.role_id;
  insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, actor_type, new_value)
  values (d.restaurant_id, d.branch_id, u.id, 'device.unlock', 'devices', v_dev, 'user', jsonb_build_object('device', d.name));
  return jsonb_build_object('ok', true, 'name', u.full_name, 'role', v_role,
    'can_bill', exists (select 1 from public.role_permissions where role_id = u.role_id and permission_key = 'order.create'));
end $function$
;

CREATE OR REPLACE FUNCTION public.pre_order_advance(p_id uuid, p_method uuid, p_amount numeric, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('payment.take');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  r public.pre_orders; v_kind text; v_drawer boolean; v_shift uuid; v_amt numeric(14,2) := round(coalesce(p_amount, 0), 2);
begin
  select * into r from public.pre_orders where id = p_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Pre-order not found.'; end if;
  if r.status <> 'booked' then raise exception 'Pre-order % is already %.', r.number, r.status; end if;
  if v_amt <= 0 then raise exception 'Enter the advance amount.'; end if;
  select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_method and restaurant_id = v_rest and is_active;
  if not found or v_kind in ('gift_card', 'loyalty', 'advance') then raise exception 'Choose how the guest paid the advance.'; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift before taking an advance.'; end if;
  insert into public.pre_order_payments (restaurant_id, pre_order_id, kind, payment_method_id, amount, reference, shift_id, created_by)
  values (v_rest, r.id, 'advance', p_method, v_amt, nullif(left(btrim(coalesce(p_reference, '')), 60), ''), v_shift, v_user);
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', v_amt, 'Pre-order PO-' || r.number || ' advance', v_user);
  end if;
  perform app.audit('preorder.advance', 'pre_orders', r.id, jsonb_build_object('number', r.number, 'amount', v_amt, 'method', v_kind), null);
  return jsonb_build_object('held', app.pre_order_held(r.id));
end $function$
;

CREATE OR REPLACE FUNCTION public.pre_order_bill(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id();
  r public.pre_orders; v_res jsonb; o public.orders; v_held numeric(14,2); v_apply numeric(14,2); v_shift uuid; v_method uuid;
  v_extra numeric(14,2); v_give numeric(14,2); a record; v_kind text; v_drawer boolean;
begin
  select * into r from public.pre_orders where id = p_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Pre-order not found.'; end if;
  if r.status <> 'booked' then raise exception 'Pre-order % is already %.', r.number, r.status; end if;
  v_res := public.create_order(r.items, r.order_type, null::uuid,
            p_extra := jsonb_strip_nulls(jsonb_build_object('guest_name', r.guest_name, 'guest_phone', r.guest_phone, 'address', r.address)));
  select * into o from public.orders where id = (v_res->>'order_id')::uuid;
  v_held := app.pre_order_held(r.id);
  v_apply := least(v_held, o.grand_total);
  if v_apply > 0 then
    v_method := app.advance_method(v_rest);
    select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
    perform set_config('app.advance', 'on', true);
    insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, status, received_by, client_created_at, reference_no)
    values (gen_random_uuid(), o.restaurant_id, o.id, v_method, v_apply, o.currency_code, 'captured', v_user, now(), 'PO-' || r.number);
    perform set_config('app.advance', 'off', true);
    update public.orders set paid_total = paid_total + v_apply,
           payment_status = case when v_apply >= o.grand_total then 'paid' else 'partial' end,
           shift_id = coalesce(o.shift_id, v_shift)
     where id = o.id;
  end if;
  -- An advance above the bill: the extra is handed back, by the way it came in (newest advance first), and written down.
  v_extra := v_held - v_apply;
  if v_extra > 0 then
    select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
    for a in select p.payment_method_id, sum(case when p.kind = 'advance' then p.amount else -p.amount end) as net
               from public.pre_order_payments p where p.pre_order_id = r.id group by p.payment_method_id
             having sum(case when p.kind = 'advance' then p.amount else -p.amount end) > 0
              order by max(p.created_at) desc, p.payment_method_id loop
      exit when v_extra <= 0;
      v_give := least(a.net, v_extra);
      select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = a.payment_method_id;
      if (v_kind = 'cash' or coalesce(v_drawer, false)) and v_shift is null then
        raise exception 'Open a shift first: the advance is more than the bill, and % has to be handed back from the till.', v_extra;
      end if;
      insert into public.pre_order_payments (restaurant_id, pre_order_id, kind, payment_method_id, amount, shift_id, created_by)
      values (v_rest, r.id, 'refund', a.payment_method_id, v_give, v_shift, v_user);
      if v_kind = 'cash' or coalesce(v_drawer, false) then
        insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
        values (v_rest, v_shift, 'out', v_give, 'Pre-order PO-' || r.number || ' advance above the bill handed back', v_user);
      end if;
      v_extra := v_extra - v_give;
    end loop;
  end if;
  update public.pre_orders set status = 'billed', order_id = o.id, updated_at = now() where id = r.id;
  perform app.audit('preorder.bill', 'pre_orders', r.id, jsonb_build_object('number', r.number, 'bill', o.bill_number, 'advance_applied', v_apply), null);
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'total', o.grand_total, 'advance_applied', v_apply,
                            'balance', o.grand_total - v_apply, 'advance_left_over', v_held - v_apply, 'advance_handed_back', v_held - v_apply - v_extra);
end $function$
;

CREATE OR REPLACE FUNCTION public.pre_order_cancel(p_id uuid, p_reason text, p_refund_method uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  r public.pre_orders; v_held numeric(14,2); v_kind text; v_drawer boolean; v_shift uuid;
begin
  select * into r from public.pre_orders where id = p_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Pre-order not found.'; end if;
  if r.status <> 'booked' then raise exception 'Pre-order % is already %.', r.number, r.status; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'Enter why the pre-order is cancelled.'; end if;
  v_held := app.pre_order_held(r.id);
  if v_held > 0 then
    perform app.require_permission('payment.take');
    select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_refund_method and restaurant_id = v_rest and is_active;
    if not found or v_kind in ('gift_card', 'loyalty', 'advance') then raise exception 'Choose how the advance of % is given back.', v_held; end if;
    select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
    if v_shift is null then raise exception 'Open a shift before refunding an advance.'; end if;
    insert into public.pre_order_payments (restaurant_id, pre_order_id, kind, payment_method_id, amount, shift_id, created_by)
    values (v_rest, r.id, 'refund', p_refund_method, v_held, v_shift, v_user);
    if v_kind = 'cash' or coalesce(v_drawer, false) then
      insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
      values (v_rest, v_shift, 'out', v_held, 'Pre-order PO-' || r.number || ' advance refunded', v_user);
    end if;
  end if;
  update public.pre_orders set status = 'cancelled', cancel_reason = left(btrim(p_reason), 200), updated_at = now() where id = r.id;
  perform app.audit('preorder.cancel', 'pre_orders', r.id, jsonb_build_object('number', r.number, 'refund', v_held, 'reason', p_reason), null);
  return jsonb_build_object('refunded', v_held);
end $function$
;

CREATE OR REPLACE FUNCTION public.pre_order_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_id uuid := nullif(p->>'id', '')::uuid; v_due timestamptz; v_in jsonb; v_c jsonb; v_est numeric; r public.pre_orders; v_no int;
  v_type text := coalesce(nullif(p->>'order_type', ''), 'takeaway');
begin
  if v_branch is null then raise exception 'No outlet chosen.'; end if;
  if coalesce(btrim(p->>'guest_name'), '') = '' then raise exception 'Enter the guest''s name.'; end if;
  begin v_due := (p->>'due_at')::timestamptz; exception when others then raise exception 'Enter when the order is due.'; end;
  if v_due is null then raise exception 'Enter when the order is due.'; end if;
  if v_id is null and v_due < now() then raise exception 'The due time is in the past.'; end if;
  if v_due > now() + interval '180 days' then raise exception 'A pre-order can be at most 180 days ahead.'; end if;
  if v_type = 'delivery' and coalesce(btrim(p->>'address'), '') = '' then raise exception 'Enter the delivery address.'; end if;
  -- the same checks as a bill: dishes on the menu, options, sizes
  v_in := app.bill_input(v_rest, v_branch, p->'items', 0, null, null);
  v_c := app.calc_bill(v_in->'calc');
  v_est := coalesce((v_c->>'grand_total')::numeric, 0);
  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('pre_order_no:' || v_rest::text));
    select coalesce(max(number), 0) + 1 into v_no from public.pre_orders where restaurant_id = v_rest;
    insert into public.pre_orders (restaurant_id, branch_id, number, guest_name, guest_phone, due_at, order_type, address, note, items, estimate, created_by)
    values (v_rest, v_branch, v_no, btrim(p->>'guest_name'), app.clean_phone(p->>'guest_phone'), v_due, v_type,
            nullif(btrim(coalesce(p->>'address', '')), ''), nullif(btrim(coalesce(p->>'note', '')), ''), p->'items', v_est, v_user)
    returning * into r;
  else
    update public.pre_orders set guest_name = btrim(p->>'guest_name'), guest_phone = app.clean_phone(p->>'guest_phone'), due_at = v_due,
           order_type = v_type, address = nullif(btrim(coalesce(p->>'address', '')), ''), note = nullif(btrim(coalesce(p->>'note', '')), ''),
           items = p->'items', estimate = v_est, updated_at = now()
     where id = v_id and restaurant_id = v_rest and status = 'booked' returning * into r;
    if not found then raise exception 'That pre-order is not open for changes.'; end if;
  end if;
  return jsonb_build_object('id', r.id, 'number', r.number, 'estimate', r.estimate);
end $function$
;

CREATE OR REPLACE FUNCTION public.pre_orders_list(p_status text DEFAULT 'booked'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'number', r.number, 'guest_name', r.guest_name, 'guest_phone', r.guest_phone, 'due_at', r.due_at,
             'order_type', r.order_type, 'address', r.address, 'note', r.note, 'items', r.items, 'estimate', r.estimate,
             'status', r.status, 'order_id', r.order_id, 'bill_number', (select bill_number from public.orders where id = r.order_id),
             'advance', app.pre_order_held(r.id), 'created_at', r.created_at,
             'lines', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'qty', (x->>'qty')::numeric, 'note', x->>'note',
                         'options', (select string_agg(mi.name, ', ') from jsonb_array_elements_text(coalesce(x->'options', '[]')) oid
                                       join public.modifier_items mi on mi.id = oid::uuid))), '[]'::jsonb)
                         from jsonb_array_elements(r.items) x join public.products p on p.id = (x->>'product_id')::uuid))
             order by r.due_at)
      from public.pre_orders r
     where r.restaurant_id = v_rest and r.branch_id = app.current_branch_id()
       and (p_status = 'all' or r.status = p_status)
       and (p_status = 'booked' or r.created_at > now() - interval '60 days')), '[]'::jsonb);
end $function$
;

CREATE OR REPLACE FUNCTION public.price_rules_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) - 'restaurant_id' - 'created_by' order by x.is_active desc, x.start_time, x.name)
                     from public.price_rules x where x.restaurant_id = v_rest), '[]'::jsonb);
end $function$
;

CREATE OR REPLACE FUNCTION public.public_receipt(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.purchase_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_branch uuid; v_today date; v_sup jsonb; v_owed jsonb; v_items jsonb; v_tot jsonb;
begin
  perform app.require_feature('stock');
  perform app.require_permission('stock.manage');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;

  select coalesce(jsonb_agg(x order by (x->>'total')::numeric desc), '[]'::jsonb) into v_sup from (
    select jsonb_build_object('supplier_id', s.id, 'supplier', s.name, 'receipts', count(*),
             'total', sum(g.total), 'paid', sum(g.paid_total), 'owed', sum(g.total - g.paid_total)) x
      from public.goods_receipts g join public.suppliers s on s.id = g.supplier_id
     where g.restaurant_id = v_rest and g.branch_id = v_branch and g.status = 'received'
       and g.received_on between p_from and p_to
     group by s.id, s.name) z;

  -- Everything still owed, whenever it was received.
  select coalesce(jsonb_agg(x order by (x->>'due_on')), '[]'::jsonb) into v_owed from (
    select jsonb_build_object('id', g.id, 'number', g.number, 'supplier_id', s.id, 'supplier', s.name,
             'bill_no', g.supplier_bill_no, 'received_on', g.received_on, 'due_on', g.due_on,
             'total', g.total, 'paid', g.paid_total, 'owed', g.total - g.paid_total,
             'overdue', g.due_on is not null and g.due_on < v_today) x
      from public.goods_receipts g join public.suppliers s on s.id = g.supplier_id
     where g.restaurant_id = v_rest and g.branch_id = v_branch and g.status = 'received' and g.total > g.paid_total) z;

  select coalesce(jsonb_agg(x order by (x->>'amount')::numeric desc), '[]'::jsonb) into v_items from (
    select jsonb_build_object('ingredient', i.name, 'unit', i.unit, 'category', i.category,
             'qty', sum(l.qty), 'amount', sum(l.line_total),
             'avg_cost', case when sum(l.qty) > 0 then round(sum(l.line_total) / sum(l.qty), 4) end) x
      from public.goods_receipt_lines l
      join public.goods_receipts g on g.id = l.goods_receipt_id
      join public.ingredients i on i.id = l.ingredient_id
     where g.restaurant_id = v_rest and g.branch_id = v_branch and g.status = 'received'
       and g.received_on between p_from and p_to
     group by i.id, i.name, i.unit, i.category) z;

  select jsonb_build_object(
      'receipts', count(*) filter (where g.received_on between p_from and p_to),
      'bought', coalesce(sum(g.total) filter (where g.received_on between p_from and p_to), 0),
      'owed', coalesce(sum(g.total - g.paid_total), 0),
      'overdue', coalesce(sum(g.total - g.paid_total) filter (where g.due_on < v_today), 0))
    into v_tot
    from public.goods_receipts g
   where g.restaurant_id = v_rest and g.branch_id = v_branch and g.status = 'received';

  return jsonb_build_object('from', p_from, 'to', p_to, 'totals', v_tot, 'by_supplier', v_sup, 'owed', v_owed, 'by_ingredient', v_items);
end $function$
;

CREATE OR REPLACE FUNCTION public.push_gone(p_secret text, p_endpoints text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v text;
begin
  select decrypted_secret into v from vault.decrypted_secrets where name = 'push_secret';
  if v is null or p_secret is null or p_secret is distinct from v then raise exception 'Not allowed.'; end if;
  delete from public.push_subscriptions where endpoint = any(p_endpoints);
end $function$
;

CREATE OR REPLACE FUNCTION public.qr_menu(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.dining_tables%rowtype := app.qr_table(p_token); r record;
begin
  select res.trading_name, res.currency_code, res.second_language, b.name as branch_name
    into r from public.restaurants res join public.branches b on b.id = t.branch_id where res.id = t.restaurant_id;
  return jsonb_build_object(
    'restaurant', r.trading_name, 'outlet', r.branch_name, 'currency', r.currency_code,
    'second_language', r.second_language, 'table', t.table_number, 'kiosk', t.is_kiosk,
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'items', c.items) order by c.display_order, c.name)
        from (
          -- A sub-category's dishes are shown under its main category, headed by the sub-category's name ('sub').
          select top.id, top.name, top.display_order,
                 jsonb_agg(jsonb_build_object(
                   'id', p.id, 'name', p.name, 'name_local', p.name_local, 'is_veg', p.is_veg,
                   'sub', case when c.parent_id is not null then c.name end,
                   'price', app.rule_price(t.restaurant_id, t.branch_id, p.id, coalesce(bp.price, p.price), now()),
                   'option_groups', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'id', mg.id, 'name', mg.name,
                              'min', greatest(coalesce(mg.min_select, 0), case when mg.is_required then 1 else 0 end),
                              'max', coalesce(mg.max_select, 99),
                              'options', (select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price_delta', mi.price_delta)
                                                             order by mi.display_order, mi.name), '[]'::jsonb)
                                            from public.modifier_items mi where mi.modifier_group_id = mg.id and mi.is_active))
                            order by mg.is_required desc, mg.name)
                       from public.product_modifier_groups pmg join public.modifier_groups mg on mg.id = pmg.modifier_group_id
                      where pmg.product_id = p.id and mg.is_active), '[]'::jsonb))
                   order by (c.parent_id is not null), c.display_order, c.name, p.display_order, p.name) as items
            from public.categories c
            join public.categories top on top.id = coalesce(c.parent_id, c.id) and top.deleted_at is null
            join public.products p on p.category_id = c.id and p.deleted_at is null
            left join public.branch_prices bp on bp.product_id = p.id and bp.branch_id = t.branch_id
           where c.restaurant_id = t.restaurant_id and c.deleted_at is null
             and p.is_available and coalesce(bp.is_available, true)
             and not p.is_charge
             -- a dish with sizes is ordered by its sizes, which are listed as dishes of their own
             and not exists (select 1 from public.products ch where ch.parent_id = p.id and ch.deleted_at is null)
           group by top.id, top.name, top.display_order
        ) c), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.qr_order_status(p_request uuid, p_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('status', q.status, 'reason', q.reject_reason, 'estimated_total', q.estimated_total,
                            'bill_number', o.bill_number, 'token_no', o.token_no)
    from public.qr_orders q left join public.orders o on o.id = q.order_id
   where q.id = p_request and q.guest_key = p_key;
$function$
;

CREATE OR REPLACE FUNCTION public.qr_place_order(p_token text, p_items jsonb, p_guest_name text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.dining_tables%rowtype := app.qr_table(p_token); v_in jsonb; v_total numeric; v_key text := app.new_token(); v_id uuid; v_items jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Your order is empty.'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Please send at most 30 lines at a time.'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) x
              where coalesce((x->>'qty')::numeric, 0) not between 1 and 20 or (x->>'qty')::numeric <> trunc((x->>'qty')::numeric)) then
    raise exception 'Each quantity must be a whole number from 1 to 20.';
  end if;
  if (select count(*) from public.qr_orders q where q.dining_table_id = t.id and q.status = 'pending') >= greatest(3, 30 * t.is_kiosk::int) then
    raise exception 'This table already has orders waiting. Please wait for the staff to accept them.';
  end if;
  if (select count(*) from public.qr_orders q where q.dining_table_id = t.id and q.created_at > now() - interval '10 minutes') >= greatest(8, 60 * t.is_kiosk::int) then
    raise exception 'Too many orders from this table. Please ask the staff.';
  end if;
  select jsonb_agg(jsonb_build_object('product_id', x->>'product_id', 'qty', (x->>'qty')::int,
                                      'note', left(coalesce(x->>'note', ''), 120),
                                      'options', coalesce(case when jsonb_typeof(x->'options') = 'array' then x->'options' end, '[]'::jsonb)))
    into v_items from jsonb_array_elements(p_items) x;
  v_in := app.bill_input(t.restaurant_id, t.branch_id, v_items, 0, null, null);
  v_total := (app.calc_bill(v_in->'calc')->>'grand_total')::numeric;
  insert into public.qr_orders (restaurant_id, branch_id, dining_table_id, items, estimated_total, guest_name, guest_note, guest_key)
  values (t.restaurant_id, t.branch_id, t.id, v_items, v_total, nullif(left(trim(p_guest_name), 60), ''), nullif(left(trim(p_note), 200), ''), v_key)
  returning id into v_id;
  if t.is_kiosk and t.kiosk_user_id is not null then perform app.kiosk_auto_accept(v_id, t.kiosk_user_id); end if;
  return jsonb_build_object('request_id', v_id, 'key', v_key, 'estimated_total', v_total);
end $function$
;

CREATE OR REPLACE FUNCTION public.quote_order(p_items jsonb, p_discount_amount numeric DEFAULT 0, p_service_charge boolean DEFAULT NULL::boolean, p_senior jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_in jsonb; v_calc jsonb;
begin
  perform app.require_permission('order.create');
  if coalesce(p_discount_amount, 0) > 0 and not app.has_permission('order.discount') then
    raise exception 'A manager must approve a discount.';
  end if;
  v_in := app.bill_input(app.current_restaurant_id(), app.current_branch_id(), p_items,
                         p_discount_amount, p_service_charge, p_senior);
  v_calc := app.calc_bill(v_in->'calc');
  return v_calc - 'lines'
    || jsonb_build_object(
         'lines', (select coalesce(jsonb_agg(jsonb_build_object('key', l->'key', 'total', l->'total')), '[]'::jsonb)
                     from jsonb_array_elements(v_calc->'lines') l),
         'service_charge_available', v_in->'service_charge_available',
         'service_charge_on', v_in->'service_charge_on',
         'service_charge_percent', v_in->'service_charge_percent',
         'service_charge_label', v_in->'service_charge_label',
         'cash_rounding', v_in->'cash_rounding');
end $function$
;

CREATE OR REPLACE FUNCTION public.receive_goods(p_supplier_id uuid, p_lines jsonb, p_purchase_order_id uuid DEFAULT NULL::uuid, p_bill_no text DEFAULT NULL::text, p_bill_date date DEFAULT NULL::date, p_tax numeric DEFAULT 0, p_other numeric DEFAULT 0, p_due_on date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_payment jsonb DEFAULT NULL::jsonb, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  sup public.suppliers%rowtype; po public.purchase_orders%rowtype; l record;
  v_id uuid := gen_random_uuid(); v_no text; v_seq int; v_today date; v_now numeric;
  v_sub numeric(14,2) := 0; v_tax numeric(14,2) := round(coalesce(p_tax, 0), 2); v_other numeric(14,2) := round(coalesce(p_other, 0), 2);
  v_total numeric(14,2); v_pay jsonb; v_out jsonb; v_po_status text; v_prev_cost numeric; v_new_cost numeric;
begin
  perform app.require_feature('stock');
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('grn_ref:' || p_client_ref::text));
    select jsonb_build_object('id', g.id, 'number', g.number, 'total', g.total, 'balance', g.total - g.paid_total, 'repeat', true)
      into v_out from public.goods_receipts g where g.restaurant_id = v_rest and g.client_ref = p_client_ref;
    if v_out is not null then return v_out; end if;
  end if;
  select * into sup from public.suppliers where id = p_supplier_id and restaurant_id = v_rest and is_active;
  if not found then raise exception 'Choose a supplier.'; end if;
  if v_tax < 0 or v_other < 0 then raise exception 'Tax and other charges cannot be negative.'; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;
  if p_bill_date is not null and p_bill_date > v_today then raise exception 'The supplier''s bill date cannot be in the future.'; end if;

  if p_purchase_order_id is not null then
    select * into po from public.purchase_orders where id = p_purchase_order_id and restaurant_id = v_rest and branch_id = v_branch for update;
    if not found then raise exception 'Purchase order not found.'; end if;
    if po.supplier_id <> sup.id then raise exception 'Purchase order % is for another supplier.', po.number; end if;
    if po.status not in ('ordered', 'part_received') then
      raise exception 'Purchase order % is %, so goods cannot be received against it.', po.number, replace(po.status, '_', ' ');
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('goods_receipt:' || v_branch::text));
  select count(*) + 1 into v_seq from public.goods_receipts where branch_id = v_branch;
  v_no := 'GRN-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');

  insert into public.goods_receipts (id, restaurant_id, branch_id, supplier_id, purchase_order_id, number, supplier_bill_no,
                                     supplier_bill_date, received_on, due_on, notes, received_by, client_ref)
  values (v_id, v_rest, v_branch, sup.id, po.id, v_no, nullif(left(trim(coalesce(p_bill_no, '')), 40), ''), p_bill_date, v_today,
          coalesce(p_due_on, coalesce(p_bill_date, v_today) + sup.payment_days),
          nullif(left(trim(coalesce(p_notes, '')), 300), ''), v_user, p_client_ref);

  -- Fixed order, so two people receiving at once cannot block each other.
  for l in select * from app.purchase_lines(v_rest, p_lines) x order by x.ingredient_id loop
    perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || l.ingredient_id::text));
    select coalesce(sum(m.qty), 0) into v_now from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = l.ingredient_id;
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, goods_receipt_id)
    values (v_rest, v_branch, l.ingredient_id, 'purchase', l.qty, l.unit_cost, left(v_no || ' · ' || sup.name, 200), v_user, v_id);
    -- Same rule as a purchase on the Stock screen: the new price is weighted with the stock already held.
    select i.cost_per_unit into v_prev_cost from public.ingredients i where i.id = l.ingredient_id;
    update public.ingredients i set cost_per_unit = case when v_now > 0
             then round((v_now * i.cost_per_unit + l.qty * l.unit_cost) / (v_now + l.qty), 4) else l.unit_cost end
     where i.id = l.ingredient_id
    returning i.cost_per_unit into v_new_cost;
    insert into public.goods_receipt_lines (restaurant_id, goods_receipt_id, ingredient_id, qty, unit_cost, line_total, prev_cost, new_cost)
    values (v_rest, v_id, l.ingredient_id, l.qty, l.unit_cost, round(l.qty * l.unit_cost, 2), v_prev_cost, v_new_cost);
    v_sub := v_sub + round(l.qty * l.unit_cost, 2);
    if po.id is not null then
      update public.purchase_order_lines set received_qty = received_qty + l.qty
       where purchase_order_id = po.id and ingredient_id = l.ingredient_id;
    end if;
  end loop;

  v_total := v_sub + v_tax + v_other;
  update public.goods_receipts set subtotal = v_sub, tax_amount = v_tax, other_charges = v_other, total = v_total,
         payment_status = case when v_total = 0 then 'paid' else 'unpaid' end
   where id = v_id;

  if po.id is not null then
    v_po_status := case when exists (select 1 from public.purchase_order_lines where purchase_order_id = po.id and received_qty < qty)
                        then 'part_received' else 'received' end;
    update public.purchase_orders set status = v_po_status,
           closed_at = case when v_po_status = 'received' then now() else null end
     where id = po.id;
  end if;

  perform app.audit('goods.receive', 'goods_receipts', v_id,
    jsonb_build_object('number', v_no, 'supplier', sup.name, 'total', v_total, 'purchase_order', po.number));

  if p_payment is not null and jsonb_typeof(p_payment) = 'object' and coalesce((p_payment->>'amount')::numeric, 0) > 0 then
    v_pay := app.pay_goods_receipt(v_id, (p_payment->>'amount')::numeric, p_payment->>'method', p_payment->>'reference',
                                   null, coalesce((p_payment->>'from_till')::boolean, false), v_user);
  end if;

  return jsonb_build_object('id', v_id, 'number', v_no, 'total', v_total,
    'balance', v_total - coalesce((v_pay->>'amount')::numeric, 0),
    'purchase_order_status', v_po_status);
end $function$
;

CREATE OR REPLACE FUNCTION public.record_cash_movement(p_direction text, p_amount numeric, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('cash.movement');
  v_shift uuid;
  v_id uuid := gen_random_uuid();
begin
  if p_direction not in ('in','out') then raise exception 'Choose cash in or cash out.'; end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'Enter a reason.'; end if;
  select id into v_shift from public.shifts
   where branch_id = app.current_branch_id() and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(app.current_branch_id()); end if;
  if v_shift is null then raise exception 'There is no open shift.'; end if;
  insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
  values (v_id, app.current_restaurant_id(), v_shift, p_direction, round(p_amount,2), left(trim(p_reason),200), v_user);
  perform app.audit('cash.' || p_direction, 'cash_movements', v_id,
    jsonb_build_object('amount', round(p_amount,2), 'reason', left(trim(p_reason),200)));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.record_stock(p_ingredient_id uuid, p_kind text, p_qty numeric, p_unit_cost numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_ing public.ingredients%rowtype; v_now numeric; v_move numeric;
begin
  perform app.require_feature('stock');
  select * into v_ing from public.ingredients where id = p_ingredient_id and restaurant_id = v_rest;
  if not found then raise exception 'Ingredient not found.'; end if;
  if p_kind not in ('purchase', 'wastage', 'count') then raise exception 'Choose purchase, wastage or count.'; end if;
  if p_qty is null or p_qty < 0 or (p_kind <> 'count' and p_qty = 0) then raise exception 'Enter a quantity.'; end if;
  select coalesce(sum(qty), 0) into v_now from public.stock_movements where branch_id = v_branch and ingredient_id = v_ing.id;
  v_move := case p_kind when 'purchase' then p_qty when 'wastage' then -p_qty else p_qty - v_now end;
  if v_move = 0 and p_kind = 'count' then return jsonb_build_object('stock', v_now, 'change', 0); end if;
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by)
  values (v_rest, v_branch, v_ing.id, p_kind, v_move, case when p_kind = 'purchase' then p_unit_cost end, nullif(left(trim(coalesce(p_note, '')), 200), ''), v_user);
  -- A purchase at a new price updates the ingredient's cost (weighted with the stock already held).
  if p_kind = 'purchase' and p_unit_cost is not null and p_unit_cost >= 0 then
    update public.ingredients set cost_per_unit = case when v_now > 0 then round((v_now * cost_per_unit + p_qty * p_unit_cost) / (v_now + p_qty), 4) else p_unit_cost end
     where id = v_ing.id;
  end if;
  perform app.audit('stock.' || p_kind, 'ingredients', v_ing.id, jsonb_build_object('qty', p_qty, 'change', v_move, 'unit_cost', p_unit_cost, 'note', p_note));
  return jsonb_build_object('stock', v_now + v_move, 'change', v_move);
end $function$
;

CREATE OR REPLACE FUNCTION public.redeem_gift_card(p_order uuid, p_code text, p_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; g public.gift_cards%rowtype; v_bal numeric; v_due numeric; v_amt numeric; v_res jsonb;
begin
  perform app.require_permission('payment.take');
  perform app.require_feature('loyalty');
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  select * into g from public.gift_cards where restaurant_id = o.restaurant_id and code = upper(trim(p_code)) for update;
  if not found then raise exception 'No gift card with that code.'; end if;
  if g.expires_on is not null and g.expires_on < app.local_today(o.restaurant_id) then raise exception 'Gift card % expired on %.', g.code, g.expires_on; end if;
  v_bal := app.gift_balance(g.id);
  v_due := o.grand_total - app.order_covered(o.id);
  v_amt := round(least(coalesce(p_amount, v_due), v_bal, v_due), 2);
  if v_bal <= 0 then raise exception 'Gift card % has no balance left.', g.code; end if;
  if v_amt <= 0 then raise exception 'Nothing left to pay on this bill.'; end if;
  perform set_config('app.redeem', 'on', true);
  v_res := public.pay_order(o.id, app.system_method(o.restaurant_id, 'gift_card'), null, v_amt, g.code, null);
  perform set_config('app.redeem', '', true);
  insert into public.gift_card_ledger (restaurant_id, gift_card_id, order_id, amount, kind, created_by)
  values (o.restaurant_id, g.id, o.id, -v_amt, 'redeem', app.current_user_id());
  return v_res || jsonb_build_object('card', g.code, 'used', v_amt, 'card_balance', v_bal - v_amt);
end $function$
;

CREATE OR REPLACE FUNCTION public.redeem_points(p_order uuid, p_points numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; s public.loyalty_settings%rowtype; v_bal numeric; v_due numeric; v_amt numeric; v_pts numeric; v_res jsonb;
begin
  perform app.require_permission('payment.take');
  perform app.require_feature('loyalty');
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.customer_id is null then raise exception 'Add the guest''s phone number to the bill first.'; end if;
  select * into s from public.loyalty_settings where restaurant_id = o.restaurant_id;
  if not found or s.point_value <= 0 then raise exception 'Set up loyalty points in Settings first.'; end if;
  perform pg_advisory_xact_lock(hashtext('points:' || o.customer_id::text));
  v_bal := app.points_balance(o.customer_id);
  v_pts := floor(coalesce(p_points, 0));
  if v_pts <= 0 then raise exception 'Enter the points to use.'; end if;
  if v_pts > v_bal then raise exception 'The guest has only % points.', v_bal; end if;
  if v_pts < s.min_redeem then raise exception 'At least % points must be used at a time.', s.min_redeem; end if;
  v_due := o.grand_total - app.order_covered(o.id);
  v_amt := round(v_pts * s.point_value, 2);
  if v_amt > v_due then
    v_amt := v_due;
    v_pts := ceil(v_amt / s.point_value);
  end if;
  if v_amt <= 0 then raise exception 'Nothing left to pay on this bill.'; end if;
  perform set_config('app.redeem', 'on', true);
  v_res := public.pay_order(o.id, app.system_method(o.restaurant_id, 'loyalty'), null, v_amt, v_pts || ' points', null);
  perform set_config('app.redeem', '', true);
  insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note, created_by)
  values (o.restaurant_id, o.customer_id, o.id, -v_pts, 'redeem', 'Bill ' || o.bill_number, app.current_user_id());
  return v_res || jsonb_build_object('points_used', v_pts, 'points_left', v_bal - v_pts);
end $function$
;

CREATE OR REPLACE FUNCTION public.refund_order(p_order_id uuid, p_amount numeric, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_method uuid;
begin
  select payment_method_id into v_method from public.payments
   where order_id = p_order_id and restaurant_id = app.current_restaurant_id() order by created_at limit 1;
  if v_method is null then raise exception 'Bill not found.'; end if;
  return public.issue_credit_note(p_order_id, p_amount, v_method, p_reason);
end $function$
;

CREATE OR REPLACE FUNCTION public.regenerate_invite(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('user.manage');
  u public.users%rowtype;
  v_code text := app.new_invite_code();
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null;
  if not found then raise exception 'Staff member not found.'; end if;
  if u.auth_user_id is not null then raise exception '% has already joined.', u.full_name; end if;
  if (select name from public.roles where id = u.role_id) = 'Owner' and not app.is_owner() then
    raise exception 'Only an owner can manage another owner.';
  end if;
  insert into public.staff_invites (user_id, restaurant_id, code_hash, expires_at, created_by)
  values (u.id, u.restaurant_id, extensions.crypt(v_code, extensions.gen_salt('bf')), now() + interval '7 days', v_me)
  on conflict (user_id) do update set code_hash = excluded.code_hash,
    expires_at = excluded.expires_at, created_by = excluded.created_by, created_at = now();
  perform app.audit('user.invite_regenerated', 'users', u.id, null);
  return jsonb_build_object('user_id', u.id, 'invite_code', v_code, 'expires_at', now() + interval '7 days');
end $function$
;

CREATE OR REPLACE FUNCTION public.region_set_price(p_region text, p_product uuid, p_price numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.register_counter_device(p_auth_user_id uuid, p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid := app.require_permission('settings.manage'); v_id uuid := gen_random_uuid(); a record;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the device a name, e.g. Counter 1.'; end if;
  select id, email, created_at into a from auth.users where id = p_auth_user_id;
  if not found or a.email not like 'counter-%@devices.sna-pos.app' or a.created_at < now() - interval '10 minutes' then
    raise exception 'The device sign-in could not be verified. Try again.';
  end if;
  if exists (select 1 from public.users where auth_user_id = p_auth_user_id)
     or exists (select 1 from public.devices where auth_user_id = p_auth_user_id) then
    raise exception 'The device sign-in is already in use.';
  end if;
  insert into public.devices (id, restaurant_id, branch_id, name, device_type, is_active, auth_user_id)
  values (v_id, app.current_restaurant_id(), app.current_branch_id(), left(trim(p_name), 60), 'counter', true, p_auth_user_id);
  perform app.audit('device.register', 'devices', v_id, jsonb_build_object('name', trim(p_name)));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.reject_qr_order(p_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('order.create');
  update public.qr_orders set status = 'rejected', reject_reason = nullif(left(trim(p_reason), 120), ''),
         decided_by = app.current_user_id(), decided_at = now()
   where id = p_id and restaurant_id = app.current_restaurant_id() and status = 'pending';
  if not found then raise exception 'That table order is not waiting any more.'; end if;
  perform app.audit('qr_order.reject', 'qr_orders', p_id, jsonb_build_object('reason', p_reason), null);
end $function$
;

CREATE OR REPLACE FUNCTION public.remove_counter_device(p_device_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid := app.require_permission('settings.manage'); d public.devices%rowtype;
begin
  select * into d from public.devices where id = p_device_id and restaurant_id = app.current_restaurant_id()
    and device_type = 'counter' for update;
  if not found then raise exception 'Counter device not found.'; end if;
  update public.devices set is_active = false where id = d.id;
  delete from public.pin_sessions where device_id = d.id;
  if d.auth_user_id is not null then delete from auth.sessions where user_id = d.auth_user_id; end if;
  perform app.audit('device.remove', 'devices', d.id, jsonb_build_object('name', d.name));
end $function$
;

CREATE OR REPLACE FUNCTION public.remove_push_subscription(p_endpoint text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = app.current_user_id();
$function$
;

CREATE OR REPLACE FUNCTION public.remove_report_schedule(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_old jsonb;
begin
  perform app.require_permission('settings.manage');
  perform app.require_permission('report.view_sales');
  delete from public.report_schedules
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id()
  returning jsonb_build_object('time', to_char(send_time, 'HH24:MI'), 'emails', to_jsonb(emails), 'phone_alert', phone_alert) into v_old;
  if not found then return; end if;
  perform app.audit('report_schedule.remove', 'report_schedules', p_id, null, v_old);
end $function$
;

CREATE OR REPLACE FUNCTION public.reopen_day(p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('day.reopen');
  v_branch uuid := app.current_branch_id(); d public.business_days; cur public.business_days; v_list text;
begin
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for reopening the day.'; end if;
  if exists (select 1 from public.business_days where branch_id = v_branch and status = 'parked') then
    raise exception 'A day is already reopened. Close it first.';
  end if;
  select * into d from public.business_days where branch_id = v_branch and status = 'closed'
   order by business_date desc limit 1 for update;
  if not found then raise exception 'There is no closed day to reopen.'; end if;
  select * into cur from public.business_days where branch_id = v_branch and status = 'open' for update;
  if found then
    if cur.business_date < d.business_date then raise exception 'Only the last closed day can be reopened.'; end if;
    select string_agg(bill_number, ', ' order by created_at) into v_list from (
      select o.bill_number, o.created_at from public.orders o
       where o.branch_id = v_branch and o.business_date = cur.business_date and o.status <> 'voided' and o.merged_into is null
       limit 20) x;
    if v_list is null then
      select string_agg(kt.ticket_number, ', ') into v_list from public.kitchen_tickets kt join public.orders o on o.id = kt.order_id
       where o.branch_id = v_branch and o.business_date = cur.business_date and kt.status not in ('cancelled');
    end if;
    if v_list is not null then
      raise exception 'Bills or kitchen tickets have already been made today: %. Void them first, then reopen the day.', v_list;
    end if;
    perform app.close_auto_shifts(v_branch, null); if exists (select 1 from public.shifts where branch_id = v_branch and status = 'open') then
      raise exception 'Close the open shift first, then reopen the day.';
    end if;
    if exists (select 1 from public.orders where branch_id = v_branch and business_date = cur.business_date) then
      update public.business_days set status = 'parked' where id = cur.id;
    else
      delete from public.business_days where id = cur.id;
    end if;
  end if;
  update public.business_days set status = 'open', closed_at = null, closed_by = null, reopen_count = reopen_count + 1
   where id = d.id;
  perform app.audit('day.reopen', 'business_days', d.id,
    jsonb_build_object('business_date', d.business_date, 'reason', left(trim(p_reason), 300)),
    jsonb_build_object('z_report_total', d.z_report->'total_billed'));
  return jsonb_build_object('business_date', d.business_date);
end $function$
;

CREATE OR REPLACE FUNCTION public.report_schedules_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_branch uuid; v_rest uuid; v_cut time; v_tz text;
begin
  perform app.require_permission('settings.manage');
  perform app.require_permission('report.view_sales');
  v_rest := app.current_restaurant_id();
  v_branch := app.current_branch_id();
  select coalesce(bs.day_cutoff, '04:00'::time), coalesce(b.timezone, r.timezone, 'UTC') into v_cut, v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id
    left join public.branch_settings bs on bs.branch_id = b.id
   where b.id = v_branch;
  return jsonb_build_object(
    'cutoff', to_char(coalesce(v_cut, '04:00'::time), 'HH24:MI'),
    'timezone', v_tz,
    'phone_alert_available', app.feature_on(v_rest, 'owner_app'),
    'schedules', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', rs.id, 'time', to_char(rs.send_time, 'HH24:MI'), 'days', to_jsonb(rs.days),
               'emails', to_jsonb(rs.emails), 'phone_alert', rs.phone_alert, 'active', rs.is_active,
               'last_sent_at', rs.last_sent_at, 'last_for_date', rs.last_for_date,
               'last_result', rs.last_result, 'last_email_result', rs.last_email_result,
               'last_problem', rs.last_problem, 'last_problem_at', rs.last_problem_at)
             order by rs.send_time, rs.created_at)
        from public.report_schedules rs
       where rs.restaurant_id = v_rest and rs.branch_id = v_branch), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.report_sent(p_secret text, p_schedule uuid, p_ok boolean, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v text;
begin
  select decrypted_secret into v from vault.decrypted_secrets where name = 'push_secret';
  if v is null or p_secret is null or p_secret is distinct from v then raise exception 'Not allowed.'; end if;
  update public.report_schedules
     set last_email_result = left(coalesce(nullif(trim(p_note), ''), case when p_ok then 'Email sent.' else 'The email could not be sent.' end), 200),
         last_problem = case when p_ok then last_problem else 'The email was not sent.' end,
         last_problem_at = case when p_ok then last_problem_at else now() end
   where id = p_schedule;
end $function$
;

CREATE OR REPLACE FUNCTION public.request_plan_change(p_kind text, p_module text DEFAULT NULL::text, p_outlet_name text DEFAULT NULL::text, p_outlet_city text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id(); v_id uuid; v_ed text;
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if not app.is_owner() then raise exception 'Only the owner can ask for plan changes.'; end if;
  select edition into v_ed from public.restaurants where id = v_rest;
  if p_kind = 'upgrade' then
    if v_ed = 'professional' then raise exception 'You already have the Professional edition.'; end if;
  elsif p_kind = 'module' then
    if not exists (select 1 from public.modules where key = p_module and kind = 'addon') then
      raise exception 'Choose an add-on module.';
    end if;
    if app.feature_on(v_rest, p_module) then raise exception 'That module is already on.'; end if;
  elsif p_kind = 'outlet' then
    if coalesce(trim(p_outlet_name), '') = '' then raise exception 'Enter the new outlet''s name.'; end if;
  else
    raise exception 'Unknown request.';
  end if;
  if exists (select 1 from public.plan_requests where restaurant_id = v_rest and kind = p_kind
               and coalesce(module_key, '') = coalesce(p_module, '') and status in ('requested', 'approved')
               and p_kind <> 'outlet') then
    raise exception 'This request is already with the SNA team.';
  end if;
  insert into public.plan_requests (restaurant_id, kind, module_key, outlet_name, outlet_city, note, requested_by_user)
  values (v_rest, p_kind, case when p_kind = 'module' then p_module end, left(trim(p_outlet_name), 80),
          left(trim(p_outlet_city), 60), left(trim(p_note), 300), app.current_user_id())
  returning id into v_id;
  perform app.log_plan(v_rest, 'request.' || p_kind, jsonb_build_object('request', v_id, 'module', p_module, 'outlet', p_outlet_name));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.reset_table_qr(p_table uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('settings.manage');
  update public.dining_tables set qr_token = app.new_token()
   where id = p_table and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That table does not exist.'; end if;
  perform app.audit('table.qr_reset', 'dining_tables', p_table, '{}'::jsonb, null);
end $function$
;

CREATE OR REPLACE FUNCTION public.revoke_api_key(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('settings.manage');
  update public.api_keys set revoked_at = now() where id = p_id and restaurant_id = app.current_restaurant_id() and revoked_at is null;
  if not found then raise exception 'Key not found.'; end if;
  perform app.audit('api_key.revoke', 'api_keys', p_id, '{}'::jsonb, null);
end $function$
;

CREATE OR REPLACE FUNCTION public.rider_save(p_id uuid, p_name text, p_phone text DEFAULT NULL::text, p_active boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('order.create'); v_rest uuid := app.current_restaurant_id(); v_id uuid; v_name text := btrim(coalesce(p_name, ''));
begin
  if v_name = '' or length(v_name) > 60 then raise exception 'Enter the rider''s name.'; end if;
  if p_id is null then
    insert into public.riders (restaurant_id, branch_id, name, phone) values (v_rest, app.current_branch_id(), v_name, nullif(btrim(coalesce(p_phone, '')), ''))
    returning id into v_id;
  else
    update public.riders set name = v_name, phone = nullif(btrim(coalesce(p_phone, '')), ''), is_active = coalesce(p_active, true)
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'That rider was not found.'; end if;
  end if;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.rider_settle(p_rider uuid, p_method uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id();
  v_method uuid; o record; v_due numeric; v_total numeric := 0; v_n int := 0;
begin
  if not exists (select 1 from public.riders where id = p_rider and restaurant_id = v_rest) then raise exception 'That rider was not found.'; end if;
  v_method := coalesce(p_method, (select id from public.payment_methods where restaurant_id = v_rest and kind = 'cash' and is_active order by display_order limit 1));
  if v_method is null then raise exception 'Add a cash payment method first.'; end if;
  for o in select id from public.orders
            where restaurant_id = v_rest and branch_id = app.current_branch_id() and rider_id = p_rider and delivery_status = 'delivered'
              and status <> 'voided' and payment_status in ('unpaid', 'partial') order by created_at for update loop
    v_due := (select grand_total from public.orders where id = o.id) - app.order_covered(o.id);
    if v_due > 0 then
      perform public.pay_order(o.id, v_method, v_due, v_due, 'Rider ' || (select name from public.riders where id = p_rider), null);
      v_total := v_total + v_due; v_n := v_n + 1;
    end if;
  end loop;
  if v_n = 0 then raise exception 'This rider has no delivered bills waiting for payment.'; end if;
  return jsonb_build_object('bills', v_n, 'amount', v_total);
end $function$
;

CREATE OR REPLACE FUNCTION public.sales_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_fin boolean;
  v_summary jsonb; v_by_day jsonb; v_by_hour jsonb; v_by_item jsonb; v_by_method jsonb; v_by_type jsonb;
  v_tax jsonb := '[]'::jsonb; v_refunds numeric(14,2); v_refund_count int; v_net numeric(14,2);
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_fin  := app.has_permission('report.view_financial');
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;

  drop table if exists _rep_orders;
  create temp table _rep_orders (id uuid primary key, created_at timestamptz, status text,
    order_type text, subtotal numeric, discount_total numeric, tax_total numeric, tax_included numeric,
    service_charge numeric, rounding_adjustment numeric, grand_total numeric, exempt_sales numeric, due numeric, comp_kind text) on commit drop;
  insert into _rep_orders
  select id, created_at, status, order_type, subtotal, discount_total, tax_total, tax_included,
         service_charge, rounding_adjustment, grand_total, exempt_sales,
         case when status = 'completed' and payment_status in ('unpaid', 'partial')
              then grand_total - app.order_covered(id) else 0 end,
         comp_kind
    from public.orders
   where restaurant_id = v_rest and app.in_scope(branch_id) and created_at >= v_start and created_at < v_end
     and status in ('completed', 'voided') and merged_into is null;

  select coalesce(sum(r.amount), 0), count(*) into v_refunds, v_refund_count
    from public.refunds r where r.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = r.order_id)) and r.created_at >= v_start and r.created_at < v_end;
  select coalesce(sum(oi.net_amount), 0) into v_net
    from public.order_items oi join _rep_orders o on o.id = oi.order_id where o.status = 'completed';

  select jsonb_build_object(
      'bills',          count(*) filter (where status = 'completed' and comp_kind is null),
      'gross_sales',    coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind is null), 0),
      'net_sales',      v_net,
      'discounts',      coalesce(sum(discount_total) filter (where status = 'completed' and comp_kind is null), 0),
      'complimentary_bills', count(*) filter (where status = 'completed' and comp_kind = 'complimentary'),
      'complimentary_value', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind = 'complimentary'), 0),
      'staff_meal_bills',    count(*) filter (where status = 'completed' and comp_kind = 'staff_meal'),
      'staff_meal_value',    coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind = 'staff_meal'), 0),
      'service_charge', coalesce(sum(service_charge) filter (where status = 'completed'), 0),
      'tax',            coalesce(sum(tax_total) filter (where status = 'completed'), 0),
      'tax_included',   coalesce(sum(tax_included) filter (where status = 'completed'), 0),
      'exempt_sales',   coalesce(sum(exempt_sales) filter (where status = 'completed'), 0),
      'rounding',       coalesce(sum(rounding_adjustment) filter (where status = 'completed'), 0),
      'total_billed',   coalesce(sum(grand_total) filter (where status = 'completed'), 0),
      'average_bill',   coalesce(round(avg(grand_total) filter (where status = 'completed' and comp_kind is null), 2), 0),
      'voided_bills',   count(*) filter (where status = 'voided'),
      'voided_value',   coalesce(sum(grand_total) filter (where status = 'voided'), 0),
      'refunds',        v_refunds,
      'refund_count',   v_refund_count,
      'unpaid_bills',   count(*) filter (where status = 'completed' and due > 0),
      'unpaid_amount',  coalesce(sum(due), 0),
      'net_collected',  coalesce(sum(grand_total) filter (where status = 'completed'), 0) - coalesce(sum(due), 0) - v_refunds)
    into v_summary from _rep_orders;

  select coalesce(jsonb_agg(jsonb_build_object('day', d, 'bills', n, 'total', t) order by d), '[]'::jsonb) into v_by_day
    from (select (created_at at time zone v_tz)::date d, count(*) n, sum(grand_total) t
            from _rep_orders where status = 'completed' group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('hour', h, 'bills', n, 'total', t) order by h), '[]'::jsonb) into v_by_hour
    from (select extract(hour from created_at at time zone v_tz)::int h, count(*) n, sum(grand_total) t
            from _rep_orders where status = 'completed' group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('item', name, 'qty', q, 'amount', a) order by a desc), '[]'::jsonb) into v_by_item
    from (select oi.product_name name, sum(oi.quantity) q, sum(oi.line_subtotal) a
            from public.order_items oi join _rep_orders o on o.id = oi.order_id
           where o.status = 'completed' and oi.cancelled_at is null group by oi.product_name order by 3 desc limit 5000) x;
  select coalesce(jsonb_agg(jsonb_build_object('method', name, 'bills', n, 'amount', a) order by a desc), '[]'::jsonb) into v_by_method
    from (select pm.name, count(*) n, sum(p.amount) a
            from public.payments p join _rep_orders o on o.id = p.order_id
            join public.payment_methods pm on pm.id = p.payment_method_id
           where o.status = 'completed' group by pm.name) x;
  select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'bills', n, 'total', t) order by t desc), '[]'::jsonb) into v_by_type
    from (select order_type, count(*) n, sum(grand_total) t from _rep_orders where status = 'completed' group by 1) x;

  if v_fin then
    select coalesce(jsonb_agg(jsonb_build_object('component', c, 'rate', r, 'taxable', tx, 'tax', ta) order by r, c), '[]'::jsonb)
      into v_tax
      from (select t.component_name c, t.rate r, sum(t.taxable_amount) tx, sum(t.tax_amount) ta
              from public.order_item_taxes t join _rep_orders o on o.id = t.order_id
             where o.status = 'completed' group by 1, 2) x;
  end if;

  return jsonb_build_object('from', p_from, 'to', p_to, 'timezone', v_tz, 'financial', v_fin,
    'summary', v_summary, 'by_day', v_by_day, 'by_hour', v_by_hour, 'by_item', v_by_item,
    'by_method', v_by_method, 'by_type', v_by_type, 'tax', v_tax);
end $function$
;

CREATE OR REPLACE FUNCTION public.save_day_settings(p_shifts_enabled boolean, p_cutoff time without time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('settings.manage');
  if p_cutoff < '00:00' or p_cutoff > '08:00' then raise exception 'The day cutoff must be between midnight and 8 a.m.'; end if;
  update public.branch_settings set shifts_enabled = p_shifts_enabled, day_cutoff = p_cutoff, updated_at = now()
   where restaurant_id = app.current_restaurant_id();
  perform app.audit('settings.day', 'branch_settings', null, jsonb_build_object('shifts_enabled', p_shifts_enabled, 'day_cutoff', p_cutoff), null);
end $function$
;

CREATE OR REPLACE FUNCTION public.save_ingredient(p_id uuid, p_name text, p_unit text, p_cost numeric, p_reorder numeric, p_category text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_id uuid;
begin
  perform app.require_feature('stock');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the ingredient name.'; end if;
  if exists (select 1 from public.ingredients where restaurant_id = v_rest and is_active and lower(trim(name)) = lower(trim(p_name)) and id is distinct from p_id) then
    raise exception 'An ingredient called % already exists.', trim(p_name);
  end if;
  if p_id is null then
    insert into public.ingredients (restaurant_id, name, unit, cost_per_unit, reorder_level, category)
    values (v_rest, left(trim(p_name), 60), p_unit, coalesce(p_cost, 0), coalesce(p_reorder, 0), nullif(left(trim(coalesce(p_category, '')), 40), '')) returning id into v_id;
  else
    update public.ingredients set name = left(trim(p_name), 60), unit = p_unit, cost_per_unit = coalesce(p_cost, 0), reorder_level = coalesce(p_reorder, 0),
           category = nullif(left(trim(coalesce(p_category, '')), 40), '')
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'Ingredient not found.'; end if;
  end if;
  perform app.audit('stock.ingredient', 'ingredients', v_id, jsonb_build_object('name', p_name, 'unit', p_unit, 'cost', p_cost, 'reorder', p_reorder));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.save_loyalty_settings(p_spend_per_point numeric, p_point_value numeric, p_min_redeem integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('settings.manage');
  perform app.require_feature('loyalty');
  insert into public.loyalty_settings (restaurant_id, spend_per_point, point_value, min_redeem)
  values (app.current_restaurant_id(), p_spend_per_point, p_point_value, coalesce(p_min_redeem, 0))
  on conflict (restaurant_id) do update set spend_per_point = excluded.spend_per_point, point_value = excluded.point_value,
    min_redeem = excluded.min_redeem, updated_at = now();
  perform app.audit('loyalty.settings', 'loyalty_settings', null,
    jsonb_build_object('spend_per_point', p_spend_per_point, 'point_value', p_point_value, 'min_redeem', p_min_redeem), null);
end $function$
;

CREATE OR REPLACE FUNCTION public.save_meal_sessions(p_branch uuid, p_sessions jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id(); a jsonb; b jsonb; i int; j int; n int;
  sa int; ea int; sb int; eb int; da int[]; db int[];
begin
  perform app.require_permission('settings.manage');
  if p_branch is not null and not exists (select 1 from public.branches where id = p_branch and restaurant_id = v_rest) then
    raise exception 'Outlet not found.';
  end if;
  if jsonb_typeof(p_sessions) <> 'array' then raise exception 'Send a list of sessions.'; end if;
  n := jsonb_array_length(p_sessions);
  if n > 12 then raise exception 'At most 12 sessions.'; end if;
  for i in 0 .. n - 1 loop
    a := p_sessions->i;
    if coalesce(trim(a->>'name'), '') = '' then raise exception 'Every session needs a name.'; end if;
    if (a->>'start')::time = (a->>'end')::time then raise exception '% starts and ends at the same time.', a->>'name'; end if;
    for j in i + 1 .. n - 1 loop
      b := p_sessions->j;
      da := coalesce((select array_agg(x::int) from jsonb_array_elements_text(a->'days') x), '{1,2,3,4,5,6,7}');
      db := coalesce((select array_agg(x::int) from jsonb_array_elements_text(b->'days') x), '{1,2,3,4,5,6,7}');
      if not (da && db) then continue; end if;
      sa := extract(epoch from (a->>'start')::time) / 60; ea := extract(epoch from (a->>'end')::time) / 60;
      sb := extract(epoch from (b->>'start')::time) / 60; eb := extract(epoch from (b->>'end')::time) / 60;
      if ea <= sa then ea := ea + 1440; end if;
      if eb <= sb then eb := eb + 1440; end if;
      if (sa < eb and sb < ea) or (sa + 1440 < eb and sb < ea + 1440) or (sb + 1440 < ea and sa < eb + 1440) then
        raise exception '% and % overlap. Sessions must not overlap.', a->>'name', b->>'name';
      end if;
    end loop;
  end loop;
  delete from public.meal_sessions where restaurant_id = v_rest and branch_id is not distinct from p_branch;
  insert into public.meal_sessions (restaurant_id, branch_id, name, start_time, end_time, days, display_order)
  select v_rest, p_branch, left(trim(x->>'name'), 30), (x->>'start')::time, (x->>'end')::time,
         coalesce((select array_agg(d::smallint) from jsonb_array_elements_text(x->'days') d), '{1,2,3,4,5,6,7}'), o::int
    from jsonb_array_elements(p_sessions) with ordinality as t(x, o);
  perform app.audit('settings.sessions', 'meal_sessions', null, jsonb_build_object('branch', p_branch, 'sessions', p_sessions), null);
end $function$
;

CREATE OR REPLACE FUNCTION public.save_packing_charge(p_amount numeric, p_per text, p_tax_group_id uuid, p_takeaway boolean DEFAULT true, p_delivery boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_cat uuid; v_prod uuid; v_outlets int;
begin
  if v_branch is null then raise exception 'No branch is set up for this restaurant.'; end if;
  if v_amount < 0 then raise exception 'The packing charge cannot be negative.'; end if;
  if v_amount > 100000 then raise exception 'That packing charge is too large.'; end if;

  -- One "Packing charge" menu item per restaurant, found by its mark (so renaming it is harmless).
  select p.id into v_prod from public.products p
   where p.restaurant_id = v_rest and p.is_charge and p.deleted_at is null order by p.created_at limit 1;

  -- Switched off: this outlet's bills stop getting the line and the item leaves
  -- this outlet's menu. Old bills and reports keep their name for it.
  if v_amount = 0 then
    update public.branch_settings set packing_product_id = null where branch_id = v_branch;
    if v_prod is not null then
      insert into public.branch_prices (restaurant_id, branch_id, product_id, is_available, updated_by)
      values (v_rest, v_branch, v_prod, false, v_user)
      on conflict (branch_id, product_id) do update set is_available = false, updated_at = now(), updated_by = excluded.updated_by;
    end if;
    perform app.audit('settings.packing', 'branch_settings', v_branch, jsonb_build_object('amount', 0));
    return jsonb_build_object('on', false);
  end if;

  if coalesce(p_per, '') not in ('bill', 'item') then raise exception 'Choose per bill or per item.'; end if;
  if not coalesce(p_takeaway, false) and not coalesce(p_delivery, false) then
    raise exception 'Tick takeaway, delivery or both.';
  end if;
  if not exists (select 1 from public.tax_groups g where g.id = p_tax_group_id and g.restaurant_id = v_rest and g.is_active) then
    raise exception 'Choose the tax for the packing charge.';
  end if;

  if v_prod is null then
    select c.id into v_cat from public.categories c
     where c.restaurant_id = v_rest and c.deleted_at is null and lower(trim(c.name)) = 'charges' order by c.created_at limit 1;
    if v_cat is null then
      insert into public.categories (restaurant_id, name, display_order) values (v_rest, 'Charges', 999) returning id into v_cat;
    end if;
    insert into public.products (restaurant_id, category_id, tax_group_id, name, price, display_order, is_charge)
    values (v_rest, v_cat, p_tax_group_id, 'Packing charge', v_amount, 999, true) returning id into v_prod;
  else
    -- The tax is the menu item's, so it is the same at every outlet. Touch the
    -- item only when something really changes (price and tax changes are guarded).
    update public.products set tax_group_id = p_tax_group_id, is_available = true
     where id = v_prod and (tax_group_id is distinct from p_tax_group_id or not is_available);
    -- With a single outlet the menu price follows too, so the Menu screen shows the same amount.
    select count(*) into v_outlets from public.branches b where b.restaurant_id = v_rest and b.deleted_at is null and b.is_active;
    if v_outlets <= 1 then
      update public.products set price = v_amount where id = v_prod and price is distinct from v_amount;
    end if;
  end if;

  -- The amount belongs to this outlet: another outlet can charge a different one.
  insert into public.branch_prices (restaurant_id, branch_id, product_id, price, is_available, updated_by)
  values (v_rest, v_branch, v_prod, v_amount, true, v_user)
  on conflict (branch_id, product_id) do update
     set price = excluded.price, is_available = true, updated_at = now(), updated_by = excluded.updated_by;

  update public.branch_settings
     set packing_product_id = v_prod, packing_per = p_per,
         packing_takeaway = coalesce(p_takeaway, false), packing_delivery = coalesce(p_delivery, false)
   where branch_id = v_branch;

  perform app.audit('settings.packing', 'branch_settings', v_branch,
    jsonb_build_object('amount', v_amount, 'per', p_per, 'takeaway', p_takeaway, 'delivery', p_delivery));
  return jsonb_build_object('on', true, 'product_id', v_prod, 'amount', v_amount);
end $function$
;

CREATE OR REPLACE FUNCTION public.save_payment_method(p_id uuid, p_name text, p_kind text, p_ask_reference boolean DEFAULT false, p_upi_id text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_name text := btrim(coalesce(p_name, ''));
  v_upi text := nullif(btrim(coalesce(p_upi_id, '')), '');
  v_old public.payment_methods%rowtype; v_id uuid; v_used boolean;
begin
  if v_name = '' or length(v_name) > 30 then raise exception 'Give the payment method a name (up to 30 letters).'; end if;
  if coalesce(p_kind, '') not in ('cash', 'card', 'wallet', 'bank_transfer', 'upi', 'other') then raise exception 'Choose what kind of payment it is.'; end if;
  if v_upi is not null and p_kind <> 'upi' then v_upi := null; end if;
  if v_upi is not null and v_upi !~ '^[A-Za-z0-9._-]{2,200}@[A-Za-z][A-Za-z0-9]{1,63}$' then
    raise exception 'That UPI ID does not look right. It should look like shopname@okbank.';
  end if;
  if exists (select 1 from public.payment_methods where restaurant_id = v_rest and lower(name) = lower(v_name)
               and id is distinct from p_id) then
    raise exception 'A payment method called % already exists.', v_name;
  end if;
  if p_id is null then
    insert into public.payment_methods (restaurant_id, name, kind, affects_cash_drawer, is_active, display_order, ask_reference, upi_id)
    values (v_rest, v_name, p_kind, p_kind = 'cash', true,
            coalesce((select max(display_order) + 1 from public.payment_methods where restaurant_id = v_rest), 0),
            coalesce(p_ask_reference, false) and p_kind <> 'cash', v_upi)
    returning id into v_id;
    perform app.audit('payment_method.created', 'payment_methods', v_id, jsonb_build_object('name', v_name, 'kind', p_kind));
  else
    select * into v_old from public.payment_methods where id = p_id and restaurant_id = v_rest for update;
    if not found then raise exception 'Payment method not found.'; end if;
    select exists (select 1 from public.payments where payment_method_id = p_id) into v_used;
    if v_used and v_old.kind <> p_kind and (v_old.kind = 'cash' or p_kind = 'cash') then
      raise exception '% already has payments, so it cannot be switched to or from cash. Add a new method instead.', v_old.name;
    end if;
    update public.payment_methods set name = v_name, kind = p_kind, affects_cash_drawer = (p_kind = 'cash'),
           ask_reference = coalesce(p_ask_reference, false) and p_kind <> 'cash', upi_id = v_upi
     where id = p_id;
    v_id := p_id;
    perform app.audit('payment_method.changed', 'payment_methods', v_id,
      jsonb_build_object('name', v_name, 'kind', p_kind, 'upi_id', v_upi),
      jsonb_build_object('name', v_old.name, 'kind', v_old.kind, 'upi_id', v_old.upi_id));
  end if;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.save_price_rule(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('menu.manage');
  v_rest uuid := app.current_restaurant_id();
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_prod uuid[] := coalesce((select array_agg(distinct x::uuid) from jsonb_array_elements_text(coalesce(p->'product_ids', '[]')) x), '{}');
  v_cat uuid[] := coalesce((select array_agg(distinct x::uuid) from jsonb_array_elements_text(coalesce(p->'category_ids', '[]')) x), '{}');
  v_days smallint[] := coalesce((select array_agg(distinct x::smallint order by x::smallint) from jsonb_array_elements_text(coalesce(p->'days', '[]')) x), '{}');
  v_branch uuid := nullif(p->>'branch_id', '')::uuid;
  r public.price_rules;
begin
  if cardinality(v_days) = 0 then raise exception 'Choose at least one day.'; end if;
  if exists (select 1 from unnest(v_prod) u where not exists (select 1 from public.products x where x.id = u and x.restaurant_id = v_rest and x.deleted_at is null)) then
    raise exception 'A dish in this offer is no longer on the menu.';
  end if;
  if exists (select 1 from unnest(v_cat) u where not exists (select 1 from public.categories x where x.id = u and x.restaurant_id = v_rest and x.deleted_at is null)) then
    raise exception 'A category in this offer no longer exists.';
  end if;
  if coalesce(p->>'kind', '') not in ('percent_off', 'price') then raise exception 'Choose percent off or a fixed price.'; end if;
  if p->>'kind' = 'price' and cardinality(v_prod) = 0 then raise exception 'A fixed offer price needs the dishes it is for.'; end if;
  if p->>'kind' = 'percent_off' and not coalesce((p->>'value')::numeric, 0) between 1 and 99 then raise exception 'Percent off is 1 to 99.'; end if;
  if coalesce((p->>'value')::numeric, 0) <= 0 then raise exception 'Enter the offer price.'; end if;
  if nullif(p->>'start_time', '') is null or nullif(p->>'end_time', '') is null or (p->>'start_time')::time = (p->>'end_time')::time then
    raise exception 'Enter a start and end time, for example 16:00 to 19:00.';
  end if;
  if v_id is null then
    insert into public.price_rules (restaurant_id, branch_id, name, days, start_time, end_time, kind, value, product_ids, category_ids, valid_from, valid_to, is_active, created_by)
    values (v_rest, v_branch, btrim(p->>'name'), v_days, (p->>'start_time')::time, (p->>'end_time')::time, p->>'kind', (p->>'value')::numeric,
            v_prod, v_cat, nullif(p->>'valid_from', '')::date, nullif(p->>'valid_to', '')::date, coalesce((p->>'is_active')::boolean, true), v_user)
    returning * into r;
  else
    update public.price_rules set branch_id = v_branch, name = btrim(p->>'name'), days = v_days,
           start_time = (p->>'start_time')::time, end_time = (p->>'end_time')::time, kind = p->>'kind', value = (p->>'value')::numeric,
           product_ids = v_prod, category_ids = v_cat, valid_from = nullif(p->>'valid_from', '')::date, valid_to = nullif(p->>'valid_to', '')::date,
           is_active = coalesce((p->>'is_active')::boolean, true)
     where id = v_id and restaurant_id = v_rest returning * into r;
    if not found then raise exception 'That offer was not found.'; end if;
  end if;
  return r.id;
end $function$
;

CREATE OR REPLACE FUNCTION public.save_purchase_order(p_id uuid, p_supplier_id uuid, p_lines jsonb, p_expected_on date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_place boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  po public.purchase_orders%rowtype; v_id uuid := p_id; v_no text; v_seq int; v_total numeric(14,2);
begin
  perform app.require_feature('stock');
  if not exists (select 1 from public.suppliers s where s.id = p_supplier_id and s.restaurant_id = v_rest and s.is_active) then
    raise exception 'Choose a supplier.';
  end if;
  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('purchase_order:' || v_branch::text));
    select count(*) + 1 into v_seq from public.purchase_orders where branch_id = v_branch;
    v_no := 'PO-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');
    v_id := gen_random_uuid();
    insert into public.purchase_orders (id, restaurant_id, branch_id, supplier_id, number, expected_on, notes, created_by)
    values (v_id, v_rest, v_branch, p_supplier_id, v_no, p_expected_on, nullif(left(trim(coalesce(p_notes, '')), 300), ''), v_user);
  else
    select * into po from public.purchase_orders where id = v_id and restaurant_id = v_rest and branch_id = v_branch for update;
    if not found then raise exception 'Purchase order not found.'; end if;
    if po.status <> 'draft' then
      raise exception 'Purchase order % has already been sent, so it cannot be changed. Cancel it and write a new one.', po.number;
    end if;
    v_no := po.number;
    update public.purchase_orders set supplier_id = p_supplier_id, expected_on = p_expected_on,
           notes = nullif(left(trim(coalesce(p_notes, '')), 300), '') where id = v_id;
    delete from public.purchase_order_lines where purchase_order_id = v_id;
  end if;
  insert into public.purchase_order_lines (restaurant_id, purchase_order_id, ingredient_id, qty, unit_cost)
  select v_rest, v_id, l.ingredient_id, l.qty, l.unit_cost from app.purchase_lines(v_rest, p_lines) l;
  select coalesce(sum(round(qty * unit_cost, 2)), 0) into v_total from public.purchase_order_lines where purchase_order_id = v_id;
  update public.purchase_orders set total = v_total,
         status = case when p_place then 'ordered' else 'draft' end,
         ordered_at = case when p_place then now() else null end
   where id = v_id;
  perform app.audit('purchase_order.save', 'purchase_orders', v_id,
    jsonb_build_object('number', v_no, 'total', v_total, 'placed', coalesce(p_place, false)));
  return jsonb_build_object('id', v_id, 'number', v_no, 'total', v_total, 'status', case when p_place then 'ordered' else 'draft' end);
end $function$
;

CREATE OR REPLACE FUNCTION public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_feature('owner_app');
  if not app.has_permission('report.view_sales') then raise exception 'Alerts are for owners and managers (report.view_sales).'; end if;
  insert into public.push_subscriptions (restaurant_id, user_id, endpoint, p256dh, auth)
  values (app.current_restaurant_id(), app.current_user_id(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set restaurant_id = excluded.restaurant_id, user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $function$
;

CREATE OR REPLACE FUNCTION public.save_recipe(p_product_id uuid, p_lines jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); n int;
begin
  perform app.require_feature('stock');
  if not exists (select 1 from public.products where id = p_product_id and restaurant_id = v_rest) then raise exception 'Item not found.'; end if;
  delete from public.recipe_lines where product_id = p_product_id;
  insert into public.recipe_lines (restaurant_id, product_id, ingredient_id, qty)
  select v_rest, p_product_id, (l->>'ingredient_id')::uuid, (l->>'qty')::numeric
    from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) l
   where coalesce((l->>'qty')::numeric, 0) > 0
     and exists (select 1 from public.ingredients i where i.id = (l->>'ingredient_id')::uuid and i.restaurant_id = v_rest);
  get diagnostics n = row_count;
  perform app.audit('stock.recipe', 'products', p_product_id, jsonb_build_object('lines', p_lines));
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.save_report_schedule(p_id uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  v_time time; v_days smallint[]; v_emails text[] := '{}'; v_phone boolean; v_active boolean;
  v_tz text; v_local timestamp; v_handled date; e text; v_id uuid; v_old jsonb;
  o public.report_schedules%rowtype;
begin
  perform app.require_permission('report.view_sales');
  if v_rest is null or v_branch is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Nothing to save.'; end if;

  if coalesce(p->>'time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'Choose the time to send the summary.';
  end if;
  v_time := (p->>'time')::time;

  if jsonb_typeof(p->'days') = 'array' then
    select array_agg(distinct x::smallint order by x::smallint) into v_days
      from jsonb_array_elements_text(p->'days') x where x ~ '^[1-7]$';
  end if;
  if v_days is null or cardinality(v_days) = 0 then raise exception 'Choose at least one day of the week.'; end if;

  if jsonb_typeof(p->'emails') = 'array' then
    if jsonb_array_length(p->'emails') > 20 then raise exception 'A schedule can go to 5 email addresses at most.'; end if;
    for e in select distinct lower(trim(x)) from jsonb_array_elements_text(p->'emails') x where trim(x) <> '' order by 1 loop
      if length(e) > 254 or e !~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' then
        raise exception '"%" does not look like an email address.', left(e, 80);
      end if;
      v_emails := v_emails || e;
    end loop;
  end if;
  if cardinality(v_emails) > 5 then
    raise exception 'A schedule can go to 5 email addresses at most. Add another schedule for more.';
  end if;

  v_phone := coalesce(p->>'phone_alert', '') = 'true';
  v_active := coalesce(p->>'active', 'true') <> 'false';

  -- A time that has already passed today starts tomorrow: saving never sends by itself.
  select coalesce(b.timezone, r.timezone, 'UTC') into v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = v_branch;
  v_local := now() at time zone v_tz;
  v_handled := case when v_local::time >= v_time then v_local::date else v_local::date - 1 end;

  if p_id is null then
    if v_phone then perform app.require_feature('owner_app'); end if;
    if cardinality(v_emails) = 0 and not v_phone then
      raise exception 'Add at least one email address, or tick the phone alert.';
    end if;
    -- One at a time per outlet, so two saves at the same moment cannot both slip under the limit.
    perform pg_advisory_xact_lock(hashtext('report_schedules:' || v_branch::text));
    if (select count(*) from public.report_schedules where branch_id = v_branch) >= 5 then
      raise exception 'This outlet already has 5 schedules. Change or remove one.';
    end if;
    insert into public.report_schedules (restaurant_id, branch_id, send_time, days, emails, phone_alert, is_active, last_run_on, created_by)
    values (v_rest, v_branch, v_time, v_days, v_emails, v_phone, v_active, v_handled, v_user)
    returning id into v_id;
  else
    select * into o from public.report_schedules
     where id = p_id and restaurant_id = v_rest and branch_id = v_branch for update;
    if not found then raise exception 'That schedule is not here any more. Refresh the page.'; end if;
    -- Ticking the phone alert needs the module; a schedule that already has it may still be changed.
    if v_phone and not o.phone_alert then perform app.require_feature('owner_app'); end if;
    if cardinality(v_emails) = 0 and not v_phone then
      raise exception 'Add at least one email address, or tick the phone alert.';
    end if;
    v_old := jsonb_build_object('time', to_char(o.send_time, 'HH24:MI'), 'days', to_jsonb(o.days), 'emails', to_jsonb(o.emails),
                                'phone_alert', o.phone_alert, 'active', o.is_active);
    update public.report_schedules
       set send_time = v_time, days = v_days, emails = v_emails, phone_alert = v_phone, is_active = v_active,
           -- Changing who gets it leaves today's send alone. A new time, or switching it back on, counts from
           -- now -- and a schedule that has already sent today never sends a second time today.
           last_run_on = case when o.send_time is distinct from v_time or (v_active and not o.is_active)
                              then greatest(coalesce(o.last_run_on, v_handled), v_handled)
                              else o.last_run_on end,
           updated_at = now()
     where id = p_id;
    v_id := p_id;
  end if;

  perform app.audit('report_schedule.save', 'report_schedules', v_id,
    jsonb_build_object('time', to_char(v_time, 'HH24:MI'), 'days', to_jsonb(v_days), 'emails', to_jsonb(v_emails),
                       'phone_alert', v_phone, 'active', v_active),
    v_old);
  return jsonb_build_object('id', v_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.save_reservation(p_id uuid, p_name text, p_phone text, p_party integer, p_when timestamp with time zone, p_table uuid, p_note text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_id uuid;
begin
  perform app.require_permission('order.create');
  perform app.require_feature('reservations');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the guest''s name.'; end if;
  if coalesce(p_party, 0) < 1 then raise exception 'Enter how many people.'; end if;
  if p_party > 200 then raise exception 'A booking can be for at most 200 people.'; end if;
  if p_table is not null and not exists (select 1 from public.dining_tables where id = p_table and restaurant_id = v_rest and branch_id = v_branch and is_active) then
    raise exception 'That table does not exist.';
  end if;
  if p_id is null then
    insert into public.reservations (restaurant_id, branch_id, guest_name, phone, party_size, reserved_for, dining_table_id, status, note, created_by)
    values (v_rest, v_branch, left(trim(p_name), 80), app.clean_phone(p_phone), p_party, p_when, p_table,
            case when p_when is null then 'waiting' else 'booked' end, nullif(left(trim(p_note), 200), ''), app.current_user_id())
    returning id into v_id;
  else
    update public.reservations set guest_name = left(trim(p_name), 80), phone = app.clean_phone(p_phone), party_size = p_party,
           reserved_for = p_when, dining_table_id = p_table, note = nullif(left(trim(p_note), 200), ''), updated_at = now()
     where id = p_id and restaurant_id = v_rest and status in ('booked', 'waiting')
     returning id into v_id;
    if v_id is null then raise exception 'That booking cannot be changed any more.'; end if;
  end if;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.save_role(p_role_id uuid, p_name text, p_permissions text[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('user.manage');
  v_rest uuid := app.current_restaurant_id();
  v_name text := btrim(coalesce(p_name, ''));
  v_old public.roles;
  v_id uuid;
  v_bad text;
begin
  perform app.require_feature('custom_roles');
  if not app.is_owner() then raise exception 'Only an owner can change roles and rights.'; end if;
  if v_name = '' or length(v_name) > 40 then raise exception 'Give the role a name (up to 40 letters).'; end if;
  if lower(v_name) = 'owner' then raise exception 'The name Owner is reserved.'; end if;
  if exists (select 1 from public.roles r where r.restaurant_id = v_rest and lower(btrim(r.name)) = lower(v_name)
             and r.id is distinct from p_role_id) then
    raise exception 'A role called % already exists.', v_name;
  end if;
  select string_agg(k, ', ') into v_bad from unnest(coalesce(p_permissions, '{}')) k
   where not exists (select 1 from public.permissions p where p.key = k);
  if v_bad is not null then raise exception 'Unknown right: %', v_bad; end if;

  if p_role_id is not null then
    select * into v_old from public.roles where id = p_role_id and restaurant_id = v_rest for update;
    if not found then raise exception 'Role not found.'; end if;
    if v_old.name = 'Owner' and v_old.is_system then raise exception 'The Owner role always has every right and cannot be changed.'; end if;
    update public.roles set name = v_name where id = p_role_id;
    delete from public.role_permissions where role_id = p_role_id;
    v_id := p_role_id;
  else
    insert into public.roles (restaurant_id, name, is_system) values (v_rest, v_name, false) returning id into v_id;
  end if;

  insert into public.role_permissions (role_id, permission_key)
  select distinct v_id, k from unnest(coalesce(p_permissions, '{}')) k;

  perform app.audit(case when p_role_id is null then 'role.created' else 'role.changed' end, 'role', v_id,
    jsonb_build_object('name', v_name, 'rights', to_jsonb(coalesce(p_permissions, '{}'))),
    case when p_role_id is null then null else jsonb_build_object('name', v_old.name) end);
  return v_id;
exception when unique_violation then
  raise exception 'A role called % already exists.', v_name;
end $function$
;

CREATE OR REPLACE FUNCTION public.save_supplier(p_id uuid, p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id();
  v_name text := left(trim(coalesce(p->>'name', '')), 80);
  v_days int := coalesce(nullif(trim(coalesce(p->>'payment_days', '')), '')::int, 0);
  v_active boolean := coalesce((p->>'is_active')::boolean, true);
  v_id uuid;
begin
  perform app.require_feature('stock');
  if v_name = '' then raise exception 'Enter the supplier''s name.'; end if;
  if v_days < 0 or v_days > 365 then raise exception 'Payment days must be between 0 and 365.'; end if;
  if v_active and exists (select 1 from public.suppliers s where s.restaurant_id = v_rest and s.is_active
                             and lower(trim(s.name)) = lower(v_name) and s.id is distinct from p_id) then
    raise exception 'A supplier called % already exists.', v_name;
  end if;
  if p_id is null then
    insert into public.suppliers (restaurant_id, name, contact_person, phone, email, tax_no, address, payment_days, notes, is_active)
    values (v_rest, v_name,
            nullif(left(trim(coalesce(p->>'contact_person', '')), 80), ''),
            nullif(left(trim(coalesce(p->>'phone', '')), 30), ''),
            nullif(left(trim(coalesce(p->>'email', '')), 120), ''),
            upper(nullif(left(trim(coalesce(p->>'tax_no', '')), 30), '')),
            nullif(left(trim(coalesce(p->>'address', '')), 300), ''),
            v_days,
            nullif(left(trim(coalesce(p->>'notes', '')), 300), ''),
            v_active)
    returning id into v_id;
  else
    update public.suppliers set
           name = v_name,
           contact_person = nullif(left(trim(coalesce(p->>'contact_person', '')), 80), ''),
           phone = nullif(left(trim(coalesce(p->>'phone', '')), 30), ''),
           email = nullif(left(trim(coalesce(p->>'email', '')), 120), ''),
           tax_no = upper(nullif(left(trim(coalesce(p->>'tax_no', '')), 30), '')),
           address = nullif(left(trim(coalesce(p->>'address', '')), 300), ''),
           payment_days = v_days,
           notes = nullif(left(trim(coalesce(p->>'notes', '')), 300), ''),
           is_active = v_active
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'Supplier not found.'; end if;
  end if;
  perform app.audit('supplier.save', 'suppliers', v_id, jsonb_build_object('name', v_name, 'is_active', v_active));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.save_tax_group(p_group_id uuid, p_name text, p_components jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('tax.manage');
  v_rest uuid := app.current_restaurant_id();
  v_group uuid := p_group_id; v_incl boolean; c jsonb; v_old jsonb;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a name for the tax group.'; end if;
  if p_components is null or jsonb_typeof(p_components) <> 'array' then raise exception 'Invalid tax list.'; end if;
  if jsonb_array_length(p_components) > 6 then raise exception 'A tax group can have at most 6 taxes.'; end if;
  for c in select * from jsonb_array_elements(p_components) loop
    if coalesce(trim(c->>'name'), '') = '' then raise exception 'Every tax needs a name.'; end if;
    if (c->>'rate') is null or (c->>'rate')::numeric < 0 or (c->>'rate')::numeric > 40 then
      raise exception 'Tax rates must be between 0 and 40 percent.';
    end if;
    if coalesce(c->>'applies_when', 'always') not in ('always', 'intra_region', 'inter_region') then
      raise exception 'Unknown option for when a tax applies.';
    end if;
  end loop;

  if v_group is null then
    if exists (select 1 from public.tax_groups where restaurant_id = v_rest and lower(name) = lower(trim(p_name))) then
      raise exception 'A tax group with that name already exists.';
    end if;
    select coalesce(bool_or(is_price_inclusive), false) into v_incl from public.tax_groups where restaurant_id = v_rest;
    insert into public.tax_groups (restaurant_id, name, is_price_inclusive)
    values (v_rest, left(trim(p_name), 60), v_incl) returning id into v_group;
  else
    if not exists (select 1 from public.tax_groups where id = v_group and restaurant_id = v_rest) then
      raise exception 'Tax group not found.';
    end if;
    if exists (select 1 from public.tax_groups where restaurant_id = v_rest and lower(name) = lower(trim(p_name)) and id <> v_group) then
      raise exception 'A tax group with that name already exists.';
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('name', c2.name, 'rate', c2.rate) order by c2.display_order), '[]'::jsonb)
      into v_old
      from public.tax_rates tr join public.tax_rate_components c2 on c2.tax_rate_id = tr.id
     where tr.tax_group_id = v_group and tr.valid_to is null;
    update public.tax_groups set name = left(trim(p_name), 60) where id = v_group;
  end if;

  perform app.write_tax_group(v_rest, v_group, p_components);
  perform app.audit('tax.group_save', 'tax_groups', v_group,
    jsonb_build_object('name', trim(p_name), 'components', p_components), v_old);
  return v_group;
end $function$
;

CREATE OR REPLACE FUNCTION public.send_report_now(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  s public.report_schedules%rowtype; v_tz text; v_local timestamp; v_text text;
begin
  perform app.require_permission('settings.manage');
  perform app.require_permission('report.view_sales');
  select * into s from public.report_schedules
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'That schedule is not here any more. Refresh the page.'; end if;
  select coalesce(b.timezone, r.timezone, 'UTC') into v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = s.branch_id;
  v_local := now() at time zone v_tz;
  if s.last_sent_at is not null and now() - s.last_sent_at < interval '30 seconds' then
    raise exception 'One was sent a moment ago. Wait half a minute and try again.';
  end if;
  -- Counted for the restaurant, not on the schedule: removing a schedule does not give more tests.
  perform pg_advisory_xact_lock(hashtext('report_tests:' || s.restaurant_id::text));
  if coalesce((select tests from public.report_send_days where scope = 'r:' || s.restaurant_id and day = v_local::date), 0) >= 5 then
    raise exception 'You have sent 5 tests today. The next test can be sent tomorrow.';
  end if;
  perform app.report_count('r:' || s.restaurant_id, v_local::date, 0, 1, 0);

  v_text := app.send_report(s.id, true, v_local);
  perform app.audit('report_schedule.test', 'report_schedules', s.id, jsonb_build_object('result', v_text));
  return jsonb_build_object('message', v_text, 'ok', coalesce(v_text, '') !~* '(could not be sent|nothing was sent)');
end $function$
;

CREATE OR REPLACE FUNCTION public.send_to_kitchen(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; v_ids uuid[];
begin
  perform app.require_permission('order.create');
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then return jsonb_build_object('sent', 0); end if;
  select array_agg(oi.id order by oi.created_at, oi.id) into v_ids
    from public.order_items oi
   where oi.order_id = o.id and not oi.held and oi.cancelled_at is null
     and not exists (select 1 from public.products cp where cp.id = oi.product_id and cp.is_charge)
     and not exists (select 1 from public.kitchen_ticket_items ki where ki.order_item_id = oi.id);
  if v_ids is null then return jsonb_build_object('sent', 0); end if;
  perform app.create_kitchen_ticket(o.id, v_ids);
  return jsonb_build_object('sent', array_length(v_ids, 1));
end $function$
;

CREATE OR REPLACE FUNCTION public.session_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('report.view_sales');
  if p_to < p_from or p_to - p_from > 366 then raise exception 'Choose up to one year.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('session', sn, 'bills', c, 'total', t, 'average', round(t / nullif(c, 0), 2),
             'top_items', (select coalesce(jsonb_agg(jsonb_build_object('item', it, 'qty', q) order by q desc), '[]'::jsonb) from (
                 select i.product_name it, sum(i.quantity) q from public.order_items i join public.orders o2 on o2.id = i.order_id
                  where o2.branch_id = app.current_branch_id() and o2.business_date between p_from and p_to and o2.status = 'completed'
                    and o2.merged_into is null and coalesce(o2.session_name, 'Other') = sn and i.cancelled_at is null
                  group by 1 order by 2 desc limit 5) ti))
           order by first_t)
      from (select coalesce(o.session_name, 'Other') sn, count(*) c, sum(o.grand_total) t,
                   min(coalesce(ms.display_order, 99)) first_t
              from public.orders o left join public.meal_sessions ms on ms.id = o.session_id
             where o.branch_id = app.current_branch_id() and o.business_date between p_from and p_to
               and o.status = 'completed' and o.merged_into is null
             group by 1) s), '[]'::jsonb);
end $function$
;

CREATE OR REPLACE FUNCTION public.set_bill_customer(p_order_id uuid, p_gstin text, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.set_bill_prefix(p_prefix text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_p text := btrim(coalesce(p_prefix, '')); cur public.bill_series; old public.bill_series; v_other text; v_had boolean;
begin
  if v_branch is null then raise exception 'No outlet chosen.'; end if;
  if v_p !~ '^[A-Za-z0-9/]{1,7}$' then
    raise exception 'The bill prefix is 1 to 7 letters, digits or "/" (for example BILL26). No spaces or "-": the number is added after a "-".';
  end if;
  cur := app.current_bill_series(v_branch);
  if upper(cur.prefix) = upper(v_p) and cur.prefix = v_p then
    return jsonb_build_object('changed', false, 'prefix', cur.prefix, 'next_number', cur.prefix || '-' || lpad(cur.next_seq::text, greatest(4, length(cur.next_seq::text)), '0'));
  end if;
  select * into old from public.bill_series where restaurant_id = v_rest and upper(prefix) = upper(v_p) for update;
  v_had := found;
  if v_had and old.branch_id <> v_branch then
    select name into v_other from public.branches where id = old.branch_id;
    raise exception 'The prefix % is used by the outlet %. Choose another.', old.prefix, v_other;
  end if;
  if v_had and old.id = cur.id then
    -- Only the letters' case changes; the numbers carry on.
    if exists (select 1 from public.orders where branch_id = v_branch and bill_number like cur.prefix || '-%') then
      raise exception 'Bills have already been made with %. Choose a new prefix instead of changing its capital letters.', cur.prefix;
    end if;
    update public.bill_series set prefix = v_p where id = cur.id returning * into cur;
  else
    update public.bill_series set is_current = false where id = cur.id;
    if v_had then
      update public.bill_series set is_current = true where id = old.id returning * into cur;   -- back to an earlier prefix: carry on
    else
      insert into public.bill_series (restaurant_id, branch_id, prefix, created_by) values (v_rest, v_branch, v_p, v_user) returning * into cur;
    end if;
  end if;
  perform app.audit('settings.bill_prefix', 'branches', v_branch,
    jsonb_build_object('prefix', cur.prefix, 'next_number', cur.prefix || '-' || lpad(cur.next_seq::text, greatest(4, length(cur.next_seq::text)), '0')),
    jsonb_build_object('prefix', (select prefix from public.bill_series where id <> cur.id and branch_id = v_branch order by created_at desc limit 1)));
  return jsonb_build_object('changed', true, 'prefix', cur.prefix, 'next_number', cur.prefix || '-' || lpad(cur.next_seq::text, greatest(4, length(cur.next_seq::text)), '0'));
end $function$
;

CREATE OR REPLACE FUNCTION public.set_business_type(p_type text, p_apply boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('settings.manage');
  return app.set_business_type(app.current_restaurant_id(), p_type, coalesce(p_apply, false));
end $function$
;

CREATE OR REPLACE FUNCTION public.set_central_kitchen(p_branch uuid, p_on boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('settings.manage');
  perform app.require_feature('central_kitchen');
  update public.branches set is_central_kitchen = p_on where id = p_branch and restaurant_id = app.current_restaurant_id() and deleted_at is null;
  if not found then raise exception 'Outlet not found.'; end if;
  perform app.audit('outlet.central_kitchen', 'branches', p_branch, jsonb_build_object('on', p_on));
end $function$
;

CREATE OR REPLACE FUNCTION public.set_company_timezone(p_timezone text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_tz text := btrim(coalesce(p_timezone, ''));
  v_old text;
begin
  if v_tz = '' or v_tz !~ '^([A-Za-z_]+/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?|UTC)$' or v_tz ~ '^(posix|right|SystemV)/'
     or not exists (select 1 from pg_timezone_names n where n.name = v_tz) then
    raise exception 'Choose a time zone from the list.';
  end if;
  select timezone into v_old from public.restaurants where id = v_rest for update;
  if v_old = v_tz and not exists (select 1 from public.branches b where b.restaurant_id = v_rest and b.timezone <> v_tz) then
    return jsonb_build_object('timezone', v_tz, 'changed', false);
  end if;
  if exists (select 1 from public.shifts s where s.restaurant_id = v_rest and s.status = 'open') then
    raise exception 'Close the open shift on every outlet before changing the time zone, so that no bill falls on the wrong day.';
  end if;
  update public.restaurants set timezone = v_tz where id = v_rest;
  update public.branches set timezone = v_tz where restaurant_id = v_rest and timezone <> v_tz;
  perform app.audit('company.timezone', 'restaurants', v_rest, jsonb_build_object('timezone', v_tz), jsonb_build_object('timezone', v_old));
  return jsonb_build_object('timezone', v_tz, 'changed', true, 'was', v_old);
end $function$
;

CREATE OR REPLACE FUNCTION public.set_current_outlet(p_branch uuid, p_all boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if app.current_user_id() is null then raise exception 'You are not signed in.'; end if;
  if app.device_id() is not null then raise exception 'A counter tablet always works in its own outlet.'; end if;
  if not app.can_use_branch(p_branch) then raise exception 'You do not work in that outlet.'; end if;
  if p_all and not (app.is_owner() or not exists (select 1 from public.user_branches ub where ub.user_id = app.current_user_id())) then
    raise exception 'Only the owner can see all outlets together.';
  end if;
  update public.users set current_branch_id = p_branch, all_outlets = coalesce(p_all, false) where id = app.current_user_id();
end $function$
;

CREATE OR REPLACE FUNCTION public.set_kitchen_status(p_ticket_id uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare t public.kitchen_tickets%rowtype;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_status not in ('preparing','ready','served') then raise exception 'Unknown kitchen status.'; end if;
  select * into t from public.kitchen_tickets
   where id = p_ticket_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Kitchen ticket not found.'; end if;
  if t.status = 'cancelled' then raise exception 'This ticket was cancelled.'; end if;
  update public.kitchen_tickets set status = p_status,
         started_at = case when p_status = 'preparing' then coalesce(started_at, now()) else started_at end,
         ready_at   = case when p_status in ('ready','served') then coalesce(ready_at, now()) else ready_at end
   where id = t.id;
  update public.kitchen_ticket_items set status = p_status
   where kitchen_ticket_id = t.id and status <> 'cancelled';
end $function$
;

CREATE OR REPLACE FUNCTION public.set_liquor_prefix(p_prefix text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('settings.manage'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_p text := btrim(coalesce(p_prefix, '')); s public.liquor_series;
begin
  if v_branch is null then raise exception 'No outlet chosen.'; end if;
  if v_p !~ '^[A-Za-z0-9/]{1,7}$' then raise exception 'The liquor bill prefix is 1 to 7 letters, digits or "/" (for example BAR26).'; end if;
  if exists (select 1 from public.liquor_series where restaurant_id = v_rest and upper(prefix) = upper(v_p) and branch_id <> v_branch) then
    raise exception 'The prefix % is used by another outlet. Choose another.', v_p;
  end if;
  if exists (select 1 from public.orders where branch_id = v_branch and upper(split_part(bill_number, '-', 1)) = upper(v_p)) then
    if not exists (select 1 from public.liquor_series where branch_id = v_branch and upper(prefix) = upper(v_p)) then
      raise exception 'Bills already exist with the prefix %. Choose a new one.', v_p;
    end if;
  end if;
  insert into public.liquor_series (restaurant_id, branch_id, prefix) values (v_rest, v_branch, v_p)
  on conflict (branch_id) do update set prefix = excluded.prefix,
       next_seq = case when upper(public.liquor_series.prefix) = upper(excluded.prefix) then public.liquor_series.next_seq else 1 end
  returning * into s;
  perform app.audit('settings.liquor_prefix', 'branches', v_branch, jsonb_build_object('prefix', s.prefix), null);
  return jsonb_build_object('prefix', s.prefix, 'next_number', s.prefix || '-' || lpad(s.next_seq::text, greatest(4, length(s.next_seq::text)), '0'));
end $function$
;

CREATE OR REPLACE FUNCTION public.set_order_guest(p_order_id uuid, p_name text, p_phone text, p_address text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id();
  o public.orders%rowtype;
  v_name text := nullif(left(trim(coalesce(p_name, '')), 80), '');
  v_phone text := app.clean_phone(p_phone);
  v_addr text := nullif(left(trim(coalesce(p_address, '')), 300), '');
  v_cust uuid; v_del timestamptz;
begin
  select * into o from public.orders where id = p_order_id and restaurant_id = v_rest for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if v_phone is not null and length(regexp_replace(p_phone, '[^0-9]', '', 'g')) < 7 then raise exception 'That phone number looks too short.'; end if;
  v_cust := o.customer_id;
  -- Once a bill is paid, the customer it was paid under (and any points earned) stays;
  -- only the name and phone printed on the bill change.
  if v_phone is not null and v_phone is distinct from o.guest_phone
     and (o.customer_id is null or o.payment_status <> 'paid') then
    select c.id, c.deleted_at into v_cust, v_del from public.customers c where c.restaurant_id = v_rest and c.phone = v_phone;
    if v_cust is null then
      insert into public.customers (restaurant_id, name, phone) values (v_rest, coalesce(v_name, 'Guest'), v_phone) returning id into v_cust;
    else
      update public.customers set deleted_at = null,
             name = case when v_name is not null and (name is null or name = 'Guest' or v_del is not null) then v_name else name end
       where id = v_cust and (v_del is not null or (v_name is not null and (name is null or name = 'Guest')));
    end if;
  end if;
  update public.orders set guest_name = v_name, guest_phone = v_phone,
         delivery_address = case when o.order_type = 'delivery' then v_addr else delivery_address end,
         customer_id = v_cust
   where id = o.id;
  perform app.audit('order.guest', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'name', v_name, 'phone', v_phone),
    jsonb_build_object('name', o.guest_name, 'phone', o.guest_phone));
  return jsonb_build_object('bill_number', o.bill_number, 'guest_name', v_name, 'guest_phone', v_phone, 'customer_id', v_cust);
end $function$
;

CREATE OR REPLACE FUNCTION public.set_order_types(p_types text[], p_default text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_t text[] := array(select distinct x from unnest(coalesce(p_types, '{}')) x where x in ('dine_in', 'takeaway', 'delivery') order by 1);
begin
  perform app.require_permission('settings.manage');
  if cardinality(v_t) = 0 then raise exception 'Keep at least one kind of bill.'; end if;
  if not (p_default = any (v_t)) then raise exception 'The billing screen must start on a kind of bill that is switched on.'; end if;
  update public.branch_settings set order_types = v_t, default_order_type = p_default where branch_id = app.current_branch_id();
  if not found then raise exception 'No outlet chosen.'; end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.set_outlet_price(p_product_id uuid, p_branch_id uuid, p_price numeric, p_available boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id(); v_old public.branch_prices%rowtype; v_prod public.products%rowtype;
begin
  perform app.require_feature('multi_outlet');
  select * into v_prod from public.products where id = p_product_id and restaurant_id = v_rest and deleted_at is null;
  if not found then raise exception 'Menu item not found.'; end if;
  if not exists (select 1 from public.branches where id = p_branch_id and restaurant_id = v_rest and deleted_at is null) then
    raise exception 'Outlet not found.';
  end if;
  select * into v_old from public.branch_prices where branch_id = p_branch_id and product_id = p_product_id;
  if p_price is distinct from v_old.price then perform app.require_permission('menu.price_change'); end if;
  if p_available is distinct from v_old.is_available then perform app.require_permission('menu.manage'); end if;
  if p_price is not null and (p_price < 0 or p_price > 10000000) then raise exception 'Enter a sensible price.'; end if;
  if p_price is null and p_available is null then
    delete from public.branch_prices where branch_id = p_branch_id and product_id = p_product_id;
  else
    insert into public.branch_prices (restaurant_id, branch_id, product_id, price, is_available, updated_by)
    values (v_rest, p_branch_id, p_product_id, p_price, p_available, app.current_user_id())
    on conflict (branch_id, product_id) do update set price = excluded.price, is_available = excluded.is_available,
      updated_at = now(), updated_by = excluded.updated_by;
  end if;
  perform app.audit('menu.outlet_price', 'products', p_product_id,
    jsonb_build_object('branch', p_branch_id, 'price', p_price, 'available', p_available),
    jsonb_build_object('price', v_old.price, 'available', v_old.is_available));
end $function$
;

CREATE OR REPLACE FUNCTION public.set_prices_include_tax(p_inclusive boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('tax.manage');
begin
  update public.tax_groups set is_price_inclusive = coalesce(p_inclusive, false)
   where restaurant_id = app.current_restaurant_id();
  perform app.audit('tax.prices_include_tax', 'restaurants', app.current_restaurant_id(),
    jsonb_build_object('prices_include_tax', p_inclusive));
end $function$
;

CREATE OR REPLACE FUNCTION public.set_purchase_order_status(p_id uuid, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('stock.manage');
  po public.purchase_orders%rowtype; v_new text;
begin
  perform app.require_feature('stock');
  select * into po from public.purchase_orders
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Purchase order not found.'; end if;
  if p_action = 'order' then
    if po.status <> 'draft' then raise exception 'Purchase order % has already been sent.', po.number; end if;
    v_new := 'ordered';
  elsif p_action = 'cancel' then
    if po.status not in ('draft', 'ordered') then
      raise exception 'Purchase order % already has goods received. Use "No more coming" to close it instead.', po.number;
    end if;
    v_new := 'cancelled';
  elsif p_action = 'close' then
    if po.status <> 'part_received' then raise exception 'Only a part-received order can be closed this way.'; end if;
    v_new := 'received';
  else
    raise exception 'Unknown action.';
  end if;
  update public.purchase_orders set status = v_new,
         ordered_at = case when v_new = 'ordered' then now() else ordered_at end,
         closed_at = case when v_new in ('cancelled', 'received') then now() else closed_at end
   where id = po.id;
  perform app.audit('purchase_order.' || p_action, 'purchase_orders', po.id, jsonb_build_object('number', po.number, 'status', v_new),
                    jsonb_build_object('status', po.status));
  return jsonb_build_object('id', po.id, 'number', po.number, 'status', v_new);
end $function$
;

CREATE OR REPLACE FUNCTION public.set_report_schedule_active(p_id uuid, p_on boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.report_schedules%rowtype; v_tz text; v_local timestamp; v_handled date; v_on boolean := coalesce(p_on, false);
begin
  perform app.require_permission('settings.manage');
  perform app.require_permission('report.view_sales');
  select * into o from public.report_schedules
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'That schedule is not here any more. Refresh the page.'; end if;
  if o.is_active = v_on then return; end if;
  select coalesce(b.timezone, r.timezone, 'UTC') into v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = o.branch_id;
  v_local := now() at time zone v_tz;
  v_handled := case when v_local::time >= o.send_time then v_local::date else v_local::date - 1 end;
  update public.report_schedules
     set is_active = v_on,
         -- Switched back on after its time has passed today: the next send is tomorrow's.
         last_run_on = case when v_on then greatest(coalesce(o.last_run_on, v_handled), v_handled) else o.last_run_on end,
         updated_at = now()
   where id = o.id;
  perform app.audit('report_schedule.switch', 'report_schedules', o.id, jsonb_build_object('active', v_on), jsonb_build_object('active', o.is_active));
end $function$
;

CREATE OR REPLACE FUNCTION public.set_reservation_status(p_id uuid, p_status text, p_table uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('order.create');
  if p_status not in ('seated', 'cancelled', 'no_show', 'booked', 'waiting') then raise exception 'Unknown status.'; end if;
  if p_table is not null and not exists (select 1 from public.dining_tables
        where id = p_table and restaurant_id = app.current_restaurant_id() and is_active) then
    raise exception 'That table does not exist.';
  end if;
  update public.reservations set status = p_status, updated_at = now(),
         dining_table_id = coalesce(p_table, dining_table_id),
         seated_at = case when p_status = 'seated' then now() else seated_at end
   where id = p_id and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'Booking not found.'; end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.set_second_language(p_lang text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('settings.manage');
  update public.restaurants set second_language = nullif(p_lang, '') where id = app.current_restaurant_id();
  perform app.audit('settings.second_language', 'restaurants', app.current_restaurant_id(), jsonb_build_object('language', p_lang));
end $function$
;

CREATE OR REPLACE FUNCTION public.set_staff_pin(p_user_id uuid, p_pin text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('user.manage');
  u public.users%rowtype; v_role text; v_pin text; v_len int; i int := 0;
begin
  if nullif(trim(coalesce(p_pin, '')), '') is not null then
    raise exception 'PINs are picked by SNA POS so they stay private and unique. Use "Pick a PIN".';
  end if;
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  select name into v_role from public.roles where id = u.role_id;
  if v_role = 'Owner' and not app.is_owner() and u.id <> v_me then
    raise exception 'Only an owner can set another owner''s PIN.';
  end if;
  v_len := case when v_role = 'Owner' or exists (select 1 from public.role_permissions
                  where role_id = u.role_id and permission_key in ('user.manage', 'settings.manage', 'order.void', 'order.refund'))
                then 6 else 4 end;
  loop
    i := i + 1;
    v_pin := lpad((floor(random() * power(10, v_len)))::bigint::text, v_len, '0');
    exit when v_pin !~ '^(\d)\1+$' and v_pin not in ('1234', '4321', '0123', '9876', '123456', '654321', '012345')
      and not exists (select 1 from public.users where restaurant_id = u.restaurant_id and deleted_at is null
                        and id <> u.id and pin_hash = app.pin_hash(u.restaurant_id, v_pin));
    if i > 500 then raise exception 'Could not find a free PIN. Try again.'; end if;
  end loop;
  update public.users set pin_hash = app.pin_hash(u.restaurant_id, v_pin), pin_set_at = now() where id = u.id;
  delete from public.pin_sessions where user_id = u.id;
  perform app.audit('user.pin_set', 'users', u.id, jsonb_build_object('full_name', u.full_name, 'digits', v_len));
  return jsonb_build_object('user_id', u.id, 'pin', v_pin);
end $function$
;

CREATE OR REPLACE FUNCTION public.set_tax_rate(p_tax_group_id uuid, p_total_rate numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('tax.manage');
  v_rest uuid := app.current_restaurant_id();
  g public.tax_groups%rowtype;
  cur public.tax_rates%rowtype;
  v_has boolean;
  v_rate uuid;
  v_r numeric := round(p_total_rate, 3);
begin
  if v_r is null or v_r < 0 or v_r > 40 then
    raise exception 'Enter a tax rate between 0 and 40 percent.';
  end if;
  select * into g from public.tax_groups where id = p_tax_group_id and restaurant_id = v_rest;
  if not found then raise exception 'Tax group not found.'; end if;

  select * into cur from public.tax_rates
   where tax_group_id = g.id and valid_from <= app.local_today(v_rest)
     and (valid_to is null or valid_to >= app.local_today(v_rest))
   order by valid_from desc limit 1 for update;
  v_has := found;
  if v_has and cur.total_rate = v_r then return; end if;

  if v_has and cur.valid_from = app.local_today(v_rest) then
    update public.tax_rates set total_rate = v_r where id = cur.id;
    v_rate := cur.id;
  else
    if v_has then
      update public.tax_rates set valid_to = app.local_today(v_rest) - 1 where id = cur.id;
    end if;
    insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from)
    values (v_rest, g.id, v_r, app.local_today(v_rest)) returning id into v_rate;
  end if;
  perform app.write_tax_components(v_rest, v_rate, v_r);

  perform app.audit('tax.rate_change', 'tax_groups', g.id,
    jsonb_build_object('group', g.name, 'rate', v_r),
    case when v_has then jsonb_build_object('rate', cur.total_rate) else null end);
end $function$
;

CREATE OR REPLACE FUNCTION public.set_user_outlets(p_user_id uuid, p_branches uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  perform app.require_permission('user.manage');
  perform app.require_feature('multi_outlet');
  if not exists (select 1 from public.users where id = p_user_id and restaurant_id = v_rest) then raise exception 'Person not found.'; end if;
  if coalesce(array_length(p_branches, 1), 0) = 0 then raise exception 'Choose at least one outlet.'; end if;
  if exists (select 1 from unnest(p_branches) x where not exists (select 1 from public.branches b where b.id = x and b.restaurant_id = v_rest and b.deleted_at is null)) then
    raise exception 'An outlet in the list does not exist.';
  end if;
  delete from public.user_branches where user_id = p_user_id and not (branch_id = any(p_branches));
  insert into public.user_branches (user_id, branch_id, restaurant_id)
  select p_user_id, x, v_rest from unnest(p_branches) x on conflict do nothing;
  perform app.audit('user.outlets', 'users', p_user_id, jsonb_build_object('outlets', p_branches));
end $function$
;

CREATE OR REPLACE FUNCTION public.settlement_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
     where p.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = p.order_id)) and p.created_at >= v_start and p.created_at < v_end
       and p.status in ('captured', 'refunded')
     group by 1),
  ref as (
    select p.payment_method_id m, sum(r.amount) amt
      from public.refunds r join public.payments p on p.id = r.payment_id
     where r.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = p.order_id)) and r.created_at >= v_start and r.created_at < v_end
     group by 1),
  voids as (
    select p.payment_method_id m, sum(p.amount) amt
      from public.payments p join public.orders o on o.id = p.order_id
     where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.status = 'voided' and o.voided_at >= v_start and o.voided_at < v_end
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
   where p.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = p.order_id)) and p.created_at >= v_start and p.created_at < v_end
     and p.status in ('captured', 'refunded');

  return jsonb_build_object('from', p_from, 'to', p_to, 'timezone', v_tz, 'methods', v_methods, 'payments', v_rows);
end $function$
;

CREATE OR REPLACE FUNCTION public.share_bill(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_tok text; v_phone text;
begin
  perform app.require_permission('order.create');
  perform app.require_feature('whatsapp');
  update public.orders set receipt_token = coalesce(receipt_token, app.new_token())
   where id = p_order and restaurant_id = app.current_restaurant_id()
   returning receipt_token into v_tok;
  if v_tok is null then raise exception 'That bill does not exist.'; end if;
  select c.phone into v_phone from public.orders o join public.customers c on c.id = o.customer_id where o.id = p_order;
  perform app.audit('order.share', 'orders', p_order, '{}'::jsonb, null);
  return jsonb_build_object('token', v_tok, 'phone', v_phone);
end $function$
;

CREATE OR REPLACE FUNCTION public.shift_report(p_shift_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.require_permission('report.view_financial');
  if not exists (select 1 from public.shifts where id = p_shift_id
                 and restaurant_id = app.current_restaurant_id()) then
    raise exception 'Shift not found.';
  end if;
  return app.shift_figures(p_shift_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_add_note(p_restaurant uuid, p_kind text, p_body text, p_next_contact date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid; v_id uuid; v_body text := trim(coalesce(p_body, ''));
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  if coalesce(p_kind, '') not in ('note', 'call', 'visit', 'message', 'email') then raise exception 'Unknown kind of note.'; end if;
  if length(v_body) = 0 then raise exception 'Write the note first.'; end if;
  if length(v_body) > 2000 then raise exception 'The note is too long (2,000 characters at most).'; end if;
  if p_next_contact is not null and p_next_contact < app.sna_today() then raise exception 'The follow-up date cannot be in the past.'; end if;

  perform app.sna_account_row(p_restaurant);
  insert into public.sna_notes (restaurant_id, kind, body, staff_id) values (p_restaurant, p_kind, v_body, v_me) returning id into v_id;
  update public.sna_accounts
     set last_contact = case when p_kind <> 'note' then app.sna_today() else last_contact end,
         -- A contact clears the follow-up that was due, unless a new one is given.
         next_contact = case when p_next_contact is not null then p_next_contact
                             when p_kind <> 'note' and next_contact <= app.sna_today() then null
                             else next_contact end,
         updated_at = now(), updated_by = v_me
   where restaurant_id = p_restaurant;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_add_request(p_restaurant uuid, p_kind text, p_module text DEFAULT NULL::text, p_outlet_name text DEFAULT NULL::text, p_outlet_city text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  perform app.sna_require(array['sales']);
  if p_kind <> 'outlet' then raise exception 'Use the edition and module switches for upgrades and modules.'; end if;
  if coalesce(trim(p_outlet_name), '') = '' then raise exception 'Enter the new outlet''s name.'; end if;
  insert into public.plan_requests (restaurant_id, kind, outlet_name, outlet_city, note, requested_by_staff)
  values (p_restaurant, 'outlet', left(trim(p_outlet_name), 80), left(trim(p_outlet_city), 60), left(trim(p_note), 300), app.sna_staff_id())
  returning id into v_id;
  perform app.log_plan(p_restaurant, 'request.outlet', jsonb_build_object('request', v_id, 'outlet', p_outlet_name, 'by_sna', true));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_add_sale(p_restaurant uuid, p_kind text, p_description text, p_amount numeric, p_sale_date date, p_period_from date DEFAULT NULL::date, p_period_to date DEFAULT NULL::date, p_invoice_no text DEFAULT NULL::text, p_paid_on date DEFAULT NULL::date, p_note text DEFAULT NULL::text, p_extend_licence boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid; v_id uuid; v_cur char(3); v_old date;
  v_desc text := trim(coalesce(p_description, ''));
  v_today date := app.sna_today();
begin
  v_me := app.sna_require(array['sales']);
  if coalesce(p_kind, '') not in ('new', 'renewal', 'upgrade', 'addon', 'outlet', 'hardware', 'service', 'other') then raise exception 'Unknown kind of sale.'; end if;
  if length(v_desc) = 0 then raise exception 'Say what was sold.'; end if;
  if length(v_desc) > 200 then raise exception 'The description is too long (200 characters at most).'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 99999999 then raise exception 'Enter the amount (0 or more).'; end if;
  if p_sale_date is null or p_sale_date > v_today then raise exception 'The sale date cannot be in the future.'; end if;
  if p_paid_on is not null and p_paid_on > v_today then raise exception 'The paid date cannot be in the future.'; end if;
  if p_period_from is not null and p_period_to is not null and p_period_to < p_period_from then raise exception 'The period cannot end before it starts.'; end if;
  if coalesce(p_extend_licence, false) and p_period_to is null then raise exception 'To move the licence date, enter the date the period ends.'; end if;

  perform app.sna_account_row(p_restaurant);
  select currency_code into v_cur from public.restaurants where id = p_restaurant;
  insert into public.sna_sales (restaurant_id, sale_date, kind, description, amount, currency_code, period_from, period_to, invoice_no, paid_on, note, staff_id)
  values (p_restaurant, p_sale_date, p_kind, v_desc, round(p_amount, 2), v_cur, p_period_from, p_period_to,
          nullif(trim(coalesce(p_invoice_no, '')), ''), p_paid_on, nullif(trim(coalesce(p_note, '')), ''), v_me)
  returning id into v_id;

  if coalesce(p_extend_licence, false) then
    select licence_expiry into v_old from public.sna_accounts where restaurant_id = p_restaurant for update;
    update public.sna_accounts
       set licence_expiry = p_period_to,
           licence_start = case when licence_start is null or licence_start > p_period_to then coalesce(p_period_from, p_sale_date) else licence_start end,
           updated_at = now(), updated_by = v_me
     where restaurant_id = p_restaurant;
  end if;
  perform app.log_plan(p_restaurant, 'sale.added', jsonb_strip_nulls(jsonb_build_object(
    'kind', p_kind, 'what', v_desc, 'amount', round(p_amount, 2), 'currency', v_cur,
    'licence_expiry', case when coalesce(p_extend_licence, false) then p_period_to end,
    'expiry_was', case when coalesce(p_extend_licence, false) then v_old end)));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_cancel_sale(p_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid; s public.sna_sales%rowtype; v_reason text := trim(coalesce(p_reason, ''));
begin
  v_me := app.sna_require(array['sales']);
  if length(v_reason) < 3 then raise exception 'Write a short reason for cancelling this entry.'; end if;
  select * into s from public.sna_sales where id = p_id for update;
  if not found then raise exception 'Sale not found.'; end if;
  if s.cancelled_at is not null then raise exception 'This sale was already cancelled.'; end if;
  update public.sna_sales set cancelled_at = now(), cancelled_by = v_me, cancel_reason = left(v_reason, 300) where id = p_id;
  perform app.log_plan(s.restaurant_id, 'sale.cancelled',
    jsonb_build_object('what', s.description, 'amount', s.amount, 'currency', s.currency_code, 'reason', left(v_reason, 300)));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_client(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  r public.restaurants%rowtype; a public.sna_accounts%rowtype;
  v_today date := app.sna_today();
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_id and deleted_at is null;
  if not found then raise exception 'Restaurant not found.'; end if;
  select * into a from public.sna_accounts where restaurant_id = p_id;

  return jsonb_build_object(
    'id', r.id, 'today', v_today,
    'client_code', r.client_code, 'trading_name', r.trading_name, 'legal_name', r.legal_name,
    'country_code', r.country_code, 'currency', r.currency_code, 'edition', r.edition, 'status', r.subscription_status,
    'signed_up', (r.created_at at time zone 'Asia/Kolkata')::date,
    'monthly', app.monthly_charge(r.id),
    'licence_start', a.licence_start, 'licence_expiry', a.licence_expiry, 'days_left', a.licence_expiry - v_today,
    'account_manager', a.account_manager, 'sales_person', a.sales_person, 'support_person', a.support_person,
    'last_contact', a.last_contact, 'next_contact', a.next_contact,
    'owner', (select jsonb_build_object('full_name', u.full_name, 'email', u.email, 'phone', coalesce(u.phone, r.contact_phone))
                from public.users u join public.roles ro on ro.id = u.role_id
               where u.restaurant_id = r.id and ro.name = 'Owner' and ro.is_system and u.deleted_at is null
               order by u.created_at limit 1),
    'usage', jsonb_build_object(
      'outlets',   (select count(*) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null),
      'people',    (select count(*) from public.users u where u.restaurant_id = r.id and u.deleted_at is null and u.is_active),
      'last_bill', (select max(od.business_date) from public.orders od where od.restaurant_id = r.id),
      'bills_30d', (select count(*) from public.orders od where od.restaurant_id = r.id and od.business_date > v_today - 30)),
    'contacts', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'full_name', c.full_name, 'job_title', c.job_title,
                    'phone', c.phone, 'email', c.email) order by c.created_at), '[]'::jsonb)
                   from public.sna_contacts c where c.restaurant_id = r.id and c.removed_at is null),
    'notes', (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'body', n.body, 'created_at', n.created_at,
                    'by', (select s.full_name from public.sna_staff s where s.id = n.staff_id)) order by n.created_at desc), '[]'::jsonb)
                from (select * from public.sna_notes where restaurant_id = r.id order by created_at desc limit 200) n),
    'sales', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'sale_date', s.sale_date, 'kind', s.kind, 'description', s.description,
                    'amount', s.amount, 'currency', s.currency_code, 'period_from', s.period_from, 'period_to', s.period_to,
                    'invoice_no', s.invoice_no, 'paid_on', s.paid_on, 'note', s.note, 'cancelled', s.cancelled_at is not null,
                    'cancel_reason', s.cancel_reason,
                    'by', (select st.full_name from public.sna_staff st where st.id = s.staff_id)) order by s.sale_date desc, s.created_at desc), '[]'::jsonb)
                from public.sna_sales s where s.restaurant_id = r.id),
    'sales_total', (select coalesce(sum(amount), 0) from public.sna_sales where restaurant_id = r.id and cancelled_at is null),
    'sales_unpaid', (select coalesce(sum(amount), 0) from public.sna_sales where restaurant_id = r.id and cancelled_at is null and paid_on is null),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'full_name', s.full_name, 'role', s.role) order by s.full_name), '[]'::jsonb)
                from public.sna_staff s where s.is_active));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_clients(p_search text DEFAULT NULL::text, p_filter text DEFAULT 'all'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today date := app.sna_today();
  v_q text := nullif(trim(coalesce(p_search, '')), '');
  v_counts jsonb; v_rows jsonb;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  if coalesce(p_filter, 'all') not in ('all', 'new', 'expiring', 'expired', 'nolicence', 'followup') then
    raise exception 'Unknown list.';
  end if;

  select jsonb_build_object(
           'all',       count(*),
           'new',       count(*) filter (where (r.created_at at time zone 'Asia/Kolkata')::date > v_today - 14),
           'expiring',  count(*) filter (where a.licence_expiry between v_today and v_today + 30),
           'expired',   count(*) filter (where a.licence_expiry < v_today),
           'nolicence', count(*) filter (where a.licence_expiry is null),
           'followup',  count(*) filter (where a.next_contact <= v_today))
    into v_counts
    from public.restaurants r left join public.sna_accounts a on a.restaurant_id = r.id
   where r.deleted_at is null;

  select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb) into v_rows from (
    select r.created_at, jsonb_build_object(
             'id', r.id, 'client_code', r.client_code, 'trading_name', r.trading_name, 'legal_name', r.legal_name,
             'country_code', r.country_code, 'currency', r.currency_code, 'edition', r.edition, 'status', r.subscription_status,
             'signed_up', (r.created_at at time zone 'Asia/Kolkata')::date,
             'is_new', (r.created_at at time zone 'Asia/Kolkata')::date > v_today - 14,
             'outlets', (select count(*) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null),
             'monthly', app.monthly_charge(r.id),
             'licence_expiry', a.licence_expiry,
             'days_left', a.licence_expiry - v_today,
             'last_contact', a.last_contact, 'next_contact', a.next_contact,
             'account_manager', (select s.full_name from public.sna_staff s where s.id = a.account_manager),
             'open_requests', (select count(*) from public.plan_requests q where q.restaurant_id = r.id and q.status in ('requested', 'approved')),
             'owner_name', o.full_name, 'owner_email', o.email,
             'last_bill', (select max(od.business_date) from public.orders od where od.restaurant_id = r.id)) as j
      from public.restaurants r
      left join public.sna_accounts a on a.restaurant_id = r.id
      left join lateral (
        select u.full_name, u.email from public.users u join public.roles ro on ro.id = u.role_id
         where u.restaurant_id = r.id and ro.name = 'Owner' and ro.is_system and u.deleted_at is null
         order by u.created_at limit 1) o on true
     where r.deleted_at is null
       and (v_q is null or r.trading_name ilike '%' || v_q || '%' or r.legal_name ilike '%' || v_q || '%' or r.client_code = v_q)
       and case coalesce(p_filter, 'all')
             when 'new'       then (r.created_at at time zone 'Asia/Kolkata')::date > v_today - 14
             when 'expiring'  then a.licence_expiry between v_today and v_today + 30
             when 'expired'   then a.licence_expiry < v_today
             when 'nolicence' then a.licence_expiry is null
             when 'followup'  then a.next_contact <= v_today
             else true end
     order by r.created_at desc
     limit 500) x;

  return jsonb_build_object('today', v_today, 'counts', v_counts, 'rows', v_rows);
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_create_client(p_owner_email text, p_owner_name text, p_legal_name text, p_trading_name text, p_country_code text, p_temp_password text, p_branch_name text DEFAULT 'Main Branch'::text, p_branch_code text DEFAULT 'MN'::text, p_tax_registration_no text DEFAULT NULL::text, p_edition text DEFAULT 'basic'::text, p_licence_start date DEFAULT NULL::date, p_licence_expiry date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid; v_auth uuid; v_rest uuid; v_hash text; v_is_sna boolean;
  v_email text := lower(trim(coalesce(p_owner_email, '')));
  v_owner text := trim(coalesce(p_owner_name, ''));
  v_legal text := trim(coalesce(p_legal_name, ''));
  v_trading text := trim(coalesce(p_trading_name, ''));
  v_branch text := coalesce(nullif(trim(coalesce(p_branch_name, '')), ''), 'Main Branch');
  v_code text := upper(coalesce(nullif(trim(coalesce(p_branch_code, '')), ''), 'MN'));
  v_claims text; v_sub text;
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  -- Edition and licence dates are a sales matter, as they are on the client page.
  if coalesce(p_edition, 'basic') <> 'basic' or p_licence_start is not null or p_licence_expiry is not null then
    perform app.sna_require(array['sales']);
  end if;
  if coalesce(p_edition, 'basic') not in ('basic', 'professional') then raise exception 'Unknown edition.'; end if;
  if p_licence_start is not null and p_licence_expiry is not null and p_licence_expiry < p_licence_start then
    raise exception 'The licence cannot end before it starts.';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(v_email) > 200 then raise exception 'Enter the owner''s email address.'; end if;
  if length(v_owner) = 0 or length(v_legal) = 0 or length(v_trading) = 0 then raise exception 'Fill in the business name, the display name and the owner''s name.'; end if;
  if length(v_owner) > 120 or length(v_legal) > 200 or length(v_trading) > 200 or length(v_branch) > 120 then raise exception 'One of the names is too long.'; end if;
  if v_code !~ '^[A-Z0-9]{2,3}$' then raise exception 'The outlet code is 2 or 3 letters or digits, for example MN (a GST bill number can be at most 16 characters).'; end if;

  select id into v_auth from auth.users where lower(email) = v_email;
  if v_auth is null then raise exception 'The sign-in for % could not be made. Try again.', v_email; end if;
  if exists (select 1 from public.devices where auth_user_id = v_auth) then raise exception 'That email belongs to a counter tablet.'; end if;
  if exists (select 1 from public.users where auth_user_id = v_auth and deleted_at is null) then
    raise exception '% already belongs to a restaurant. Use a different email for this owner.', v_email;
  end if;
  v_is_sna := exists (select 1 from public.sna_staff where auth_user_id = v_auth);

  -- The owner gets the temporary password SNA hands over, whoever made the sign-in and whenever:
  -- an address someone else registered first must not keep that person's password.
  -- An SNA staff member testing with their own address keeps their own password.
  if not v_is_sna then
    if length(coalesce(p_temp_password, '')) < 8 or length(p_temp_password) > 72 then raise exception 'The temporary password must be 8 to 72 characters.'; end if;
    v_hash := extensions.crypt(p_temp_password, extensions.gen_salt('bf', 10));
    update auth.users set encrypted_password = v_hash, email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now() where id = v_auth;
    delete from auth.sessions where user_id = v_auth;
  end if;

  -- Build the restaurant exactly as a sign-up always has: as the owner, for this one call.
  v_claims := current_setting('request.jwt.claims', true);
  v_sub := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_auth::text, true);
  v_rest := app.create_restaurant_with_owner(v_legal, v_trading, p_country_code::character(2), v_owner, v_branch, v_code, null, p_tax_registration_no);
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
  if app.sna_staff_id() is distinct from v_me then raise exception 'Could not finish creating the client.'; end if;

  if p_edition = 'professional' then update public.restaurants set edition = 'professional' where id = v_rest; end if;
  update public.restaurants set subscription_status = 'active' where id = v_rest;
  insert into public.sna_accounts (restaurant_id, licence_start, licence_expiry, updated_by)
  values (v_rest, p_licence_start, p_licence_expiry, v_me);
  if not v_is_sna then
    update public.users set must_change_password = true, password_reset_hash = v_hash where restaurant_id = v_rest and auth_user_id = v_auth;
  end if;
  perform app.log_plan(v_rest, 'client.created', jsonb_strip_nulls(jsonb_build_object(
    'owner', v_email, 'edition', coalesce(p_edition, 'basic'), 'licence_start', p_licence_start, 'licence_expiry', p_licence_expiry)));

  return jsonb_build_object('id', v_rest, 'client_code', (select client_code from public.restaurants where id = v_rest),
                            'owner_email', v_email, 'kept_password', v_is_sna);
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_create_outlet(p_request uuid, p_name text, p_code text, p_city text, p_address text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_timezone text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare q public.plan_requests%rowtype; v_rest public.restaurants%rowtype; v_first public.branches%rowtype; v_id uuid;
begin
  perform app.sna_require(array['implementer']);
  select * into q from public.plan_requests where id = p_request for update;
  if not found or q.kind <> 'outlet' then raise exception 'Outlet request not found.'; end if;
  if q.status <> 'approved' then raise exception 'Sales must approve this outlet before it is added.'; end if;
  select * into v_rest from public.restaurants where id = q.restaurant_id;
  if v_rest.edition <> 'professional' then raise exception 'Upgrade the restaurant to Professional before adding outlets.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the outlet name.'; end if;
  if coalesce(trim(p_code), '') !~ '^[A-Za-z0-9]{2,3}$' then raise exception 'The outlet code is 2 or 3 letters or digits (it starts every bill number, and a GST bill number can be at most 16 characters).'; end if;
  if exists (select 1 from public.branches where restaurant_id = q.restaurant_id and upper(code) = upper(trim(p_code)) and deleted_at is null) then
    raise exception 'Another outlet already uses the code %.', upper(trim(p_code));
  end if;
  select * into v_first from public.branches where restaurant_id = q.restaurant_id and deleted_at is null order by created_at limit 1;
  insert into public.branches (restaurant_id, name, code, address_line1, city, country_code, phone, timezone, is_active)
  values (q.restaurant_id, left(trim(p_name), 80), upper(trim(p_code)), nullif(trim(p_address), ''), nullif(trim(p_city), ''),
          v_rest.country_code, nullif(trim(p_phone), ''), coalesce(nullif(p_timezone, ''), v_first.timezone, v_rest.timezone), true)
  returning id into v_id;
  insert into public.branch_settings (branch_id, restaurant_id, receipt_header, receipt_footer, service_charge_percent, cash_rounding_mode,
      default_order_type, auto_print_kot, service_charge_taxable, service_charge_default_on, service_charge_label, rounding_cash_only)
  select v_id, s.restaurant_id, s.receipt_header, s.receipt_footer, s.service_charge_percent, s.cash_rounding_mode,
         s.default_order_type, s.auto_print_kot, s.service_charge_taxable, s.service_charge_default_on, s.service_charge_label, s.rounding_cash_only
    from public.branch_settings s where s.branch_id = v_first.id;
  if not found then
    insert into public.branch_settings (branch_id, restaurant_id) values (v_id, q.restaurant_id);
  end if;
  insert into public.devices (restaurant_id, branch_id, name, device_type, bill_prefix)
  values (q.restaurant_id, v_id, 'Counter 1', 'tablet', 'C1');
  insert into public.user_branches (user_id, branch_id, restaurant_id)
  select u.id, v_id, q.restaurant_id from public.users u join public.roles r on r.id = u.role_id
   where u.restaurant_id = q.restaurant_id and r.name = 'Owner' and r.is_system and u.deleted_at is null
  on conflict do nothing;
  update public.plan_requests set status = 'done', done_by = app.sna_staff_id(), done_at = now(), branch_id = v_id where id = p_request;
  perform app.log_plan(q.restaurant_id, 'outlet.created', jsonb_build_object('request', p_request, 'branch', v_id, 'name', p_name, 'code', upper(trim(p_code))));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_decide_request(p_id uuid, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare q public.plan_requests%rowtype;
begin
  perform app.sna_require(array['sales']);
  select * into q from public.plan_requests where id = p_id for update;
  if not found or q.status <> 'requested' then raise exception 'This request is not waiting for a decision.'; end if;
  if not p_approve then
    update public.plan_requests set status = 'rejected', decided_by = app.sna_staff_id(), decided_at = now(), decision_note = left(p_note, 300) where id = p_id;
    perform app.log_plan(q.restaurant_id, 'request.rejected', jsonb_build_object('request', p_id, 'note', p_note));
    return;
  end if;
  update public.plan_requests set status = 'approved', decided_by = app.sna_staff_id(), decided_at = now(), decision_note = left(p_note, 300) where id = p_id;
  perform app.log_plan(q.restaurant_id, 'request.approved', jsonb_build_object('request', p_id, 'kind', q.kind, 'note', p_note));
  if q.kind = 'upgrade' then perform public.sna_set_edition(q.restaurant_id, 'professional', p_note);
  elsif q.kind = 'module' then perform public.sna_set_module(q.restaurant_id, q.module_key, true, p_note);
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_erase(p_restaurant uuid, p_pos_tx boolean, p_pos_master boolean, p_stock_tx boolean, p_stock_master boolean, p_client_code text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid; r public.restaurants%rowtype; v_live timestamptz;
  v_reason text := trim(coalesce(p_reason, ''));
  v_pos_tx boolean := coalesce(p_pos_tx, false); v_pos_ms boolean := coalesce(p_pos_master, false);
  v_stk_tx boolean := coalesce(p_stock_tx, false); v_stk_ms boolean := coalesce(p_stock_master, false);
  v_g jsonb := app.erase_groups(); v_done jsonb := '{}'::jsonb; v_n bigint; v_more bigint;
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_restaurant and deleted_at is null for update;
  if not found then raise exception 'Restaurant not found.'; end if;
  if not (v_pos_tx or v_pos_ms or v_stk_tx or v_stk_ms) then raise exception 'Tick what to erase.'; end if;
  if v_pos_ms and not v_pos_tx then
    raise exception 'To erase POS masters, tick POS transactions too. The menu and tables cannot go while bills still point at them.';
  end if;
  if v_stk_ms and not v_stk_tx then
    raise exception 'To erase Stock masters, tick Stock transactions too. Ingredients and suppliers cannot go while stock entries still point at them.';
  end if;
  select live_at into v_live from public.sna_accounts where restaurant_id = p_restaurant;
  if v_live is not null then
    raise exception 'This client is live, so its data cannot be erased. These are real bills the restaurant must keep.';
  end if;
  if trim(coalesce(p_client_code, '')) is distinct from r.client_code then
    raise exception 'The client code does not match. Type % to confirm.', r.client_code;
  end if;
  if length(v_reason) < 5 then raise exception 'Write why this data is being erased.'; end if;

  -- From here to the end of this transaction, the "cannot be deleted" guards let this one restaurant through.
  perform set_config('app.erase_restaurant', p_restaurant::text, true);

  if v_pos_tx then
    v_n := app.erase_tables(p_restaurant, v_g->'pos_tx');
    -- The stock those bills used goes with them (sales and returns are stock entries tied to a bill).
    if not v_stk_tx then
      delete from public.stock_movements where restaurant_id = p_restaurant and order_id is not null;
      get diagnostics v_more = row_count;
      v_n := v_n + v_more;
    end if;
    update public.devices set next_bill_seq = 1 where restaurant_id = p_restaurant;
    update public.offline_series set next_seq = 1 where restaurant_id = p_restaurant;
    update public.bill_series set next_seq = 1 where restaurant_id = p_restaurant;
    update public.liquor_series set next_seq = 1 where restaurant_id = p_restaurant;
    v_done := v_done || jsonb_build_object('pos_tx', v_n);
  end if;
  if v_stk_tx then
    v_done := v_done || jsonb_build_object('stock_tx', app.erase_tables(p_restaurant, v_g->'stock_tx'));
  end if;
  if v_pos_ms then
    -- The packing charge is a dish; the outlet setting that points at it is switched off.
    update public.branch_settings set packing_product_id = null where restaurant_id = p_restaurant and packing_product_id is not null;
    v_done := v_done || jsonb_build_object('pos_master', app.erase_tables(p_restaurant, v_g->'pos_master'));
  end if;
  if v_stk_ms then
    v_done := v_done || jsonb_build_object('stock_master', app.erase_tables(p_restaurant, v_g->'stock_master'));
  end if;

  perform set_config('app.erase_restaurant', '', true);
  perform app.log_plan(p_restaurant, 'data.erased', jsonb_build_object('rows', v_done, 'reason', left(v_reason, 300)));
  return jsonb_build_object('rows', v_done);
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_erase_preview(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.restaurants%rowtype; a public.sna_accounts%rowtype; g text; t text; v_n bigint; v_sum bigint; v_out jsonb := '{}'::jsonb; v_parts jsonb;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_id and deleted_at is null;
  if not found then raise exception 'Restaurant not found.'; end if;
  select * into a from public.sna_accounts where restaurant_id = p_id;
  for g in select jsonb_object_keys(app.erase_groups()) loop
    v_sum := 0; v_parts := '{}'::jsonb;
    for t in select jsonb_array_elements_text(app.erase_groups()->g) loop
      execute format('select count(*) from public.%I where restaurant_id = $1', t) into v_n using p_id;
      v_sum := v_sum + v_n;
      if v_n > 0 then v_parts := v_parts || jsonb_build_object(t, v_n); end if;
    end loop;
    v_out := v_out || jsonb_build_object(g, jsonb_build_object('rows', v_sum, 'tables', v_parts));
  end loop;
  return jsonb_build_object(
    'live', a.live_at is not null, 'live_at', a.live_at,
    'live_by', (select full_name from public.sna_staff where id = a.live_by),
    'client_code', r.client_code, 'trading_name', r.trading_name,
    'bills', (select count(*) from public.orders where restaurant_id = p_id),
    'groups', v_out);
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_licence(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare a public.sna_accounts%rowtype;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  if not exists (select 1 from public.restaurants where id = p_id and deleted_at is null) then raise exception 'Restaurant not found.'; end if;
  select * into a from public.sna_accounts where restaurant_id = p_id;
  return app.licence_state(p_id, now())
      || jsonb_build_object('reminder_off', a.reminder_off_for is not null and a.reminder_off_for = a.licence_expiry);
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_me()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('id', s.id, 'full_name', s.full_name, 'email', s.email, 'role', s.role)
    from public.sna_staff s where s.auth_user_id = auth.uid() and s.is_active
$function$
;

CREATE OR REPLACE FUNCTION public.sna_record_sale(p_restaurant uuid, p_kind text, p_description text, p_amount numeric, p_sale_date date, p_period_from date DEFAULT NULL::date, p_period_to date DEFAULT NULL::date, p_invoice_no text DEFAULT NULL::text, p_paid_on date DEFAULT NULL::date, p_note text DEFAULT NULL::text, p_extend_licence boolean DEFAULT false, p_modules text[] DEFAULT '{}'::text[], p_switch_on boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_id uuid; v_key text; v_mods text[];
  v_why text := 'Sold' || coalesce(', invoice ' || nullif(trim(coalesce(p_invoice_no, '')), ''), '');
begin
  perform app.sna_require(array['sales']);
  select coalesce(array_agg(distinct k order by k), '{}') into v_mods from unnest(coalesce(p_modules, '{}')) k where k is not null and trim(k) <> '';
  foreach v_key in array v_mods loop
    if v_key not in ('basic', 'professional') and not exists (select 1 from public.modules where key = v_key and kind = 'addon') then
      raise exception 'Unknown module on the sale: %.', v_key;
    end if;
  end loop;
  if 'basic' = any(v_mods) and 'professional' = any(v_mods) then raise exception 'Choose Basic or Professional, not both.'; end if;

  v_id := public.sna_add_sale(p_restaurant, p_kind, p_description, p_amount, p_sale_date, p_period_from, p_period_to,
                              p_invoice_no, p_paid_on, p_note, p_extend_licence);
  update public.sna_sales set modules = v_mods where id = v_id;

  if coalesce(p_switch_on, false) then
    -- Edition first: an add-on is of no use without it. Moving down to Basic is never done from a sale.
    if 'professional' = any(v_mods) then perform public.sna_set_edition(p_restaurant, 'professional', v_why); end if;
    foreach v_key in array v_mods loop
      if v_key not in ('basic', 'professional') then perform public.sna_set_module(p_restaurant, v_key, true, v_why); end if;
    end loop;
  end if;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_remove_contact(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  update public.sna_contacts set removed_at = now() where id = p_id and removed_at is null;
  if not found then raise exception 'Contact not found.'; end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_requests(p_status text DEFAULT 'open'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'restaurant_id', q.restaurant_id, 'trading_name', r.trading_name,
            'kind', q.kind, 'module_key', q.module_key, 'outlet_name', q.outlet_name, 'outlet_city', q.outlet_city, 'note', q.note,
            'status', q.status, 'created_at', q.created_at, 'decision_note', q.decision_note) order by q.created_at), '[]'::jsonb)
    from public.plan_requests q join public.restaurants r on r.id = q.restaurant_id
   where case when p_status = 'open' then q.status in ('requested', 'approved') else q.status = p_status end);
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_restaurant(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.restaurants%rowtype;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_id;
  if not found then raise exception 'Restaurant not found.'; end if;
  return jsonb_build_object(
    'id', r.id, 'trading_name', r.trading_name, 'legal_name', r.legal_name, 'country_code', r.country_code,
    'currency', r.currency_code, 'edition', r.edition, 'business_type', r.business_type, 'timezone', r.timezone, 'created_at', r.created_at,
    'contact_email', r.contact_email, 'contact_phone', r.contact_phone,
    'monthly', app.monthly_charge(r.id),
    'modules', (select jsonb_agg(jsonb_build_object('key', m.key, 'name', m.name, 'kind', m.kind, 'on', app.feature_on(r.id, m.key),
                  'price', (select monthly_price from public.plan_prices where item = m.key and currency_code = r.currency_code))
                  order by m.display_order) from public.modules m),
    'prices', (select coalesce(jsonb_object_agg(item, monthly_price), '{}'::jsonb) from public.plan_prices where currency_code = r.currency_code),
    'branches', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'city', b.city, 'is_active', b.is_active)
                  order by b.created_at), '[]'::jsonb) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'module_key', q.module_key, 'outlet_name', q.outlet_name,
                  'outlet_city', q.outlet_city, 'note', q.note, 'status', q.status, 'created_at', q.created_at, 'decision_note', q.decision_note)
                  order by q.created_at desc), '[]'::jsonb) from public.plan_requests q where q.restaurant_id = r.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('event', e.event, 'details', e.details, 'created_at', e.created_at,
                  'by', coalesce((select full_name from public.sna_staff where id = e.staff_id), (select full_name from public.users where id = e.user_id)))
                  order by e.created_at desc), '[]'::jsonb)
                 from (select * from public.subscription_events where restaurant_id = r.id order by created_at desc limit 50) e));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_restaurants(p_search text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  return (select coalesce(jsonb_agg(x order by x->>'trading_name'), '[]'::jsonb) from (
    select jsonb_build_object('id', r.id, 'trading_name', r.trading_name, 'legal_name', r.legal_name,
             'country_code', r.country_code, 'currency', r.currency_code, 'edition', r.edition, 'created_at', r.created_at,
             'outlets', (select count(*) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null),
             'modules', (select coalesce(jsonb_agg(rm.module_key order by rm.module_key), '[]'::jsonb) from public.restaurant_modules rm where rm.restaurant_id = r.id),
             'open_requests', (select count(*) from public.plan_requests q where q.restaurant_id = r.id and q.status in ('requested', 'approved')),
             'owner_email', (select u.email from public.users u join public.roles ro on ro.id = u.role_id
                              where u.restaurant_id = r.id and ro.name = 'Owner' and ro.is_system and u.deleted_at is null
                              order by u.created_at limit 1),
             'monthly', app.monthly_charge(r.id)) as x
      from public.restaurants r
     where r.deleted_at is null
       and (coalesce(trim(p_search), '') = '' or r.trading_name ilike '%' || trim(p_search) || '%'
            or r.legal_name ilike '%' || trim(p_search) || '%')
     limit 500) s);
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_sales_list(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.restaurants%rowtype;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_id and deleted_at is null;
  if not found then raise exception 'Restaurant not found.'; end if;
  return jsonb_build_object(
    'modules', (select coalesce(jsonb_object_agg(s.id, to_jsonb(s.modules)), '{}'::jsonb)
                  from public.sna_sales s where s.restaurant_id = p_id and cardinality(s.modules) > 0),
    'catalog', jsonb_build_array(
                 jsonb_build_object('key', 'basic', 'name', 'Basic edition', 'on', r.edition = 'basic'),
                 jsonb_build_object('key', 'professional', 'name', 'Professional edition', 'on', r.edition = 'professional'))
               || (select coalesce(jsonb_agg(jsonb_build_object('key', m.key, 'name', m.name, 'on', app.feature_on(r.id, m.key)) order by m.display_order), '[]'::jsonb)
                     from public.modules m where m.kind = 'addon'));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_save_account(p_restaurant uuid, p_status text, p_licence_start date, p_licence_expiry date, p_account_manager uuid DEFAULT NULL::uuid, p_sales_person uuid DEFAULT NULL::uuid, p_support_person uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid; v_old_status text; a public.sna_accounts%rowtype; v_id uuid;
begin
  v_me := app.sna_require(array['sales']);
  if p_status not in ('trial', 'active', 'past_due', 'suspended', 'cancelled') then raise exception 'Unknown status.'; end if;
  if p_licence_start is not null and p_licence_expiry is not null and p_licence_expiry < p_licence_start then
    raise exception 'The licence cannot end before it starts.';
  end if;
  foreach v_id in array array[p_account_manager, p_sales_person, p_support_person] loop
    if v_id is not null and not exists (select 1 from public.sna_staff where id = v_id and is_active) then
      raise exception 'Choose an active SNA staff member.';
    end if;
  end loop;

  perform app.sna_account_row(p_restaurant);
  select * into a from public.sna_accounts where restaurant_id = p_restaurant for update;
  select subscription_status into v_old_status from public.restaurants where id = p_restaurant for update;

  update public.sna_accounts
     set licence_start = p_licence_start, licence_expiry = p_licence_expiry,
         account_manager = p_account_manager, sales_person = p_sales_person, support_person = p_support_person,
         updated_at = now(), updated_by = v_me
   where restaurant_id = p_restaurant;
  if v_old_status is distinct from p_status then
    update public.restaurants set subscription_status = p_status where id = p_restaurant;
  end if;

  if v_old_status is distinct from p_status or a.licence_start is distinct from p_licence_start or a.licence_expiry is distinct from p_licence_expiry then
    perform app.log_plan(p_restaurant, 'account.changed', jsonb_strip_nulls(jsonb_build_object(
      'status_from', case when v_old_status is distinct from p_status then v_old_status end,
      'status_to',   case when v_old_status is distinct from p_status then p_status end,
      'licence_start', p_licence_start, 'licence_expiry', p_licence_expiry,
      'expiry_was', case when a.licence_expiry is distinct from p_licence_expiry then a.licence_expiry end)));
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_save_contact(p_restaurant uuid, p_id uuid, p_kind text, p_full_name text, p_job_title text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid; v_id uuid;
  v_name text := trim(coalesce(p_full_name, ''));
  v_title text := nullif(trim(coalesce(p_job_title, '')), '');
  v_phone text := nullif(trim(coalesce(p_phone, '')), '');
  v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  if coalesce(p_kind, '') not in ('owner', 'billing', 'accounts', 'manager', 'it', 'contact') then raise exception 'Unknown kind of contact.'; end if;
  if length(v_name) = 0 then raise exception 'Enter the person''s name.'; end if;
  if length(v_name) > 120 or length(coalesce(v_title, '')) > 120 then raise exception 'The name or position is too long.'; end if;
  if v_phone is not null and (v_phone !~ '^[0-9+() -]{6,25}$') then raise exception 'Enter a phone number with digits only (spaces, + and - are fine).'; end if;
  if v_email is not null and (length(v_email) > 200 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') then raise exception 'That email address does not look right.'; end if;
  if v_phone is null and v_email is null then raise exception 'Enter a phone number or an email address.'; end if;

  if p_id is null then
    perform app.sna_account_row(p_restaurant);
    if (select count(*) from public.sna_contacts where restaurant_id = p_restaurant and removed_at is null) >= 30 then
      raise exception 'This client already has 30 contacts. Remove one first.';
    end if;
    insert into public.sna_contacts (restaurant_id, kind, full_name, job_title, phone, email, created_by)
    values (p_restaurant, p_kind, v_name, v_title, v_phone, v_email, v_me) returning id into v_id;
  else
    update public.sna_contacts set kind = p_kind, full_name = v_name, job_title = v_title, phone = v_phone, email = v_email
     where id = p_id and restaurant_id = p_restaurant and removed_at is null returning id into v_id;
    if v_id is null then raise exception 'Contact not found.'; end if;
  end if;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_save_staff(p_email text, p_full_name text, p_role text, p_active boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_auth uuid; v_id uuid; v_me uuid;
begin
  v_me := app.sna_require(array[]::text[]);
  if p_role not in ('admin', 'sales', 'implementer', 'support') then raise exception 'Choose a role.'; end if;
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Enter the name.'; end if;
  select id into v_auth from auth.users where lower(email) = lower(trim(p_email));
  if v_auth is null then
    raise exception 'No SNA POS account uses %. Ask them to sign up first (without creating a restaurant), then add them.', trim(p_email);
  end if;
  select id into v_id from public.sna_staff where auth_user_id = v_auth;
  if v_id = v_me and (not p_active or p_role <> 'admin') then raise exception 'You cannot remove your own admin access.'; end if;
  insert into public.sna_staff (auth_user_id, full_name, email, role, is_active)
  values (v_auth, trim(p_full_name), lower(trim(p_email)), p_role, p_active)
  on conflict (auth_user_id) do update set full_name = excluded.full_name, role = excluded.role, is_active = excluded.is_active
  returning id into v_id;
  perform app.log_plan(null, 'sna_staff.saved', jsonb_build_object('staff', v_id, 'email', lower(trim(p_email)), 'role', p_role, 'active', p_active));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_set_business_type(p_restaurant uuid, p_type text, p_apply boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.sna_require(array['sales', 'support']);
  return app.set_business_type(p_restaurant, p_type, coalesce(p_apply, false));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_set_edition(p_restaurant uuid, p_edition text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_old text; v_n int;
begin
  perform app.sna_require(array['sales']);
  if p_edition not in ('basic', 'professional') then raise exception 'Unknown edition.'; end if;
  select edition into v_old from public.restaurants where id = p_restaurant for update;
  if not found then raise exception 'Restaurant not found.'; end if;
  if v_old = p_edition then return; end if;
  if p_edition = 'basic' then
    select count(*) into v_n from public.branches where restaurant_id = p_restaurant and deleted_at is null;
    if v_n > 1 then raise exception 'This restaurant has % outlets. Basic allows one — close the extra outlets first.', v_n; end if;
  end if;
  update public.restaurants set edition = p_edition where id = p_restaurant;
  update public.plan_requests set status = 'done', decided_by = app.sna_staff_id(), decided_at = now(), done_by = app.sna_staff_id(), done_at = now()
   where restaurant_id = p_restaurant and kind = 'upgrade' and status in ('requested', 'approved') and p_edition = 'professional';
  perform app.log_plan(p_restaurant, 'edition.changed', jsonb_build_object('from', v_old, 'to', p_edition, 'note', p_note));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_set_follow_up(p_restaurant uuid, p_next_contact date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid;
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  if p_next_contact is not null and p_next_contact < app.sna_today() then raise exception 'The follow-up date cannot be in the past.'; end if;
  perform app.sna_account_row(p_restaurant);
  update public.sna_accounts set next_contact = p_next_contact, updated_at = now(), updated_by = v_me where restaurant_id = p_restaurant;
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_set_live(p_restaurant uuid, p_live boolean, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid; v_was timestamptz; v_reason text := trim(coalesce(p_reason, ''));
begin
  if coalesce(p_live, false) then
    v_me := app.sna_require(array['sales', 'implementer', 'support']);
  else
    -- Taking Live off opens the door to erasing real bills: admins only, with a reason.
    v_me := app.sna_require(array[]::text[]);
    if length(v_reason) < 5 then raise exception 'Write why this client is no longer live.'; end if;
  end if;
  perform app.sna_account_row(p_restaurant);
  select live_at into v_was from public.sna_accounts where restaurant_id = p_restaurant for update;
  if coalesce(p_live, false) = (v_was is not null) then return; end if;
  update public.sna_accounts
     set live_at = case when p_live then now() end, live_by = case when p_live then v_me end, updated_at = now(), updated_by = v_me
   where restaurant_id = p_restaurant;
  perform app.log_plan(p_restaurant, case when p_live then 'client.live' else 'client.not_live' end,
                       jsonb_strip_nulls(jsonb_build_object('reason', nullif(left(v_reason, 300), ''))));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_set_module(p_restaurant uuid, p_module text, p_on boolean, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.sna_require(array['sales']);
  if not exists (select 1 from public.modules where key = p_module and kind = 'addon') then raise exception 'Unknown add-on module.'; end if;
  if not exists (select 1 from public.restaurants where id = p_restaurant) then raise exception 'Restaurant not found.'; end if;
  if p_on then
    insert into public.restaurant_modules (restaurant_id, module_key, enabled_by) values (p_restaurant, p_module, app.sna_staff_id())
    on conflict do nothing;
    if not found then return; end if;
    update public.plan_requests set status = 'done', decided_by = app.sna_staff_id(), decided_at = now(), done_by = app.sna_staff_id(), done_at = now()
     where restaurant_id = p_restaurant and kind = 'module' and module_key = p_module and status in ('requested', 'approved');
  else
    delete from public.restaurant_modules where restaurant_id = p_restaurant and module_key = p_module;
    if not found then return; end if;
  end if;
  perform app.log_plan(p_restaurant, case when p_on then 'module.on' else 'module.off' end, jsonb_build_object('module', p_module, 'note', p_note));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_set_price(p_item text, p_currency text, p_price numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.sna_require(array[]::text[]);
  if p_item not in ('basic', 'professional') and not exists (select 1 from public.modules where key = p_item and kind = 'addon') then
    raise exception 'Unknown plan item.';
  end if;
  if p_price is not null and (p_price < 0 or p_price > 1000000) then raise exception 'Enter a sensible price.'; end if;
  insert into public.plan_prices (item, currency_code, monthly_price) values (p_item, upper(p_currency), p_price)
  on conflict (item, currency_code) do update set monthly_price = excluded.monthly_price;
  perform app.log_plan(null, 'price.set', jsonb_build_object('item', p_item, 'currency', upper(p_currency), 'price', p_price));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_set_reminder(p_restaurant uuid, p_on boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_me uuid; v_end date;
begin
  v_me := app.sna_require(array['sales']);
  perform app.sna_account_row(p_restaurant);
  select licence_expiry into v_end from public.sna_accounts where restaurant_id = p_restaurant for update;
  if v_end is null then raise exception 'Set the licence end date first.'; end if;
  update public.sna_accounts
     set reminder_off_for = case when coalesce(p_on, true) then null else v_end end, updated_at = now(), updated_by = v_me
   where restaurant_id = p_restaurant;
  perform app.log_plan(p_restaurant, case when coalesce(p_on, true) then 'reminder.on' else 'reminder.off' end,
                       jsonb_build_object('licence_expiry', v_end));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_set_sale_paid(p_id uuid, p_paid_on date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s public.sna_sales%rowtype;
begin
  perform app.sna_require(array['sales']);
  select * into s from public.sna_sales where id = p_id for update;
  if not found then raise exception 'Sale not found.'; end if;
  if s.cancelled_at is not null then raise exception 'This sale was cancelled.'; end if;
  if p_paid_on is not null and p_paid_on > app.sna_today() then raise exception 'The paid date cannot be in the future.'; end if;
  if p_paid_on is not null and p_paid_on < s.sale_date - 366 then raise exception 'Check the paid date.'; end if;
  update public.sna_sales set paid_on = p_paid_on where id = p_id;
  perform app.log_plan(s.restaurant_id, case when p_paid_on is null then 'sale.unpaid' else 'sale.paid' end,
    jsonb_strip_nulls(jsonb_build_object('what', s.description, 'amount', s.amount, 'currency', s.currency_code, 'paid_on', p_paid_on)));
end $function$
;

CREATE OR REPLACE FUNCTION public.sna_staff_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  perform app.sna_require(array[]::text[]);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'email', email, 'role', role,
            'is_active', is_active, 'created_at', created_at) order by full_name), '[]'::jsonb) from public.sna_staff);
end $function$
;

CREATE OR REPLACE FUNCTION public.split_order(p_order_id uuid, p_items jsonb, p_client_ref uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid;
  o public.orders%rowtype; it public.order_items%rowtype; r record; v_shift uuid; v_device uuid; v_bill text;
  v_new uuid := gen_random_uuid(); v_line uuid; v_c1 jsonb; v_c2 jsonb; v_moved int := 0;
  v_seen record; v_out jsonb;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen
      from public.request_refs rr where rr.restaurant_id = app.current_restaurant_id() and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'split' or v_seen.order_id is distinct from p_order_id then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  v_user := app.require_permission('order.create');
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment. Split the payment instead.', o.bill_number;
  end if;
  if coalesce((o.calc_params->>'discount')::numeric, 0) > 0 or nullif(o.senior_details, 'null'::jsonb) is not null
     or exists (select 1 from public.order_discounts where order_id = o.id) then
    raise exception 'Bill % has a discount, so it cannot be split. Split the payment instead.', o.bill_number;
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Choose the items to move to the new bill.';
  end if;
  select id into v_shift from public.shifts where branch_id = o.branch_id and status = 'open' limit 1; if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;
  if v_shift is null then raise exception 'Open a shift before taking bills.'; end if;

  if o.is_liquor then
    select n.device_id, n.bill_no into v_device, v_bill from app.next_liquor_number(o.branch_id) n;
  else
    select n.device_id, n.bill_no into v_device, v_bill from app.next_bill_number(o.branch_id) n;
  end if;
  insert into public.orders
    (id, restaurant_id, branch_id, device_id, bill_number, order_type, dining_table_id, customer_id,
     cashier_id, shift_id, currency_code, status, payment_status, client_created_at, calc_params)
  values
    (v_new, o.restaurant_id, o.branch_id, v_device, v_bill, o.order_type, o.dining_table_id, o.customer_id,
     v_user, v_shift, o.currency_code, 'open', 'unpaid', now(), o.calc_params);

  for r in select (x->>'order_item_id') as oid, sum(coalesce((x->>'qty')::numeric, 0)) as q
             from jsonb_array_elements(p_items) x group by 1 loop
    if coalesce(r.oid, '') !~* '^[0-9a-f-]{36}$' then raise exception 'An item is not on this bill.'; end if;
    select * into it from public.order_items where id = r.oid::uuid and order_id = o.id and cancelled_at is null for update;
    if not found then raise exception 'An item is not on this bill.'; end if;
    if r.q <= 0 then continue; end if;
    if r.q > it.quantity then raise exception 'Only % of % are on the bill.', trim_scale(it.quantity), it.product_name; end if;
    v_moved := v_moved + 1;
    if r.q = it.quantity then
      update public.order_items set order_id = v_new where id = it.id;
      update public.order_item_taxes set order_id = v_new where order_item_id = it.id;
    else
      update public.order_items set quantity = quantity - r.q where id = it.id;
      v_line := gen_random_uuid();
      insert into public.order_items
        (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity, modifier_total,
         line_subtotal, line_discount, line_tax, line_total, is_price_inclusive, kitchen_note,
         net_amount, service_charge, tax_included, tax_comps, options_text, created_at)
      values
        (v_line, it.restaurant_id, v_new, it.product_id, it.product_name, it.unit_price, r.q, it.modifier_total,
         0, 0, 0, 0, it.is_price_inclusive, it.kitchen_note, 0, 0, 0, it.tax_comps, it.options_text, clock_timestamp());
      insert into public.order_item_modifiers (restaurant_id, order_item_id, modifier_item_id, name, price_delta)
      select restaurant_id, v_line, modifier_item_id, name, price_delta from public.order_item_modifiers where order_item_id = it.id;
      -- The kitchen already has this line. Give the moved part its own kitchen
      -- line, so cancelling or voiding one bill never touches the other's food.
      insert into public.kitchen_ticket_items (restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, note, status, product_name_local)
      select k.restaurant_id, k.kitchen_ticket_id, v_line, k.product_name, r.q, k.note, k.status, k.product_name_local
        from public.kitchen_ticket_items k
       where k.order_item_id = it.id and k.status <> 'cancelled' and k.quantity > r.q
       order by k.id limit 1;
      update public.kitchen_ticket_items set quantity = quantity - r.q
       where id = (select k.id from public.kitchen_ticket_items k
                    where k.order_item_id = it.id and k.status <> 'cancelled' and k.quantity > r.q
                    order by k.id limit 1);
    end if;
  end loop;
  if v_moved = 0 then raise exception 'Choose the items to move to the new bill.'; end if;
  if not exists (select 1 from public.order_items where order_id = o.id and cancelled_at is null) then
    raise exception 'Leave at least one item on bill %.', o.bill_number;
  end if;

  v_c1 := app.recalc_order(o.id);
  v_c2 := app.recalc_order(v_new);
  update public.orders set status = 'completed',
         payment_status = case when (v_c2->>'grand_total')::numeric = 0 then 'paid' else 'unpaid' end
   where id = v_new;

  perform app.audit('order.split', 'orders', v_new,
    jsonb_build_object('bill_number', v_bill, 'split_from', o.bill_number, 'grand_total', (v_c2->>'grand_total')::numeric),
    jsonb_build_object('source_total_before', o.grand_total, 'source_total_after', (v_c1->>'grand_total')::numeric));
  v_out := jsonb_build_object('order_id', v_new, 'bill_number', v_bill, 'grand_total', (v_c2->>'grand_total')::numeric,
                            'source_bill_number', o.bill_number, 'source_grand_total', (v_c1->>'grand_total')::numeric);
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result)
    values (app.current_restaurant_id(), p_client_ref, 'split', p_order_id, v_out);
    -- Request ids only matter for a retry within minutes; old ones are cleared as new ones arrive.
    delete from public.request_refs
     where restaurant_id = app.current_restaurant_id() and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $function$
;

CREATE OR REPLACE FUNCTION public.stock_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_branch uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_levels jsonb; v_costs jsonb;
begin
  perform app.require_feature('stock');
  perform app.require_permission('stock.manage');
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz; v_end := (p_to + 1)::timestamp at time zone v_tz;
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_levels from (
    select jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'cost', i.cost_per_unit, 'reorder', i.reorder_level, 'category', i.category,
      'stock', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id), 0),
      'used', -coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind in ('sale', 'returned') and m.created_at >= v_start and m.created_at < v_end), 0),
      'wasted', -coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind = 'wastage' and m.created_at >= v_start and m.created_at < v_end), 0),
      'bought', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind = 'purchase' and m.created_at >= v_start and m.created_at < v_end), 0),
      'transfers', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id and m.kind in ('transfer_in', 'transfer_out') and m.created_at >= v_start and m.created_at < v_end), 0),
      'count_diff', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind = 'count' and m.created_at >= v_start and m.created_at < v_end), 0)) x
      from public.ingredients i where i.restaurant_id = v_rest and i.is_active) z;
  select coalesce(jsonb_agg(x order by (x->>'cost_pct')::numeric desc nulls last), '[]'::jsonb) into v_costs from (
    select jsonb_build_object('product', p.name, 'price', p.price,
      'cost', round(sum(rl.qty * i.cost_per_unit), 2),
      'cost_pct', case when p.price > 0 then round(100 * sum(rl.qty * i.cost_per_unit) / p.price, 1) end) x
      from public.products p join public.recipe_lines rl on rl.product_id = p.id join public.ingredients i on i.id = rl.ingredient_id
     where p.restaurant_id = v_rest and p.deleted_at is null group by p.id, p.name, p.price) z;
  return jsonb_build_object('levels', v_levels, 'food_cost', v_costs);
end $function$
;

CREATE OR REPLACE FUNCTION public.sync_offline_bill(p_bill jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.create');
  v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_ref uuid; ser public.offline_series; v_seq int; v_no text; v_expected text; v_at timestamptz; v_liq boolean := false;
  v_shift uuid; v_existing uuid; it jsonb; v_prod public.products%rowtype; v_incl boolean; v_rate uuid; v_comps jsonb;
  v_lines jsonb := '[]'::jsonb; v_calc_lines jsonb := '[]'::jsonb; i int := 0; v_hist numeric; v_flags jsonb := '[]'::jsonb;
  v_opts jsonb; v_text text; v_delta numeric; v_price numeric; v_disc numeric; v_sc boolean; bs record; v_c jsonb;
  v_order uuid := gen_random_uuid(); v_ids uuid[]; v_method uuid; v_kind text; v_amount numeric(14,2); v_round numeric(14,2) := 0;
  v_tendered numeric; v_currency char(3); v_rmode text; v_device uuid;
  v_snap timestamptz; v_bp numeric; v_hsnap numeric; v_srv numeric; v_ok boolean; v_claim timestamptz; v_summary text;
begin
  v_ref := (p_bill->>'client_id')::uuid;
  if v_ref is null then raise exception 'Offline bill without an id.'; end if;
  perform pg_advisory_xact_lock(hashtext('order_ref:' || v_ref::text));
  select id into v_existing from public.orders where restaurant_id = v_rest and client_ref = v_ref;
  if found then return jsonb_build_object('ok', true, 'order_id', v_existing, 'repeat', true); end if;

  select * into ser from public.offline_series where branch_id = v_branch and device_key = p_bill->>'device_key' for update;
  if not found then raise exception 'This device has no offline bill series.'; end if;
  v_seq := (p_bill->>'seq')::int;
  if v_seq is null or v_seq < 1 or v_seq > 999999 then raise exception 'Bad offline bill number.'; end if;
  v_no := p_bill->>'number';
  -- New numbers: <one of this outlet's bill prefixes>-X<device>-<seq>. Older devices: <code>-X01-<fy>-<seq>.
  v_expected := '-X' || (substr(ser.prefix, 2)::int) || '-' || lpad(v_seq::text, greatest(4, length(v_seq::text)), '0');
  if not (right(coalesce(v_no, ''), length(v_expected)) = v_expected
          and (exists (select 1 from public.bill_series bs2 where bs2.branch_id = v_branch
                       and bs2.prefix = left(v_no, length(v_no) - length(v_expected)))
               or exists (select 1 from public.liquor_series ls where ls.branch_id = v_branch
                       and ls.prefix = left(v_no, length(v_no) - length(v_expected))))) then
    v_expected := (select code from public.branches where id = v_branch) || '-' || ser.prefix || '-' ||
                  case when p_bill->>'fy' is not null then (p_bill->>'fy') || '-' else '' end || lpad(v_seq::text, greatest(4, length(v_seq::text)), '0');
    if v_no is distinct from v_expected then raise exception 'Offline bill number % does not match this device.', v_no; end if;
  end if;
  v_liq := exists (select 1 from public.liquor_series ls where ls.branch_id = v_branch and v_no like ls.prefix || '-X%');
  if exists (select 1 from public.orders where branch_id = v_branch and bill_number = v_no) then
    raise exception 'Bill number % is already used.', v_no;
  end if;
  v_claim := coalesce((p_bill->>'created_at')::timestamptz, now());
  v_at := least(v_claim, now());
  -- A till clock that runs ahead is clamped to now (as before) and now reported, so the owner can have the clock fixed.
  if v_claim > now() + interval '5 minutes' then
    v_flags := v_flags || jsonb_build_object('flag', 'device_clock_ahead', 'till_time', v_claim, 'server_time', now());
  end if;
  -- When the till last copied the menu: its prices were right at that moment even if the owner changed them since.
  -- Only believed if it is no older than 14 days before the bill, so an old time cannot be used to reach old, cheap prices.
  begin v_snap := nullif(p_bill->>'snapshot_at', '')::timestamptz; exception when others then v_snap := null; end;
  if v_snap is not null and (v_snap > v_at or v_snap < v_at - interval '14 days') then v_snap := null; end if;
  if v_at < now() - interval '7 days' then v_flags := v_flags || jsonb_build_object('flag', 'older_than_7_days'); end if;

  select s.id into v_shift from public.shifts s where s.branch_id = v_branch and s.status = 'open' order by s.opened_at desc limit 1; if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then return jsonb_build_object('ok', false, 'reason', 'Open a shift to send offline bills.'); end if;

  -- Lines at the prices shown offline; any price that was not the menu price at that time is flagged for the owner.
  for it in select * from jsonb_array_elements(coalesce(p_bill->'items', '[]'::jsonb)) loop
    select * into v_prod from public.products where id = (it->>'product_id')::uuid and restaurant_id = v_rest;
    if not found then raise exception 'An item on offline bill % no longer exists.', v_no; end if;
    v_opts := '[]'::jsonb; v_delta := 0; v_text := null;
    if jsonb_typeof(it->'options') = 'array' and jsonb_array_length(it->'options') > 0 then
      select coalesce(jsonb_agg(jsonb_build_object('id', mi.id, 'name', mi.name, 'price_delta', mi.price_delta, 'group', mg.name) order by mg.name, mi.display_order), '[]'::jsonb),
             coalesce(sum(mi.price_delta), 0), string_agg(mi.name, ', ' order by mg.name, mi.display_order)
        into v_opts, v_delta, v_text
        from jsonb_array_elements_text(it->'options') x
        join public.modifier_items mi on mi.id = x::uuid and mi.restaurant_id = v_rest
        join public.modifier_groups mg on mg.id = mi.modifier_group_id;
    end if;
    v_price := round((it->>'price')::numeric, 2);
    select price into v_hist from public.product_price_history
     where product_id = v_prod.id and valid_from <= v_at and (valid_to is null or valid_to > v_at) order by valid_from desc limit 1;
    if v_hist is null then
      select price into v_hist from public.product_price_history where product_id = v_prod.id order by valid_from limit 1;
    end if;
    v_bp := (select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = v_prod.id);
    -- the price this menu really had when the bill was made (happy-hour rules included)
    v_srv := app.rule_price(v_rest, v_branch, v_prod.id, coalesce(v_bp, v_hist, v_prod.price), v_at) + v_delta;
    v_ok := v_price = v_srv or v_price = coalesce(v_hist, v_prod.price) + v_delta or v_price = v_prod.price + v_delta
            or (v_bp is not null and v_price = v_bp + v_delta);
    if not v_ok and v_snap is not null then
      select price into v_hsnap from public.product_price_history
       where product_id = v_prod.id and valid_from <= v_snap and (valid_to is null or valid_to > v_snap) order by valid_from desc limit 1;
      if v_hsnap is not null then
        v_ok := v_price = v_hsnap + v_delta or v_price = app.rule_price(v_rest, v_branch, v_prod.id, coalesce(v_bp, v_hsnap), v_snap) + v_delta;
      end if;
    end if;
    if not v_ok then
      -- Not a price this menu has ever had: it is NOT trusted. The bill is recorded at the real price, and the owner is told.
      v_flags := v_flags || jsonb_build_object('flag', 'price_corrected', 'item', v_prod.name, 'offline_price', v_price, 'menu_price', v_srv);
      v_price := v_srv;
    end if;
    select g2.is_price_inclusive into v_incl from public.tax_groups g2 where g2.id = v_prod.tax_group_id;
    select tr.id into v_rate from public.tax_rates tr where tr.tax_group_id = v_prod.tax_group_id
       and tr.valid_from <= v_at::date and (tr.valid_to is null or tr.valid_to >= v_at::date) order by tr.valid_from desc limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'rate', rate, 'compound', is_compound) order by display_order), '[]'::jsonb)
      into v_comps from public.tax_rate_components where tax_rate_id = v_rate and applies_when in ('always', 'intra_region');
    if coalesce((it->>'qty')::numeric, 0) <= 0 or (it->>'qty')::numeric > 999 then raise exception 'Bad quantity on offline bill %.', v_no; end if;
    i := i + 1;
    v_lines := v_lines || jsonb_build_object('key', i, 'product_id', v_prod.id, 'name', v_prod.name, 'base_price', v_price - v_delta,
      'price', v_price, 'options', v_opts, 'options_text', v_text, 'qty', (it->>'qty')::numeric,
      'note', nullif(left(coalesce(it->>'note', ''), 200), ''), 'inclusive', coalesce(v_incl, false), 'comps', v_comps);
  end loop;
  if i = 0 then raise exception 'Offline bill % has no items.', v_no; end if;

  v_disc := round(coalesce((p_bill->>'discount')::numeric, 0), 2);
  if v_disc < 0 then v_disc := 0; end if;
  if v_disc > 0 and not app.allowed('order.discount') then
    -- Online, a discount needs a manager. Offline nobody can approve it, so without the right it is not honoured here.
    v_flags := v_flags || jsonb_build_object('flag', 'discount_removed', 'amount', v_disc);
    v_disc := 0;
  end if;
  select coalesce(s.service_charge_percent, 0) pct, coalesce(s.service_charge_taxable, false) tx,
         coalesce(s.cash_rounding_mode, 'none') rmode, coalesce(s.rounding_cash_only, false) rcash
    into bs from public.branch_settings s where s.branch_id = v_branch;
  v_sc := coalesce((p_bill->>'service_charge')::boolean, false) and bs.pct > 0;
  v_rmode := case when bs.rcash then 'none' else bs.rmode end;

  select d.id into v_device from public.devices d where d.branch_id = v_branch and d.is_active and d.device_type <> 'counter' order by d.created_at limit 1;
  select currency_code into v_currency from public.restaurants where id = v_rest;

  perform set_config('app.liquor_bill', case when v_liq then 'on' else '' end, true);
  insert into public.orders (id, restaurant_id, branch_id, device_id, bill_number, order_type, cashier_id, shift_id, currency_code,
                             status, payment_status, client_created_at, created_at, calc_params, client_ref, offline_flags)
  values (v_order, v_rest, v_branch, v_device, v_no, case when p_bill->>'order_type' in ('dine_in', 'takeaway', 'delivery') then p_bill->>'order_type' else 'takeaway' end,
          v_user, v_shift, v_currency, 'open', 'unpaid', v_at, v_at,
          jsonb_build_object('discount', v_disc, 'sc_percent', case when v_sc then bs.pct else 0 end, 'sc_taxable', bs.tx, 'senior', null, 'rounding', v_rmode),
          v_ref, nullif(v_flags, '[]'::jsonb));
  v_ids := app.insert_order_lines(v_order, v_rest, v_lines);
  v_c := app.recalc_order(v_order);
  if (v_c->>'discount')::numeric > 0 then
    insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
    values (v_rest, v_order, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric, 'Offline bill', v_user);
  end if;
  if p_bill ? 'grand_total' and round((p_bill->>'grand_total')::numeric, 2) <> (v_c->>'grand_total')::numeric then
    v_flags := v_flags || jsonb_build_object('flag', 'total_differs', 'printed', (p_bill->>'grand_total')::numeric, 'recorded', (v_c->>'grand_total')::numeric);
  end if;

  v_method := (p_bill->>'method_id')::uuid;
  select kind into v_kind from public.payment_methods where id = v_method and restaurant_id = v_rest;
  if not found then
    v_flags := v_flags || jsonb_build_object('flag', 'method_unknown', 'sent', p_bill->>'method_id');
    select id, kind into v_method, v_kind from public.payment_methods where restaurant_id = v_rest and kind = 'cash' limit 1;
  end if;
  v_amount := (v_c->>'grand_total')::numeric;
  if v_kind = 'cash' and bs.rcash and bs.rmode <> 'none' then
    v_amount := app.round_cash(v_amount, bs.rmode);
    v_round := v_amount - (v_c->>'grand_total')::numeric;
  end if;
  v_tendered := nullif((p_bill->>'tendered')::numeric, 0);
  if v_amount > 0 then
    insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, tendered_amount, change_amount,
                                 status, received_by, client_created_at, rounding_adjustment, reference_no, client_ref, shift_id)
    values (gen_random_uuid(), v_rest, v_order, v_method, v_amount, v_currency, case when v_tendered >= v_amount then v_tendered end,
            case when v_tendered >= v_amount then v_tendered - v_amount else 0 end, 'captured', v_user, v_at, v_round,
            nullif(left(trim(coalesce(p_bill->>'reference', '')), 60), ''), v_ref, v_shift);
  end if;
  update public.orders set status = 'completed', payment_status = 'paid', paid_total = v_amount, synced_at = now() where id = v_order;
  -- The kitchen already got a printed ticket offline; keep a served ticket for the record.
  perform app.create_kitchen_ticket(v_order, v_ids);
  update public.kitchen_tickets set status = 'served', printed_at = v_at where order_id = v_order;

  if v_liq then
    update public.offline_series set liquor_next_seq = greatest(liquor_next_seq, v_seq + 1), last_sync_at = now() where id = ser.id;
  else
  update public.offline_series set next_seq = greatest(next_seq, v_seq + 1), last_sync_at = now() where id = ser.id;
  end if;
  if jsonb_array_length(v_flags) > 0 then
    update public.orders set offline_flags = v_flags where id = v_order;
    select string_agg(case f->>'flag'
             when 'price_corrected' then 'price of ' || (f->>'item') || ' corrected ' || (f->>'offline_price') || ' -> ' || (f->>'menu_price')
             when 'discount_removed' then 'discount ' || (f->>'amount') || ' removed (no right to give it)'
             when 'method_unknown' then 'unknown payment method, recorded as cash'
             when 'total_differs' then 'till total ' || (f->>'printed') || ' but bill ' || (f->>'recorded')
             when 'device_clock_ahead' then 'till clock was ahead'
             when 'older_than_7_days' then 'bill is over 7 days old'
             else f->>'flag' end, '; ') into v_summary
      from jsonb_array_elements(v_flags) f;
    perform app.audit('order.offline_flagged', 'orders', v_order,
      jsonb_build_object('bill_number', v_no, 'summary', v_summary, 'flags', v_flags));
  end if;
  perform app.audit('order.offline_sync', 'orders', v_order,
    jsonb_build_object('bill_number', v_no, 'grand_total', (v_c->>'grand_total')::numeric, 'made_at', v_at, 'flags', v_flags));
  return jsonb_build_object('ok', true, 'order_id', v_order, 'bill_number', v_no, 'grand_total', (v_c->>'grand_total')::numeric,
                            'flags', v_flags);
end $function$
;

CREATE OR REPLACE FUNCTION public.table_qr_codes()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  perform app.require_permission('settings.manage');
  perform app.require_feature('qr_ordering');
  update public.dining_tables set qr_token = app.new_token()
   where restaurant_id = v_rest and branch_id = v_branch and is_active and qr_token is null;
  return coalesce((select jsonb_agg(jsonb_build_object('table_id', t.id, 'table_number', t.table_number, 'token', t.qr_token)
                    order by length(t.table_number), t.table_number)
                     from public.dining_tables t where t.restaurant_id = v_rest and t.branch_id = v_branch and t.is_active and not t.is_kiosk), '[]'::jsonb);
end $function$
;

CREATE OR REPLACE FUNCTION public.tax_group_set_liquor(p_group uuid, p_on boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('tax.manage');
begin
  update public.tax_groups set separate_bill = coalesce(p_on, false) where id = p_group and restaurant_id = app.current_restaurant_id();
  if not found then raise exception 'That tax group was not found.'; end if;
  perform app.audit('tax.liquor', 'tax_groups', p_group, jsonb_build_object('liquor', p_on), null);
end $function$
;

CREATE OR REPLACE FUNCTION public.top_up_gift_card(p_code text, p_amount numeric, p_method_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('payment.take'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  g public.gift_cards%rowtype; v_kind text; v_drawer boolean; v_shift uuid; v_amt numeric := round(coalesce(p_amount, 0), 2);
begin
  perform app.require_feature('loyalty');
  if v_amt <= 0 or v_amt > 1000000 then raise exception 'Enter the amount to add.'; end if;
  select * into g from public.gift_cards where restaurant_id = v_rest and code = upper(trim(p_code)) for update;
  if not found then raise exception 'No card with that code.'; end if;
  select kind, affects_cash_drawer into v_kind, v_drawer from public.payment_methods where id = p_method_id and restaurant_id = v_rest and is_active;
  if not found or v_kind in ('gift_card', 'loyalty', 'advance', 'account') then raise exception 'Choose how the guest paid.'; end if;
  select id into v_shift from public.shifts where branch_id = v_branch and status = 'open' limit 1;
  if v_shift is null then v_shift := app.auto_shift(v_branch); end if;
  if v_shift is null then raise exception 'Open a shift first.'; end if;
  insert into public.gift_card_ledger (restaurant_id, gift_card_id, amount, kind, created_by) values (v_rest, g.id, v_amt, 'topup', v_user);
  if g.expires_on is not null and g.expires_on < app.local_today(v_rest) + 365 then
    update public.gift_cards set expires_on = app.local_today(v_rest) + 365 where id = g.id;
  end if;
  if v_kind = 'cash' or coalesce(v_drawer, false) then
    insert into public.cash_movements (restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_rest, v_shift, 'in', v_amt, 'Card top-up ' || g.code, v_user);
  end if;
  perform app.audit('giftcard.topup', 'gift_cards', g.id, jsonb_build_object('code', g.code, 'amount', v_amt, 'method', v_kind), null);
  return jsonb_build_object('code', g.code, 'added', v_amt, 'balance', app.gift_balance(g.id));
end $function$
;

CREATE OR REPLACE FUNCTION public.transfer_stock(p_ingredient_id uuid, p_qty numeric, p_to_branch uuid, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_from uuid := app.current_branch_id();
  v_ing public.ingredients%rowtype; v_now numeric; v_id uuid := gen_random_uuid(); v_from_name text; v_to_name text;
begin
  perform app.require_feature('central_kitchen');
  perform app.require_feature('stock');
  select * into v_ing from public.ingredients where id = p_ingredient_id and restaurant_id = v_rest;
  if not found then raise exception 'Ingredient not found.'; end if;
  if p_to_branch = v_from then raise exception 'Choose another outlet to send to.'; end if;
  select name into v_to_name from public.branches where id = p_to_branch and restaurant_id = v_rest and deleted_at is null;
  if v_to_name is null then raise exception 'Outlet not found.'; end if;
  select name into v_from_name from public.branches where id = v_from;
  if p_qty is null or p_qty <= 0 then raise exception 'Enter a quantity.'; end if;
  perform pg_advisory_xact_lock(hashtext('stock:' || v_from::text || ':' || v_ing.id::text));
  select coalesce(sum(qty), 0) into v_now from public.stock_movements where branch_id = v_from and ingredient_id = v_ing.id;
  if p_qty > v_now then raise exception 'Only % % of % in stock here.', v_now, v_ing.unit, v_ing.name; end if;
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, transfer_id) values
    (v_rest, v_from, v_ing.id, 'transfer_out', -p_qty, v_ing.cost_per_unit, left('To ' || v_to_name || coalesce(': ' || nullif(trim(p_note), ''), ''), 200), v_user, v_id),
    (v_rest, p_to_branch, v_ing.id, 'transfer_in', p_qty, v_ing.cost_per_unit, left('From ' || v_from_name || coalesce(': ' || nullif(trim(p_note), ''), ''), 200), v_user, v_id);
  perform app.audit('stock.transfer', 'ingredients', v_ing.id, jsonb_build_object('qty', p_qty, 'from', v_from, 'to', p_to_branch, 'transfer', v_id));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.undo_supplier_payment(p_payment_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('stock.manage');
  sp public.supplier_payments%rowtype; g public.goods_receipts%rowtype;
  v_shift uuid; v_move uuid; v_sup text; v_id uuid := gen_random_uuid(); v_today date; v_paid numeric(14,2);
begin
  perform app.require_feature('stock');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for undoing the payment.'; end if;
  select * into sp from public.supplier_payments
   where id = p_payment_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id();
  if not found then raise exception 'Payment not found.'; end if;
  -- The receipt row is the lock for everything that changes what is owed on it.
  select * into g from public.goods_receipts where id = sp.goods_receipt_id for update;
  if sp.reverses_id is not null then raise exception 'That entry is itself an undo; it cannot be undone.'; end if;
  if exists (select 1 from public.supplier_payments x where x.reverses_id = sp.id) then
    raise exception 'That payment has already been undone.';
  end if;
  select name into v_sup from public.suppliers where id = g.supplier_id;
  v_today := (now() at time zone (select timezone from public.restaurants where id = g.restaurant_id))::date;

  -- Cash that left the till for this payment comes back into the drawer that is open now.
  if sp.from_till then
    if not app.allowed('cash.movement') then
      raise exception 'Your role does not allow this action (cash.movement).';
    end if;
    select id into v_shift from public.shifts where branch_id = g.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(g.branch_id); end if;
    if v_shift is null then raise exception 'Open a shift before undoing a payment that was made from the till.'; end if;
    v_move := gen_random_uuid();
    insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_move, g.restaurant_id, v_shift, 'in', sp.amount,
            left('Supplier payment undone: ' || v_sup || ' (' || g.number || ')', 200), v_user);
  end if;

  insert into public.supplier_payments (id, restaurant_id, branch_id, supplier_id, goods_receipt_id, amount, method, reference,
                                        paid_on, from_till, cash_movement_id, paid_by, reverses_id, reason)
  values (v_id, sp.restaurant_id, sp.branch_id, sp.supplier_id, sp.goods_receipt_id, -sp.amount, sp.method, sp.reference,
          v_today, sp.from_till, v_move, v_user, sp.id, left(trim(p_reason), 300));
  v_paid := greatest(0, g.paid_total - sp.amount);
  update public.goods_receipts set paid_total = v_paid,
         payment_status = case when v_paid <= 0 then (case when total = 0 then 'paid' else 'unpaid' end)
                               when v_paid >= total then 'paid' else 'partial' end
   where id = g.id;
  perform app.audit('supplier.pay_undo', 'goods_receipts', g.id,
    jsonb_build_object('number', g.number, 'supplier', v_sup, 'amount', sp.amount, 'method', sp.method,
                       'from_till', sp.from_till, 'reason', left(trim(p_reason), 300)));
  return jsonb_build_object('payment_id', v_id, 'amount', sp.amount, 'balance', g.total - v_paid, 'number', g.number);
end $function$
;

CREATE OR REPLACE FUNCTION public.update_settings(p_settings jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  s jsonb := coalesce(p_settings, '{}'::jsonb);
  v_country char(2); v_taxno text; v_logo text;
begin
  select country_code into v_country from public.restaurants where id = v_rest;

  if s ? 'trading_name' and coalesce(trim(s->>'trading_name'), '') = '' then
    raise exception 'The name customers see cannot be empty.';
  end if;
  if s ? 'legal_name' and coalesce(trim(s->>'legal_name'), '') = '' then
    raise exception 'The registered business name cannot be empty.';
  end if;
  if s ? 'tax_registration_no' then
    v_taxno := upper(nullif(trim(s->>'tax_registration_no'), ''));
    if v_taxno is not null and v_country = 'IN'
       and v_taxno !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
      raise exception 'That GSTIN does not look right. It should be 15 characters, like 33AAACA0000A1Z5.';
    end if;
    if v_taxno is not null and length(v_taxno) > 30 then raise exception 'That tax number is too long.'; end if;
  end if;
  if s ? 'cash_rounding_mode' and (s->>'cash_rounding_mode') not in ('none', 'nearest_1', 'nearest_0_05', 'nearest_0_10') then
    raise exception 'Unknown rounding option.';
  end if;
  if s ? 'service_charge_percent' and ((s->>'service_charge_percent')::numeric < 0 or (s->>'service_charge_percent')::numeric > 30) then
    raise exception 'The service charge must be between 0 and 30 percent.';
  end if;

  if s ? 'token_numbers' and (s->>'token_numbers') not in ('off', 'takeaway', 'all') then
    raise exception 'Unknown token number option.';
  end if;
  if s ? 'bill_format' and (jsonb_typeof(s->'bill_format') <> 'object' or length((s->'bill_format')::text) > 4000) then
    raise exception 'The bill layout could not be saved.';
  end if;
  if s ? 'logo' then
    v_logo := nullif(s->>'logo', '');
    if v_logo is not null and (length(v_logo) > 150000 or v_logo !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$') then
      raise exception 'The logo must be a PNG or JPEG picture of about 100 KB or less.';
    end if;
  end if;
  if s ? 'fssai_no' and nullif(trim(s->>'fssai_no'), '') is not null and trim(s->>'fssai_no') !~ '^[0-9]{14}$' then
    raise exception 'The FSSAI licence number has 14 digits.';
  end if;
  if s ? 'sac_code' and nullif(trim(s->>'sac_code'), '') is not null and trim(s->>'sac_code') !~ '^[0-9]{4,8}$' then
    raise exception 'The SAC / HSN code is 4 to 8 digits.';
  end if;

  update public.restaurants set
    logo_url = case when s ? 'logo' then v_logo else logo_url end,
    fssai_no = case when s ? 'fssai_no' then nullif(trim(s->>'fssai_no'), '') else fssai_no end,
    sac_code = case when s ? 'sac_code' then nullif(trim(s->>'sac_code'), '') else sac_code end,
    trading_name = case when s ? 'trading_name' then left(trim(s->>'trading_name'), 120) else trading_name end,
    legal_name   = case when s ? 'legal_name' then left(trim(s->>'legal_name'), 160) else legal_name end,
    tax_registration_no = case when s ? 'tax_registration_no' then v_taxno else tax_registration_no end,
    contact_phone = case when s ? 'contact_phone' then nullif(left(trim(s->>'contact_phone'), 30), '') else contact_phone end
  where id = v_rest;

  update public.branches set
    name = case when s ? 'branch_name' and coalesce(trim(s->>'branch_name'), '') <> '' then left(trim(s->>'branch_name'), 80) else name end,
    address_line1 = case when s ? 'address_line1' then nullif(left(trim(s->>'address_line1'), 160), '') else address_line1 end,
    address_line2 = case when s ? 'address_line2' then nullif(left(trim(s->>'address_line2'), 160), '') else address_line2 end,
    city = case when s ? 'city' then nullif(left(trim(s->>'city'), 80), '') else city end,
    state_or_region = case when s ? 'state_or_region' then nullif(left(trim(s->>'state_or_region'), 80), '') else state_or_region end,
    postal_code = case when s ? 'postal_code' then nullif(left(trim(s->>'postal_code'), 12), '') else postal_code end,
    phone = case when s ? 'phone' then nullif(left(trim(s->>'phone'), 30), '') else phone end
  where id = v_branch;

  update public.branch_settings set
    receipt_header = case when s ? 'receipt_header' then nullif(left(trim(s->>'receipt_header'), 120), '') else receipt_header end,
    receipt_footer = case when s ? 'receipt_footer' then nullif(left(trim(s->>'receipt_footer'), 300), '') else receipt_footer end,
    cash_rounding_mode = case when s ? 'cash_rounding_mode' then s->>'cash_rounding_mode' else cash_rounding_mode end,
    rounding_cash_only = case when s ? 'rounding_cash_only' then (s->>'rounding_cash_only')::boolean else rounding_cash_only end,
    auto_print_kot = case when s ? 'auto_print_kot' then (s->>'auto_print_kot')::boolean else auto_print_kot end,
    token_numbers = case when s ? 'token_numbers' then s->>'token_numbers' else token_numbers end,
    bill_format = case when s ? 'bill_format' then app.clean_bill_format(s->'bill_format') else bill_format end,
    service_charge_percent = case when s ? 'service_charge_percent' then round((s->>'service_charge_percent')::numeric, 2) else service_charge_percent end,
    service_charge_taxable = case when s ? 'service_charge_taxable' then (s->>'service_charge_taxable')::boolean else service_charge_taxable end,
    service_charge_default_on = case when s ? 'service_charge_default_on' then (s->>'service_charge_default_on')::boolean else service_charge_default_on end,
    service_charge_label = case when s ? 'service_charge_label' and coalesce(trim(s->>'service_charge_label'), '') <> ''
                                then left(trim(s->>'service_charge_label'), 40) else service_charge_label end
  where branch_id = v_branch;

  -- The audit log keeps what changed, not the picture itself.
  perform app.audit('settings.update', 'restaurants', v_rest,
    (s - 'logo') || case when s ? 'logo' then jsonb_build_object('logo', case when v_logo is null then 'removed' else 'changed' end) else '{}'::jsonb end);
end $function$
;

CREATE OR REPLACE FUNCTION public.update_staff(p_user_id uuid, p_role_id uuid DEFAULT NULL::uuid, p_is_active boolean DEFAULT NULL::boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid := app.require_permission('user.manage');
  u public.users%rowtype;
  v_cur_role text;
  v_new_role public.roles%rowtype;
begin
  select * into u from public.users where id = p_user_id and restaurant_id = app.current_restaurant_id()
    and deleted_at is null for update;
  if not found then raise exception 'Staff member not found.'; end if;
  if u.id = v_me then raise exception 'You cannot change your own role or access.'; end if;
  select name into v_cur_role from public.roles where id = u.role_id;
  if v_cur_role = 'Owner' and not app.is_owner() then
    raise exception 'Only an owner can change another owner.';
  end if;

  if p_role_id is not null and p_role_id <> u.role_id then
    select * into v_new_role from public.roles where id = p_role_id and restaurant_id = u.restaurant_id;
    if not found then raise exception 'Choose a role.'; end if;
    if v_new_role.name = 'Owner' and not app.is_owner() then
      raise exception 'Only an owner can make someone an owner.';
    end if;
    update public.users set role_id = v_new_role.id where id = u.id;
    perform app.audit('user.role_change', 'users', u.id,
      jsonb_build_object('role', v_new_role.name), jsonb_build_object('role', v_cur_role));
  end if;

  if p_is_active is not null and p_is_active <> u.is_active then
    update public.users set is_active = p_is_active where id = u.id;
    perform app.audit(case when p_is_active then 'user.activate' else 'user.deactivate' end,
      'users', u.id, jsonb_build_object('is_active', p_is_active));
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.void_order(p_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('order.void');
  o public.orders%rowtype;
  v_cash numeric(14,2);
  v_open uuid;
begin
  if coalesce(trim(p_reason),'') = '' then raise exception 'A reason is required to void a bill.'; end if;
  select * into o from public.orders
   where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is already voided.', o.bill_number; end if;
  if o.status <> 'completed' then raise exception 'Only a completed bill can be voided.'; end if;
  if exists (select 1 from public.refunds where order_id = o.id) then
    raise exception 'Bill % already has a refund, so it cannot also be voided.', o.bill_number;
  end if;

  -- If the bill's shift is already closed, its cash is no longer in that
  -- drawer's count: the money goes back out of today's drawer instead.
  -- Cash that was counted into a shift which has since closed is given back
  -- from the drawer that is open now, so it must be written down there. With
  -- no drawer open there is nowhere to record it, so the void waits.
  select coalesce(sum(p.amount),0) into v_cash
    from public.payments p
    join public.payment_methods pm on pm.id = p.payment_method_id
    join public.shifts s on s.id = coalesce(p.shift_id, o.shift_id)
   where p.order_id = o.id and p.status = 'captured' and pm.affects_cash_drawer and s.status = 'closed';
  if v_cash > 0 then
    select id into v_open from public.shifts
     where branch_id = o.branch_id and status = 'open' limit 1;
    if v_open is null then v_open := app.auto_shift(o.branch_id); end if;
    if v_open is null then
      raise exception 'Open a shift before voiding bill %. Its cash (%) has to come out of a drawer that is being counted.', o.bill_number, v_cash;
    end if;
    insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (gen_random_uuid(), o.restaurant_id, v_open, 'out', v_cash,
            left('Cash returned for voided bill ' || o.bill_number, 200), v_user);
  end if;

  update public.orders set status = 'voided', voided_by = v_user, voided_at = now(),
         void_reason = left(trim(p_reason),300),
         payment_status = case when o.paid_total > 0 then 'refunded' else o.payment_status end
   where id = o.id;
  update public.payments set status = 'refunded' where order_id = o.id and status = 'captured';
  -- Cancel only this bill's own lines in the kitchen. After a split, a kitchen
  -- ticket can carry lines that now belong to another bill; those stay.
  update public.kitchen_ticket_items k set status = 'cancelled'
   where k.order_item_id in (select oi.id from public.order_items oi where oi.order_id = o.id)
     and k.status in ('new','preparing');
  update public.kitchen_tickets kt set status = 'cancelled'
   where kt.restaurant_id = o.restaurant_id and kt.status in ('new','preparing')
     and (kt.order_id = o.id
          or exists (select 1 from public.kitchen_ticket_items k join public.order_items oi on oi.id = k.order_item_id
                      where k.kitchen_ticket_id = kt.id and oi.order_id = o.id))
     and not exists (select 1 from public.kitchen_ticket_items k2
                      where k2.kitchen_ticket_id = kt.id and k2.status <> 'cancelled');

  perform app.audit('order.void', 'orders', o.id,
    jsonb_build_object('status','voided','reason', left(trim(p_reason),300)),
    jsonb_build_object('status', o.status, 'grand_total', o.grand_total));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'status', 'voided');
end $function$
;

-- ---------------------------------------------------------------------
-- Column defaults
-- ---------------------------------------------------------------------
ALTER TABLE ONLY public.agent_actions ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.agent_actions ALTER COLUMN status SET DEFAULT 'proposed'::text;
ALTER TABLE ONLY public.agent_actions ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.agent_messages ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.agent_messages ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.agent_sessions ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.agent_sessions ALTER COLUMN channel SET DEFAULT 'in_app'::text;
ALTER TABLE ONLY public.agent_sessions ALTER COLUMN started_at SET DEFAULT now();
ALTER TABLE ONLY public.agent_sessions ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.agent_settings ALTER COLUMN is_enabled SET DEFAULT false;
ALTER TABLE ONLY public.agent_settings ALTER COLUMN allow_analyst SET DEFAULT true;
ALTER TABLE ONLY public.agent_settings ALTER COLUMN allow_back_office SET DEFAULT false;
ALTER TABLE ONLY public.agent_settings ALTER COLUMN allow_forecasting SET DEFAULT false;
ALTER TABLE ONLY public.agent_settings ALTER COLUMN preferred_language SET DEFAULT 'en'::text;
ALTER TABLE ONLY public.agent_settings ALTER COLUMN monthly_question_cap SET DEFAULT 500;
ALTER TABLE ONLY public.agent_settings ALTER COLUMN monthly_spend_cap SET DEFAULT 0;
ALTER TABLE ONLY public.agent_settings ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.agent_settings ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.agent_usage ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.agent_usage ALTER COLUMN questions_asked SET DEFAULT 0;
ALTER TABLE ONLY public.agent_usage ALTER COLUMN input_tokens SET DEFAULT 0;
ALTER TABLE ONLY public.agent_usage ALTER COLUMN output_tokens SET DEFAULT 0;
ALTER TABLE ONLY public.agent_usage ALTER COLUMN estimated_cost SET DEFAULT 0;
ALTER TABLE ONLY public.agent_usage ALTER COLUMN currency_code SET DEFAULT 'USD'::bpchar;
ALTER TABLE ONLY public.agent_usage ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.api_calls ALTER COLUMN id SET DEFAULT nextval('api_calls_id_seq'::regclass);
ALTER TABLE ONLY public.api_calls ALTER COLUMN at SET DEFAULT now();
ALTER TABLE ONLY public.api_keys ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.api_keys ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.approval_failures ALTER COLUMN id SET DEFAULT nextval('approval_failures_id_seq'::regclass);
ALTER TABLE ONLY public.approval_failures ALTER COLUMN at SET DEFAULT now();
ALTER TABLE ONLY public.approvals ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.approvals ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.approvals ALTER COLUMN expires_at SET DEFAULT (now() + '00:02:00'::interval);
ALTER TABLE ONLY public.audit_logs ALTER COLUMN id SET DEFAULT nextval('audit_logs_id_seq'::regclass);
ALTER TABLE ONLY public.audit_logs ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.audit_logs ALTER COLUMN actor_type SET DEFAULT 'user'::text;
ALTER TABLE ONLY public.batch_movements ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.batch_movements ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.bill_series ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.bill_series ALTER COLUMN next_seq SET DEFAULT 1;
ALTER TABLE ONLY public.bill_series ALTER COLUMN is_current SET DEFAULT true;
ALTER TABLE ONLY public.bill_series ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.branch_prices ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.branch_settings ALTER COLUMN service_charge_percent SET DEFAULT 0;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN cash_rounding_mode SET DEFAULT 'none'::text;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN default_order_type SET DEFAULT 'dine_in'::text;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN auto_print_kot SET DEFAULT true;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.branch_settings ALTER COLUMN service_charge_taxable SET DEFAULT true;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN service_charge_default_on SET DEFAULT false;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN service_charge_label SET DEFAULT 'Service charge'::text;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN rounding_cash_only SET DEFAULT false;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN shifts_enabled SET DEFAULT false;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN day_cutoff SET DEFAULT '04:00:00'::time without time zone;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN token_numbers SET DEFAULT 'off'::text;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN packing_per SET DEFAULT 'bill'::text;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN packing_takeaway SET DEFAULT true;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN packing_delivery SET DEFAULT true;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN bill_format SET DEFAULT '{}'::jsonb;
ALTER TABLE ONLY public.branch_settings ALTER COLUMN order_types SET DEFAULT '{dine_in,takeaway,delivery}'::text[];
ALTER TABLE ONLY public.branches ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.branches ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.branches ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.branches ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.branches ALTER COLUMN is_central_kitchen SET DEFAULT false;
ALTER TABLE ONLY public.branches ALTER COLUMN royalty_percent SET DEFAULT 0;
ALTER TABLE ONLY public.brands ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.brands ALTER COLUMN commission_percent SET DEFAULT 0;
ALTER TABLE ONLY public.brands ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.brands ALTER COLUMN display_order SET DEFAULT 0;
ALTER TABLE ONLY public.brands ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.business_days ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.business_days ALTER COLUMN status SET DEFAULT 'open'::text;
ALTER TABLE ONLY public.business_days ALTER COLUMN opened_at SET DEFAULT now();
ALTER TABLE ONLY public.business_days ALTER COLUMN reopen_count SET DEFAULT 0;
ALTER TABLE ONLY public.business_days ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.business_days ALTER COLUMN last_token SET DEFAULT 0;
ALTER TABLE ONLY public.cash_movements ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.cash_movements ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.categories ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.categories ALTER COLUMN display_order SET DEFAULT 0;
ALTER TABLE ONLY public.categories ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.categories ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.categories ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.countries ALTER COLUMN requires_fiscal_certification SET DEFAULT false;
ALTER TABLE ONLY public.countries ALTER COLUMN is_supported SET DEFAULT false;
ALTER TABLE ONLY public.countries ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.countries ALTER COLUMN has_senior_discount SET DEFAULT false;
ALTER TABLE ONLY public.credit_notes ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.credit_notes ALTER COLUMN tax_amount SET DEFAULT 0;
ALTER TABLE ONLY public.credit_notes ALTER COLUMN taxes SET DEFAULT '[]'::jsonb;
ALTER TABLE ONLY public.credit_notes ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.currencies ALTER COLUMN decimal_places SET DEFAULT 2;
ALTER TABLE ONLY public.customer_ledger ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.customer_ledger ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.customers ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.customers ALTER COLUMN marketing_consent SET DEFAULT false;
ALTER TABLE ONLY public.customers ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.customers ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.devices ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.devices ALTER COLUMN device_type SET DEFAULT 'tablet'::text;
ALTER TABLE ONLY public.devices ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.devices ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.devices ALTER COLUMN next_bill_seq SET DEFAULT 1;
ALTER TABLE ONLY public.dining_tables ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.dining_tables ALTER COLUMN seats SET DEFAULT 4;
ALTER TABLE ONLY public.dining_tables ALTER COLUMN status SET DEFAULT 'free'::text;
ALTER TABLE ONLY public.dining_tables ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.dining_tables ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.dining_tables ALTER COLUMN is_kiosk SET DEFAULT false;
ALTER TABLE ONLY public.floors ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.floors ALTER COLUMN display_order SET DEFAULT 0;
ALTER TABLE ONLY public.gift_card_ledger ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.gift_card_ledger ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.gift_cards ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.gift_cards ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.goods_receipt_lines ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.goods_receipts ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.goods_receipts ALTER COLUMN subtotal SET DEFAULT 0;
ALTER TABLE ONLY public.goods_receipts ALTER COLUMN tax_amount SET DEFAULT 0;
ALTER TABLE ONLY public.goods_receipts ALTER COLUMN other_charges SET DEFAULT 0;
ALTER TABLE ONLY public.goods_receipts ALTER COLUMN total SET DEFAULT 0;
ALTER TABLE ONLY public.goods_receipts ALTER COLUMN paid_total SET DEFAULT 0;
ALTER TABLE ONLY public.goods_receipts ALTER COLUMN payment_status SET DEFAULT 'unpaid'::text;
ALTER TABLE ONLY public.goods_receipts ALTER COLUMN status SET DEFAULT 'received'::text;
ALTER TABLE ONLY public.goods_receipts ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.ingredients ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.ingredients ALTER COLUMN cost_per_unit SET DEFAULT 0;
ALTER TABLE ONLY public.ingredients ALTER COLUMN reorder_level SET DEFAULT 0;
ALTER TABLE ONLY public.ingredients ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.ingredients ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.kitchen_ticket_items ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.kitchen_ticket_items ALTER COLUMN status SET DEFAULT 'new'::text;
ALTER TABLE ONLY public.kitchen_tickets ALTER COLUMN status SET DEFAULT 'new'::text;
ALTER TABLE ONLY public.kitchen_tickets ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.liquor_series ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.liquor_series ALTER COLUMN next_seq SET DEFAULT 1;
ALTER TABLE ONLY public.liquor_series ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.loyalty_ledger ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.loyalty_ledger ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.loyalty_settings ALTER COLUMN spend_per_point SET DEFAULT 100;
ALTER TABLE ONLY public.loyalty_settings ALTER COLUMN point_value SET DEFAULT 1;
ALTER TABLE ONLY public.loyalty_settings ALTER COLUMN min_redeem SET DEFAULT 0;
ALTER TABLE ONLY public.loyalty_settings ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.meal_sessions ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.meal_sessions ALTER COLUMN days SET DEFAULT '{1,2,3,4,5,6,7}'::smallint[];
ALTER TABLE ONLY public.meal_sessions ALTER COLUMN display_order SET DEFAULT 0;
ALTER TABLE ONLY public.meal_sessions ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.modifier_groups ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.modifier_groups ALTER COLUMN min_select SET DEFAULT 0;
ALTER TABLE ONLY public.modifier_groups ALTER COLUMN max_select SET DEFAULT 1;
ALTER TABLE ONLY public.modifier_groups ALTER COLUMN is_required SET DEFAULT false;
ALTER TABLE ONLY public.modifier_groups ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.modifier_groups ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.modifier_items ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.modifier_items ALTER COLUMN price_delta SET DEFAULT 0;
ALTER TABLE ONLY public.modifier_items ALTER COLUMN display_order SET DEFAULT 0;
ALTER TABLE ONLY public.modifier_items ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.modules ALTER COLUMN display_order SET DEFAULT 0;
ALTER TABLE ONLY public.offline_series ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.offline_series ALTER COLUMN next_seq SET DEFAULT 1;
ALTER TABLE ONLY public.offline_series ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.offline_series ALTER COLUMN liquor_next_seq SET DEFAULT 1;
ALTER TABLE ONLY public.online_channels ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.online_orders ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.online_orders ALTER COLUMN paid_online SET DEFAULT false;
ALTER TABLE ONLY public.online_orders ALTER COLUMN status SET DEFAULT 'pending'::text;
ALTER TABLE ONLY public.online_orders ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.order_discounts ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.order_discounts ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.order_item_modifiers ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.order_item_modifiers ALTER COLUMN price_delta SET DEFAULT 0;
ALTER TABLE ONLY public.order_item_taxes ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.order_items ALTER COLUMN modifier_total SET DEFAULT 0;
ALTER TABLE ONLY public.order_items ALTER COLUMN line_discount SET DEFAULT 0;
ALTER TABLE ONLY public.order_items ALTER COLUMN line_tax SET DEFAULT 0;
ALTER TABLE ONLY public.order_items ALTER COLUMN is_price_inclusive SET DEFAULT false;
ALTER TABLE ONLY public.order_items ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.order_items ALTER COLUMN net_amount SET DEFAULT 0;
ALTER TABLE ONLY public.order_items ALTER COLUMN service_charge SET DEFAULT 0;
ALTER TABLE ONLY public.order_items ALTER COLUMN tax_included SET DEFAULT 0;
ALTER TABLE ONLY public.order_items ALTER COLUMN cancelled_qty SET DEFAULT 0;
ALTER TABLE ONLY public.order_items ALTER COLUMN held SET DEFAULT false;
ALTER TABLE ONLY public.orders ALTER COLUMN status SET DEFAULT 'open'::text;
ALTER TABLE ONLY public.orders ALTER COLUMN payment_status SET DEFAULT 'unpaid'::text;
ALTER TABLE ONLY public.orders ALTER COLUMN subtotal SET DEFAULT 0;
ALTER TABLE ONLY public.orders ALTER COLUMN discount_total SET DEFAULT 0;
ALTER TABLE ONLY public.orders ALTER COLUMN tax_total SET DEFAULT 0;
ALTER TABLE ONLY public.orders ALTER COLUMN service_charge SET DEFAULT 0;
ALTER TABLE ONLY public.orders ALTER COLUMN rounding_adjustment SET DEFAULT 0;
ALTER TABLE ONLY public.orders ALTER COLUMN grand_total SET DEFAULT 0;
ALTER TABLE ONLY public.orders ALTER COLUMN paid_total SET DEFAULT 0;
ALTER TABLE ONLY public.orders ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.orders ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.orders ALTER COLUMN tax_included SET DEFAULT 0;
ALTER TABLE ONLY public.orders ALTER COLUMN tax_exempt_amount SET DEFAULT 0;
ALTER TABLE ONLY public.orders ALTER COLUMN exempt_sales SET DEFAULT 0;
ALTER TABLE ONLY public.orders ALTER COLUMN is_liquor SET DEFAULT false;
ALTER TABLE ONLY public.owner_alerts ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.owner_alerts ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.payment_methods ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.payment_methods ALTER COLUMN affects_cash_drawer SET DEFAULT false;
ALTER TABLE ONLY public.payment_methods ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.payment_methods ALTER COLUMN display_order SET DEFAULT 0;
ALTER TABLE ONLY public.payment_methods ALTER COLUMN collection_mode SET DEFAULT 'record'::text;
ALTER TABLE ONLY public.payment_methods ALTER COLUMN ask_reference SET DEFAULT false;
ALTER TABLE ONLY public.payments ALTER COLUMN change_amount SET DEFAULT 0;
ALTER TABLE ONLY public.payments ALTER COLUMN status SET DEFAULT 'captured'::text;
ALTER TABLE ONLY public.payments ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.payments ALTER COLUMN rounding_adjustment SET DEFAULT 0;
ALTER TABLE ONLY public.permissions ALTER COLUMN is_sensitive SET DEFAULT false;
ALTER TABLE ONLY public.pin_attempts ALTER COLUMN at SET DEFAULT now();
ALTER TABLE ONLY public.pin_sessions ALTER COLUMN started_at SET DEFAULT now();
ALTER TABLE ONLY public.pin_sessions ALTER COLUMN last_activity_at SET DEFAULT now();
ALTER TABLE ONLY public.plan_requests ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.plan_requests ALTER COLUMN status SET DEFAULT 'requested'::text;
ALTER TABLE ONLY public.plan_requests ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.pre_order_payments ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.pre_order_payments ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.pre_orders ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.pre_orders ALTER COLUMN order_type SET DEFAULT 'takeaway'::text;
ALTER TABLE ONLY public.pre_orders ALTER COLUMN estimate SET DEFAULT 0;
ALTER TABLE ONLY public.pre_orders ALTER COLUMN status SET DEFAULT 'booked'::text;
ALTER TABLE ONLY public.pre_orders ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.pre_orders ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.price_rules ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.price_rules ALTER COLUMN days SET DEFAULT '{1,2,3,4,5,6,7}'::smallint[];
ALTER TABLE ONLY public.price_rules ALTER COLUMN product_ids SET DEFAULT '{}'::uuid[];
ALTER TABLE ONLY public.price_rules ALTER COLUMN category_ids SET DEFAULT '{}'::uuid[];
ALTER TABLE ONLY public.price_rules ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.price_rules ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.printers ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.printers ALTER COLUMN paper_width_mm SET DEFAULT 80;
ALTER TABLE ONLY public.printers ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.product_batches ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.product_batches ALTER COLUMN made_on SET DEFAULT CURRENT_DATE;
ALTER TABLE ONLY public.product_batches ALTER COLUMN wasted SET DEFAULT 0;
ALTER TABLE ONLY public.product_batches ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.product_price_history ALTER COLUMN id SET DEFAULT nextval('product_price_history_id_seq'::regclass);
ALTER TABLE ONLY public.product_price_history ALTER COLUMN valid_from SET DEFAULT now();
ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.products ALTER COLUMN is_available SET DEFAULT true;
ALTER TABLE ONLY public.products ALTER COLUMN display_order SET DEFAULT 0;
ALTER TABLE ONLY public.products ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.products ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.products ALTER COLUMN is_charge SET DEFAULT false;
ALTER TABLE ONLY public.products ALTER COLUMN is_combo SET DEFAULT false;
ALTER TABLE ONLY public.products ALTER COLUMN sold_by SET DEFAULT 'unit'::text;
ALTER TABLE ONLY public.products ALTER COLUMN track_batches SET DEFAULT false;
ALTER TABLE ONLY public.purchase_order_lines ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.purchase_order_lines ALTER COLUMN unit_cost SET DEFAULT 0;
ALTER TABLE ONLY public.purchase_order_lines ALTER COLUMN received_qty SET DEFAULT 0;
ALTER TABLE ONLY public.purchase_orders ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.purchase_orders ALTER COLUMN status SET DEFAULT 'draft'::text;
ALTER TABLE ONLY public.purchase_orders ALTER COLUMN total SET DEFAULT 0;
ALTER TABLE ONLY public.purchase_orders ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.push_subscriptions ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.push_subscriptions ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.qr_orders ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.qr_orders ALTER COLUMN status SET DEFAULT 'pending'::text;
ALTER TABLE ONLY public.qr_orders ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.refunds ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.report_schedules ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.report_schedules ALTER COLUMN days SET DEFAULT '{1,2,3,4,5,6,7}'::smallint[];
ALTER TABLE ONLY public.report_schedules ALTER COLUMN emails SET DEFAULT '{}'::text[];
ALTER TABLE ONLY public.report_schedules ALTER COLUMN phone_alert SET DEFAULT false;
ALTER TABLE ONLY public.report_schedules ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.report_schedules ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.report_schedules ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.report_send_days ALTER COLUMN sends SET DEFAULT 0;
ALTER TABLE ONLY public.report_send_days ALTER COLUMN tests SET DEFAULT 0;
ALTER TABLE ONLY public.report_send_days ALTER COLUMN emails SET DEFAULT 0;
ALTER TABLE ONLY public.request_refs ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.reservations ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.reservations ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.reservations ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.restaurant_modules ALTER COLUMN enabled_at SET DEFAULT now();
ALTER TABLE ONLY public.restaurants ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.restaurants ALTER COLUMN subscription_status SET DEFAULT 'trial'::text;
ALTER TABLE ONLY public.restaurants ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.restaurants ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.restaurants ALTER COLUMN edition SET DEFAULT 'basic'::text;
ALTER TABLE ONLY public.restaurants ALTER COLUMN client_code SET DEFAULT (nextval('restaurant_client_code_seq'::regclass))::text;
ALTER TABLE ONLY public.restaurants ALTER COLUMN business_type SET DEFAULT 'restaurant'::text;
ALTER TABLE ONLY public.riders ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.riders ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.riders ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.roles ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.roles ALTER COLUMN is_system SET DEFAULT false;
ALTER TABLE ONLY public.roles ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.shift_closings ALTER COLUMN unpaid_orders SET DEFAULT '{}'::uuid[];
ALTER TABLE ONLY public.shift_closings ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.shifts ALTER COLUMN opening_float SET DEFAULT 0;
ALTER TABLE ONLY public.shifts ALTER COLUMN status SET DEFAULT 'open'::text;
ALTER TABLE ONLY public.shifts ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.sna_accounts ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.sna_contacts ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.sna_contacts ALTER COLUMN kind SET DEFAULT 'contact'::text;
ALTER TABLE ONLY public.sna_contacts ALTER COLUMN created_at SET DEFAULT clock_timestamp();
ALTER TABLE ONLY public.sna_notes ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.sna_notes ALTER COLUMN kind SET DEFAULT 'note'::text;
ALTER TABLE ONLY public.sna_notes ALTER COLUMN created_at SET DEFAULT clock_timestamp();
ALTER TABLE ONLY public.sna_sales ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.sna_sales ALTER COLUMN created_at SET DEFAULT clock_timestamp();
ALTER TABLE ONLY public.sna_sales ALTER COLUMN modules SET DEFAULT '{}'::text[];
ALTER TABLE ONLY public.sna_staff ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.sna_staff ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.sna_staff ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.staff_invites ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.stock_movements ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.stock_movements ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.subscription_events ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.subscription_events ALTER COLUMN details SET DEFAULT '{}'::jsonb;
ALTER TABLE ONLY public.subscription_events ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.supplier_payments ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.supplier_payments ALTER COLUMN from_till SET DEFAULT false;
ALTER TABLE ONLY public.supplier_payments ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.suppliers ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.suppliers ALTER COLUMN payment_days SET DEFAULT 0;
ALTER TABLE ONLY public.suppliers ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.suppliers ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.sync_log ALTER COLUMN id SET DEFAULT nextval('sync_log_id_seq'::regclass);
ALTER TABLE ONLY public.sync_log ALTER COLUMN records_sent SET DEFAULT 0;
ALTER TABLE ONLY public.sync_log ALTER COLUMN records_ok SET DEFAULT 0;
ALTER TABLE ONLY public.sync_log ALTER COLUMN records_failed SET DEFAULT 0;
ALTER TABLE ONLY public.tax_groups ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.tax_groups ALTER COLUMN is_price_inclusive SET DEFAULT false;
ALTER TABLE ONLY public.tax_groups ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.tax_groups ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.tax_groups ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.tax_groups ALTER COLUMN separate_bill SET DEFAULT false;
ALTER TABLE ONLY public.tax_rate_components ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.tax_rate_components ALTER COLUMN display_order SET DEFAULT 0;
ALTER TABLE ONLY public.tax_rate_components ALTER COLUMN applies_when SET DEFAULT 'always'::text;
ALTER TABLE ONLY public.tax_rate_components ALTER COLUMN is_compound SET DEFAULT false;
ALTER TABLE ONLY public.tax_rates ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.tax_rates ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.time_entries ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.time_entries ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE ONLY public.users ALTER COLUMN is_active SET DEFAULT true;
ALTER TABLE ONLY public.users ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE ONLY public.users ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE ONLY public.users ALTER COLUMN must_change_password SET DEFAULT false;
ALTER TABLE ONLY public.users ALTER COLUMN all_outlets SET DEFAULT false;
ALTER TABLE ONLY public.users ALTER COLUMN login_failed_count SET DEFAULT 0;

-- ---------------------------------------------------------------------
-- Primary keys, unique, check and exclusion constraints
-- ---------------------------------------------------------------------
ALTER TABLE ONLY app.secrets ADD CONSTRAINT secrets_pkey PRIMARY KEY (key);
ALTER TABLE ONLY public.agent_actions ADD CONSTRAINT agent_actions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.agent_actions ADD CONSTRAINT agent_actions_check CHECK (((status <> ALL (ARRAY['approved'::text, 'applied'::text])) OR (reviewed_by IS NOT NULL)));
ALTER TABLE ONLY public.agent_actions ADD CONSTRAINT agent_actions_status_check CHECK ((status = ANY (ARRAY['proposed'::text, 'approved'::text, 'rejected'::text, 'applied'::text, 'failed'::text])));
ALTER TABLE ONLY public.agent_messages ADD CONSTRAINT agent_messages_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.agent_messages ADD CONSTRAINT agent_messages_role_check CHECK ((role = ANY (ARRAY['user'::text, 'agent'::text, 'tool'::text])));
ALTER TABLE ONLY public.agent_sessions ADD CONSTRAINT agent_sessions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.agent_sessions ADD CONSTRAINT agent_sessions_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.agent_sessions ADD CONSTRAINT agent_sessions_channel_check CHECK ((channel = ANY (ARRAY['in_app'::text, 'whatsapp'::text, 'voice'::text])));
ALTER TABLE ONLY public.agent_sessions ADD CONSTRAINT agent_sessions_job_check CHECK ((job = ANY (ARRAY['analyst'::text, 'back_office'::text, 'forecasting'::text, 'support'::text])));
ALTER TABLE ONLY public.agent_settings ADD CONSTRAINT agent_settings_pkey PRIMARY KEY (restaurant_id);
ALTER TABLE ONLY public.agent_settings ADD CONSTRAINT agent_settings_monthly_question_cap_check CHECK ((monthly_question_cap >= 0));
ALTER TABLE ONLY public.agent_settings ADD CONSTRAINT agent_settings_monthly_spend_cap_check CHECK ((monthly_spend_cap >= (0)::numeric));
ALTER TABLE ONLY public.agent_usage ADD CONSTRAINT agent_usage_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.agent_usage ADD CONSTRAINT agent_usage_restaurant_id_period_month_key UNIQUE (restaurant_id, period_month);
ALTER TABLE ONLY public.api_calls ADD CONSTRAINT api_calls_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.api_keys ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.api_keys ADD CONSTRAINT api_keys_key_hash_key UNIQUE (key_hash);
ALTER TABLE ONLY public.api_keys ADD CONSTRAINT api_keys_name_check CHECK (((length(name) >= 1) AND (length(name) <= 60)));
ALTER TABLE ONLY public.approval_failures ADD CONSTRAINT approval_failures_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.approvals ADD CONSTRAINT approvals_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_actor_type_check CHECK ((actor_type = ANY (ARRAY['user'::text, 'agent'::text, 'system'::text])));
ALTER TABLE ONLY public.batch_movements ADD CONSTRAINT batch_movements_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.bill_series ADD CONSTRAINT bill_series_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.bill_series ADD CONSTRAINT bill_series_next_seq_check CHECK ((next_seq >= 1));
ALTER TABLE ONLY public.bill_series ADD CONSTRAINT bill_series_prefix_check CHECK ((prefix ~ '^[A-Za-z0-9/]{1,7}$'::text));
ALTER TABLE ONLY public.branch_prices ADD CONSTRAINT branch_prices_pkey PRIMARY KEY (branch_id, product_id);
ALTER TABLE ONLY public.branch_prices ADD CONSTRAINT branch_prices_price_check CHECK (((price IS NULL) OR (price >= (0)::numeric)));
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_pkey PRIMARY KEY (branch_id);
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_cash_rounding_mode_check CHECK ((cash_rounding_mode = ANY (ARRAY['none'::text, 'nearest_1'::text, 'nearest_0_05'::text, 'nearest_0_10'::text])));
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_default_type_known CHECK ((default_order_type = ANY (ARRAY['dine_in'::text, 'takeaway'::text, 'delivery'::text])));
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_default_type_offered CHECK ((default_order_type = ANY (order_types)));
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_order_types_check CHECK ((((cardinality(order_types) >= 1) AND (cardinality(order_types) <= 3)) AND (order_types <@ '{dine_in,takeaway,delivery}'::text[])));
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_packing_per_check CHECK ((packing_per = ANY (ARRAY['bill'::text, 'item'::text])));
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_service_charge_percent_check CHECK ((service_charge_percent >= (0)::numeric));
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_token_numbers_check CHECK ((token_numbers = ANY (ARRAY['off'::text, 'takeaway'::text, 'all'::text])));
ALTER TABLE ONLY public.branches ADD CONSTRAINT branches_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.branches ADD CONSTRAINT branches_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.branches ADD CONSTRAINT branches_restaurant_id_code_key UNIQUE (restaurant_id, code);
ALTER TABLE ONLY public.branches ADD CONSTRAINT branches_region_check CHECK (((region IS NULL) OR ((length(btrim(region)) >= 1) AND (length(btrim(region)) <= 40))));
ALTER TABLE ONLY public.branches ADD CONSTRAINT branches_royalty_percent_check CHECK (((royalty_percent >= (0)::numeric) AND (royalty_percent <= (100)::numeric)));
ALTER TABLE ONLY public.brands ADD CONSTRAINT brands_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.brands ADD CONSTRAINT brands_restaurant_id_id_key UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.brands ADD CONSTRAINT brands_commission_percent_check CHECK (((commission_percent >= (0)::numeric) AND (commission_percent <= (100)::numeric)));
ALTER TABLE ONLY public.brands ADD CONSTRAINT brands_gstin_check CHECK (((gstin IS NULL) OR (gstin ~ '^[0-9A-Z]{15}$'::text)));
ALTER TABLE ONLY public.brands ADD CONSTRAINT brands_legal_name_check CHECK (((legal_name IS NULL) OR (length(legal_name) <= 120)));
ALTER TABLE ONLY public.brands ADD CONSTRAINT brands_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 60)));
ALTER TABLE ONLY public.business_days ADD CONSTRAINT business_days_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.business_days ADD CONSTRAINT business_days_branch_id_business_date_key UNIQUE (branch_id, business_date);
ALTER TABLE ONLY public.business_days ADD CONSTRAINT business_days_restaurant_id_id_key UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.business_days ADD CONSTRAINT business_days_status_check CHECK ((status = ANY (ARRAY['open'::text, 'closed'::text, 'parked'::text])));
ALTER TABLE ONLY public.cash_movements ADD CONSTRAINT cash_movements_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.cash_movements ADD CONSTRAINT cash_movements_amount_check CHECK ((amount > (0)::numeric));
ALTER TABLE ONLY public.cash_movements ADD CONSTRAINT cash_movements_direction_check CHECK ((direction = ANY (ARRAY['in'::text, 'out'::text])));
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_parent_not_self CHECK (((parent_id IS NULL) OR (parent_id <> id)));
ALTER TABLE ONLY public.countries ADD CONSTRAINT countries_pkey PRIMARY KEY (code);
ALTER TABLE ONLY public.credit_notes ADD CONSTRAINT credit_notes_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.credit_notes ADD CONSTRAINT credit_notes_branch_id_number_key UNIQUE (branch_id, number);
ALTER TABLE ONLY public.credit_notes ADD CONSTRAINT credit_notes_restaurant_id_id_key UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.credit_notes ADD CONSTRAINT credit_notes_amount_check CHECK ((amount > (0)::numeric));
ALTER TABLE ONLY public.currencies ADD CONSTRAINT currencies_pkey PRIMARY KEY (code);
ALTER TABLE ONLY public.currencies ADD CONSTRAINT currencies_decimal_places_check CHECK (((decimal_places >= 0) AND (decimal_places <= 4)));
ALTER TABLE ONLY public.customer_ledger ADD CONSTRAINT customer_ledger_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.customer_ledger ADD CONSTRAINT customer_ledger_amount_check CHECK ((amount <> (0)::numeric));
ALTER TABLE ONLY public.customer_ledger ADD CONSTRAINT customer_ledger_kind_check CHECK ((kind = ANY (ARRAY['charge'::text, 'settlement'::text, 'adjustment'::text])));
ALTER TABLE ONLY public.customer_ledger ADD CONSTRAINT customer_ledger_note_check CHECK (((note IS NULL) OR (length(note) <= 200)));
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_restaurant_id_phone_key UNIQUE (restaurant_id, phone);
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_account_company_check CHECK (((account_company IS NULL) OR (length(account_company) <= 80)));
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_credit_limit_check CHECK (((credit_limit IS NULL) OR (credit_limit >= (0)::numeric)));
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_auth_user_id_key UNIQUE (auth_user_id);
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_bill_prefix_unique UNIQUE (branch_id, bill_prefix);
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_device_type_check CHECK ((device_type = ANY (ARRAY['tablet'::text, 'desktop'::text, 'phone'::text, 'kiosk'::text, 'counter'::text])));
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_branch_id_table_number_key UNIQUE (branch_id, table_number);
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_seats_check CHECK ((seats > 0));
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_status_check CHECK ((status = ANY (ARRAY['free'::text, 'occupied'::text, 'reserved'::text, 'cleaning'::text])));
ALTER TABLE ONLY public.floors ADD CONSTRAINT floors_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.floors ADD CONSTRAINT floors_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.gift_card_ledger ADD CONSTRAINT gift_card_ledger_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.gift_card_ledger ADD CONSTRAINT gift_card_ledger_kind_check CHECK ((kind = ANY (ARRAY['issue'::text, 'redeem'::text, 'topup'::text, 'payback'::text, 'void'::text])));
ALTER TABLE ONLY public.gift_cards ADD CONSTRAINT gift_cards_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.gift_cards ADD CONSTRAINT gift_cards_restaurant_id_code_key UNIQUE (restaurant_id, code);
ALTER TABLE ONLY public.gift_cards ADD CONSTRAINT gift_cards_value_check CHECK ((value > (0)::numeric));
ALTER TABLE ONLY public.goods_receipt_lines ADD CONSTRAINT goods_receipt_lines_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.goods_receipt_lines ADD CONSTRAINT goods_receipt_lines_qty_check CHECK ((qty > (0)::numeric));
ALTER TABLE ONLY public.goods_receipt_lines ADD CONSTRAINT goods_receipt_lines_unit_cost_check CHECK ((unit_cost >= (0)::numeric));
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_branch_id_number_key UNIQUE (branch_id, number);
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_restaurant_id_id_key UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_check CHECK ((paid_total <= total));
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_other_charges_check CHECK ((other_charges >= (0)::numeric));
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_paid_total_check CHECK ((paid_total >= (0)::numeric));
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_payment_status_check CHECK ((payment_status = ANY (ARRAY['unpaid'::text, 'partial'::text, 'paid'::text])));
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_status_check CHECK ((status = ANY (ARRAY['received'::text, 'cancelled'::text])));
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_tax_amount_check CHECK ((tax_amount >= (0)::numeric));
ALTER TABLE ONLY public.ingredients ADD CONSTRAINT ingredients_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.ingredients ADD CONSTRAINT ingredients_restaurant_id_id_key UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.ingredients ADD CONSTRAINT ingredients_cost_per_unit_check CHECK ((cost_per_unit >= (0)::numeric));
ALTER TABLE ONLY public.ingredients ADD CONSTRAINT ingredients_name_check CHECK (((length(TRIM(BOTH FROM name)) >= 1) AND (length(TRIM(BOTH FROM name)) <= 60)));
ALTER TABLE ONLY public.ingredients ADD CONSTRAINT ingredients_reorder_level_check CHECK ((reorder_level >= (0)::numeric));
ALTER TABLE ONLY public.ingredients ADD CONSTRAINT ingredients_unit_check CHECK ((unit = ANY (ARRAY['kg'::text, 'g'::text, 'l'::text, 'ml'::text, 'pcs'::text, 'pack'::text])));
ALTER TABLE ONLY public.kitchen_ticket_items ADD CONSTRAINT kitchen_ticket_items_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.kitchen_ticket_items ADD CONSTRAINT kitchen_ticket_items_status_check CHECK ((status = ANY (ARRAY['new'::text, 'preparing'::text, 'ready'::text, 'served'::text, 'cancelled'::text])));
ALTER TABLE ONLY public.kitchen_tickets ADD CONSTRAINT kitchen_tickets_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.kitchen_tickets ADD CONSTRAINT kitchen_tickets_status_check CHECK ((status = ANY (ARRAY['new'::text, 'preparing'::text, 'ready'::text, 'served'::text, 'cancelled'::text])));
ALTER TABLE ONLY public.liquor_series ADD CONSTRAINT liquor_series_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.liquor_series ADD CONSTRAINT liquor_series_branch_id_key UNIQUE (branch_id);
ALTER TABLE ONLY public.liquor_series ADD CONSTRAINT liquor_series_next_seq_check CHECK ((next_seq >= 1));
ALTER TABLE ONLY public.liquor_series ADD CONSTRAINT liquor_series_prefix_check CHECK ((prefix ~ '^[A-Za-z0-9/]{1,7}$'::text));
ALTER TABLE ONLY public.loyalty_ledger ADD CONSTRAINT loyalty_ledger_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.loyalty_ledger ADD CONSTRAINT loyalty_ledger_kind_check CHECK ((kind = ANY (ARRAY['earn'::text, 'redeem'::text, 'reverse'::text, 'adjust'::text])));
ALTER TABLE ONLY public.loyalty_settings ADD CONSTRAINT loyalty_settings_pkey PRIMARY KEY (restaurant_id);
ALTER TABLE ONLY public.loyalty_settings ADD CONSTRAINT loyalty_settings_min_redeem_check CHECK ((min_redeem >= 0));
ALTER TABLE ONLY public.loyalty_settings ADD CONSTRAINT loyalty_settings_point_value_check CHECK ((point_value >= (0)::numeric));
ALTER TABLE ONLY public.loyalty_settings ADD CONSTRAINT loyalty_settings_spend_per_point_check CHECK ((spend_per_point > (0)::numeric));
ALTER TABLE ONLY public.meal_sessions ADD CONSTRAINT meal_sessions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.meal_sessions ADD CONSTRAINT meal_sessions_check CHECK ((start_time <> end_time));
ALTER TABLE ONLY public.meal_sessions ADD CONSTRAINT meal_sessions_name_check CHECK (((length(name) >= 1) AND (length(name) <= 30)));
ALTER TABLE ONLY public.modifier_groups ADD CONSTRAINT modifier_groups_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.modifier_groups ADD CONSTRAINT modifier_groups_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.modifier_groups ADD CONSTRAINT modifier_groups_check CHECK ((max_select >= min_select));
ALTER TABLE ONLY public.modifier_items ADD CONSTRAINT modifier_items_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.modifier_items ADD CONSTRAINT modifier_items_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.modules ADD CONSTRAINT modules_pkey PRIMARY KEY (key);
ALTER TABLE ONLY public.modules ADD CONSTRAINT modules_kind_check CHECK ((kind = ANY (ARRAY['professional'::text, 'addon'::text])));
ALTER TABLE ONLY public.offline_series ADD CONSTRAINT offline_series_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.offline_series ADD CONSTRAINT offline_series_branch_id_device_key_key UNIQUE (branch_id, device_key);
ALTER TABLE ONLY public.offline_series ADD CONSTRAINT offline_series_branch_id_prefix_key UNIQUE (branch_id, prefix);
ALTER TABLE ONLY public.offline_series ADD CONSTRAINT offline_series_device_key_check CHECK ((device_key ~ '^[0-9a-f-]{36}$'::text));
ALTER TABLE ONLY public.offline_series ADD CONSTRAINT offline_series_liquor_next_seq_check CHECK ((liquor_next_seq >= 1));
ALTER TABLE ONLY public.online_channels ADD CONSTRAINT online_channels_pkey PRIMARY KEY (restaurant_id, channel);
ALTER TABLE ONLY public.online_channels ADD CONSTRAINT online_channels_callback_url_check CHECK (((callback_url IS NULL) OR ((callback_url ~ '^https://[^/\s]+'::text) AND (length(callback_url) <= 300))));
ALTER TABLE ONLY public.online_channels ADD CONSTRAINT online_channels_channel_check CHECK ((channel ~ '^[a-z0-9_]{2,20}$'::text));
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_restaurant_id_channel_external_ref_key UNIQUE (restaurant_id, channel, external_ref);
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_address_check CHECK (((address IS NULL) OR (length(address) <= 300)));
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_channel_check CHECK ((channel ~ '^[a-z0-9_]{2,20}$'::text));
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_customer_name_check CHECK (((customer_name IS NULL) OR (length(customer_name) <= 80)));
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_customer_phone_check CHECK (((customer_phone IS NULL) OR (length(customer_phone) <= 20)));
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_external_ref_check CHECK (((length(external_ref) >= 1) AND (length(external_ref) <= 60)));
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_note_check CHECK (((note IS NULL) OR (length(note) <= 200)));
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_reject_reason_check CHECK (((reject_reason IS NULL) OR (length(reject_reason) <= 200)));
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'rejected'::text])));
ALTER TABLE ONLY public.order_discounts ADD CONSTRAINT order_discounts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.order_discounts ADD CONSTRAINT order_discounts_amount_check CHECK ((amount >= (0)::numeric));
ALTER TABLE ONLY public.order_discounts ADD CONSTRAINT order_discounts_discount_type_check CHECK ((discount_type = ANY (ARRAY['percentage'::text, 'fixed_amount'::text, 'senior_pwd'::text])));
ALTER TABLE ONLY public.order_discounts ADD CONSTRAINT order_discounts_value_check CHECK ((value >= (0)::numeric));
ALTER TABLE ONLY public.order_item_modifiers ADD CONSTRAINT order_item_modifiers_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.order_item_taxes ADD CONSTRAINT order_item_taxes_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_line_discount_check CHECK ((line_discount >= (0)::numeric));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_line_subtotal_check CHECK ((line_subtotal >= (0)::numeric));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_line_tax_check CHECK ((line_tax >= (0)::numeric));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_line_total_check CHECK ((line_total >= (0)::numeric));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_quantity_check CHECK ((quantity > (0)::numeric));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_unit_check CHECK (((unit IS NULL) OR (unit = 'kg'::text)));
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_unit_price_check CHECK ((unit_price >= (0)::numeric));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_branch_id_bill_number_key UNIQUE (branch_id, bill_number);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_channel_check CHECK (((channel IS NULL) OR (channel ~ '^[a-z0-9_]{2,20}$'::text)));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_check CHECK (((status <> 'voided'::text) OR ((voided_by IS NOT NULL) AND (void_reason IS NOT NULL))));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_comp_complete CHECK ((((comp_kind IS NULL) = (comp_reason IS NULL)) AND ((comp_kind IS NULL) = (comp_by IS NULL))));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_comp_kind_check CHECK ((comp_kind = ANY (ARRAY['complimentary'::text, 'staff_meal'::text])));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_comp_reason_check CHECK (((comp_reason IS NULL) OR ((length(comp_reason) >= 3) AND (length(comp_reason) <= 200))));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_covers_check CHECK (((covers IS NULL) OR ((covers >= 1) AND (covers <= 99))));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_delivery_status_check CHECK ((delivery_status = ANY (ARRAY['waiting'::text, 'out'::text, 'delivered'::text, 'returned'::text])));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_discount_total_check CHECK ((discount_total >= (0)::numeric));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_grand_total_check CHECK ((grand_total >= (0)::numeric));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_order_type_check CHECK ((order_type = ANY (ARRAY['dine_in'::text, 'takeaway'::text, 'delivery'::text])));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_paid_total_check CHECK ((paid_total >= (0)::numeric));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_payment_status_check CHECK ((payment_status = ANY (ARRAY['unpaid'::text, 'partial'::text, 'paid'::text, 'refunded'::text, 'partially_refunded'::text])));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_service_charge_check CHECK ((service_charge >= (0)::numeric));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_status_check CHECK ((status = ANY (ARRAY['open'::text, 'placed'::text, 'served'::text, 'completed'::text, 'voided'::text])));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_subtotal_check CHECK ((subtotal >= (0)::numeric));
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_tax_total_check CHECK ((tax_total >= (0)::numeric));
ALTER TABLE ONLY public.owner_alerts ADD CONSTRAINT owner_alerts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.payment_methods ADD CONSTRAINT payment_methods_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.payment_methods ADD CONSTRAINT payment_methods_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.payment_methods ADD CONSTRAINT payment_methods_restaurant_id_name_key UNIQUE (restaurant_id, name);
ALTER TABLE ONLY public.payment_methods ADD CONSTRAINT payment_methods_collection_mode_check CHECK ((collection_mode = ANY (ARRAY['record'::text, 'gateway'::text])));
ALTER TABLE ONLY public.payment_methods ADD CONSTRAINT payment_methods_kind_check CHECK ((kind = ANY (ARRAY['cash'::text, 'card'::text, 'wallet'::text, 'bank_transfer'::text, 'upi'::text, 'other'::text, 'gift_card'::text, 'loyalty'::text, 'advance'::text, 'account'::text])));
ALTER TABLE ONLY public.payment_methods ADD CONSTRAINT payment_methods_upi_id_check CHECK (((upi_id IS NULL) OR (upi_id ~ '^[A-Za-z0-9._-]{2,200}@[A-Za-z][A-Za-z0-9]{1,63}$'::text)));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_amount_check CHECK ((amount > (0)::numeric));
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'captured'::text, 'failed'::text, 'refunded'::text])));
ALTER TABLE ONLY public.permissions ADD CONSTRAINT permissions_pkey PRIMARY KEY (key);
ALTER TABLE ONLY public.pin_attempts ADD CONSTRAINT pin_attempts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.pin_sessions ADD CONSTRAINT pin_sessions_pkey PRIMARY KEY (device_id);
ALTER TABLE ONLY public.plan_prices ADD CONSTRAINT plan_prices_pkey PRIMARY KEY (item, currency_code);
ALTER TABLE ONLY public.plan_requests ADD CONSTRAINT plan_requests_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.plan_requests ADD CONSTRAINT plan_requests_kind_check CHECK ((kind = ANY (ARRAY['upgrade'::text, 'module'::text, 'outlet'::text])));
ALTER TABLE ONLY public.plan_requests ADD CONSTRAINT plan_requests_status_check CHECK ((status = ANY (ARRAY['requested'::text, 'approved'::text, 'rejected'::text, 'done'::text, 'cancelled'::text])));
ALTER TABLE ONLY public.pre_order_payments ADD CONSTRAINT pre_order_payments_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.pre_order_payments ADD CONSTRAINT pre_order_payments_amount_check CHECK ((amount > (0)::numeric));
ALTER TABLE ONLY public.pre_order_payments ADD CONSTRAINT pre_order_payments_kind_check CHECK ((kind = ANY (ARRAY['advance'::text, 'refund'::text])));
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_restaurant_id_number_key UNIQUE (restaurant_id, number);
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_address_check CHECK (((address IS NULL) OR (length(address) <= 300)));
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_guest_name_check CHECK (((length(btrim(guest_name)) >= 1) AND (length(btrim(guest_name)) <= 80)));
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_items_check CHECK (((jsonb_typeof(items) = 'array'::text) AND ((jsonb_array_length(items) >= 1) AND (jsonb_array_length(items) <= 100))));
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_note_check CHECK (((note IS NULL) OR (length(note) <= 500)));
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_order_type_check CHECK ((order_type = ANY (ARRAY['takeaway'::text, 'delivery'::text, 'dine_in'::text])));
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_status_check CHECK ((status = ANY (ARRAY['booked'::text, 'billed'::text, 'cancelled'::text])));
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_check CHECK ((end_time <> start_time));
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_check1 CHECK (((value > (0)::numeric) AND ((kind <> 'percent_off'::text) OR (value < (100)::numeric))));
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_check2 CHECK (((valid_to IS NULL) OR (valid_from IS NULL) OR (valid_to >= valid_from)));
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_check3 CHECK (((kind <> 'price'::text) OR (cardinality(product_ids) > 0)));
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_days_check CHECK ((((cardinality(days) >= 1) AND (cardinality(days) <= 7)) AND (days <@ '{1,2,3,4,5,6,7}'::smallint[])));
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_kind_check CHECK ((kind = ANY (ARRAY['percent_off'::text, 'price'::text])));
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 40)));
ALTER TABLE ONLY public.printers ADD CONSTRAINT printers_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.printers ADD CONSTRAINT printers_connection_check CHECK ((connection = ANY (ARRAY['bluetooth'::text, 'usb'::text, 'network'::text])));
ALTER TABLE ONLY public.printers ADD CONSTRAINT printers_paper_width_mm_check CHECK ((paper_width_mm = ANY (ARRAY[58, 80])));
ALTER TABLE ONLY public.printers ADD CONSTRAINT printers_purpose_check CHECK ((purpose = ANY (ARRAY['receipt'::text, 'kitchen'::text, 'report'::text])));
ALTER TABLE ONLY public.product_batches ADD CONSTRAINT product_batches_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.product_batches ADD CONSTRAINT product_batches_check CHECK ((expires_on >= made_on));
ALTER TABLE ONLY public.product_batches ADD CONSTRAINT product_batches_note_check CHECK (((note IS NULL) OR (length(note) <= 200)));
ALTER TABLE ONLY public.product_batches ADD CONSTRAINT product_batches_qty_left_check CHECK ((qty_left >= (0)::numeric));
ALTER TABLE ONLY public.product_batches ADD CONSTRAINT product_batches_qty_made_check CHECK ((qty_made > (0)::numeric));
ALTER TABLE ONLY public.product_batches ADD CONSTRAINT product_batches_wasted_check CHECK ((wasted >= (0)::numeric));
ALTER TABLE ONLY public.product_modifier_groups ADD CONSTRAINT product_modifier_groups_pkey PRIMARY KEY (product_id, modifier_group_id);
ALTER TABLE ONLY public.product_price_history ADD CONSTRAINT product_price_history_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.products ADD CONSTRAINT products_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.products ADD CONSTRAINT products_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.products ADD CONSTRAINT products_restaurant_id_sku_key UNIQUE (restaurant_id, sku);
ALTER TABLE ONLY public.products ADD CONSTRAINT products_cost_price_check CHECK ((cost_price >= (0)::numeric));
ALTER TABLE ONLY public.products ADD CONSTRAINT products_hsn_code_check CHECK (((hsn_code IS NULL) OR (hsn_code ~ '^[0-9]{4,8}$'::text)));
ALTER TABLE ONLY public.products ADD CONSTRAINT products_name_local_check CHECK (((name_local IS NULL) OR (length(name_local) <= 120)));
ALTER TABLE ONLY public.products ADD CONSTRAINT products_price_check CHECK ((price >= (0)::numeric));
ALTER TABLE ONLY public.products ADD CONSTRAINT products_sold_by_check CHECK ((sold_by = ANY (ARRAY['unit'::text, 'weight'::text])));
ALTER TABLE ONLY public.products ADD CONSTRAINT products_station_len CHECK (((kitchen_station IS NULL) OR (length(kitchen_station) <= 30)));
ALTER TABLE ONLY public.products ADD CONSTRAINT products_variant_name_len CHECK (((variant_name IS NULL) OR ((length(btrim(variant_name)) >= 1) AND (length(btrim(variant_name)) <= 30))));
ALTER TABLE ONLY public.products ADD CONSTRAINT products_variant_not_self CHECK (((parent_id IS NULL) OR (parent_id <> id)));
ALTER TABLE ONLY public.products ADD CONSTRAINT products_variant_pair CHECK (((parent_id IS NULL) = (variant_name IS NULL)));
ALTER TABLE ONLY public.purchase_order_lines ADD CONSTRAINT purchase_order_lines_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.purchase_order_lines ADD CONSTRAINT purchase_order_lines_purchase_order_id_ingredient_id_key UNIQUE (purchase_order_id, ingredient_id);
ALTER TABLE ONLY public.purchase_order_lines ADD CONSTRAINT purchase_order_lines_qty_check CHECK ((qty > (0)::numeric));
ALTER TABLE ONLY public.purchase_order_lines ADD CONSTRAINT purchase_order_lines_received_qty_check CHECK ((received_qty >= (0)::numeric));
ALTER TABLE ONLY public.purchase_order_lines ADD CONSTRAINT purchase_order_lines_unit_cost_check CHECK ((unit_cost >= (0)::numeric));
ALTER TABLE ONLY public.purchase_orders ADD CONSTRAINT purchase_orders_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.purchase_orders ADD CONSTRAINT purchase_orders_branch_id_number_key UNIQUE (branch_id, number);
ALTER TABLE ONLY public.purchase_orders ADD CONSTRAINT purchase_orders_restaurant_id_id_key UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.purchase_orders ADD CONSTRAINT purchase_orders_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'ordered'::text, 'part_received'::text, 'received'::text, 'cancelled'::text])));
ALTER TABLE ONLY public.purchase_orders ADD CONSTRAINT purchase_orders_total_check CHECK ((total >= (0)::numeric));
ALTER TABLE ONLY public.push_subscriptions ADD CONSTRAINT push_subscriptions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.push_subscriptions ADD CONSTRAINT push_subscriptions_endpoint_key UNIQUE (endpoint);
ALTER TABLE ONLY public.push_subscriptions ADD CONSTRAINT push_subscriptions_auth_check CHECK ((length(auth) < 100));
ALTER TABLE ONLY public.push_subscriptions ADD CONSTRAINT push_subscriptions_endpoint_check CHECK (((endpoint ~~ 'https://%'::text) AND (length(endpoint) < 1000)));
ALTER TABLE ONLY public.push_subscriptions ADD CONSTRAINT push_subscriptions_p256dh_check CHECK ((length(p256dh) < 200));
ALTER TABLE ONLY public.qr_orders ADD CONSTRAINT qr_orders_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.qr_orders ADD CONSTRAINT qr_orders_guest_name_check CHECK (((guest_name IS NULL) OR (length(guest_name) <= 60)));
ALTER TABLE ONLY public.qr_orders ADD CONSTRAINT qr_orders_guest_note_check CHECK (((guest_note IS NULL) OR (length(guest_note) <= 200)));
ALTER TABLE ONLY public.qr_orders ADD CONSTRAINT qr_orders_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'rejected'::text])));
ALTER TABLE ONLY public.recipe_lines ADD CONSTRAINT recipe_lines_pkey PRIMARY KEY (product_id, ingredient_id);
ALTER TABLE ONLY public.recipe_lines ADD CONSTRAINT recipe_lines_qty_check CHECK ((qty > (0)::numeric));
ALTER TABLE ONLY public.refunds ADD CONSTRAINT refunds_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.refunds ADD CONSTRAINT refunds_amount_check CHECK ((amount > (0)::numeric));
ALTER TABLE ONLY public.report_schedules ADD CONSTRAINT report_schedules_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.report_schedules ADD CONSTRAINT report_schedules_days_check CHECK ((((cardinality(days) >= 1) AND (cardinality(days) <= 7)) AND (days <@ '{1,2,3,4,5,6,7}'::smallint[])));
ALTER TABLE ONLY public.report_schedules ADD CONSTRAINT report_schedules_emails_check CHECK ((cardinality(emails) <= 5));
ALTER TABLE ONLY public.report_schedules ADD CONSTRAINT report_schedules_someone_check CHECK (((cardinality(emails) > 0) OR phone_alert));
ALTER TABLE ONLY public.report_send_days ADD CONSTRAINT report_send_days_pkey PRIMARY KEY (scope, day);
ALTER TABLE ONLY public.request_refs ADD CONSTRAINT request_refs_pkey PRIMARY KEY (restaurant_id, ref);
ALTER TABLE ONLY public.reservations ADD CONSTRAINT reservations_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.reservations ADD CONSTRAINT reservations_guest_name_check CHECK (((length(guest_name) >= 1) AND (length(guest_name) <= 80)));
ALTER TABLE ONLY public.reservations ADD CONSTRAINT reservations_note_check CHECK (((note IS NULL) OR (length(note) <= 200)));
ALTER TABLE ONLY public.reservations ADD CONSTRAINT reservations_party_size_check CHECK (((party_size >= 1) AND (party_size <= 200)));
ALTER TABLE ONLY public.reservations ADD CONSTRAINT reservations_status_check CHECK ((status = ANY (ARRAY['booked'::text, 'waiting'::text, 'seated'::text, 'cancelled'::text, 'no_show'::text])));
ALTER TABLE ONLY public.restaurant_modules ADD CONSTRAINT restaurant_modules_pkey PRIMARY KEY (restaurant_id, module_key);
ALTER TABLE ONLY public.restaurants ADD CONSTRAINT restaurants_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.restaurants ADD CONSTRAINT restaurants_business_type_check CHECK ((business_type = ANY (ARRAY['restaurant'::text, 'cafe'::text, 'fine_dine'::text, 'bar'::text, 'food_court'::text, 'canteen'::text, 'pizzeria'::text, 'qsr'::text, 'desserts'::text, 'bakery'::text, 'cloud_kitchen'::text, 'chain'::text])));
ALTER TABLE ONLY public.restaurants ADD CONSTRAINT restaurants_edition_check CHECK ((edition = ANY (ARRAY['basic'::text, 'professional'::text])));
ALTER TABLE ONLY public.restaurants ADD CONSTRAINT restaurants_second_language_check CHECK ((second_language = ANY (ARRAY['hi'::text, 'ta'::text, 'te'::text, 'kn'::text, 'ml'::text, 'mr'::text, 'bn'::text, 'gu'::text, 'pa'::text, 'or'::text, 'ur'::text, 'as'::text, 'ar'::text, 'ms'::text, 'id'::text, 'th'::text, 'fil'::text, 'zh'::text])));
ALTER TABLE ONLY public.restaurants ADD CONSTRAINT restaurants_subscription_status_check CHECK ((subscription_status = ANY (ARRAY['trial'::text, 'active'::text, 'past_due'::text, 'suspended'::text, 'cancelled'::text])));
ALTER TABLE ONLY public.riders ADD CONSTRAINT riders_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.riders ADD CONSTRAINT riders_restaurant_id_id_key UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.riders ADD CONSTRAINT riders_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 60)));
ALTER TABLE ONLY public.riders ADD CONSTRAINT riders_phone_check CHECK (((phone IS NULL) OR (length(phone) <= 20)));
ALTER TABLE ONLY public.role_permissions ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (role_id, permission_key);
ALTER TABLE ONLY public.roles ADD CONSTRAINT roles_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.roles ADD CONSTRAINT roles_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.roles ADD CONSTRAINT roles_restaurant_id_name_key UNIQUE (restaurant_id, name);
ALTER TABLE ONLY public.shift_closings ADD CONSTRAINT shift_closings_pkey PRIMARY KEY (shift_id);
ALTER TABLE ONLY public.shifts ADD CONSTRAINT shifts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.shifts ADD CONSTRAINT shifts_check CHECK (((status <> 'closed'::text) OR (closed_at IS NOT NULL)));
ALTER TABLE ONLY public.shifts ADD CONSTRAINT shifts_opening_float_check CHECK ((opening_float >= (0)::numeric));
ALTER TABLE ONLY public.shifts ADD CONSTRAINT shifts_status_check CHECK ((status = ANY (ARRAY['open'::text, 'closed'::text])));
ALTER TABLE ONLY public.sna_accounts ADD CONSTRAINT sna_accounts_pkey PRIMARY KEY (restaurant_id);
ALTER TABLE ONLY public.sna_accounts ADD CONSTRAINT sna_accounts_licence_order CHECK (((licence_start IS NULL) OR (licence_expiry IS NULL) OR (licence_expiry >= licence_start)));
ALTER TABLE ONLY public.sna_contacts ADD CONSTRAINT sna_contacts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sna_contacts ADD CONSTRAINT sna_contacts_email_check CHECK (((email IS NULL) OR (length(email) <= 200)));
ALTER TABLE ONLY public.sna_contacts ADD CONSTRAINT sna_contacts_full_name_check CHECK (((length(TRIM(BOTH FROM full_name)) >= 1) AND (length(TRIM(BOTH FROM full_name)) <= 120)));
ALTER TABLE ONLY public.sna_contacts ADD CONSTRAINT sna_contacts_job_title_check CHECK (((job_title IS NULL) OR (length(job_title) <= 120)));
ALTER TABLE ONLY public.sna_contacts ADD CONSTRAINT sna_contacts_kind_check CHECK ((kind = ANY (ARRAY['owner'::text, 'billing'::text, 'accounts'::text, 'manager'::text, 'it'::text, 'contact'::text])));
ALTER TABLE ONLY public.sna_contacts ADD CONSTRAINT sna_contacts_phone_check CHECK (((phone IS NULL) OR (length(phone) <= 40)));
ALTER TABLE ONLY public.sna_notes ADD CONSTRAINT sna_notes_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sna_notes ADD CONSTRAINT sna_notes_body_check CHECK (((length(TRIM(BOTH FROM body)) >= 1) AND (length(TRIM(BOTH FROM body)) <= 2000)));
ALTER TABLE ONLY public.sna_notes ADD CONSTRAINT sna_notes_kind_check CHECK ((kind = ANY (ARRAY['note'::text, 'call'::text, 'visit'::text, 'message'::text, 'email'::text])));
ALTER TABLE ONLY public.sna_sales ADD CONSTRAINT sna_sales_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sna_sales ADD CONSTRAINT sna_sales_amount_check CHECK ((amount >= (0)::numeric));
ALTER TABLE ONLY public.sna_sales ADD CONSTRAINT sna_sales_description_check CHECK (((length(TRIM(BOTH FROM description)) >= 1) AND (length(TRIM(BOTH FROM description)) <= 200)));
ALTER TABLE ONLY public.sna_sales ADD CONSTRAINT sna_sales_invoice_no_check CHECK (((invoice_no IS NULL) OR (length(invoice_no) <= 60)));
ALTER TABLE ONLY public.sna_sales ADD CONSTRAINT sna_sales_kind_check CHECK ((kind = ANY (ARRAY['new'::text, 'renewal'::text, 'upgrade'::text, 'addon'::text, 'outlet'::text, 'hardware'::text, 'service'::text, 'other'::text])));
ALTER TABLE ONLY public.sna_sales ADD CONSTRAINT sna_sales_note_check CHECK (((note IS NULL) OR (length(note) <= 500)));
ALTER TABLE ONLY public.sna_sales ADD CONSTRAINT sna_sales_period_order CHECK (((period_from IS NULL) OR (period_to IS NULL) OR (period_to >= period_from)));
ALTER TABLE ONLY public.sna_staff ADD CONSTRAINT sna_staff_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sna_staff ADD CONSTRAINT sna_staff_auth_user_id_key UNIQUE (auth_user_id);
ALTER TABLE ONLY public.sna_staff ADD CONSTRAINT sna_staff_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'sales'::text, 'implementer'::text, 'support'::text])));
ALTER TABLE ONLY public.staff_invites ADD CONSTRAINT staff_invites_pkey PRIMARY KEY (user_id);
ALTER TABLE ONLY public.stock_movements ADD CONSTRAINT stock_movements_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.stock_movements ADD CONSTRAINT stock_movements_kind_check CHECK ((kind = ANY (ARRAY['purchase'::text, 'sale'::text, 'returned'::text, 'wastage'::text, 'count'::text, 'adjust'::text, 'transfer_in'::text, 'transfer_out'::text])));
ALTER TABLE ONLY public.subscription_events ADD CONSTRAINT subscription_events_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.supplier_payments ADD CONSTRAINT supplier_payments_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.supplier_payments ADD CONSTRAINT supplier_payments_amount_check CHECK ((amount <> (0)::numeric));
ALTER TABLE ONLY public.supplier_payments ADD CONSTRAINT supplier_payments_check CHECK ((((reverses_id IS NULL) AND (amount > (0)::numeric)) OR ((reverses_id IS NOT NULL) AND (amount < (0)::numeric))));
ALTER TABLE ONLY public.supplier_payments ADD CONSTRAINT supplier_payments_method_check CHECK ((method = ANY (ARRAY['cash'::text, 'bank'::text, 'upi'::text, 'cheque'::text, 'card'::text, 'other'::text])));
ALTER TABLE ONLY public.suppliers ADD CONSTRAINT suppliers_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.suppliers ADD CONSTRAINT suppliers_restaurant_id_id_key UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.suppliers ADD CONSTRAINT suppliers_name_check CHECK (((length(TRIM(BOTH FROM name)) >= 1) AND (length(TRIM(BOTH FROM name)) <= 80)));
ALTER TABLE ONLY public.suppliers ADD CONSTRAINT suppliers_payment_days_check CHECK (((payment_days >= 0) AND (payment_days <= 365)));
ALTER TABLE ONLY public.sync_log ADD CONSTRAINT sync_log_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.sync_log ADD CONSTRAINT sync_log_direction_check CHECK ((direction = ANY (ARRAY['push'::text, 'pull'::text])));
ALTER TABLE ONLY public.tax_groups ADD CONSTRAINT tax_groups_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.tax_groups ADD CONSTRAINT tax_groups_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.tax_groups ADD CONSTRAINT tax_groups_restaurant_id_name_key UNIQUE (restaurant_id, name);
ALTER TABLE ONLY public.tax_rate_components ADD CONSTRAINT tax_rate_components_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.tax_rate_components ADD CONSTRAINT tax_rate_components_applies_when_check CHECK ((applies_when = ANY (ARRAY['always'::text, 'intra_region'::text, 'inter_region'::text])));
ALTER TABLE ONLY public.tax_rate_components ADD CONSTRAINT tax_rate_components_rate_check CHECK ((rate >= (0)::numeric));
ALTER TABLE ONLY public.tax_rates ADD CONSTRAINT tax_rates_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.tax_rates ADD CONSTRAINT tax_rates_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.tax_rates ADD CONSTRAINT tax_rates_check CHECK (((valid_to IS NULL) OR (valid_to >= valid_from)));
ALTER TABLE ONLY public.tax_rates ADD CONSTRAINT tax_rates_total_rate_check CHECK (((total_rate >= (0)::numeric) AND (total_rate <= (100)::numeric)));
ALTER TABLE ONLY public.time_entries ADD CONSTRAINT time_entries_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.time_entries ADD CONSTRAINT time_entries_check CHECK (((clock_out IS NULL) OR (clock_out > clock_in)));
ALTER TABLE ONLY public.user_branches ADD CONSTRAINT user_branches_pkey PRIMARY KEY (user_id, branch_id);
ALTER TABLE ONLY public.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.users ADD CONSTRAINT users_auth_user_id_key UNIQUE (auth_user_id);
ALTER TABLE ONLY public.users ADD CONSTRAINT users_rest_id_uq UNIQUE (restaurant_id, id);
ALTER TABLE ONLY public.users ADD CONSTRAINT users_restaurant_id_employee_code_key UNIQUE (restaurant_id, employee_code);
ALTER TABLE ONLY public.users ADD CONSTRAINT users_email_required_for_password_login CHECK (((auth_user_id IS NULL) OR (email IS NOT NULL)));

-- ---------------------------------------------------------------------
-- Foreign keys
-- ---------------------------------------------------------------------
ALTER TABLE ONLY public.agent_actions ADD CONSTRAINT agent_actions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.agent_actions ADD CONSTRAINT agent_actions_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.agent_actions ADD CONSTRAINT agent_actions_reviewed_by_same_rest FOREIGN KEY (restaurant_id, reviewed_by) REFERENCES users(restaurant_id, id);
ALTER TABLE ONLY public.agent_actions ADD CONSTRAINT agent_actions_session_id_fkey FOREIGN KEY (session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.agent_actions ADD CONSTRAINT agent_actions_session_id_same_rest FOREIGN KEY (restaurant_id, session_id) REFERENCES agent_sessions(restaurant_id, id);
ALTER TABLE ONLY public.agent_messages ADD CONSTRAINT agent_messages_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.agent_messages ADD CONSTRAINT agent_messages_session_id_fkey FOREIGN KEY (session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.agent_messages ADD CONSTRAINT agent_messages_session_id_same_rest FOREIGN KEY (restaurant_id, session_id) REFERENCES agent_sessions(restaurant_id, id);
ALTER TABLE ONLY public.agent_sessions ADD CONSTRAINT agent_sessions_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.agent_sessions ADD CONSTRAINT agent_sessions_branch_id_same_rest FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.agent_sessions ADD CONSTRAINT agent_sessions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.agent_sessions ADD CONSTRAINT agent_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.agent_sessions ADD CONSTRAINT agent_sessions_user_id_same_rest FOREIGN KEY (restaurant_id, user_id) REFERENCES users(restaurant_id, id);
ALTER TABLE ONLY public.agent_settings ADD CONSTRAINT agent_settings_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.agent_usage ADD CONSTRAINT agent_usage_currency_code_fkey FOREIGN KEY (currency_code) REFERENCES currencies(code);
ALTER TABLE ONLY public.agent_usage ADD CONSTRAINT agent_usage_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.api_calls ADD CONSTRAINT api_calls_key_id_fkey FOREIGN KEY (key_id) REFERENCES api_keys(id);
ALTER TABLE ONLY public.api_keys ADD CONSTRAINT api_keys_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id);
ALTER TABLE ONLY public.api_keys ADD CONSTRAINT api_keys_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.approvals ADD CONSTRAINT approvals_permission_key_fkey FOREIGN KEY (permission_key) REFERENCES permissions(key);
ALTER TABLE ONLY public.approvals ADD CONSTRAINT approvals_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_agent_session_fk FOREIGN KEY (agent_session_id) REFERENCES agent_sessions(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_device_id_fkey FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.audit_logs ADD CONSTRAINT audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.batch_movements ADD CONSTRAINT batch_movements_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES product_batches(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.batch_movements ADD CONSTRAINT batch_movements_order_item_id_fkey FOREIGN KEY (order_item_id) REFERENCES order_items(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.batch_movements ADD CONSTRAINT batch_movements_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.bill_series ADD CONSTRAINT bill_series_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.bill_series ADD CONSTRAINT bill_series_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.bill_series ADD CONSTRAINT bill_series_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.branch_prices ADD CONSTRAINT branch_prices_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id);
ALTER TABLE ONLY public.branch_prices ADD CONSTRAINT branch_prices_product_id_fkey FOREIGN KEY (product_id) REFERENCES products(id);
ALTER TABLE ONLY public.branch_prices ADD CONSTRAINT branch_prices_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.branch_prices ADD CONSTRAINT branch_prices_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES users(id);
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_branch_id_same_rest FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_packing_product_same_rest FOREIGN KEY (restaurant_id, packing_product_id) REFERENCES products(restaurant_id, id);
ALTER TABLE ONLY public.branch_settings ADD CONSTRAINT branch_settings_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.branches ADD CONSTRAINT branches_country_code_fkey FOREIGN KEY (country_code) REFERENCES countries(code);
ALTER TABLE ONLY public.branches ADD CONSTRAINT branches_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.brands ADD CONSTRAINT brands_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.business_days ADD CONSTRAINT business_days_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.business_days ADD CONSTRAINT business_days_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.cash_movements ADD CONSTRAINT cash_movements_recorded_by_fkey FOREIGN KEY (recorded_by) REFERENCES users(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.cash_movements ADD CONSTRAINT cash_movements_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.cash_movements ADD CONSTRAINT cash_movements_shift_id_fkey FOREIGN KEY (shift_id) REFERENCES shifts(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_brand_same_rest FOREIGN KEY (restaurant_id, brand_id) REFERENCES brands(restaurant_id, id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_parent_same_rest FOREIGN KEY (restaurant_id, parent_id) REFERENCES categories(restaurant_id, id);
ALTER TABLE ONLY public.categories ADD CONSTRAINT categories_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.credit_notes ADD CONSTRAINT credit_notes_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.credit_notes ADD CONSTRAINT credit_notes_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.credit_notes ADD CONSTRAINT credit_notes_restaurant_id_order_id_fkey FOREIGN KEY (restaurant_id, order_id) REFERENCES orders(restaurant_id, id);
ALTER TABLE ONLY public.credit_notes ADD CONSTRAINT credit_notes_restaurant_id_payment_method_id_fkey FOREIGN KEY (restaurant_id, payment_method_id) REFERENCES payment_methods(restaurant_id, id);
ALTER TABLE ONLY public.customer_ledger ADD CONSTRAINT customer_ledger_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.customer_ledger ADD CONSTRAINT customer_ledger_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.customer_ledger ADD CONSTRAINT customer_ledger_payment_method_id_fkey FOREIGN KEY (payment_method_id) REFERENCES payment_methods(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.customer_ledger ADD CONSTRAINT customer_ledger_restaurant_id_customer_id_fkey FOREIGN KEY (restaurant_id, customer_id) REFERENCES customers(restaurant_id, id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.customer_ledger ADD CONSTRAINT customer_ledger_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.customer_ledger ADD CONSTRAINT customer_ledger_shift_id_fkey FOREIGN KEY (shift_id) REFERENCES shifts(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.customers ADD CONSTRAINT customers_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.devices ADD CONSTRAINT devices_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_branch_id_same_rest FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_floor_id_fkey FOREIGN KEY (floor_id) REFERENCES floors(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_floor_id_same_rest FOREIGN KEY (restaurant_id, floor_id) REFERENCES floors(restaurant_id, id);
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_kiosk_user_id_fkey FOREIGN KEY (kiosk_user_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.dining_tables ADD CONSTRAINT dining_tables_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.floors ADD CONSTRAINT floors_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.floors ADD CONSTRAINT floors_branch_id_same_rest FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.floors ADD CONSTRAINT floors_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.gift_card_ledger ADD CONSTRAINT gift_card_ledger_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id);
ALTER TABLE ONLY public.gift_card_ledger ADD CONSTRAINT gift_card_ledger_gift_card_id_fkey FOREIGN KEY (gift_card_id) REFERENCES gift_cards(id);
ALTER TABLE ONLY public.gift_card_ledger ADD CONSTRAINT gift_card_ledger_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id);
ALTER TABLE ONLY public.gift_card_ledger ADD CONSTRAINT gift_card_ledger_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.gift_cards ADD CONSTRAINT gift_cards_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(id);
ALTER TABLE ONLY public.gift_cards ADD CONSTRAINT gift_cards_issued_by_fkey FOREIGN KEY (issued_by) REFERENCES users(id);
ALTER TABLE ONLY public.gift_cards ADD CONSTRAINT gift_cards_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.gift_cards ADD CONSTRAINT gift_cards_sold_branch_id_fkey FOREIGN KEY (sold_branch_id) REFERENCES branches(id);
ALTER TABLE ONLY public.gift_cards ADD CONSTRAINT gift_cards_sold_method_id_fkey FOREIGN KEY (sold_method_id) REFERENCES payment_methods(id);
ALTER TABLE ONLY public.gift_cards ADD CONSTRAINT gift_cards_sold_shift_id_fkey FOREIGN KEY (sold_shift_id) REFERENCES shifts(id);
ALTER TABLE ONLY public.goods_receipt_lines ADD CONSTRAINT goods_receipt_lines_restaurant_id_goods_receipt_id_fkey FOREIGN KEY (restaurant_id, goods_receipt_id) REFERENCES goods_receipts(restaurant_id, id) ON DELETE CASCADE;
ALTER TABLE ONLY public.goods_receipt_lines ADD CONSTRAINT goods_receipt_lines_restaurant_id_ingredient_id_fkey FOREIGN KEY (restaurant_id, ingredient_id) REFERENCES ingredients(restaurant_id, id);
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_cancelled_by_fkey FOREIGN KEY (cancelled_by) REFERENCES users(id);
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_received_by_fkey FOREIGN KEY (received_by) REFERENCES users(id);
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_restaurant_id_purchase_order_id_fkey FOREIGN KEY (restaurant_id, purchase_order_id) REFERENCES purchase_orders(restaurant_id, id);
ALTER TABLE ONLY public.goods_receipts ADD CONSTRAINT goods_receipts_restaurant_id_supplier_id_fkey FOREIGN KEY (restaurant_id, supplier_id) REFERENCES suppliers(restaurant_id, id);
ALTER TABLE ONLY public.ingredients ADD CONSTRAINT ingredients_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.kitchen_ticket_items ADD CONSTRAINT kitchen_ticket_items_kitchen_ticket_id_fkey FOREIGN KEY (kitchen_ticket_id) REFERENCES kitchen_tickets(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.kitchen_ticket_items ADD CONSTRAINT kitchen_ticket_items_order_item_id_fkey FOREIGN KEY (order_item_id) REFERENCES order_items(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.kitchen_ticket_items ADD CONSTRAINT kitchen_ticket_items_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.kitchen_tickets ADD CONSTRAINT kitchen_tickets_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.kitchen_tickets ADD CONSTRAINT kitchen_tickets_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.kitchen_tickets ADD CONSTRAINT kitchen_tickets_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.liquor_series ADD CONSTRAINT liquor_series_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.liquor_series ADD CONSTRAINT liquor_series_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.loyalty_ledger ADD CONSTRAINT loyalty_ledger_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id);
ALTER TABLE ONLY public.loyalty_ledger ADD CONSTRAINT loyalty_ledger_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(id);
ALTER TABLE ONLY public.loyalty_ledger ADD CONSTRAINT loyalty_ledger_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id);
ALTER TABLE ONLY public.loyalty_ledger ADD CONSTRAINT loyalty_ledger_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.loyalty_settings ADD CONSTRAINT loyalty_settings_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.meal_sessions ADD CONSTRAINT meal_sessions_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id);
ALTER TABLE ONLY public.meal_sessions ADD CONSTRAINT meal_sessions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.modifier_groups ADD CONSTRAINT modifier_groups_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.modifier_items ADD CONSTRAINT modifier_items_modifier_group_id_fkey FOREIGN KEY (modifier_group_id) REFERENCES modifier_groups(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.modifier_items ADD CONSTRAINT modifier_items_modifier_group_id_same_rest FOREIGN KEY (restaurant_id, modifier_group_id) REFERENCES modifier_groups(restaurant_id, id);
ALTER TABLE ONLY public.modifier_items ADD CONSTRAINT modifier_items_product_same_rest FOREIGN KEY (restaurant_id, product_id) REFERENCES products(restaurant_id, id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.modifier_items ADD CONSTRAINT modifier_items_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.offline_series ADD CONSTRAINT offline_series_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.offline_series ADD CONSTRAINT offline_series_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.online_channels ADD CONSTRAINT online_channels_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.online_orders ADD CONSTRAINT online_orders_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_discounts ADD CONSTRAINT order_discounts_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.order_discounts ADD CONSTRAINT order_discounts_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_discounts ADD CONSTRAINT order_discounts_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_item_modifiers ADD CONSTRAINT order_item_modifiers_modifier_item_id_fkey FOREIGN KEY (modifier_item_id) REFERENCES modifier_items(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.order_item_modifiers ADD CONSTRAINT order_item_modifiers_modifier_item_id_same_rest FOREIGN KEY (restaurant_id, modifier_item_id) REFERENCES modifier_items(restaurant_id, id);
ALTER TABLE ONLY public.order_item_modifiers ADD CONSTRAINT order_item_modifiers_order_item_id_fkey FOREIGN KEY (order_item_id) REFERENCES order_items(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_item_modifiers ADD CONSTRAINT order_item_modifiers_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_item_taxes ADD CONSTRAINT order_item_taxes_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_item_taxes ADD CONSTRAINT order_item_taxes_order_item_id_fkey FOREIGN KEY (order_item_id) REFERENCES order_items(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_item_taxes ADD CONSTRAINT order_item_taxes_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES brands(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_cancelled_by_fkey FOREIGN KEY (cancelled_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_product_id_same_rest FOREIGN KEY (restaurant_id, product_id) REFERENCES products(restaurant_id, id);
ALTER TABLE ONLY public.order_items ADD CONSTRAINT order_items_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_business_day_fk FOREIGN KEY (branch_id, business_date) REFERENCES business_days(branch_id, business_date);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_cashier_id_fkey FOREIGN KEY (cashier_id) REFERENCES users(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_comp_by_fkey FOREIGN KEY (comp_by) REFERENCES users(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_currency_code_fkey FOREIGN KEY (currency_code) REFERENCES currencies(code);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_customer_id_same_rest FOREIGN KEY (restaurant_id, customer_id) REFERENCES customers(restaurant_id, id);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_device_id_fkey FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_dining_table_id_fkey FOREIGN KEY (dining_table_id) REFERENCES dining_tables(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_dining_table_id_same_rest FOREIGN KEY (restaurant_id, dining_table_id) REFERENCES dining_tables(restaurant_id, id);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_merged_into_fkey FOREIGN KEY (merged_into) REFERENCES orders(id);
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_rider_same_rest FOREIGN KEY (restaurant_id, rider_id) REFERENCES riders(restaurant_id, id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_shift_fk FOREIGN KEY (shift_id) REFERENCES shifts(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_voided_by_fkey FOREIGN KEY (voided_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.orders ADD CONSTRAINT orders_waiter_id_fkey FOREIGN KEY (waiter_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.owner_alerts ADD CONSTRAINT owner_alerts_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id);
ALTER TABLE ONLY public.owner_alerts ADD CONSTRAINT owner_alerts_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.payment_methods ADD CONSTRAINT payment_methods_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_currency_code_fkey FOREIGN KEY (currency_code) REFERENCES currencies(code);
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_payment_method_id_fkey FOREIGN KEY (payment_method_id) REFERENCES payment_methods(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_payment_method_id_same_rest FOREIGN KEY (restaurant_id, payment_method_id) REFERENCES payment_methods(restaurant_id, id);
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_received_by_fkey FOREIGN KEY (received_by) REFERENCES users(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.payments ADD CONSTRAINT payments_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.pin_attempts ADD CONSTRAINT pin_attempts_device_id_fkey FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.pin_sessions ADD CONSTRAINT pin_sessions_device_id_fkey FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.pin_sessions ADD CONSTRAINT pin_sessions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.pin_sessions ADD CONSTRAINT pin_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id);
ALTER TABLE ONLY public.plan_requests ADD CONSTRAINT plan_requests_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id);
ALTER TABLE ONLY public.plan_requests ADD CONSTRAINT plan_requests_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES sna_staff(id);
ALTER TABLE ONLY public.plan_requests ADD CONSTRAINT plan_requests_done_by_fkey FOREIGN KEY (done_by) REFERENCES sna_staff(id);
ALTER TABLE ONLY public.plan_requests ADD CONSTRAINT plan_requests_module_key_fkey FOREIGN KEY (module_key) REFERENCES modules(key);
ALTER TABLE ONLY public.plan_requests ADD CONSTRAINT plan_requests_requested_by_staff_fkey FOREIGN KEY (requested_by_staff) REFERENCES sna_staff(id);
ALTER TABLE ONLY public.plan_requests ADD CONSTRAINT plan_requests_requested_by_user_fkey FOREIGN KEY (requested_by_user) REFERENCES users(id);
ALTER TABLE ONLY public.plan_requests ADD CONSTRAINT plan_requests_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.pre_order_payments ADD CONSTRAINT pre_order_payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.pre_order_payments ADD CONSTRAINT pre_order_payments_payment_method_id_fkey FOREIGN KEY (payment_method_id) REFERENCES payment_methods(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.pre_order_payments ADD CONSTRAINT pre_order_payments_pre_order_id_fkey FOREIGN KEY (pre_order_id) REFERENCES pre_orders(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.pre_order_payments ADD CONSTRAINT pre_order_payments_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.pre_order_payments ADD CONSTRAINT pre_order_payments_shift_id_fkey FOREIGN KEY (shift_id) REFERENCES shifts(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.pre_orders ADD CONSTRAINT pre_orders_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id) ON DELETE CASCADE;
ALTER TABLE ONLY public.price_rules ADD CONSTRAINT price_rules_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.printers ADD CONSTRAINT printers_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.printers ADD CONSTRAINT printers_branch_id_same_rest FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.printers ADD CONSTRAINT printers_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.product_batches ADD CONSTRAINT product_batches_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.product_batches ADD CONSTRAINT product_batches_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.product_batches ADD CONSTRAINT product_batches_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.product_batches ADD CONSTRAINT product_batches_restaurant_id_product_id_fkey FOREIGN KEY (restaurant_id, product_id) REFERENCES products(restaurant_id, id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.product_modifier_groups ADD CONSTRAINT product_modifier_groups_modifier_group_id_fkey FOREIGN KEY (modifier_group_id) REFERENCES modifier_groups(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.product_modifier_groups ADD CONSTRAINT product_modifier_groups_modifier_group_id_same_rest FOREIGN KEY (restaurant_id, modifier_group_id) REFERENCES modifier_groups(restaurant_id, id);
ALTER TABLE ONLY public.product_modifier_groups ADD CONSTRAINT product_modifier_groups_product_id_fkey FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.product_modifier_groups ADD CONSTRAINT product_modifier_groups_product_id_same_rest FOREIGN KEY (restaurant_id, product_id) REFERENCES products(restaurant_id, id);
ALTER TABLE ONLY public.product_modifier_groups ADD CONSTRAINT product_modifier_groups_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.product_price_history ADD CONSTRAINT product_price_history_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.products ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.products ADD CONSTRAINT products_category_id_same_rest FOREIGN KEY (restaurant_id, category_id) REFERENCES categories(restaurant_id, id);
ALTER TABLE ONLY public.products ADD CONSTRAINT products_parent_same_rest FOREIGN KEY (restaurant_id, parent_id) REFERENCES products(restaurant_id, id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.products ADD CONSTRAINT products_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.products ADD CONSTRAINT products_tax_group_id_fkey FOREIGN KEY (tax_group_id) REFERENCES tax_groups(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.products ADD CONSTRAINT products_tax_group_id_same_rest FOREIGN KEY (restaurant_id, tax_group_id) REFERENCES tax_groups(restaurant_id, id);
ALTER TABLE ONLY public.purchase_order_lines ADD CONSTRAINT purchase_order_lines_restaurant_id_ingredient_id_fkey FOREIGN KEY (restaurant_id, ingredient_id) REFERENCES ingredients(restaurant_id, id);
ALTER TABLE ONLY public.purchase_order_lines ADD CONSTRAINT purchase_order_lines_restaurant_id_purchase_order_id_fkey FOREIGN KEY (restaurant_id, purchase_order_id) REFERENCES purchase_orders(restaurant_id, id) ON DELETE CASCADE;
ALTER TABLE ONLY public.purchase_orders ADD CONSTRAINT purchase_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id);
ALTER TABLE ONLY public.purchase_orders ADD CONSTRAINT purchase_orders_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.purchase_orders ADD CONSTRAINT purchase_orders_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.purchase_orders ADD CONSTRAINT purchase_orders_restaurant_id_supplier_id_fkey FOREIGN KEY (restaurant_id, supplier_id) REFERENCES suppliers(restaurant_id, id);
ALTER TABLE ONLY public.push_subscriptions ADD CONSTRAINT push_subscriptions_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.push_subscriptions ADD CONSTRAINT push_subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id);
ALTER TABLE ONLY public.qr_orders ADD CONSTRAINT qr_orders_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id);
ALTER TABLE ONLY public.qr_orders ADD CONSTRAINT qr_orders_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES users(id);
ALTER TABLE ONLY public.qr_orders ADD CONSTRAINT qr_orders_dining_table_id_fkey FOREIGN KEY (dining_table_id) REFERENCES dining_tables(id);
ALTER TABLE ONLY public.qr_orders ADD CONSTRAINT qr_orders_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id);
ALTER TABLE ONLY public.qr_orders ADD CONSTRAINT qr_orders_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.recipe_lines ADD CONSTRAINT recipe_lines_restaurant_id_ingredient_id_fkey FOREIGN KEY (restaurant_id, ingredient_id) REFERENCES ingredients(restaurant_id, id) ON DELETE CASCADE;
ALTER TABLE ONLY public.recipe_lines ADD CONSTRAINT recipe_lines_restaurant_id_product_id_fkey FOREIGN KEY (restaurant_id, product_id) REFERENCES products(restaurant_id, id) ON DELETE CASCADE;
ALTER TABLE ONLY public.refunds ADD CONSTRAINT refunds_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.refunds ADD CONSTRAINT refunds_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.refunds ADD CONSTRAINT refunds_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES payments(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.refunds ADD CONSTRAINT refunds_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.report_schedules ADD CONSTRAINT report_schedules_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.report_schedules ADD CONSTRAINT report_schedules_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id) ON DELETE CASCADE;
ALTER TABLE ONLY public.report_schedules ADD CONSTRAINT report_schedules_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.request_refs ADD CONSTRAINT request_refs_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.reservations ADD CONSTRAINT reservations_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id);
ALTER TABLE ONLY public.reservations ADD CONSTRAINT reservations_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id);
ALTER TABLE ONLY public.reservations ADD CONSTRAINT reservations_dining_table_id_fkey FOREIGN KEY (dining_table_id) REFERENCES dining_tables(id);
ALTER TABLE ONLY public.reservations ADD CONSTRAINT reservations_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.restaurant_modules ADD CONSTRAINT restaurant_modules_module_key_fkey FOREIGN KEY (module_key) REFERENCES modules(key);
ALTER TABLE ONLY public.restaurant_modules ADD CONSTRAINT restaurant_modules_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.restaurants ADD CONSTRAINT restaurants_country_code_fkey FOREIGN KEY (country_code) REFERENCES countries(code);
ALTER TABLE ONLY public.restaurants ADD CONSTRAINT restaurants_currency_code_fkey FOREIGN KEY (currency_code) REFERENCES currencies(code);
ALTER TABLE ONLY public.riders ADD CONSTRAINT riders_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.riders ADD CONSTRAINT riders_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.role_permissions ADD CONSTRAINT role_permissions_permission_key_fkey FOREIGN KEY (permission_key) REFERENCES permissions(key) ON DELETE CASCADE;
ALTER TABLE ONLY public.role_permissions ADD CONSTRAINT role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.roles ADD CONSTRAINT roles_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.shift_closings ADD CONSTRAINT shift_closings_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.shift_closings ADD CONSTRAINT shift_closings_shift_id_fkey FOREIGN KEY (shift_id) REFERENCES shifts(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.shifts ADD CONSTRAINT shifts_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.shifts ADD CONSTRAINT shifts_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.shifts ADD CONSTRAINT shifts_device_id_fkey FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.shifts ADD CONSTRAINT shifts_opened_by_fkey FOREIGN KEY (opened_by) REFERENCES users(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.shifts ADD CONSTRAINT shifts_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.sna_accounts ADD CONSTRAINT sna_accounts_account_manager_fkey FOREIGN KEY (account_manager) REFERENCES sna_staff(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.sna_accounts ADD CONSTRAINT sna_accounts_live_by_fkey FOREIGN KEY (live_by) REFERENCES sna_staff(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.sna_accounts ADD CONSTRAINT sna_accounts_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.sna_accounts ADD CONSTRAINT sna_accounts_sales_person_fkey FOREIGN KEY (sales_person) REFERENCES sna_staff(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.sna_accounts ADD CONSTRAINT sna_accounts_support_person_fkey FOREIGN KEY (support_person) REFERENCES sna_staff(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.sna_accounts ADD CONSTRAINT sna_accounts_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES sna_staff(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.sna_contacts ADD CONSTRAINT sna_contacts_created_by_fkey FOREIGN KEY (created_by) REFERENCES sna_staff(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.sna_contacts ADD CONSTRAINT sna_contacts_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.sna_notes ADD CONSTRAINT sna_notes_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.sna_notes ADD CONSTRAINT sna_notes_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES sna_staff(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.sna_sales ADD CONSTRAINT sna_sales_cancelled_by_fkey FOREIGN KEY (cancelled_by) REFERENCES sna_staff(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.sna_sales ADD CONSTRAINT sna_sales_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.sna_sales ADD CONSTRAINT sna_sales_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES sna_staff(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.sna_staff ADD CONSTRAINT sna_staff_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id);
ALTER TABLE ONLY public.staff_invites ADD CONSTRAINT staff_invites_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.staff_invites ADD CONSTRAINT staff_invites_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.staff_invites ADD CONSTRAINT staff_invites_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.stock_movements ADD CONSTRAINT stock_movements_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.stock_movements ADD CONSTRAINT stock_movements_restaurant_id_ingredient_id_fkey FOREIGN KEY (restaurant_id, ingredient_id) REFERENCES ingredients(restaurant_id, id);
ALTER TABLE ONLY public.subscription_events ADD CONSTRAINT subscription_events_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.subscription_events ADD CONSTRAINT subscription_events_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES sna_staff(id);
ALTER TABLE ONLY public.subscription_events ADD CONSTRAINT subscription_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id);
ALTER TABLE ONLY public.supplier_payments ADD CONSTRAINT supplier_payments_paid_by_fkey FOREIGN KEY (paid_by) REFERENCES users(id);
ALTER TABLE ONLY public.supplier_payments ADD CONSTRAINT supplier_payments_restaurant_id_branch_id_fkey FOREIGN KEY (restaurant_id, branch_id) REFERENCES branches(restaurant_id, id);
ALTER TABLE ONLY public.supplier_payments ADD CONSTRAINT supplier_payments_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.supplier_payments ADD CONSTRAINT supplier_payments_restaurant_id_goods_receipt_id_fkey FOREIGN KEY (restaurant_id, goods_receipt_id) REFERENCES goods_receipts(restaurant_id, id);
ALTER TABLE ONLY public.supplier_payments ADD CONSTRAINT supplier_payments_restaurant_id_supplier_id_fkey FOREIGN KEY (restaurant_id, supplier_id) REFERENCES suppliers(restaurant_id, id);
ALTER TABLE ONLY public.supplier_payments ADD CONSTRAINT supplier_payments_reverses_id_fkey FOREIGN KEY (reverses_id) REFERENCES supplier_payments(id);
ALTER TABLE ONLY public.suppliers ADD CONSTRAINT suppliers_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.sync_log ADD CONSTRAINT sync_log_device_id_fkey FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.sync_log ADD CONSTRAINT sync_log_device_id_same_rest FOREIGN KEY (restaurant_id, device_id) REFERENCES devices(restaurant_id, id);
ALTER TABLE ONLY public.sync_log ADD CONSTRAINT sync_log_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.tax_groups ADD CONSTRAINT tax_groups_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.tax_rate_components ADD CONSTRAINT tax_rate_components_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.tax_rate_components ADD CONSTRAINT tax_rate_components_tax_rate_id_fkey FOREIGN KEY (tax_rate_id) REFERENCES tax_rates(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.tax_rate_components ADD CONSTRAINT tax_rate_components_tax_rate_id_same_rest FOREIGN KEY (restaurant_id, tax_rate_id) REFERENCES tax_rates(restaurant_id, id);
ALTER TABLE ONLY public.tax_rates ADD CONSTRAINT tax_rates_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.tax_rates ADD CONSTRAINT tax_rates_tax_group_id_fkey FOREIGN KEY (tax_group_id) REFERENCES tax_groups(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.tax_rates ADD CONSTRAINT tax_rates_tax_group_id_same_rest FOREIGN KEY (restaurant_id, tax_group_id) REFERENCES tax_groups(restaurant_id, id);
ALTER TABLE ONLY public.time_entries ADD CONSTRAINT time_entries_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id);
ALTER TABLE ONLY public.time_entries ADD CONSTRAINT time_entries_edited_by_fkey FOREIGN KEY (edited_by) REFERENCES users(id);
ALTER TABLE ONLY public.time_entries ADD CONSTRAINT time_entries_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id);
ALTER TABLE ONLY public.time_entries ADD CONSTRAINT time_entries_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id);
ALTER TABLE ONLY public.user_branches ADD CONSTRAINT user_branches_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES branches(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.user_branches ADD CONSTRAINT user_branches_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.user_branches ADD CONSTRAINT user_branches_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.users ADD CONSTRAINT users_current_branch_id_fkey FOREIGN KEY (current_branch_id) REFERENCES branches(id);
ALTER TABLE ONLY public.users ADD CONSTRAINT users_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES restaurants(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.users ADD CONSTRAINT users_role_id_fkey FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE RESTRICT;
ALTER TABLE ONLY public.users ADD CONSTRAINT users_role_id_same_rest FOREIGN KEY (restaurant_id, role_id) REFERENCES roles(restaurant_id, id);

-- ---------------------------------------------------------------------
-- Sequence ownership
-- ---------------------------------------------------------------------
ALTER SEQUENCE public.api_calls_id_seq OWNED BY public.api_calls.id;
ALTER SEQUENCE public.approval_failures_id_seq OWNED BY public.approval_failures.id;
ALTER SEQUENCE public.audit_logs_id_seq OWNED BY public.audit_logs.id;
ALTER SEQUENCE public.product_price_history_id_seq OWNED BY public.product_price_history.id;
ALTER SEQUENCE public.restaurant_client_code_seq OWNED BY public.restaurants.client_code;
ALTER SEQUENCE public.sync_log_id_seq OWNED BY public.sync_log.id;

-- ---------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------
CREATE INDEX idx_agent_actions_pending ON public.agent_actions USING btree (restaurant_id, status) WHERE (status = 'proposed'::text);
CREATE INDEX idx_agent_messages_session ON public.agent_messages USING btree (session_id, created_at);
CREATE INDEX idx_agent_sessions_restaurant ON public.agent_sessions USING btree (restaurant_id, started_at DESC);
CREATE INDEX idx_agent_sessions_user ON public.agent_sessions USING btree (user_id);
CREATE INDEX api_calls_key_at ON public.api_calls USING btree (key_id, at DESC);
CREATE INDEX approvals_lookup ON public.approvals USING btree (requested_by, permission_key) WHERE (used_at IS NULL);
CREATE INDEX idx_audit_entity ON public.audit_logs USING btree (entity_type, entity_id);
CREATE INDEX idx_audit_restaurant_date ON public.audit_logs USING btree (restaurant_id, created_at DESC);
CREATE INDEX idx_batch_moves_item ON public.batch_movements USING btree (order_item_id);
CREATE UNIQUE INDEX bill_series_current_uq ON public.bill_series USING btree (branch_id) WHERE is_current;
CREATE UNIQUE INDEX bill_series_prefix_uq ON public.bill_series USING btree (restaurant_id, upper(prefix));
CREATE INDEX idx_branches_restaurant ON public.branches USING btree (restaurant_id) WHERE (deleted_at IS NULL);
CREATE UNIQUE INDEX brands_name_uq ON public.brands USING btree (restaurant_id, lower(btrim(name)));
CREATE UNIQUE INDEX business_days_one_open ON public.business_days USING btree (branch_id) WHERE (status = 'open'::text);
CREATE UNIQUE INDEX business_days_one_parked ON public.business_days USING btree (branch_id) WHERE (status = 'parked'::text);
CREATE INDEX idx_cash_movements_shift ON public.cash_movements USING btree (shift_id);
CREATE UNIQUE INDEX categories_name_uq ON public.categories USING btree (restaurant_id, COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(btrim(name))) WHERE (deleted_at IS NULL);
CREATE INDEX categories_parent_idx ON public.categories USING btree (parent_id) WHERE (parent_id IS NOT NULL);
CREATE INDEX idx_categories_restaurant ON public.categories USING btree (restaurant_id) WHERE (deleted_at IS NULL);
CREATE INDEX idx_customer_ledger ON public.customer_ledger USING btree (customer_id, created_at);
CREATE UNIQUE INDEX customers_phone_uq ON public.customers USING btree (restaurant_id, phone) WHERE ((deleted_at IS NULL) AND (phone IS NOT NULL));
CREATE INDEX idx_customers_phone ON public.customers USING btree (restaurant_id, phone) WHERE (deleted_at IS NULL);
CREATE INDEX idx_customers_restaurant ON public.customers USING btree (restaurant_id) WHERE (deleted_at IS NULL);
CREATE INDEX idx_devices_branch ON public.devices USING btree (branch_id);
CREATE UNIQUE INDEX dining_tables_qr_token_uq ON public.dining_tables USING btree (qr_token) WHERE (qr_token IS NOT NULL);
CREATE INDEX idx_tables_branch ON public.dining_tables USING btree (branch_id);
CREATE INDEX goods_receipt_lines_receipt ON public.goods_receipt_lines USING btree (goods_receipt_id);
CREATE UNIQUE INDEX goods_receipts_client_ref_uq ON public.goods_receipts USING btree (restaurant_id, client_ref) WHERE (client_ref IS NOT NULL);
CREATE INDEX goods_receipts_lookup ON public.goods_receipts USING btree (branch_id, received_on DESC);
CREATE INDEX goods_receipts_supplier ON public.goods_receipts USING btree (supplier_id, payment_status);
CREATE UNIQUE INDEX ingredients_name_uq ON public.ingredients USING btree (restaurant_id, lower(TRIM(BOTH FROM name))) WHERE is_active;
CREATE INDEX idx_kot_items_ticket ON public.kitchen_ticket_items USING btree (kitchen_ticket_id);
CREATE INDEX idx_kot_active ON public.kitchen_tickets USING btree (branch_id, status) WHERE (status = ANY (ARRAY['new'::text, 'preparing'::text]));
CREATE INDEX idx_kot_order ON public.kitchen_tickets USING btree (order_id);
CREATE UNIQUE INDEX liquor_series_prefix_uq ON public.liquor_series USING btree (restaurant_id, upper(prefix));
CREATE INDEX loyalty_customer_idx ON public.loyalty_ledger USING btree (customer_id);
CREATE UNIQUE INDEX loyalty_one_earn_per_order ON public.loyalty_ledger USING btree (order_id) WHERE (kind = 'earn'::text);
CREATE INDEX meal_sessions_rest_idx ON public.meal_sessions USING btree (restaurant_id, branch_id);
CREATE INDEX idx_modifier_items_product ON public.modifier_items USING btree (product_id) WHERE (product_id IS NOT NULL);
CREATE INDEX idx_online_orders_pending ON public.online_orders USING btree (branch_id, status, created_at);
CREATE INDEX idx_order_discounts_order ON public.order_discounts USING btree (order_id);
CREATE INDEX idx_item_modifiers_item ON public.order_item_modifiers USING btree (order_item_id);
CREATE INDEX idx_order_taxes_order ON public.order_item_taxes USING btree (order_id);
CREATE INDEX idx_order_items_brand ON public.order_items USING btree (brand_id) WHERE (brand_id IS NOT NULL);
CREATE INDEX idx_order_items_order ON public.order_items USING btree (order_id);
CREATE INDEX idx_orders_branch_date ON public.orders USING btree (branch_id, client_created_at DESC);
CREATE INDEX idx_orders_customer ON public.orders USING btree (customer_id) WHERE (customer_id IS NOT NULL);
CREATE INDEX idx_orders_delivery ON public.orders USING btree (branch_id, delivery_status) WHERE (order_type = 'delivery'::text);
CREATE INDEX idx_orders_restaurant ON public.orders USING btree (restaurant_id);
CREATE INDEX idx_orders_shift ON public.orders USING btree (shift_id);
CREATE INDEX idx_orders_unsynced ON public.orders USING btree (synced_at) WHERE (synced_at IS NULL);
CREATE UNIQUE INDEX orders_client_ref_uq ON public.orders USING btree (restaurant_id, client_ref) WHERE (client_ref IS NOT NULL);
CREATE UNIQUE INDEX orders_receipt_token_uq ON public.orders USING btree (receipt_token) WHERE (receipt_token IS NOT NULL);
CREATE INDEX owner_alerts_rest_idx ON public.owner_alerts USING btree (restaurant_id, created_at DESC);
CREATE INDEX idx_payments_order ON public.payments USING btree (order_id);
CREATE INDEX idx_payments_unsynced ON public.payments USING btree (synced_at) WHERE (synced_at IS NULL);
CREATE UNIQUE INDEX payments_client_ref_uq ON public.payments USING btree (restaurant_id, client_ref) WHERE (client_ref IS NOT NULL);
CREATE INDEX pin_attempts_device_at ON public.pin_attempts USING btree (device_id, at);
CREATE INDEX plan_requests_status_created_at_idx ON public.plan_requests USING btree (status, created_at);
CREATE INDEX idx_pre_order_payments ON public.pre_order_payments USING btree (pre_order_id);
CREATE INDEX idx_pre_orders_due ON public.pre_orders USING btree (branch_id, due_at) WHERE (status = 'booked'::text);
CREATE INDEX idx_price_rules_rest ON public.price_rules USING btree (restaurant_id) WHERE is_active;
CREATE INDEX idx_printers_branch ON public.printers USING btree (branch_id);
CREATE INDEX idx_batches_open ON public.product_batches USING btree (branch_id, product_id, expires_on) WHERE (qty_left > (0)::numeric);
CREATE INDEX pph_lookup ON public.product_price_history USING btree (product_id, valid_from);
CREATE INDEX idx_products_category ON public.products USING btree (category_id) WHERE (deleted_at IS NULL);
CREATE INDEX idx_products_name_search ON public.products USING gin (to_tsvector('simple'::regconfig, name));
CREATE INDEX idx_products_parent ON public.products USING btree (parent_id) WHERE ((parent_id IS NOT NULL) AND (deleted_at IS NULL));
CREATE INDEX idx_products_restaurant ON public.products USING btree (restaurant_id) WHERE (deleted_at IS NULL);
CREATE UNIQUE INDEX products_barcode_uq ON public.products USING btree (restaurant_id, barcode) WHERE ((barcode IS NOT NULL) AND (deleted_at IS NULL));
CREATE UNIQUE INDEX products_variant_uq ON public.products USING btree (parent_id, lower(btrim(variant_name))) WHERE ((parent_id IS NOT NULL) AND (deleted_at IS NULL));
CREATE INDEX purchase_orders_lookup ON public.purchase_orders USING btree (branch_id, status, created_at DESC);
CREATE INDEX qr_orders_pending_idx ON public.qr_orders USING btree (restaurant_id, branch_id, status, created_at);
CREATE INDEX idx_refunds_order ON public.refunds USING btree (order_id);
CREATE INDEX report_schedules_branch ON public.report_schedules USING btree (branch_id);
CREATE INDEX report_schedules_due ON public.report_schedules USING btree (send_time) WHERE is_active;
CREATE INDEX request_refs_age ON public.request_refs USING btree (restaurant_id, created_at);
CREATE INDEX reservations_day_idx ON public.reservations USING btree (restaurant_id, branch_id, reserved_for);
CREATE UNIQUE INDEX restaurants_client_code_key ON public.restaurants USING btree (client_code);
CREATE UNIQUE INDEX roles_restaurant_lower_name ON public.roles USING btree (restaurant_id, lower(btrim(name)));
CREATE INDEX idx_shifts_branch ON public.shifts USING btree (branch_id, opened_at DESC);
CREATE UNIQUE INDEX shifts_one_open_per_branch ON public.shifts USING btree (branch_id) WHERE (status = 'open'::text);
CREATE INDEX sna_contacts_restaurant ON public.sna_contacts USING btree (restaurant_id) WHERE (removed_at IS NULL);
CREATE INDEX sna_notes_restaurant ON public.sna_notes USING btree (restaurant_id, created_at DESC);
CREATE INDEX sna_sales_restaurant ON public.sna_sales USING btree (restaurant_id, sale_date DESC);
CREATE INDEX stock_movements_lookup ON public.stock_movements USING btree (branch_id, ingredient_id, created_at);
CREATE UNIQUE INDEX supplier_payments_client_ref_uq ON public.supplier_payments USING btree (restaurant_id, client_ref) WHERE (client_ref IS NOT NULL);
CREATE INDEX supplier_payments_receipt ON public.supplier_payments USING btree (goods_receipt_id);
CREATE UNIQUE INDEX supplier_payments_reverses_uq ON public.supplier_payments USING btree (reverses_id) WHERE (reverses_id IS NOT NULL);
CREATE UNIQUE INDEX suppliers_name_uq ON public.suppliers USING btree (restaurant_id, lower(TRIM(BOTH FROM name))) WHERE is_active;
CREATE INDEX idx_sync_log_device ON public.sync_log USING btree (device_id, started_at DESC);
CREATE INDEX idx_tax_components_rate ON public.tax_rate_components USING btree (tax_rate_id);
CREATE INDEX idx_tax_rates_lookup ON public.tax_rates USING btree (tax_group_id, valid_from DESC);
CREATE INDEX time_entries_day_idx ON public.time_entries USING btree (restaurant_id, clock_in);
CREATE UNIQUE INDEX time_entries_one_open ON public.time_entries USING btree (user_id) WHERE (clock_out IS NULL);
CREATE INDEX idx_users_auth ON public.users USING btree (auth_user_id);
CREATE INDEX idx_users_restaurant ON public.users USING btree (restaurant_id) WHERE (deleted_at IS NULL);
CREATE UNIQUE INDEX users_pin_unique ON public.users USING btree (restaurant_id, pin_hash) WHERE ((pin_hash IS NOT NULL) AND (deleted_at IS NULL));

-- ---------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.agent_settings FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.agent_usage FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
CREATE TRIGGER trg_audit_to_alert AFTER INSERT ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION app.audit_to_alert();
CREATE TRIGGER trg_no_delete_audit BEFORE DELETE ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_no_update_audit BEFORE UPDATE ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION app.block_update();
CREATE TRIGGER trg_prefix_clash BEFORE INSERT OR UPDATE OF prefix ON public.bill_series FOR EACH ROW EXECUTE FUNCTION app.trg_prefix_clash();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.branch_settings FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
CREATE TRIGGER trg_basic_limits BEFORE INSERT OR UPDATE OF deleted_at ON public.branches FOR EACH ROW EXECUTE FUNCTION app.basic_limits();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.branches FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
CREATE TRIGGER trg_category_brand BEFORE INSERT OR UPDATE OF parent_id, brand_id ON public.categories FOR EACH ROW EXECUTE FUNCTION app.trg_category_brand();
CREATE TRIGGER trg_category_brand_follow AFTER UPDATE OF brand_id ON public.categories FOR EACH ROW EXECUTE FUNCTION app.trg_category_brand_follow();
CREATE TRIGGER trg_category_parent BEFORE INSERT OR UPDATE OF parent_id, deleted_at ON public.categories FOR EACH ROW EXECUTE FUNCTION app.trg_category_parent();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.categories FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
CREATE TRIGGER trg_loyalty_reverse AFTER INSERT ON public.credit_notes FOR EACH ROW EXECUTE FUNCTION app.loyalty_reverse();
CREATE TRIGGER trg_no_delete_credit_notes BEFORE DELETE ON public.credit_notes FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_no_update_credit_notes BEFORE UPDATE ON public.credit_notes FOR EACH ROW EXECUTE FUNCTION app.block_update();
CREATE TRIGGER trg_no_change_customer_ledger BEFORE DELETE OR UPDATE ON public.customer_ledger FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
CREATE TRIGGER trg_basic_limits BEFORE INSERT OR UPDATE OF is_active ON public.devices FOR EACH ROW EXECUTE FUNCTION app.basic_limits();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.dining_tables FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
CREATE TRIGGER trg_no_delete BEFORE DELETE ON public.gift_card_ledger FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_no_update BEFORE UPDATE ON public.gift_card_ledger FOR EACH ROW EXECUTE FUNCTION app.block_update();
CREATE TRIGGER trg_no_delete BEFORE DELETE ON public.gift_cards FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_fill_local_name BEFORE INSERT ON public.kitchen_ticket_items FOR EACH ROW EXECUTE FUNCTION app.fill_local_name();
CREATE TRIGGER trg_prefix_clash BEFORE INSERT OR UPDATE OF prefix ON public.liquor_series FOR EACH ROW EXECUTE FUNCTION app.trg_prefix_clash();
CREATE TRIGGER trg_no_delete BEFORE DELETE ON public.loyalty_ledger FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_no_update BEFORE UPDATE ON public.loyalty_ledger FOR EACH ROW EXECUTE FUNCTION app.block_update();
CREATE TRIGGER trg_modifier_item_dish BEFORE INSERT OR UPDATE OF product_id ON public.modifier_items FOR EACH ROW EXECUTE FUNCTION app.trg_modifier_item_dish();
CREATE TRIGGER trg_stock_on_item_option AFTER INSERT ON public.order_item_modifiers FOR EACH ROW EXECUTE FUNCTION app.stock_on_item_option();
CREATE TRIGGER trg_batch_on_item AFTER INSERT OR UPDATE OF quantity, cancelled_qty, cancelled_at ON public.order_items FOR EACH ROW EXECUTE FUNCTION app.batch_on_item();
CREATE TRIGGER trg_fill_local_name BEFORE INSERT ON public.order_items FOR EACH ROW EXECUTE FUNCTION app.fill_local_name();
CREATE TRIGGER trg_guard_closed_day_items BEFORE INSERT OR UPDATE ON public.order_items FOR EACH ROW EXECUTE FUNCTION app.guard_closed_day();
CREATE TRIGGER trg_item_liquor BEFORE INSERT OR UPDATE OF order_id ON public.order_items FOR EACH ROW EXECUTE FUNCTION app.trg_item_liquor();
CREATE TRIGGER trg_licence_order_items BEFORE INSERT ON public.order_items FOR EACH ROW EXECUTE FUNCTION app.trg_licence_order_items();
CREATE TRIGGER trg_order_item_brand BEFORE INSERT ON public.order_items FOR EACH ROW EXECUTE FUNCTION app.trg_order_item_brand();
CREATE TRIGGER trg_order_item_needs_size BEFORE INSERT ON public.order_items FOR EACH ROW EXECUTE FUNCTION app.trg_order_item_needs_size();
CREATE TRIGGER trg_order_item_unit BEFORE INSERT ON public.order_items FOR EACH ROW EXECUTE FUNCTION app.trg_order_item_unit();
CREATE TRIGGER trg_order_item_unit_upd BEFORE UPDATE OF quantity ON public.order_items FOR EACH ROW WHEN ((new.quantity IS DISTINCT FROM old.quantity)) EXECUTE FUNCTION app.trg_order_item_unit();
CREATE TRIGGER trg_stock_on_item AFTER INSERT OR UPDATE OF quantity, cancelled_qty, cancelled_at ON public.order_items FOR EACH ROW EXECUTE FUNCTION app.stock_on_item();
CREATE TRIGGER trg_delivery_status BEFORE INSERT OR UPDATE OF order_type ON public.orders FOR EACH ROW EXECUTE FUNCTION app.trg_delivery_status();
CREATE TRIGGER trg_guard_closed_day BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION app.guard_closed_day();
CREATE TRIGGER trg_licence_orders BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION app.trg_licence_orders();
CREATE TRIGGER trg_loyalty_earn AFTER UPDATE OF payment_status, customer_id ON public.orders FOR EACH ROW EXECUTE FUNCTION app.loyalty_earn();
CREATE TRIGGER trg_no_delete_orders BEFORE DELETE ON public.orders FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_order_business_date BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION app.set_order_business_date();
CREATE TRIGGER trg_order_liquor BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION app.trg_order_liquor();
CREATE TRIGGER trg_order_session BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION app.set_order_session();
CREATE TRIGGER trg_protect_completed_orders BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION app.protect_completed_orders();
CREATE TRIGGER trg_return_on_void AFTER UPDATE OF status ON public.orders FOR EACH ROW WHEN (((new.status = 'voided'::text) AND (old.status IS DISTINCT FROM 'voided'::text))) EXECUTE FUNCTION app.return_on_void();
CREATE TRIGGER trg_stock_on_void AFTER UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION app.stock_on_void();
CREATE TRIGGER trg_push_alert AFTER INSERT ON public.owner_alerts FOR EACH ROW EXECUTE FUNCTION app.push_alert();
CREATE TRIGGER trg_guard_closed_day_pay BEFORE INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION app.guard_closed_day();
CREATE TRIGGER trg_guard_payment_update BEFORE UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION app.guard_payment_update();
CREATE TRIGGER trg_guard_redeem_payment BEFORE INSERT OR UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION app.guard_redeem_payment();
CREATE TRIGGER trg_no_delete_payments BEFORE DELETE ON public.payments FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_payment_shift BEFORE INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION app.set_payment_shift();
CREATE TRIGGER trg_no_delete_pre_order_payments BEFORE DELETE OR UPDATE ON public.pre_order_payments FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_variant_options_link AFTER INSERT OR DELETE ON public.product_modifier_groups FOR EACH ROW EXECUTE FUNCTION app.trg_variant_options();
CREATE TRIGGER trg_basic_limits BEFORE INSERT OR UPDATE OF deleted_at ON public.products FOR EACH ROW EXECUTE FUNCTION app.basic_limits();
CREATE TRIGGER trg_guard_product_change AFTER INSERT OR UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION app.guard_product_change();
CREATE TRIGGER trg_product_combo_flag BEFORE INSERT OR UPDATE OF is_combo, parent_id ON public.products FOR EACH ROW EXECUTE FUNCTION app.trg_product_combo_flag();
CREATE TRIGGER trg_product_variant BEFORE INSERT OR UPDATE OF parent_id, variant_name, name, category_id, deleted_at ON public.products FOR EACH ROW EXECUTE FUNCTION app.trg_product_variant();
CREATE TRIGGER trg_product_variant_follow AFTER UPDATE OF name, category_id, deleted_at ON public.products FOR EACH ROW EXECUTE FUNCTION app.trg_product_variant_follow();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
CREATE TRIGGER trg_track_price AFTER INSERT OR UPDATE OF price ON public.products FOR EACH ROW EXECUTE FUNCTION app.track_price();
CREATE TRIGGER trg_variant_options_new AFTER INSERT ON public.products FOR EACH ROW EXECUTE FUNCTION app.trg_variant_options();
CREATE TRIGGER trg_licence_qr_orders BEFORE INSERT ON public.qr_orders FOR EACH ROW EXECUTE FUNCTION app.trg_licence_qr_orders();
CREATE TRIGGER trg_no_delete_refunds BEFORE DELETE ON public.refunds FOR EACH ROW EXECUTE FUNCTION app.block_update();
CREATE TRIGGER trg_no_update_refunds BEFORE UPDATE ON public.refunds FOR EACH ROW EXECUTE FUNCTION app.block_update();
CREATE TRIGGER trg_default_sac BEFORE INSERT ON public.restaurants FOR EACH ROW EXECUTE FUNCTION app.default_sac();
CREATE TRIGGER trg_seed_sessions AFTER INSERT ON public.restaurants FOR EACH ROW EXECUTE FUNCTION app.seed_sessions_trigger();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.restaurants FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
CREATE TRIGGER trg_freeze_shift_figures BEFORE UPDATE OF status ON public.shifts FOR EACH ROW EXECUTE FUNCTION app.freeze_shift_figures();
CREATE TRIGGER trg_no_delete_stock BEFORE DELETE ON public.stock_movements FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_no_update_stock BEFORE UPDATE ON public.stock_movements FOR EACH ROW EXECUTE FUNCTION app.block_update();
CREATE TRIGGER trg_no_delete_subevents BEFORE DELETE ON public.subscription_events FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_no_update_subevents BEFORE UPDATE ON public.subscription_events FOR EACH ROW EXECUTE FUNCTION app.block_update();
CREATE TRIGGER trg_no_delete_supplier_payments BEFORE DELETE ON public.supplier_payments FOR EACH ROW EXECUTE FUNCTION app.block_delete();
CREATE TRIGGER trg_no_update_supplier_payments BEFORE UPDATE ON public.supplier_payments FOR EACH ROW EXECUTE FUNCTION app.block_update();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.tax_groups FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
CREATE TRIGGER trg_basic_limits BEFORE INSERT OR UPDATE OF is_active, deleted_at ON public.users FOR EACH ROW EXECUTE FUNCTION app.basic_limits();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
ALTER TABLE public.agent_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_actions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.agent_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_messages FORCE ROW LEVEL SECURITY;
ALTER TABLE public.agent_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.agent_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_settings FORCE ROW LEVEL SECURITY;
ALTER TABLE public.agent_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_usage FORCE ROW LEVEL SECURITY;
ALTER TABLE public.api_calls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approval_failures ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs FORCE ROW LEVEL SECURITY;
ALTER TABLE public.batch_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bill_series ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branch_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branch_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branch_settings FORCE ROW LEVEL SECURITY;
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branches FORCE ROW LEVEL SECURITY;
ALTER TABLE public.brands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_movements FORCE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories FORCE ROW LEVEL SECURITY;
ALTER TABLE public.countries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.currencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers FORCE ROW LEVEL SECURITY;
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.devices FORCE ROW LEVEL SECURITY;
ALTER TABLE public.dining_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dining_tables FORCE ROW LEVEL SECURITY;
ALTER TABLE public.floors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.floors FORCE ROW LEVEL SECURITY;
ALTER TABLE public.gift_card_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gift_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipt_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kitchen_ticket_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kitchen_ticket_items FORCE ROW LEVEL SECURITY;
ALTER TABLE public.kitchen_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kitchen_tickets FORCE ROW LEVEL SECURITY;
ALTER TABLE public.liquor_series ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.loyalty_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.loyalty_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meal_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.modifier_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.modifier_groups FORCE ROW LEVEL SECURITY;
ALTER TABLE public.modifier_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.modifier_items FORCE ROW LEVEL SECURITY;
ALTER TABLE public.modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offline_series ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.online_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.online_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_discounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_discounts FORCE ROW LEVEL SECURITY;
ALTER TABLE public.order_item_modifiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_item_modifiers FORCE ROW LEVEL SECURITY;
ALTER TABLE public.order_item_taxes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_item_taxes FORCE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items FORCE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders FORCE ROW LEVEL SECURITY;
ALTER TABLE public.owner_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_methods FORCE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments FORCE ROW LEVEL SECURITY;
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pin_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pin_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pre_order_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pre_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.price_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.printers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.printers FORCE ROW LEVEL SECURITY;
ALTER TABLE public.product_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_modifier_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_modifier_groups FORCE ROW LEVEL SECURITY;
ALTER TABLE public.product_price_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products FORCE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qr_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recipe_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.refunds FORCE ROW LEVEL SECURITY;
ALTER TABLE public.report_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.report_send_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.request_refs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurants FORCE ROW LEVEL SECURITY;
ALTER TABLE public.riders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.shift_closings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shifts FORCE ROW LEVEL SECURITY;
ALTER TABLE public.sna_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sna_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sna_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sna_sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sna_staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_log FORCE ROW LEVEL SECURITY;
ALTER TABLE public.tax_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_groups FORCE ROW LEVEL SECURITY;
ALTER TABLE public.tax_rate_components ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_rate_components FORCE ROW LEVEL SECURITY;
ALTER TABLE public.tax_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_rates FORCE ROW LEVEL SECURITY;
ALTER TABLE public.time_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_branches FORCE ROW LEVEL SECURITY;
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users FORCE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------
CREATE POLICY agent_read ON public.agent_actions AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY agent_write_own_action ON public.agent_actions AS PERMISSIVE FOR INSERT TO sna_pos_agent
  WITH CHECK (((restaurant_id = app.current_restaurant_id()) AND (status = 'proposed'::text) AND (reviewed_by IS NULL)));
CREATE POLICY tenant_read ON public.agent_actions AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.agent_messages AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY agent_write_own_message ON public.agent_messages AS PERMISSIVE FOR INSERT TO sna_pos_agent
  WITH CHECK ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_isolation ON public.agent_messages AS PERMISSIVE FOR ALL TO authenticated
  USING ((restaurant_id = app.current_restaurant_id()))
  WITH CHECK ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY agent_read ON public.agent_sessions AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY agent_write_own_session ON public.agent_sessions AS PERMISSIVE FOR INSERT TO sna_pos_agent
  WITH CHECK ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_isolation ON public.agent_sessions AS PERMISSIVE FOR ALL TO authenticated
  USING ((restaurant_id = app.current_restaurant_id()))
  WITH CHECK ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY agent_read ON public.agent_settings AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.agent_settings AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('agent.configure'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.agent_settings AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('agent.configure'::text) AS has_permission)));
CREATE POLICY perm_update ON public.agent_settings AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('agent.configure'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('agent.configure'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.agent_settings AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.agent_usage AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.agent_usage AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.api_keys AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND app.has_permission('settings.manage'::text)));
CREATE POLICY agent_read ON public.audit_logs AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.audit_logs AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.branch_prices AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.branch_settings AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.branch_settings AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.branch_settings AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.branch_settings AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.branch_settings AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY agent_read ON public.branches AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.branches AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.branches AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.branches AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.brands AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.business_days AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY agent_read ON public.cash_movements AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.cash_movements AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.categories AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.categories AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.categories AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.categories AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.categories AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read_reference ON public.countries AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING (true);
CREATE POLICY read_reference ON public.countries AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);
CREATE POLICY tenant_read ON public.credit_notes AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY agent_read_reference ON public.currencies AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING (true);
CREATE POLICY read_reference ON public.currencies AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);
CREATE POLICY agent_read ON public.customers AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.customers AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('customer.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.customers AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('customer.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.customers AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('customer.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('customer.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.customers AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.devices AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.devices AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY agent_read ON public.dining_tables AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.dining_tables AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.dining_tables AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.dining_tables AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.dining_tables AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY agent_read ON public.floors AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.floors AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.floors AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.floors AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.floors AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.gift_card_ledger AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.gift_cards AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.goods_receipt_lines AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('stock.manage'::text) AS has_permission) AND (EXISTS ( SELECT 1
   FROM goods_receipts h
  WHERE (h.id = goods_receipt_lines.goods_receipt_id)))));
CREATE POLICY tenant_read ON public.goods_receipts AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('stock.manage'::text) AS has_permission) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.ingredients AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.kitchen_ticket_items AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.kitchen_ticket_items AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.kitchen_tickets AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.kitchen_tickets AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.liquor_series AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.loyalty_ledger AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.loyalty_settings AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.meal_sessions AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.modifier_groups AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.modifier_groups AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.modifier_groups AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.modifier_groups AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.modifier_groups AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.modifier_items AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.modifier_items AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.modifier_items AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.modifier_items AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.modifier_items AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY all_read ON public.modules AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);
CREATE POLICY tenant_read ON public.online_orders AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.order_discounts AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.order_discounts AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.order_item_modifiers AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.order_item_modifiers AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.order_item_taxes AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.order_item_taxes AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.order_items AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.order_items AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.orders AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.orders AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.owner_alerts AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND app.has_permission('report.view_sales'::text)));
CREATE POLICY agent_read ON public.payment_methods AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.payment_methods AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.payment_methods AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.payment_methods AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.payment_methods AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.payments AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.payments AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read_reference ON public.permissions AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING (true);
CREATE POLICY read_reference ON public.permissions AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);
CREATE POLICY all_read ON public.plan_prices AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);
CREATE POLICY tenant_read ON public.plan_requests AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.printers AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.printers AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.printers AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.printers AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id)) AND ( SELECT app.has_permission('settings.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.printers AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY agent_read ON public.product_modifier_groups AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.product_modifier_groups AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.product_modifier_groups AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.product_modifier_groups AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.product_modifier_groups AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.products AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.products AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.products AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.products AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('menu.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.products AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.purchase_order_lines AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('stock.manage'::text) AS has_permission) AND (EXISTS ( SELECT 1
   FROM purchase_orders h
  WHERE (h.id = purchase_order_lines.purchase_order_id)))));
CREATE POLICY tenant_read ON public.purchase_orders AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('stock.manage'::text) AS has_permission) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY own_read ON public.push_subscriptions AS PERMISSIVE FOR SELECT TO authenticated
  USING ((user_id = ( SELECT app.current_user_id() AS current_user_id)));
CREATE POLICY tenant_read ON public.qr_orders AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.recipe_lines AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.refunds AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.refunds AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.reservations AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.restaurant_modules AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.restaurants AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.restaurants AS PERMISSIVE FOR SELECT TO authenticated
  USING ((id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.riders AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.role_permissions AS PERMISSIVE FOR SELECT TO authenticated
  USING ((EXISTS ( SELECT 1
   FROM roles r
  WHERE ((r.id = role_permissions.role_id) AND (r.restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id))))));
CREATE POLICY agent_read ON public.roles AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.roles AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.shifts AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.shifts AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.stock_movements AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.supplier_payments AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('stock.manage'::text) AS has_permission) AND (branch_id = ( SELECT app.current_branch_id() AS current_branch_id))));
CREATE POLICY tenant_read ON public.suppliers AS PERMISSIVE FOR SELECT TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('stock.manage'::text) AS has_permission)));
CREATE POLICY agent_read ON public.sync_log AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_isolation ON public.sync_log AS PERMISSIVE FOR ALL TO authenticated
  USING ((restaurant_id = app.current_restaurant_id()))
  WITH CHECK ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY agent_read ON public.tax_groups AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.tax_groups AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.tax_groups AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.tax_groups AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.tax_groups AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.tax_rate_components AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.tax_rate_components AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.tax_rate_components AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.tax_rate_components AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.tax_rate_components AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.tax_rates AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY perm_delete ON public.tax_rates AS PERMISSIVE FOR DELETE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)));
CREATE POLICY perm_insert ON public.tax_rates AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)));
CREATE POLICY perm_update ON public.tax_rates AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)))
  WITH CHECK (((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)) AND ( SELECT app.has_permission('tax.manage'::text) AS has_permission)));
CREATE POLICY tenant_read ON public.tax_rates AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY tenant_read ON public.time_entries AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.user_branches AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.user_branches AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));
CREATE POLICY agent_read ON public.users AS PERMISSIVE FOR SELECT TO sna_pos_agent
  USING ((restaurant_id = app.current_restaurant_id()));
CREATE POLICY tenant_read ON public.users AS PERMISSIVE FOR SELECT TO authenticated
  USING ((restaurant_id = ( SELECT app.current_restaurant_id() AS current_restaurant_id)));

-- ---------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_current_user AS
 SELECT u.id AS user_id,
    u.restaurant_id,
    u.full_name,
    u.email,
    u.employee_code,
    r.id AS role_id,
    r.name AS role_name,
    res.trading_name,
    res.country_code,
    res.currency_code,
    res.timezone,
    ( SELECT COALESCE(array_agg(rp.permission_key ORDER BY rp.permission_key), '{}'::text[]) AS "coalesce"
           FROM role_permissions rp
          WHERE rp.role_id = r.id) AS permissions,
    u.must_change_password,
    ( SELECT d.name
           FROM devices d
          WHERE d.id = app.device_id()) AS device_name,
    res.edition,
    ( SELECT COALESCE(array_agg(m.key ORDER BY m.key), '{}'::text[]) AS "coalesce"
           FROM modules m
          WHERE app.feature_on(res.id, m.key)) AS features,
    app.sna_staff_id() IS NOT NULL AS is_sna_staff,
    app.current_branch_id() AS branch_id,
    ( SELECT b.name
           FROM branches b
          WHERE b.id = app.current_branch_id()) AS branch_name,
    ( SELECT count(*)::integer AS count
           FROM branches b
          WHERE b.restaurant_id = res.id AND b.deleted_at IS NULL) AS outlet_count,
    res.second_language
   FROM users u
     JOIN roles r ON r.id = u.role_id
     JOIN restaurants res ON res.id = u.restaurant_id
  WHERE u.id = app.current_user_id();

CREATE OR REPLACE VIEW public.v_menu with (security_invoker = true) as
 SELECT p.id,
    p.restaurant_id,
    p.category_id,
    p.tax_group_id,
    p.name,
    p.short_name,
    app.menu_price(p.id, COALESCE(bp.price, p.price))::numeric(14,2) AS price,
    p.is_veg,
    p.is_available AND COALESCE(bp.is_available, true) AS is_available,
    p.display_order,
    c.name AS category_name,
    c.display_order AS category_order,
    tg.name AS tax_group_name,
    tg.is_price_inclusive,
    ( SELECT tr.total_rate
           FROM tax_rates tr
          WHERE tr.tax_group_id = p.tax_group_id AND tr.valid_from <= CURRENT_DATE AND (tr.valid_to IS NULL OR tr.valid_to >= CURRENT_DATE)
          ORDER BY tr.valid_from DESC
         LIMIT 1) AS tax_rate,
    p.price AS menu_price,
    p.name_local,
    p.parent_id,
    p.variant_name,
    p.is_combo,
    COALESCE(bp.price, p.price)::numeric(14,2) AS list_price
   FROM products p
     JOIN categories c ON c.id = p.category_id
     JOIN tax_groups tg ON tg.id = p.tax_group_id
     LEFT JOIN branch_prices bp ON bp.product_id = p.id AND bp.branch_id = (( SELECT app.current_branch_id() AS current_branch_id))
  WHERE p.deleted_at IS NULL AND c.deleted_at IS NULL;

-- ---------------------------------------------------------------------
-- Grants: schemas
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA app TO authenticated;
GRANT USAGE ON SCHEMA app TO sna_pos_agent;
GRANT USAGE ON SCHEMA public TO PUBLIC;
GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;
GRANT USAGE ON SCHEMA public TO sna_pos_agent;

-- ---------------------------------------------------------------------
-- Grants: tables and views
-- ---------------------------------------------------------------------
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.agent_actions TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.agent_actions TO service_role;
GRANT INSERT, SELECT ON TABLE public.agent_actions TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.agent_messages TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.agent_messages TO service_role;
GRANT INSERT, SELECT ON TABLE public.agent_messages TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.agent_sessions TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.agent_sessions TO service_role;
GRANT INSERT, SELECT ON TABLE public.agent_sessions TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.agent_settings TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.agent_settings TO service_role;
GRANT SELECT ON TABLE public.agent_settings TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.agent_usage TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.agent_usage TO service_role;
GRANT SELECT ON TABLE public.agent_usage TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.api_calls TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.api_keys TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.api_keys TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.approval_failures TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.approvals TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.audit_logs TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.audit_logs TO service_role;
GRANT SELECT ON TABLE public.audit_logs TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.batch_movements TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.bill_series TO service_role;
GRANT SELECT ON TABLE public.branch_prices TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.branch_prices TO service_role;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.branch_settings TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.branch_settings TO service_role;
GRANT SELECT ON TABLE public.branch_settings TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.branches TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.branches TO service_role;
GRANT SELECT ON TABLE public.branches TO sna_pos_agent;
GRANT SELECT ON TABLE public.brands TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.brands TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.business_days TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.business_days TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.cash_movements TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.cash_movements TO service_role;
GRANT SELECT ON TABLE public.cash_movements TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.categories TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.categories TO service_role;
GRANT SELECT ON TABLE public.categories TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.countries TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.countries TO service_role;
GRANT SELECT ON TABLE public.countries TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.credit_notes TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.credit_notes TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.currencies TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.currencies TO service_role;
GRANT SELECT ON TABLE public.currencies TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.customer_ledger TO service_role;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.customers TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.customers TO service_role;
GRANT SELECT ON TABLE public.customers TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.devices TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.devices TO service_role;
GRANT SELECT ON TABLE public.devices TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.dining_tables TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.dining_tables TO service_role;
GRANT SELECT ON TABLE public.dining_tables TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.floors TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.floors TO service_role;
GRANT SELECT ON TABLE public.floors TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.gift_card_ledger TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.gift_card_ledger TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.gift_cards TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.gift_cards TO service_role;
GRANT SELECT ON TABLE public.goods_receipt_lines TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.goods_receipt_lines TO service_role;
GRANT SELECT ON TABLE public.goods_receipts TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.goods_receipts TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.ingredients TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.ingredients TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.kitchen_ticket_items TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.kitchen_ticket_items TO service_role;
GRANT SELECT ON TABLE public.kitchen_ticket_items TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.kitchen_tickets TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.kitchen_tickets TO service_role;
GRANT SELECT ON TABLE public.kitchen_tickets TO sna_pos_agent;
GRANT SELECT ON TABLE public.liquor_series TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.liquor_series TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.loyalty_ledger TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.loyalty_ledger TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.loyalty_settings TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.loyalty_settings TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.meal_sessions TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.meal_sessions TO service_role;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.modifier_groups TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.modifier_groups TO service_role;
GRANT SELECT ON TABLE public.modifier_groups TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.modifier_items TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.modifier_items TO service_role;
GRANT SELECT ON TABLE public.modifier_items TO sna_pos_agent;
GRANT SELECT ON TABLE public.modules TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.modules TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.offline_series TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.online_channels TO service_role;
GRANT SELECT ON TABLE public.online_orders TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.online_orders TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.order_discounts TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.order_discounts TO service_role;
GRANT SELECT ON TABLE public.order_discounts TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.order_item_modifiers TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.order_item_modifiers TO service_role;
GRANT SELECT ON TABLE public.order_item_modifiers TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.order_item_taxes TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.order_item_taxes TO service_role;
GRANT SELECT ON TABLE public.order_item_taxes TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.order_items TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.order_items TO service_role;
GRANT SELECT ON TABLE public.order_items TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.orders TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.orders TO service_role;
GRANT SELECT ON TABLE public.orders TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.owner_alerts TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.owner_alerts TO service_role;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.payment_methods TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.payment_methods TO service_role;
GRANT SELECT ON TABLE public.payment_methods TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.payments TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.payments TO service_role;
GRANT SELECT ON TABLE public.payments TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.permissions TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.permissions TO service_role;
GRANT SELECT ON TABLE public.permissions TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.pin_attempts TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.pin_sessions TO service_role;
GRANT SELECT ON TABLE public.plan_prices TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.plan_prices TO service_role;
GRANT SELECT ON TABLE public.plan_requests TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.plan_requests TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.pre_order_payments TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.pre_orders TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.price_rules TO service_role;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.printers TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.printers TO service_role;
GRANT SELECT ON TABLE public.printers TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.product_batches TO service_role;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.product_modifier_groups TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.product_modifier_groups TO service_role;
GRANT SELECT ON TABLE public.product_modifier_groups TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.product_price_history TO service_role;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.products TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.products TO service_role;
GRANT SELECT ON TABLE public.products TO sna_pos_agent;
GRANT SELECT ON TABLE public.purchase_order_lines TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.purchase_order_lines TO service_role;
GRANT SELECT ON TABLE public.purchase_orders TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.purchase_orders TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.push_subscriptions TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.push_subscriptions TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.qr_orders TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.qr_orders TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.recipe_lines TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.recipe_lines TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.refunds TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.refunds TO service_role;
GRANT SELECT ON TABLE public.refunds TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.report_schedules TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.report_send_days TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.request_refs TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.reservations TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.reservations TO service_role;
GRANT SELECT ON TABLE public.restaurant_modules TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.restaurant_modules TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.restaurants TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.restaurants TO service_role;
GRANT SELECT ON TABLE public.restaurants TO sna_pos_agent;
GRANT SELECT ON TABLE public.riders TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.riders TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.role_permissions TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.role_permissions TO service_role;
GRANT SELECT ON TABLE public.role_permissions TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.roles TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.roles TO service_role;
GRANT SELECT ON TABLE public.roles TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.shift_closings TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.shifts TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.shifts TO service_role;
GRANT SELECT ON TABLE public.shifts TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.sna_accounts TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.sna_contacts TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.sna_notes TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.sna_sales TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.sna_staff TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.staff_invites TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.stock_movements TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.stock_movements TO service_role;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.subscription_events TO service_role;
GRANT SELECT ON TABLE public.supplier_payments TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.supplier_payments TO service_role;
GRANT SELECT ON TABLE public.suppliers TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.suppliers TO service_role;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.sync_log TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.sync_log TO service_role;
GRANT SELECT ON TABLE public.sync_log TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.tax_groups TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.tax_groups TO service_role;
GRANT SELECT ON TABLE public.tax_groups TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.tax_rate_components TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.tax_rate_components TO service_role;
GRANT SELECT ON TABLE public.tax_rate_components TO sna_pos_agent;
GRANT DELETE, INSERT, MAINTAIN, SELECT, UPDATE ON TABLE public.tax_rates TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.tax_rates TO service_role;
GRANT SELECT ON TABLE public.tax_rates TO sna_pos_agent;
GRANT MAINTAIN, SELECT ON TABLE public.time_entries TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.time_entries TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.user_branches TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.user_branches TO service_role;
GRANT SELECT ON TABLE public.user_branches TO sna_pos_agent;
GRANT MAINTAIN ON TABLE public.users TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.users TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.v_current_user TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.v_current_user TO service_role;
GRANT MAINTAIN, SELECT ON TABLE public.v_menu TO authenticated;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE public.v_menu TO service_role;

-- ---------------------------------------------------------------------
-- Grants: columns
-- ---------------------------------------------------------------------
GRANT SELECT (auth_user_id) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (auth_user_id) ON TABLE public.users TO authenticated;
GRANT SELECT (created_at) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (created_at) ON TABLE public.users TO authenticated;
GRANT SELECT (deleted_at) ON TABLE public.users TO authenticated;
GRANT SELECT (deleted_at) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (email) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (email) ON TABLE public.users TO authenticated;
GRANT SELECT (employee_code) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (employee_code) ON TABLE public.users TO authenticated;
GRANT SELECT (full_name) ON TABLE public.users TO authenticated;
GRANT SELECT (full_name) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (id) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (id) ON TABLE public.users TO authenticated;
GRANT SELECT (is_active) ON TABLE public.users TO authenticated;
GRANT SELECT (is_active) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (last_login_at) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (last_login_at) ON TABLE public.users TO authenticated;
GRANT SELECT (must_change_password) ON TABLE public.users TO authenticated;
GRANT SELECT (must_change_password) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (phone) ON TABLE public.users TO authenticated;
GRANT SELECT (phone) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (pin_set_at) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (pin_set_at) ON TABLE public.users TO authenticated;
GRANT SELECT (restaurant_id) ON TABLE public.users TO authenticated;
GRANT SELECT (restaurant_id) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (role_id) ON TABLE public.users TO authenticated;
GRANT SELECT (role_id) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (updated_at) ON TABLE public.users TO sna_pos_agent;
GRANT SELECT (updated_at) ON TABLE public.users TO authenticated;

-- ---------------------------------------------------------------------
-- Grants: sequences
-- ---------------------------------------------------------------------
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.api_calls_id_seq TO anon;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.api_calls_id_seq TO authenticated;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.api_calls_id_seq TO service_role;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.approval_failures_id_seq TO anon;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.approval_failures_id_seq TO authenticated;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.approval_failures_id_seq TO service_role;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.audit_logs_id_seq TO anon;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.audit_logs_id_seq TO authenticated;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.audit_logs_id_seq TO service_role;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.pin_attempts_id_seq TO anon;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.pin_attempts_id_seq TO authenticated;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.pin_attempts_id_seq TO service_role;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.product_price_history_id_seq TO anon;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.product_price_history_id_seq TO authenticated;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.product_price_history_id_seq TO service_role;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.restaurant_client_code_seq TO anon;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.restaurant_client_code_seq TO authenticated;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.restaurant_client_code_seq TO service_role;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.sync_log_id_seq TO anon;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.sync_log_id_seq TO authenticated;
GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.sync_log_id_seq TO service_role;

-- ---------------------------------------------------------------------
-- Grants: functions (PUBLIC execute is removed first, then re-granted where live has it)
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION accept_qr_order(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accept_qr_order(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION accept_qr_order(uuid) TO service_role;
REVOKE ALL ON FUNCTION account_charge(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION account_charge(uuid,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION account_charge(uuid,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION account_date() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION account_date() TO authenticated;
GRANT EXECUTE ON FUNCTION account_date() TO service_role;
REVOKE ALL ON FUNCTION account_save(uuid,text,text,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION account_save(uuid,text,text,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION account_save(uuid,text,text,numeric,text) TO service_role;
REVOKE ALL ON FUNCTION account_settle(uuid,uuid,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION account_settle(uuid,uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION account_settle(uuid,uuid,numeric,text) TO service_role;
REVOKE ALL ON FUNCTION account_statement(uuid,date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION account_statement(uuid,date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION account_statement(uuid,date,date) TO service_role;
REVOKE ALL ON FUNCTION accounting_journal(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accounting_journal(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION accounting_journal(date,date) TO service_role;
REVOKE ALL ON FUNCTION accounts_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accounts_list() TO authenticated;
GRANT EXECUTE ON FUNCTION accounts_list() TO service_role;
REVOKE ALL ON FUNCTION add_order_items(uuid,jsonb,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION add_order_items(uuid,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION add_order_items(uuid,jsonb,uuid) TO service_role;
REVOKE ALL ON FUNCTION adjust_order(uuid,numeric,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION adjust_order(uuid,numeric,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION adjust_order(uuid,numeric,text,boolean) TO service_role;
REVOKE ALL ON FUNCTION admin_reset_password(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_reset_password(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_reset_password(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION api_v1(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api_v1(text,text,jsonb) TO anon;
GRANT EXECUTE ON FUNCTION api_v1(text,text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1(text,text,jsonb) TO service_role;
REVOKE ALL ON FUNCTION app.account_balance(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.account_method(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.advance_method(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.api_menu_items(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.audit(text,text,uuid,jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.auto_shift(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.basic_limits() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.batch_on_item() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.business_today(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.business_type_defaults(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.calc_bill(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.calc_bill(jsonb) TO authenticated;
REVOKE ALL ON FUNCTION app.can_use_branch(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.can_use_branch(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION app.can_use_branch(uuid) TO authenticated;
REVOKE ALL ON FUNCTION app.channel_method(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.clean_bill_format(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.clean_phone(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.close_auto_shifts(uuid,numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.country_preset(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.create_kitchen_ticket(uuid,uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.create_restaurant_with_owner(text,text,character,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.create_restaurant_with_owner(text,text,character,text,text,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION app.current_bill_series(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.current_branch_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_branch_id() TO authenticated;
REVOKE ALL ON FUNCTION app.current_restaurant_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_restaurant_id() TO authenticated;
GRANT EXECUTE ON FUNCTION app.current_restaurant_id() TO sna_pos_agent;
REVOKE ALL ON FUNCTION app.current_user_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_user_id() TO authenticated;
REVOKE ALL ON FUNCTION app.default_bill_prefix(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.device_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.device_id() TO authenticated;
REVOKE ALL ON FUNCTION app.effective_rate(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.erase_groups() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.erase_tables(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.feature_on(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.feature_on(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION app.freeze_shift_figures() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.gift_balance(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.guard_product_change() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.has_permission(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.has_permission(text) TO authenticated;
GRANT EXECUTE ON FUNCTION app.has_permission(text) TO sna_pos_agent;
REVOKE ALL ON FUNCTION app.in_scope(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.in_scope(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION app.in_scope(uuid) TO authenticated;
REVOKE ALL ON FUNCTION app.insert_order_lines(uuid,uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.is_owner() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.is_owner() TO authenticated;
REVOKE ALL ON FUNCTION app.item_recipe(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.items_are_liquor(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.kiosk_auto_accept(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.licence_locked(uuid,timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.licence_state(uuid,timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.local_today(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.local_day_start(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.log_plan(uuid,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.monthly_charge(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.new_invite_code() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.new_token(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.next_bill_number(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.next_liquor_number(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.offline_liquor_code(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.open_business_day(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.order_covered(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.pay_goods_receipt(uuid,numeric,text,text,date,boolean,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.pin_hash(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.points_balance(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.pre_order_held(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.purchase_lines(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.qr_table(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.recalc_order(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.report_branch() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.report_branch() TO PUBLIC;
GRANT EXECUTE ON FUNCTION app.report_branch() TO authenticated;
REVOKE ALL ON FUNCTION app.report_count(text,date,integer,integer,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.report_day_back(uuid,time without time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.report_summary(uuid,date) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.report_target(uuid,time without time zone,timestamp without time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.require_feature(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.require_permission(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.require_permission(text) TO authenticated;
REVOKE ALL ON FUNCTION app.return_on_void() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.round_cash(numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.round_cash(numeric,text) TO authenticated;
REVOKE ALL ON FUNCTION app.rule_price(uuid,uuid,uuid,numeric,timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.run_report_schedules() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.seed_sessions(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.send_report(uuid,boolean,timestamp without time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.session_at(uuid,timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.set_business_type(uuid,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.shift_figures(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.sna_account_row(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.sna_require(text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.sna_staff_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.sna_staff_id() TO authenticated;
REVOKE ALL ON FUNCTION app.sna_today() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.stock_on_item_option() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.system_method(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.test_money() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_category_parent() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_licence_order_items() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_licence_orders() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_licence_qr_orders() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_modifier_item_dish() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_order_item_needs_size() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_order_item_unit() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_product_combo_flag() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_product_variant_follow() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_product_variant() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.trg_variant_options() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.try_auto_close_day(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.write_tax_components(uuid,uuid,numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.write_tax_group(uuid,uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.z_report(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION approve_with_pin(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION approve_with_pin(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION approve_with_pin(text,text) TO service_role;
REVOKE ALL ON FUNCTION attach_customer(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION attach_customer(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION attach_customer(uuid,text,text) TO service_role;
REVOKE ALL ON FUNCTION batch_add(uuid,numeric,date,date,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION batch_add(uuid,numeric,date,date,text) TO authenticated;
GRANT EXECUTE ON FUNCTION batch_add(uuid,numeric,date,date,text) TO service_role;
REVOKE ALL ON FUNCTION batch_stock() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION batch_stock() TO authenticated;
GRANT EXECUTE ON FUNCTION batch_stock() TO service_role;
REVOKE ALL ON FUNCTION batch_write_off(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION batch_write_off(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION batch_write_off(uuid) TO service_role;
REVOKE ALL ON FUNCTION batches_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION batches_list() TO authenticated;
GRANT EXECUTE ON FUNCTION batches_list() TO service_role;
REVOKE ALL ON FUNCTION bill_prefix_info() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION bill_prefix_info() TO authenticated;
GRANT EXECUTE ON FUNCTION bill_prefix_info() TO service_role;
REVOKE ALL ON FUNCTION brand_save(uuid,text,numeric,text,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brand_save(uuid,text,numeric,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION brand_save(uuid,text,numeric,text,text,boolean) TO service_role;
REVOKE ALL ON FUNCTION brand_settlement(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION brand_settlement(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION brand_settlement(date,date) TO service_role;
REVOKE ALL ON FUNCTION cancel_goods_receipt(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cancel_goods_receipt(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_goods_receipt(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION cancel_invite(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cancel_invite(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_invite(uuid) TO service_role;
REVOKE ALL ON FUNCTION cancel_order_item(uuid,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cancel_order_item(uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_order_item(uuid,numeric,text) TO service_role;
REVOKE ALL ON FUNCTION cancel_plan_request(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cancel_plan_request(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_plan_request(uuid) TO service_role;
REVOKE ALL ON FUNCTION category_set_brand(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION category_set_brand(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION category_set_brand(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION chain_report(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION chain_report(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION chain_report(date,date) TO service_role;
REVOKE ALL ON FUNCTION change_payment_method(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION change_payment_method(uuid,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION change_payment_method(uuid,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION claim_staff_invite(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION claim_staff_invite(text) TO authenticated;
GRANT EXECUTE ON FUNCTION claim_staff_invite(text) TO service_role;
REVOKE ALL ON FUNCTION claim_tickets_for_print(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION claim_tickets_for_print(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION claim_tickets_for_print(uuid[]) TO service_role;
REVOKE ALL ON FUNCTION clear_pin_lockout(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION clear_pin_lockout(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION clear_pin_lockout(uuid) TO service_role;
REVOKE ALL ON FUNCTION clear_staff_pin(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION clear_staff_pin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION clear_staff_pin(uuid) TO service_role;
REVOKE ALL ON FUNCTION clock_in() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION clock_in() TO authenticated;
GRANT EXECUTE ON FUNCTION clock_in() TO service_role;
REVOKE ALL ON FUNCTION clock_out() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION clock_out() TO authenticated;
GRANT EXECUTE ON FUNCTION clock_out() TO service_role;
REVOKE ALL ON FUNCTION close_day(text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION close_day(text,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION close_day(text,numeric) TO service_role;
REVOKE ALL ON FUNCTION close_shift(numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION close_shift(numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION close_shift(numeric,text) TO service_role;
REVOKE ALL ON FUNCTION create_api_key(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_api_key(text) TO authenticated;
GRANT EXECUTE ON FUNCTION create_api_key(text) TO service_role;
REVOKE ALL ON FUNCTION create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb,text,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb,text,uuid,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb,text,uuid,jsonb) TO service_role;
REVOKE ALL ON FUNCTION create_pin_staff(text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_pin_staff(text,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION create_pin_staff(text,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION create_restaurant_with_owner(text,text,character,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_restaurant_with_owner(text,text,character,text,text,text,text,text) TO service_role;
REVOKE ALL ON FUNCTION create_tax_group(text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_tax_group(text,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION create_tax_group(text,numeric) TO service_role;
REVOKE ALL ON FUNCTION current_shift() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION current_shift() TO authenticated;
GRANT EXECUTE ON FUNCTION current_shift() TO service_role;
REVOKE ALL ON FUNCTION day_report(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION day_report(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION day_report(uuid) TO service_role;
REVOKE ALL ON FUNCTION day_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION day_status() TO authenticated;
GRANT EXECUTE ON FUNCTION day_status() TO service_role;
REVOKE ALL ON FUNCTION delete_price_rule(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delete_price_rule(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION delete_price_rule(uuid) TO service_role;
REVOKE ALL ON FUNCTION delete_role(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delete_role(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION delete_role(uuid) TO service_role;
REVOKE ALL ON FUNCTION deliveries_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION deliveries_list() TO authenticated;
GRANT EXECUTE ON FUNCTION deliveries_list() TO service_role;
REVOKE ALL ON FUNCTION delivery_update(uuid,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delivery_update(uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION delivery_update(uuid,text,uuid) TO service_role;
REVOKE ALL ON FUNCTION fire_held_items(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fire_held_items(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fire_held_items(uuid) TO service_role;
REVOKE ALL ON FUNCTION fix_time_entry(uuid,timestamp with time zone,timestamp with time zone,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fix_time_entry(uuid,timestamp with time zone,timestamp with time zone,text) TO authenticated;
GRANT EXECUTE ON FUNCTION fix_time_entry(uuid,timestamp with time zone,timestamp with time zone,text) TO service_role;
REVOKE ALL ON FUNCTION gift_card_history(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gift_card_history(text) TO authenticated;
GRANT EXECUTE ON FUNCTION gift_card_history(text) TO service_role;
REVOKE ALL ON FUNCTION gift_card_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gift_card_lookup(text) TO authenticated;
GRANT EXECUTE ON FUNCTION gift_card_lookup(text) TO service_role;
REVOKE ALL ON FUNCTION gst_register(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gst_register(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION gst_register(date,date) TO service_role;
REVOKE ALL ON FUNCTION import_menu(jsonb,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION import_menu(jsonb,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION import_menu(jsonb,boolean) TO service_role;
REVOKE ALL ON FUNCTION invite_staff(text,text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION invite_staff(text,text,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION invite_staff(text,text,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION issue_credit_note(uuid,numeric,uuid,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION issue_credit_note(uuid,numeric,uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION issue_credit_note(uuid,numeric,uuid,text,uuid) TO service_role;
REVOKE ALL ON FUNCTION issue_gift_card(numeric,uuid,text,text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION issue_gift_card(numeric,uuid,text,text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION issue_gift_card(numeric,uuid,text,text,integer) TO service_role;
REVOKE ALL ON FUNCTION kiosk_add(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION kiosk_add(text) TO authenticated;
GRANT EXECUTE ON FUNCTION kiosk_add(text) TO service_role;
REVOKE ALL ON FUNCTION kiosk_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION kiosk_list() TO authenticated;
GRANT EXECUTE ON FUNCTION kiosk_list() TO service_role;
REVOKE ALL ON FUNCTION kiosk_remove(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION kiosk_remove(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION kiosk_remove(uuid) TO service_role;
REVOKE ALL ON FUNCTION kiosk_set_auto(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION kiosk_set_auto(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION kiosk_set_auto(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION liquor_prefix_info() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION liquor_prefix_info() TO authenticated;
GRANT EXECUTE ON FUNCTION liquor_prefix_info() TO service_role;
REVOKE ALL ON FUNCTION login_staff(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION login_staff(text,text,text) TO anon;
GRANT EXECUTE ON FUNCTION login_staff(text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION login_staff(text,text,text) TO service_role;
REVOKE ALL ON FUNCTION make_complimentary(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION make_complimentary(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION make_complimentary(uuid,text,text) TO service_role;
REVOKE ALL ON FUNCTION mark_tickets_printed(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mark_tickets_printed(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION mark_tickets_printed(uuid[]) TO service_role;
REVOKE ALL ON FUNCTION merge_orders(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION merge_orders(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION merge_orders(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION move_order_table(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION move_order_table(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION move_order_table(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION my_account_state() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION my_account_state() TO authenticated;
GRANT EXECUTE ON FUNCTION my_account_state() TO service_role;
REVOKE ALL ON FUNCTION my_device_state() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION my_device_state() TO authenticated;
GRANT EXECUTE ON FUNCTION my_device_state() TO service_role;
REVOKE ALL ON FUNCTION my_licence() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION my_licence() TO authenticated;
GRANT EXECUTE ON FUNCTION my_licence() TO service_role;
REVOKE ALL ON FUNCTION my_outlets() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION my_outlets() TO authenticated;
GRANT EXECUTE ON FUNCTION my_outlets() TO service_role;
REVOKE ALL ON FUNCTION my_plan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION my_plan() TO authenticated;
GRANT EXECUTE ON FUNCTION my_plan() TO service_role;
REVOKE ALL ON FUNCTION offline_snapshot(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION offline_snapshot(text) TO authenticated;
GRANT EXECUTE ON FUNCTION offline_snapshot(text) TO service_role;
REVOKE ALL ON FUNCTION online_channel_save(text,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION online_channel_save(text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION online_channel_save(text,text,boolean) TO service_role;
REVOKE ALL ON FUNCTION online_channels_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION online_channels_list() TO authenticated;
GRANT EXECUTE ON FUNCTION online_channels_list() TO service_role;
REVOKE ALL ON FUNCTION online_order_accept(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION online_order_accept(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION online_order_accept(uuid) TO service_role;
REVOKE ALL ON FUNCTION online_order_callback(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION online_order_callback(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION online_order_callback(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION online_order_mark_ready(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION online_order_mark_ready(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION online_order_mark_ready(uuid) TO service_role;
REVOKE ALL ON FUNCTION online_order_receive(text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION online_order_receive(text,jsonb) TO anon;
GRANT EXECUTE ON FUNCTION online_order_receive(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION online_order_receive(text,jsonb) TO service_role;
REVOKE ALL ON FUNCTION online_order_reject(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION online_order_reject(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION online_order_reject(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION online_orders_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION online_orders_list() TO authenticated;
GRANT EXECUTE ON FUNCTION online_orders_list() TO service_role;
REVOKE ALL ON FUNCTION open_shift(numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION open_shift(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION open_shift(numeric) TO service_role;
REVOKE ALL ON FUNCTION outlet_comparison(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION outlet_comparison(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION outlet_comparison(date,date) TO service_role;
REVOKE ALL ON FUNCTION outlet_set_region(uuid,text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION outlet_set_region(uuid,text,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION outlet_set_region(uuid,text,numeric) TO service_role;
REVOKE ALL ON FUNCTION password_changed() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION password_changed() TO authenticated;
GRANT EXECUTE ON FUNCTION password_changed() TO service_role;
REVOKE ALL ON FUNCTION pay_back_gift_card(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pay_back_gift_card(text) TO authenticated;
GRANT EXECUTE ON FUNCTION pay_back_gift_card(text) TO service_role;
REVOKE ALL ON FUNCTION pay_order(uuid,uuid,numeric,numeric,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pay_order(uuid,uuid,numeric,numeric,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pay_order(uuid,uuid,numeric,numeric,text,uuid) TO service_role;
REVOKE ALL ON FUNCTION pay_supplier(uuid,numeric,text,text,date,boolean,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pay_supplier(uuid,numeric,text,text,date,boolean,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pay_supplier(uuid,numeric,text,text,date,boolean,uuid) TO service_role;
REVOKE ALL ON FUNCTION pin_lock() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pin_lock() TO authenticated;
GRANT EXECUTE ON FUNCTION pin_lock() TO service_role;
REVOKE ALL ON FUNCTION pin_touch() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pin_touch() TO authenticated;
GRANT EXECUTE ON FUNCTION pin_touch() TO service_role;
REVOKE ALL ON FUNCTION pin_unlock(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pin_unlock(text) TO authenticated;
GRANT EXECUTE ON FUNCTION pin_unlock(text) TO service_role;
REVOKE ALL ON FUNCTION pre_order_advance(uuid,uuid,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pre_order_advance(uuid,uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION pre_order_advance(uuid,uuid,numeric,text) TO service_role;
REVOKE ALL ON FUNCTION pre_order_bill(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pre_order_bill(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pre_order_bill(uuid) TO service_role;
REVOKE ALL ON FUNCTION pre_order_cancel(uuid,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pre_order_cancel(uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pre_order_cancel(uuid,text,uuid) TO service_role;
REVOKE ALL ON FUNCTION pre_order_save(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pre_order_save(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION pre_order_save(jsonb) TO service_role;
REVOKE ALL ON FUNCTION pre_orders_list(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pre_orders_list(text) TO authenticated;
GRANT EXECUTE ON FUNCTION pre_orders_list(text) TO service_role;
REVOKE ALL ON FUNCTION price_rules_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION price_rules_list() TO authenticated;
GRANT EXECUTE ON FUNCTION price_rules_list() TO service_role;
REVOKE ALL ON FUNCTION public_receipt(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public_receipt(text) TO anon;
GRANT EXECUTE ON FUNCTION public_receipt(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public_receipt(text) TO service_role;
REVOKE ALL ON FUNCTION purchase_report(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION purchase_report(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION purchase_report(date,date) TO service_role;
REVOKE ALL ON FUNCTION push_gone(text,text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION push_gone(text,text[]) TO anon;
GRANT EXECUTE ON FUNCTION push_gone(text,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION push_gone(text,text[]) TO service_role;
REVOKE ALL ON FUNCTION qr_menu(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qr_menu(text) TO anon;
GRANT EXECUTE ON FUNCTION qr_menu(text) TO authenticated;
GRANT EXECUTE ON FUNCTION qr_menu(text) TO service_role;
REVOKE ALL ON FUNCTION qr_order_status(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qr_order_status(uuid,text) TO anon;
GRANT EXECUTE ON FUNCTION qr_order_status(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION qr_order_status(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION qr_place_order(text,jsonb,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qr_place_order(text,jsonb,text,text) TO anon;
GRANT EXECUTE ON FUNCTION qr_place_order(text,jsonb,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION qr_place_order(text,jsonb,text,text) TO service_role;
REVOKE ALL ON FUNCTION quote_order(jsonb,numeric,boolean,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION quote_order(jsonb,numeric,boolean,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION quote_order(jsonb,numeric,boolean,jsonb) TO service_role;
REVOKE ALL ON FUNCTION receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION receive_goods(uuid,jsonb,uuid,text,date,numeric,numeric,date,text,jsonb,uuid) TO service_role;
REVOKE ALL ON FUNCTION record_cash_movement(text,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION record_cash_movement(text,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION record_cash_movement(text,numeric,text) TO service_role;
REVOKE ALL ON FUNCTION record_stock(uuid,text,numeric,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION record_stock(uuid,text,numeric,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION record_stock(uuid,text,numeric,numeric,text) TO service_role;
REVOKE ALL ON FUNCTION redeem_gift_card(uuid,text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION redeem_gift_card(uuid,text,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION redeem_gift_card(uuid,text,numeric) TO service_role;
REVOKE ALL ON FUNCTION redeem_points(uuid,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION redeem_points(uuid,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION redeem_points(uuid,numeric) TO service_role;
REVOKE ALL ON FUNCTION refund_order(uuid,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION refund_order(uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION refund_order(uuid,numeric,text) TO service_role;
REVOKE ALL ON FUNCTION regenerate_invite(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION regenerate_invite(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION regenerate_invite(uuid) TO service_role;
REVOKE ALL ON FUNCTION region_set_price(text,uuid,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION region_set_price(text,uuid,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION region_set_price(text,uuid,numeric) TO service_role;
REVOKE ALL ON FUNCTION register_counter_device(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION register_counter_device(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION register_counter_device(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION reject_qr_order(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reject_qr_order(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION reject_qr_order(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION remove_counter_device(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION remove_counter_device(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION remove_counter_device(uuid) TO service_role;
REVOKE ALL ON FUNCTION remove_push_subscription(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION remove_push_subscription(text) TO authenticated;
GRANT EXECUTE ON FUNCTION remove_push_subscription(text) TO service_role;
REVOKE ALL ON FUNCTION remove_report_schedule(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION remove_report_schedule(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION remove_report_schedule(uuid) TO service_role;
REVOKE ALL ON FUNCTION reopen_day(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reopen_day(text) TO authenticated;
GRANT EXECUTE ON FUNCTION reopen_day(text) TO service_role;
REVOKE ALL ON FUNCTION report_schedules_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION report_schedules_list() TO authenticated;
GRANT EXECUTE ON FUNCTION report_schedules_list() TO service_role;
REVOKE ALL ON FUNCTION report_sent(text,uuid,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION report_sent(text,uuid,boolean,text) TO anon;
GRANT EXECUTE ON FUNCTION report_sent(text,uuid,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION report_sent(text,uuid,boolean,text) TO service_role;
REVOKE ALL ON FUNCTION request_plan_change(text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION request_plan_change(text,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION request_plan_change(text,text,text,text,text) TO service_role;
REVOKE ALL ON FUNCTION reset_table_qr(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reset_table_qr(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION reset_table_qr(uuid) TO service_role;
REVOKE ALL ON FUNCTION revoke_api_key(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION revoke_api_key(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION revoke_api_key(uuid) TO service_role;
REVOKE ALL ON FUNCTION rider_save(uuid,text,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rider_save(uuid,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION rider_save(uuid,text,text,boolean) TO service_role;
REVOKE ALL ON FUNCTION rider_settle(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rider_settle(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION rider_settle(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION sales_report(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sales_report(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION sales_report(date,date) TO service_role;
REVOKE ALL ON FUNCTION save_day_settings(boolean,time without time zone) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_day_settings(boolean,time without time zone) TO authenticated;
GRANT EXECUTE ON FUNCTION save_day_settings(boolean,time without time zone) TO service_role;
REVOKE ALL ON FUNCTION save_ingredient(uuid,text,text,numeric,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_ingredient(uuid,text,text,numeric,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION save_ingredient(uuid,text,text,numeric,numeric,text) TO service_role;
REVOKE ALL ON FUNCTION save_loyalty_settings(numeric,numeric,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_loyalty_settings(numeric,numeric,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION save_loyalty_settings(numeric,numeric,integer) TO service_role;
REVOKE ALL ON FUNCTION save_meal_sessions(uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_meal_sessions(uuid,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION save_meal_sessions(uuid,jsonb) TO service_role;
REVOKE ALL ON FUNCTION save_packing_charge(numeric,text,uuid,boolean,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_packing_charge(numeric,text,uuid,boolean,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION save_packing_charge(numeric,text,uuid,boolean,boolean) TO service_role;
REVOKE ALL ON FUNCTION save_payment_method(uuid,text,text,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_payment_method(uuid,text,text,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION save_payment_method(uuid,text,text,boolean,text) TO service_role;
REVOKE ALL ON FUNCTION save_price_rule(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_price_rule(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION save_price_rule(jsonb) TO service_role;
REVOKE ALL ON FUNCTION save_purchase_order(uuid,uuid,jsonb,date,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_purchase_order(uuid,uuid,jsonb,date,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION save_purchase_order(uuid,uuid,jsonb,date,text,boolean) TO service_role;
REVOKE ALL ON FUNCTION save_push_subscription(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_push_subscription(text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION save_push_subscription(text,text,text) TO service_role;
REVOKE ALL ON FUNCTION save_recipe(uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_recipe(uuid,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION save_recipe(uuid,jsonb) TO service_role;
REVOKE ALL ON FUNCTION save_report_schedule(uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_report_schedule(uuid,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION save_report_schedule(uuid,jsonb) TO service_role;
REVOKE ALL ON FUNCTION save_reservation(uuid,text,text,integer,timestamp with time zone,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_reservation(uuid,text,text,integer,timestamp with time zone,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION save_reservation(uuid,text,text,integer,timestamp with time zone,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION save_role(uuid,text,text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_role(uuid,text,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION save_role(uuid,text,text[]) TO service_role;
REVOKE ALL ON FUNCTION save_supplier(uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_supplier(uuid,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION save_supplier(uuid,jsonb) TO service_role;
REVOKE ALL ON FUNCTION save_tax_group(uuid,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_tax_group(uuid,text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION save_tax_group(uuid,text,jsonb) TO service_role;
REVOKE ALL ON FUNCTION send_report_now(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION send_report_now(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION send_report_now(uuid) TO service_role;
REVOKE ALL ON FUNCTION send_to_kitchen(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION send_to_kitchen(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION send_to_kitchen(uuid) TO service_role;
REVOKE ALL ON FUNCTION session_report(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION session_report(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION session_report(date,date) TO service_role;
REVOKE ALL ON FUNCTION set_bill_customer(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_bill_customer(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION set_bill_customer(uuid,text,text) TO service_role;
REVOKE ALL ON FUNCTION set_bill_prefix(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_bill_prefix(text) TO authenticated;
GRANT EXECUTE ON FUNCTION set_bill_prefix(text) TO service_role;
REVOKE ALL ON FUNCTION set_business_type(text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_business_type(text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION set_business_type(text,boolean) TO service_role;
REVOKE ALL ON FUNCTION set_central_kitchen(uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_central_kitchen(uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION set_central_kitchen(uuid,boolean) TO service_role;
REVOKE ALL ON FUNCTION set_current_outlet(uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_current_outlet(uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION set_current_outlet(uuid,boolean) TO service_role;
REVOKE ALL ON FUNCTION set_kitchen_status(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_kitchen_status(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION set_kitchen_status(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION set_liquor_prefix(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_liquor_prefix(text) TO authenticated;
GRANT EXECUTE ON FUNCTION set_liquor_prefix(text) TO service_role;
REVOKE ALL ON FUNCTION set_order_guest(uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_order_guest(uuid,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION set_order_guest(uuid,text,text,text) TO service_role;
REVOKE ALL ON FUNCTION set_order_types(text[],text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_order_types(text[],text) TO authenticated;
GRANT EXECUTE ON FUNCTION set_order_types(text[],text) TO service_role;
REVOKE ALL ON FUNCTION set_outlet_price(uuid,uuid,numeric,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_outlet_price(uuid,uuid,numeric,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION set_outlet_price(uuid,uuid,numeric,boolean) TO service_role;
REVOKE ALL ON FUNCTION set_prices_include_tax(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_prices_include_tax(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION set_prices_include_tax(boolean) TO service_role;
REVOKE ALL ON FUNCTION set_purchase_order_status(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_purchase_order_status(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION set_purchase_order_status(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION set_report_schedule_active(uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_report_schedule_active(uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION set_report_schedule_active(uuid,boolean) TO service_role;
REVOKE ALL ON FUNCTION set_reservation_status(uuid,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_reservation_status(uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION set_reservation_status(uuid,text,uuid) TO service_role;
REVOKE ALL ON FUNCTION set_company_timezone(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_company_timezone(text) TO authenticated;
GRANT EXECUTE ON FUNCTION set_company_timezone(text) TO service_role;
REVOKE ALL ON FUNCTION set_second_language(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_second_language(text) TO authenticated;
GRANT EXECUTE ON FUNCTION set_second_language(text) TO service_role;
REVOKE ALL ON FUNCTION set_staff_pin(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_staff_pin(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION set_staff_pin(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION set_tax_rate(uuid,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_tax_rate(uuid,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION set_tax_rate(uuid,numeric) TO service_role;
REVOKE ALL ON FUNCTION set_user_outlets(uuid,uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_user_outlets(uuid,uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION set_user_outlets(uuid,uuid[]) TO service_role;
REVOKE ALL ON FUNCTION settlement_report(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION settlement_report(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION settlement_report(date,date) TO service_role;
REVOKE ALL ON FUNCTION share_bill(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION share_bill(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION share_bill(uuid) TO service_role;
REVOKE ALL ON FUNCTION shift_report(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION shift_report(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION shift_report(uuid) TO service_role;
REVOKE ALL ON FUNCTION sna_add_note(uuid,text,text,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_add_note(uuid,text,text,date) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_add_note(uuid,text,text,date) TO service_role;
REVOKE ALL ON FUNCTION sna_add_request(uuid,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_add_request(uuid,text,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_add_request(uuid,text,text,text,text,text) TO service_role;
REVOKE ALL ON FUNCTION sna_add_sale(uuid,text,text,numeric,date,date,date,text,date,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_add_sale(uuid,text,text,numeric,date,date,date,text,date,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_add_sale(uuid,text,text,numeric,date,date,date,text,date,text,boolean) TO service_role;
REVOKE ALL ON FUNCTION sna_cancel_sale(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_cancel_sale(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_cancel_sale(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION sna_client(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_client(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_client(uuid) TO service_role;
REVOKE ALL ON FUNCTION sna_clients(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_clients(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_clients(text,text) TO service_role;
REVOKE ALL ON FUNCTION sna_create_client(text,text,text,text,text,text,text,text,text,text,date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_create_client(text,text,text,text,text,text,text,text,text,text,date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_create_client(text,text,text,text,text,text,text,text,text,text,date,date) TO service_role;
REVOKE ALL ON FUNCTION sna_create_outlet(uuid,text,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_create_outlet(uuid,text,text,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_create_outlet(uuid,text,text,text,text,text,text) TO service_role;
REVOKE ALL ON FUNCTION sna_decide_request(uuid,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_decide_request(uuid,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_decide_request(uuid,boolean,text) TO service_role;
REVOKE ALL ON FUNCTION sna_erase_preview(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_erase_preview(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_erase_preview(uuid) TO service_role;
REVOKE ALL ON FUNCTION sna_erase(uuid,boolean,boolean,boolean,boolean,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_erase(uuid,boolean,boolean,boolean,boolean,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_erase(uuid,boolean,boolean,boolean,boolean,text,text) TO service_role;
REVOKE ALL ON FUNCTION sna_licence(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_licence(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_licence(uuid) TO service_role;
REVOKE ALL ON FUNCTION sna_me() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_me() TO authenticated;
GRANT EXECUTE ON FUNCTION sna_me() TO service_role;
REVOKE ALL ON FUNCTION sna_record_sale(uuid,text,text,numeric,date,date,date,text,date,text,boolean,text[],boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_record_sale(uuid,text,text,numeric,date,date,date,text,date,text,boolean,text[],boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_record_sale(uuid,text,text,numeric,date,date,date,text,date,text,boolean,text[],boolean) TO service_role;
REVOKE ALL ON FUNCTION sna_remove_contact(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_remove_contact(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_remove_contact(uuid) TO service_role;
REVOKE ALL ON FUNCTION sna_requests(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_requests(text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_requests(text) TO service_role;
REVOKE ALL ON FUNCTION sna_restaurant(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_restaurant(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_restaurant(uuid) TO service_role;
REVOKE ALL ON FUNCTION sna_restaurants(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_restaurants(text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_restaurants(text) TO service_role;
REVOKE ALL ON FUNCTION sna_sales_list(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_sales_list(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_sales_list(uuid) TO service_role;
REVOKE ALL ON FUNCTION sna_save_account(uuid,text,date,date,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_save_account(uuid,text,date,date,uuid,uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_save_account(uuid,text,date,date,uuid,uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION sna_save_contact(uuid,uuid,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_save_contact(uuid,uuid,text,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_save_contact(uuid,uuid,text,text,text,text,text) TO service_role;
REVOKE ALL ON FUNCTION sna_save_staff(text,text,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_save_staff(text,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_save_staff(text,text,text,boolean) TO service_role;
REVOKE ALL ON FUNCTION sna_set_business_type(uuid,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_set_business_type(uuid,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_set_business_type(uuid,text,boolean) TO service_role;
REVOKE ALL ON FUNCTION sna_set_edition(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_set_edition(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_set_edition(uuid,text,text) TO service_role;
REVOKE ALL ON FUNCTION sna_set_follow_up(uuid,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_set_follow_up(uuid,date) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_set_follow_up(uuid,date) TO service_role;
REVOKE ALL ON FUNCTION sna_set_live(uuid,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_set_live(uuid,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_set_live(uuid,boolean,text) TO service_role;
REVOKE ALL ON FUNCTION sna_set_module(uuid,text,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_set_module(uuid,text,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_set_module(uuid,text,boolean,text) TO service_role;
REVOKE ALL ON FUNCTION sna_set_price(text,text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_set_price(text,text,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_set_price(text,text,numeric) TO service_role;
REVOKE ALL ON FUNCTION sna_set_reminder(uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_set_reminder(uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_set_reminder(uuid,boolean) TO service_role;
REVOKE ALL ON FUNCTION sna_set_sale_paid(uuid,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_set_sale_paid(uuid,date) TO authenticated;
GRANT EXECUTE ON FUNCTION sna_set_sale_paid(uuid,date) TO service_role;
REVOKE ALL ON FUNCTION sna_staff_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sna_staff_list() TO authenticated;
GRANT EXECUTE ON FUNCTION sna_staff_list() TO service_role;
REVOKE ALL ON FUNCTION split_order(uuid,jsonb,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION split_order(uuid,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION split_order(uuid,jsonb,uuid) TO service_role;
REVOKE ALL ON FUNCTION stock_report(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION stock_report(date,date) TO authenticated;
GRANT EXECUTE ON FUNCTION stock_report(date,date) TO service_role;
REVOKE ALL ON FUNCTION sync_offline_bill(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sync_offline_bill(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION sync_offline_bill(jsonb) TO service_role;
REVOKE ALL ON FUNCTION table_qr_codes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION table_qr_codes() TO authenticated;
GRANT EXECUTE ON FUNCTION table_qr_codes() TO service_role;
REVOKE ALL ON FUNCTION tax_group_set_liquor(uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tax_group_set_liquor(uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION tax_group_set_liquor(uuid,boolean) TO service_role;
REVOKE ALL ON FUNCTION top_up_gift_card(text,numeric,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION top_up_gift_card(text,numeric,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION top_up_gift_card(text,numeric,uuid) TO service_role;
REVOKE ALL ON FUNCTION transfer_stock(uuid,numeric,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION transfer_stock(uuid,numeric,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION transfer_stock(uuid,numeric,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION undo_supplier_payment(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION undo_supplier_payment(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION undo_supplier_payment(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION update_settings(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_settings(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION update_settings(jsonb) TO service_role;
REVOKE ALL ON FUNCTION update_staff(uuid,uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION update_staff(uuid,uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION update_staff(uuid,uuid,boolean) TO service_role;
REVOKE ALL ON FUNCTION void_order(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION void_order(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION void_order(uuid,text) TO service_role;
REVOKE ALL ON FUNCTION app.menu_price(uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.menu_price(uuid, numeric) TO authenticated;

-- ---------------------------------------------------------------------
-- For reference only: default privileges found live (Supabase sets these; not re-created here)
-- ---------------------------------------------------------------------
-- default ACL: owner=postgres schema=public type=S acl={postgres=rwU/postgres,anon=rwU/postgres,authenticated=rwU/postgres,service_role=rwU/postgres}
-- default ACL: owner=supabase_admin schema=public type=S acl={postgres=rwU/supabase_admin,anon=rwU/supabase_admin,authenticated=rwU/supabase_admin,service_role=rwU/supabase_admin}
-- default ACL: owner=supabase_admin schema=public type=r acl={postgres=arwdDxtm/supabase_admin,anon=arwdDxtm/supabase_admin,authenticated=arwdDxtm/supabase_admin,service_role=arwdDxtm/supabase_admin}
-- default ACL: owner=supabase_admin schema=public type=f acl={postgres=X/supabase_admin,anon=X/supabase_admin,authenticated=X/supabase_admin,service_role=X/supabase_admin}
-- default ACL: owner=postgres schema=storage type=r acl={postgres=arwdDxtm/postgres,anon=arwdDxtm/postgres,authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres}
-- default ACL: owner=postgres schema=storage type=f acl={postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- default ACL: owner=postgres schema=storage type=S acl={postgres=rwU/postgres,anon=rwU/postgres,authenticated=rwU/postgres,service_role=rwU/postgres}
-- default ACL: owner=supabase_auth_admin schema=auth type=r acl={postgres=arwdDxtm/supabase_auth_admin,dashboard_user=arwdDxtm/supabase_auth_admin}
-- default ACL: owner=supabase_auth_admin schema=auth type=S acl={postgres=rwU/supabase_auth_admin,dashboard_user=rwU/supabase_auth_admin}
-- default ACL: owner=supabase_auth_admin schema=auth type=f acl={postgres=X/supabase_auth_admin,dashboard_user=X/supabase_auth_admin}
-- default ACL: owner=supabase_admin schema=graphql_public type=S acl={postgres=rwU/supabase_admin,anon=rwU/supabase_admin,authenticated=rwU/supabase_admin,service_role=rwU/supabase_admin}
-- default ACL: owner=supabase_admin schema=graphql_public type=r acl={postgres=arwdDxtm/supabase_admin,anon=arwdDxtm/supabase_admin,authenticated=arwdDxtm/supabase_admin,service_role=arwdDxtm/supabase_admin}
-- default ACL: owner=supabase_admin schema=graphql_public type=f acl={postgres=X/supabase_admin,anon=X/supabase_admin,authenticated=X/supabase_admin,service_role=X/supabase_admin}
-- default ACL: owner=supabase_admin schema=extensions type=r acl={postgres=a*r*w*d*D*x*t*m*/supabase_admin}
-- default ACL: owner=supabase_admin schema=extensions type=f acl={postgres=X*/supabase_admin}
-- default ACL: owner=supabase_admin schema=extensions type=S acl={postgres=r*w*U*/supabase_admin}
-- default ACL: owner=supabase_admin schema=graphql type=r acl={postgres=arwdDxtm/supabase_admin,anon=arwdDxtm/supabase_admin,authenticated=arwdDxtm/supabase_admin,service_role=arwdDxtm/supabase_admin}
-- default ACL: owner=supabase_admin schema=graphql type=f acl={postgres=X/supabase_admin,anon=X/supabase_admin,authenticated=X/supabase_admin,service_role=X/supabase_admin}
-- default ACL: owner=supabase_admin schema=graphql type=S acl={postgres=rwU/supabase_admin,anon=rwU/supabase_admin,authenticated=rwU/supabase_admin,service_role=rwU/supabase_admin}
-- default ACL: owner=supabase_admin schema=realtime type=S acl={postgres=rwU/supabase_admin,dashboard_user=rwU/supabase_admin}
-- default ACL: owner=supabase_admin schema=realtime type=f acl={postgres=X/supabase_admin,dashboard_user=X/supabase_admin}
-- default ACL: owner=supabase_admin schema=realtime type=r acl={postgres=a*r*wdDxtm/supabase_admin,dashboard_user=arwdDxtm/supabase_admin}
-- default ACL: owner=postgres schema=public type=f acl={postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- default ACL: owner=postgres schema=public type=r acl={postgres=arwdDxtm/postgres,authenticated=arwdm/postgres,service_role=arwdDxtm/postgres}
-- default ACL: owner=supabase_admin schema=cron type=S acl={postgres=r*w*U*/supabase_admin}
-- default ACL: owner=supabase_admin schema=cron type=r acl={postgres=a*r*w*d*D*x*t*m*/supabase_admin}
-- default ACL: owner=supabase_admin schema=cron type=f acl={postgres=X*/supabase_admin}

-- ---------------------------------------------------------------------
-- For reference only: pg_cron jobs found live (not re-created here)
-- ---------------------------------------------------------------------
-- cron job sna-report-schedules: */5 * * * * | select app.run_report_schedules()
-- cron job sna-timer-history: 30 21 * * * | delete from cron.job_run_details where end_time < now() - interval '7 days'
