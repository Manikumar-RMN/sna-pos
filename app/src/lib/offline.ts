/**
 * Offline billing on this device: a copy of the menu and tax rules, a queue of
 * bills made while the internet was down, and their numbers. Everything is kept
 * in this browser only; bills are sent to the server as soon as it is reachable.
 */
import { calcBill, roundCash, type CalcComp, type CalcResult } from "./calc-bill";

export type SnapOption = { id: string; name: string; price: number };
export type SnapGroup = { id: string; name: string; min: number; max: number; options: SnapOption[] };
export type SnapItem = {
  id: string;
  name: string;
  short_name: string | null;
  price: number;
  category_id: string;
  category_name: string;
  is_veg: boolean | null;
  station: string;
  inclusive: boolean;
  comps: CalcComp[];
  groups: SnapGroup[];
};
export type Snapshot = {
  taken_at: string;
  device_key: string;
  /** branch_code is the outlet's bill prefix; key changes when the prefix changes (numbers start again from 1). */
  series: {
    prefix: string;
    fy: string | null;
    next_seq: number;
    branch_code: string;
    key?: string | null;
    /** Bars: the liquor bill prefix (liquor bills have their own numbers) and this device's next liquor number. */
    liquor_code?: string | null;
    liquor_next_seq?: number;
  };
  rights: { discount: boolean; pay: boolean };
  menu: SnapItem[];
  methods: { id: string; name: string; kind: string; ask_reference: boolean; upi_id: string | null }[];
  settings: {
    sc_percent: number;
    sc_taxable: boolean;
    sc_default_on: boolean;
    sc_label: string;
    rounding: string;
    cash_rounding: string;
    /**
     * The outlet's packing charge: which menu item it is, per bill or per item, and whether takeaway and
     * delivery bills get it by default. Null when there is none; missing in a copy saved by an older version.
     */
    packing?: { product_id: string; per: string; takeaway: boolean; delivery: boolean } | null;
  };
  receipt: {
    header: string;
    legal_name: string;
    tax_id: string | null;
    tax_id_label: string | null;
    fssai_no: string | null;
    footer: string | null;
    currency: string;
    timezone: string;
    country: string;
    invoice_title: string | null;
    /** The owner's bill layout choices, as stored (run it through billFormat()). Missing in an older copy. */
    format?: unknown;
    /** The restaurant's logo as a small picture (data URL), if one was uploaded. */
    logo?: string | null;
  };
};
export type OfflineItem = { product_id: string; name: string; qty: number; price: number; options: string[]; options_text: string | null; note?: string; station: string };
export type OfflineBill = {
  client_id: string;
  device_key: string;
  seq: number;
  fy: string | null;
  number: string;
  created_at: string;
  order_type: "dine_in" | "takeaway" | "delivery";
  /** Guest name, phone and delivery address as typed (takeaway and delivery). Missing on bills queued by an older version. */
  guest?: { name: string; phone: string; address: string } | null;
  /** How often sending the guest details has failed after the bill itself was saved on the server. */
  guest_tries?: number;
  /** How often the server has refused this bill itself (see offline-queue.ts), and its last reason. */
  sync_tries?: number;
  sync_error?: string;
  items: OfflineItem[];
  discount: number;
  service_charge: boolean;
  method_id: string;
  method_name: string;
  tendered: number | null;
  reference: string | null;
  grand_total: number;
  due: number;
  calc: CalcResult;
  /** When the menu copy this bill was priced from was taken (Snapshot.taken_at). Missing on bills queued by an older version. */
  snapshot_at?: string;
};

const K_DEVICE = "sna.device.v1";
const K_SNAP = "sna.offline.snapshot.v1";
const K_QUEUE = "sna.offline.queue.v1";
const K_STUCK = "sna.offline.stuck.v1";
const K_SEQ = "sna.offline.seq.v1";
const K_LSEQ = "sna.offline.liquor-seq.v1";

function get<T>(k: string): T | null {
  try {
    const v = localStorage.getItem(k);
    return v ? (JSON.parse(v) as T) : null;
  } catch {
    return null;
  }
}
function put(k: string, v: unknown) {
  try {
    localStorage.setItem(k, JSON.stringify(v));
    return true;
  } catch {
    return false;
  }
}

