/** Front Office: shapes returned by the fo_* database functions (migrations 152-155), shared by server and client code. */

export type RoomCard = {
  room_id: string;
  room_number: string;
  floor: string | null;
  room_type: string;
  room_type_id: string;
  housekeeping: "clean" | "dirty";
  out_of_service: boolean;
  oos_reason: string | null;
  occupied: boolean;
  stay_id: string | null;
  stay_no: number | null;
  guest_name: string | null;
  departure: string | null;
};

export type ArrivalRow = { stay_id: string; stay_no: number; guest_name: string; room_type: string; nights: number; rate: number; adults: number; children: number };
export type InHouseRow = { stay_id: string; stay_no: number; guest_name: string; room_number: string | null; departure: string; balance: number };
export type DepartureRow = { stay_id: string; stay_no: number; guest_name: string; room_number: string | null; balance: number };
export type AuditRow = {
  business_date: string;
  rooms_available: number;
  rooms_sold: number;
  occupancy_pct: number;
  room_revenue: number;
  other_revenue: number;
  collections: number;
  adr: number;
  revpar: number;
  no_shows: number;
  charges_posted: number;
  run_at?: string;
};

export type DaySheet = {
  business_date: string;
  arrivals: ArrivalRow[];
  in_house: InHouseRow[];
  departures: DepartureRow[];
  last_audit: AuditRow | null;
  audited: boolean;
};

export type RoomTypeAvail = { room_type_id: string; code: string; name: string; base_rate: number; max_occupancy: number; rooms: number; free: number };

export type FolioCharge = {
  charge_id: string; on: string; kind: string; description: string; quantity: number; unit_amount: number;
  net_amount: number; tax_pct: number; tax_amount: number; total: number; order_id: string | null; voided: boolean; void_reason: string | null;
};
export type FolioPayment = { payment_id: string; on: string; amount: number; method: string; is_refund: boolean; reference: string | null; voided: boolean; void_reason: string | null };
export type Folio = {
  stay: {
    stay_id: string; stay_no: number; status: "reserved" | "inhouse" | "checked_out" | "cancelled" | "no_show";
    arrival: string; departure: string; nights: number; adults: number; children: number; nightly_rate: number;
    source: string; notes: string | null; room_id: string | null; room_number: string | null; room_type: string | null;
    rate_plan: string | null; rate_plan_code: string | null; meal_plan: string | null; rate_schedule: { night: string; rate: number }[];
    guest: { guest_id: string; full_name: string; phone: string | null; email: string | null };
  };
  charges: FolioCharge[];
  payments: FolioPayment[];
  totals: { charged: number; paid: number; refunded: number; balance: number };
};

/** Charge kinds a receptionist may post by hand ("room" is posted by the night audit only). */
export const MANUAL_CHARGE_KINDS: { value: string; label: string }[] = [
  { value: "food", label: "Food and drink" },
  { value: "laundry", label: "Laundry" },
  { value: "telephone", label: "Telephone" },
  { value: "minibar", label: "Minibar" },
  { value: "misc", label: "Other" },
];

export const STATUS_LABEL: Record<string, string> = {
  reserved: "Reserved", inhouse: "In-house", checked_out: "Checked out", cancelled: "Cancelled", no_show: "No-show",
};

/** Housekeeping list row (fo_hk_list). */
export type HkTask = "departure" | "stayover" | "vacant_dirty" | "to_inspect" | "ready" | "out_of_service";
export type HkRow = {
  room_id: string; room_number: string; floor: string | null; room_type: string;
  housekeeping: "clean" | "dirty"; inspected: boolean; out_of_service: boolean; oos_reason: string | null; note: string | null;
  attendant_id: string | null; attendant: string | null; occupied: boolean; guest_name: string | null; vip: boolean;
  departure: string | null; arriving_today: boolean; task: HkTask;
};
export const HK_TASK_LABEL: Record<HkTask, string> = {
  departure: "Departure: clean", stayover: "Stay-over", vacant_dirty: "Vacant, dirty", to_inspect: "Clean, to inspect", ready: "Ready", out_of_service: "Out of service",
};

/** Stay chart (fo_chart). */
export type ChartStay = { stay_id: string; stay_no: number; guest_name: string; vip: boolean; status: "reserved" | "inhouse" | "checked_out"; arrival: string; departure: string };
export type ChartData = {
  from: string; days: number;
  rooms: { room_id: string; room_number: string; room_type: string; out_of_service: boolean; stays: ChartStay[] }[];
  unassigned: { stay_id: string; stay_no: number; guest_name: string; room_type: string; arrival: string; departure: string }[];
};

