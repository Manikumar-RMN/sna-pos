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