export function deviceKey(): string {
  let k: string | null = null;
  try {
    k = localStorage.getItem(K_DEVICE);
    if (!k) {
      k = crypto.randomUUID();
      localStorage.setItem(K_DEVICE, k);
    }
  } catch {
    k = k ?? crypto.randomUUID();
  }
  return k;
}

export const readSnapshot = () => get<Snapshot>(K_SNAP);
export function saveSnapshot(s: Snapshot) {
  put(K_SNAP, s);
  // Never go backwards: keep the higher of the server's and this device's next number.
  const local = get<{ fy: string | null; next: number; key?: string | null }>(K_SEQ);
  const key = s.series.key ?? null;
  if (!local || local.fy !== s.series.fy || (local.key ?? null) !== key || local.next < s.series.next_seq)
    put(K_SEQ, { fy: s.series.fy, next: s.series.next_seq, key });
  if (s.series.liquor_code) {
    const lq = get<{ code: string; next: number }>(K_LSEQ);
    const n = s.series.liquor_next_seq ?? 1;
    if (!lq || lq.code !== s.series.liquor_code || lq.next < n) put(K_LSEQ, { code: s.series.liquor_code, next: n });
  }
}
export const readQueue = () => get<OfflineBill[]>(K_QUEUE) ?? [];
export const writeQueue = (q: OfflineBill[]) => put(K_QUEUE, q);
/** Bills the server refused for good reasons of their own. Kept on this device, never deleted, until someone deals with them. */
export const readStuck = () => get<OfflineBill[]>(K_STUCK) ?? [];
export const writeStuck = (q: OfflineBill[]) => put(K_STUCK, q);

/** Works out the bill exactly as the server does. */
export function offlineQuote(
  snap: Snapshot,
  lines: { product_id: string; qty: number; unit_price: number }[],
  discount: number,
  serviceCharge: boolean | null,
) {
  const byId = new Map(snap.menu.map((m) => [m.id, m]));
  const scOn = (serviceCharge ?? snap.settings.sc_default_on) && snap.settings.sc_percent > 0;
  return calcBill({
    lines: lines.map((l, i) => {
      const m = byId.get(l.product_id);
      return { key: i + 1, price: l.unit_price, qty: l.qty, inclusive: m?.inclusive ?? false, comps: m?.comps ?? [] };
    }),
    discount,
    sc_percent: scOn ? snap.settings.sc_percent : 0,
    sc_taxable: snap.settings.sc_taxable,
    senior: null,
    rounding: snap.settings.rounding,
  });
}

export function cashDue(snap: Snapshot, total: number, isCash: boolean) {
  if (!isCash || snap.settings.cash_rounding === "none") return total;
  return roundCash(Math.round(total * 100), snap.settings.cash_rounding) / 100;
}

/** Takes the next offline bill number for this device, e.g. BILL26-X1-0007. */
export function takeNumber(snap: Snapshot, liquor = false): { seq: number; number: string } {
  // Bars: a liquor bill takes the next number of the liquor series, e.g. BAR26-X1-0001.
  if (liquor && snap.series.liquor_code) {
    const code = snap.series.liquor_code;
    const lq = get<{ code: string; next: number }>(K_LSEQ);
    const seq = Math.max(lq && lq.code === code ? lq.next : 1, snap.series.liquor_next_seq ?? 1);
    put(K_LSEQ, { code, next: seq + 1 });
    return { seq, number: `${code}-${snap.series.prefix}-${String(seq).padStart(4, "0")}` };
  }
  const key = snap.series.key ?? null;
  const saved = get<{ fy: string | null; next: number; key?: string | null }>(K_SEQ);
  const cur = saved && (saved.key ?? null) === key ? saved : { fy: snap.series.fy, next: snap.series.next_seq };
  const seq = Math.max(cur.next, snap.series.next_seq);
  put(K_SEQ, { fy: snap.series.fy, next: seq + 1, key });
  const s = snap.series;
  return { seq, number: `${s.branch_code}-${s.prefix}-${s.fy ? `${s.fy}-` : ""}${String(seq).padStart(4, "0")}` };
}