/** Guest search row (fo_find_guests). */
export type GuestRow = {
  guest_id: string; full_name: string; phone: string | null; email: string | null; city: string | null;
  vip: boolean; blocked: boolean; blocked_reason: string | null; preferences: string | null; stays: number; last_stay: string | null;
};


/** Rate plans (fo_rate_setup) and the booking price list (fo_quote). */
export type RateRule = {
  id: string; room_type_id: string; valid_from: string | null; valid_to: string | null; rate: number;
  weekend_rate: number | null; single_rate: number | null; included_adults: number; extra_adult: number; extra_child: number;
};
export type RatePlan = { id: string; code: string; name: string; meal_plan: "EP" | "CP" | "MAP" | "AP"; description: string | null; display_order: number; active: boolean; rules: RateRule[] };
export const MEAL_PLAN_LABEL: Record<string, string> = { EP: "Room only", CP: "With breakfast", MAP: "Breakfast and one meal", AP: "All meals" };
export type QuoteOption =
  | { rate_plan_id: string | null; code: string; name: string; meal_plan: string; available: true; total: number; average: number; nights: { night: string; rate: number }[] }
  | { rate_plan_id: string | null; code: string; name: string; meal_plan: string; available: false; reason: string };
export type Quote = { room_type: string; nights: number; options: QuoteOption[] };

/** Business details used on the tax invoice (part of fo_setup settings). */
export type BusinessDetails = {
  legal_name: string | null; gstin: string | null; state_code: string | null; address: string | null;
  phone: string | null; email: string | null; invoice_prefix: string; invoice_footer: string | null; room_tax_exempt_below: number;
};

/** The issued tax invoice, as stored (fo_invoice_for_stay). */
export type InvoiceSnapshot = {
  property: { legal_name: string; gstin: string | null; state_code: string | null; address: string; phone: string | null; email: string | null; footer: string | null };
  bill_to: { name: string; gstin: string | null; address: string | null; state_code: string | null };
  guest: { name: string; phone: string | null };
  stay: { stay_no: number; arrival: string; departure: string; nights: number; adults: number; children: number; room_number: string | null; room_type: string | null; rate_plan: string | null; checked_out_at: string | null };
  lines: { on: string; kind: string; description: string; sac: string; quantity: number; unit_amount: number; taxable: number; tax_pct: number; tax: number; total: number }[];
  tax_summary: { sac: string; tax_pct: number; taxable: number; tax: number; cgst: number; sgst: number }[];
  payments: { on: string; method: string; amount: number; is_refund: boolean; reference: string | null }[];
  totals: { taxable: number; tax: number; total: number };
  supply: { type: string; place_of_supply_state_code: string | null; reverse_charge: boolean };
};
export type InvoiceState =
  | { issued: true; invoice_id: string; invoice_no: string; invoice_date: string; total: number; snapshot: InvoiceSnapshot }
  | { issued: false; ready: boolean; status: string; has_business_details: boolean; has_gstin: boolean; prefill: { name: string | null; gstin: string | null; address: string | null; state_code: string | null } };

/** The registration card (fo_reg_card). */
export type RegCard = {
  property: { legal_name: string | null; name: string | null; gstin: string | null; address: string | null; phone: string | null; email: string | null; check_in_time: string; check_out_time: string };
  stay: { stay_no: number; status: string; arrival: string; departure: string; nights: number; adults: number; children: number; source: string; nightly_rate: number; notes: string | null; room_number: string | null; room_type: string | null; rate_plan: string | null; meal_plan: string | null };
  guest: { full_name: string; phone: string | null; email: string | null; id_type: string | null; id_number: string | null; address: string | null; city: string | null; country: string | null; vip: boolean; preferences: string | null; company: string | null; company_gstin: string | null };
  advance_paid: number;
};

/** Group bookings (fo_groups_list, fo_group_view). */
export type GroupRow = { group_id: string; group_no: number; name: string; status: "active" | "cancelled"; arrival: string; departure: string; contact_name: string; rooms: number; in_house: number };
export type GroupStay = {
  stay_id: string; stay_no: number; status: "reserved" | "inhouse" | "checked_out" | "cancelled" | "no_show";
  guest_id: string; guest_name: string; room_type: string; room_number: string | null; rate: number; adults: number; children: number;
  charged: number; paid: number; balance: number;
};
export type GroupView = {
  group: { group_id: string; group_no: number; name: string; status: "active" | "cancelled"; arrival: string; departure: string; nights: number; notes: string | null; contact_guest_id: string; contact_name: string; cancel_reason: string | null };
  stays: GroupStay[];
  totals: { rooms: number; charged: number; paid: number; balance: number };
};
