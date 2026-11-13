/**
 * Printing through the RawBT app on Android (Settings → Printers → "RawBT app").
 * The bill or kitchen ticket is turned into ESC/POS printer commands here, in the browser,
 * and handed to RawBT, which sends them to the Bluetooth, USB or network receipt printer.
 * No print window and no page layout: the printer's own font, 32 characters a line on 58 mm
 * paper and 48 on 80 mm.
 *
 * Android Chrome lets a page open another app only just after a tap. Automatic printing
 * (straight after payment, or on the KOT screen) is tried; if Chrome holds it back, the
 * Print button on the same screen prints with one tap.
 */
import type { ReceiptData } from "@/app/(app)/pos/receipt-view";
import { billFormat } from "@/lib/bill-format";
import { loyaltyLines } from "@/lib/receipt-loyalty";
import { isOrderRef, money, orderTypeLabel } from "@/lib/format";
import type { OfflineBill, Snapshot } from "@/lib/offline";

export type Line =
  | { text: string; align?: "left" | "center" | "right"; bold?: boolean; big?: boolean }
  | { rule: true }
  | { qr: string }
  | { cut: true }
  | { feed: number };

const ESC = 0x1b;
const GS = 0x1d;

/** Characters a line holds in the printer's normal font. */
export function columns(paper: "58" | "80" | string | undefined): number {
  return paper === "58" ? 32 : 48;
}

/** The printer knows only plain letters (no ₹, no Tamil): replace what it can, drop the rest. */
export function plain(s: string): string {
  return s
    .replace(/₹\s?/g, "Rs.")
    .replace(/[–—−]/g, "-")
    .replace(/[×✕]/g, "x")
    .replace(/[·•]/g, "-")
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/ | /g, " ")
    .replace(/…/g, "...")
    .normalize("NFKD")
    .replace(/[^\x20-\x7e]/g, "");
}

/** Breaks text into lines of at most `width` characters, at spaces where possible. */
function wrap(text: string, width: number): string[] {
  const out: string[] = [];
  for (const para of text.split("\n")) {
    let rest = para.trimEnd();
    if (rest === "") {
      out.push("");
      continue;
    }
    while (rest.length > width) {
      let cut = rest.lastIndexOf(" ", width);
      if (cut <= 0) cut = width;
      out.push(rest.slice(0, cut).trimEnd());
      rest = rest.slice(cut).trimStart();
    }
    out.push(rest);
  }
  return out;
}

/** "Subtotal ......... 120.00": left text and right text on one line. */
export function lr(left: string, right: string, width: number): string {
  const l = plain(left);
  const r = plain(right);
  if (l.length + r.length + 1 > width) {
    const lines = wrap(l, width);
    const last = lines.pop() ?? "";
    if (last.length + r.length + 1 <= width) return [...lines, last + " ".repeat(width - last.length - r.length) + r].join("\n");
    return [...lines, last, " ".repeat(Math.max(0, width - r.length)) + r].join("\n");
  }
  return l + " ".repeat(width - l.length - r.length) + r;
}

/** ESC/POS bytes for the lines. */
export function encode(lines: Line[], width: number): Uint8Array {
  const b: number[] = [ESC, 0x40]; // reset
  const text = (s: string) => {
    for (const ch of s) b.push(ch.charCodeAt(0) & 0xff);
  };
  for (const ln of lines) {
    if ("rule" in ln) {
      b.push(ESC, 0x61, 0);
      text("-".repeat(width) + "\n");
    } else if ("cut" in ln) {
      b.push(ESC, 0x64, 4, GS, 0x56, 0x42, 0); // feed a little, then cut (printers without a cutter ignore it)
    } else if ("feed" in ln) {
      b.push(ESC, 0x64, Math.max(0, Math.min(10, ln.feed)));
    } else if ("qr" in ln) {
      const data = Array.from(new TextEncoder().encode(ln.qr));
      const len = data.length + 3;
      b.push(ESC, 0x61, 1);
      b.push(GS, 0x28, 0x6b, 4, 0, 0x31, 0x41, 0x32, 0); // model 2
      b.push(GS, 0x28, 0x6b, 3, 0, 0x31, 0x43, width <= 32 ? 5 : 6); // dot size
      b.push(GS, 0x28, 0x6b, 3, 0, 0x31, 0x45, 0x31); // error correction M
      b.push(GS, 0x28, 0x6b, len & 0xff, len >> 8, 0x31, 0x50, 0x30, ...data);
      b.push(GS, 0x28, 0x6b, 3, 0, 0x31, 0x51, 0x30); // print it
      b.push(0x0a);
    } else {
      const big = !!ln.big;
      const w = big ? Math.floor(width / 2) : width;
      b.push(ESC, 0x61, ln.align === "center" ? 1 : ln.align === "right" ? 2 : 0);
      b.push(ESC, 0x45, ln.bold || big ? 1 : 0);
      b.push(GS, 0x21, big ? 0x11 : 0x00);
      for (const row of ln.text.split("\n").map(plain).flatMap((r) => wrap(r, w))) text(row + "\n");
      b.push(GS, 0x21, 0x00, ESC, 0x45, 0);
    }
  }
  b.push(ESC, 0x61, 0);
  return new Uint8Array(b);
}

function base64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

/** Hands the job to the RawBT app. On a device without RawBT, Chrome opens its Play Store page. */
export function sendToRawbt(lines: Line[], width: number) {
  const data = base64(encode(lines, width));
  window.location.href = `intent:base64,${data}#Intent;scheme=rawbt;package=ru.a402d.rawbtprinter;end;`;
}

/* ------------------------------------------------------------------ bill */

export function billLines(data: ReceiptData, estimate = false): { lines: Line[]; width: number } {
  const f = billFormat(data.format);
  const W = columns(f.paper);
  const m = (n: number) => plain(money(n, data.currency));
  const L: Line[] = [];
  const row = (l: string, r: string, bold = false) => L.push({ text: lr(l, r, W), bold });

  if (data.state === "voided") L.push({ text: "VOIDED - NOT VALID", align: "center", bold: true });
  if (data.state === "voided" && data.voidReason) L.push({ text: `Reason: ${data.voidReason}`, align: "center" });
  if (data.comp && data.state !== "voided") {
    L.push({ text: data.comp.kind === "complimentary" ? "COMPLIMENTARY - NO CHARGE" : "STAFF MEAL - NO CHARGE", align: "center", bold: true });
    if (data.comp.reason) L.push({ text: data.comp.reason, align: "center" });
  }
  if (estimate && (data.state === "unpaid" || data.state === "part-paid")) L.push({ text: "ESTIMATE - NOT A TAX INVOICE", align: "center", bold: true });
  else if (data.state === "unpaid") L.push({ text: "UNPAID - NOT A TAX INVOICE", align: "center", bold: true });
  else if (data.state === "part-paid") L.push({ text: `PART PAID - BALANCE ${m(data.balance)}`, align: "center", bold: true });
  if (data.invoiceTitle && data.state !== "unpaid" && data.state !== "part-paid") L.push({ text: data.invoiceTitle.toUpperCase(), align: "center", bold: true });

  L.push({ text: data.header, align: "center", big: true });
  if (f.legal_name && data.legalName && data.legalName !== data.header) L.push({ text: data.legalName, align: "center" });
  if (f.branch && data.branchName) L.push({ text: data.branchName, align: "center" });
  if (f.address && data.address) L.push({ text: data.address, align: "center" });
  if (f.phone && data.phone) L.push({ text: `Ph: ${data.phone}`, align: "center" });
  if (data.taxId) L.push({ text: `${data.taxIdLabel}: ${data.taxId}`, align: "center" });
  if (data.fssaiNo) L.push({ text: `FSSAI Lic. No.: ${data.fssaiNo}`, align: "center" });
  if (data.sacCode && data.taxId) L.push({ text: `SAC: ${data.sacCode}`, align: "center" });
  L.push({ rule: true });

  const type = (orderTypeLabel[data.orderType] ?? data.orderType) + (data.tableNumber ? ` T${data.tableNumber}` : "");
  row(isOrderRef(data.billNumber) ? `Order: ${data.billNumber.slice(5)}` : `Bill: ${data.billNumber}`, type);
  L.push({
    text: new Date(data.createdAt).toLocaleString("en-IN", {
      timeZone: data.timezone,
      day: "2-digit",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    }),
  });
  if (f.cashier) L.push({ text: `Cashier: ${data.cashierName}` });
  if (data.token != null) L.push({ text: `TOKEN ${data.token}`, align: "center", big: true });
  if (f.guest && data.guest && (data.guest.name || data.guest.phone)) {
    L.push({ text: `Guest: ${[data.guest.name, data.guest.phone ? `+${data.guest.phone}` : null].filter(Boolean).join(" - ")}` });
  }
  if (f.guest && data.guest?.address) L.push({ text: `Deliver to: ${data.guest.address}` });
  if (data.buyer) {
    L.push({ text: `Bill to: ${data.buyer.name ?? ""}` });
    L.push({ text: `${data.taxIdLabel}: ${data.buyer.taxId}` });
  }
  L.push({ rule: true });

  // Items: name on its own line(s), then qty x rate and amount on the right.
  const amtW = W <= 32 ? 10 : 12;
  row("Item", "Amount", true);
  for (const it of data.items) {
    const name = plain(it.name) || "Item";
    const opt = it.options ? plain(it.options) : "";
    const q = it.unit ? `${it.qty.toFixed(3)}${it.unit}` : `${it.qty}`;
    const qtyRate = f.rate ? `${q} x ${it.unitPrice.toFixed(2)}` : `x ${q}`;
    const amt = it.amount.toFixed(2).padStart(amtW);
    if (name.length + 1 + qtyRate.length + amt.length + 1 <= W) {
      L.push({ text: name + " ".repeat(W - name.length - qtyRate.length - amt.length) + qtyRate + amt });
    } else {
      L.push({ text: name });
      L.push({ text: lr(`  ${qtyRate}`, amt.trim(), W) });
    }
    if (opt) L.push({ text: `  ${opt}` });
    if (it.offerName) L.push({ text: `  ${plain(it.offerName)}${it.listPrice != null && it.listPrice > it.unitPrice ? ` (was ${it.listPrice.toFixed(2)})` : ""}` });
  }
  L.push({ rule: true });

  const taxAdded = Math.round((data.taxTotal - data.taxIncluded) * 100) / 100;
  const allIncluded = data.taxIncluded > 0 && taxAdded === 0;
  const allAdded = data.taxIncluded === 0;
  row("Subtotal", m(data.subtotal));
  if (data.discount > 0) row(data.comp ? (data.comp.kind === "complimentary" ? "Complimentary" : "Staff meal") : "Discount", `-${m(data.discount)}`);
  if ((data.loyaltyDiscount ?? 0) > 0) row("Loyalty points discount", `-${m(data.loyaltyDiscount ?? 0)}`);
  if (data.vatRemoved > 0) row("Less: VAT (exempt)", `-${m(data.vatRemoved)}`);
  if (data.seniorDiscount > 0) row(`Less: ${data.senior?.kind === "pwd" ? "PWD" : "Senior"} 20%`, `-${m(data.seniorDiscount)}`);
  if (data.serviceCharge > 0) row(data.serviceChargeLabel, m(data.serviceCharge));
  if (allAdded) for (const t of data.taxLines) row(t.name, m(t.amount));
  if (!allAdded && !allIncluded && taxAdded > 0) row("Tax on service charge", m(taxAdded));
  if (Math.abs(data.rounding) >= 0.005) row("Rounding", `${data.rounding > 0 ? "+" : "-"}${m(Math.abs(data.rounding))}`);
  L.push({ text: lr("TOTAL", m(data.grandTotal), Math.floor(W / 2)), big: true });
  if (data.taxIncluded > 0 && !data.showVatBreakdown) {
    if (allIncluded) for (const t of data.taxLines) row(`Includes ${t.name}`, m(t.amount));
    else row("Includes tax", m(data.taxIncluded));
  }

  if (data.payments.length > 0) {
    L.push({ rule: true });
    for (const p of data.payments) {
      if (Math.abs(p.cashRounding) >= 0.005) row("Cash rounding", `${p.cashRounding > 0 ? "+" : "-"}${m(Math.abs(p.cashRounding))}`);
      row(`Paid (${p.methodName})`, m(p.amount));
      if (p.tendered != null && p.tendered > 0) row("Tendered", m(p.tendered));
      if (p.change > 0) row("Change", m(p.change));
    }
    if (data.state === "part-paid") row("Balance to pay", m(data.balance));
    if (data.refunded > 0) row("Refunded", `-${m(data.refunded)}`);
  }

  const pts = loyaltyLines(data.loyalty);
  if (pts.length > 0) {
    L.push({ rule: true });
    for (const x of pts) row(x.label, x.value);
  }

  if (data.showVatBreakdown) {
    const vatable = Math.round((data.netSales - data.exemptSales + data.seniorDiscount) * 100) / 100;
    L.push({ rule: true });
    row("VATable sales", m(vatable));
    if (data.taxLines.length > 0) for (const t of data.taxLines) row(t.name, m(t.amount));
    else row("VAT", m(data.taxTotal));
    row("VAT-exempt sales", m(data.exemptSales));
    row("Zero-rated sales", m(0));
    if (data.senior) {
      L.push({ text: `${data.senior.kind === "pwd" ? "PWD" : "Senior citizen"}: ${data.senior.name}` });
      L.push({ text: `ID no.: ${data.senior.idNo}` });
      L.push({ feed: 2 }, { text: "Signature: ______________" });
    }
  }

  if (f.upi_qr && data.upi && (data.state === "unpaid" || data.state === "part-paid") && data.balance > 0) {
    const q = new URLSearchParams({
      pa: data.upi.id,
      pn: data.upi.payee.slice(0, 50),
      am: data.balance.toFixed(2),
      cu: "INR",
      tn: `Bill ${data.billNumber}`.slice(0, 50),
    });
    L.push({ rule: true }, { qr: `upi://pay?${q.toString()}` }, { text: "Scan to pay with any UPI app", align: "center" });
  }

  L.push({ rule: true });
  L.push({ text: data.footer || "Thank you - visit again", align: "center" });
  if (f.powered_by) L.push({ text: "Billed on SNA POS", align: "center" });
  L.push({ cut: true });
  return { lines: L, width: W };
}

/* ------------------------------------------------------------------ kitchen ticket */

export type KotTicket = {
  station: string;
  number: string;
  createdAt: string;
  where: string;
  token: number | null;
  bill: string;
  /** Longest preparation time among the items, in minutes; printed as "~12 min" when set. */
  prepMin?: number | null;
  items: { name: string; qty: number; note: string | null; cancelled: boolean }[];
};

/** One or more kitchen tickets, each cut off on its own. */
export function kotLines(tickets: KotTicket[], opts: { paper?: string; timezone: string; large?: boolean }): { lines: Line[]; width: number } {
  const W = columns(opts.paper);
  const L: Line[] = [];
  for (const t of tickets) {
    L.push({ text: `KOT - ${t.station}`, align: "center", big: true });
    if (t.token != null) L.push({ text: `TOKEN ${t.token}`, align: "center", big: true });
    const time = new Date(t.createdAt).toLocaleTimeString("en-IN", { timeZone: opts.timezone, hour: "2-digit", minute: "2-digit" });
    L.push({ text: lr(t.where, time, W), bold: true });
    L.push({ text: `${t.number} - Bill ${t.bill}${t.prepMin ? ` - ~${t.prepMin} min` : ""}` });
    L.push({ rule: true });
    for (const i of t.items) {
      const line = `${i.qty} x ${plain(i.name) || "Item"}${i.cancelled ? " - CANCELLED" : ""}`;
      L.push({ text: line, bold: !i.cancelled, big: !!opts.large && !i.cancelled });
      if (i.note) L.push({ text: `   ** ${i.note}`, bold: true });
    }
    L.push({ rule: true }, { cut: true });
  }
  return { lines: L, width: W };
}

/* ------------------------------------------------------------------ bill made offline */


/** The offline bill, as the offline receipt screen shows it. */
export function offlineBillLines(bill: OfflineBill, snap: Snapshot): { lines: Line[]; width: number } {
  const r = snap.receipt;
  const f = billFormat(r.format);
  const W = columns(f.paper);
  const m = (n: number) => plain(money(n, r.currency));
  const c = bill.calc;
  const L: Line[] = [];
  const row = (l: string, v: string, bold = false) => L.push({ text: lr(l, v, W), bold });
  if (r.invoice_title) L.push({ text: r.invoice_title.toUpperCase(), align: "center", bold: true });
  L.push({ text: r.header, align: "center", big: true });
  if (f.legal_name && r.legal_name && r.legal_name !== r.header) L.push({ text: r.legal_name, align: "center" });
  if (r.tax_id) L.push({ text: `${r.tax_id_label ?? "Tax No."}: ${r.tax_id}`, align: "center" });
  if (r.fssai_no) L.push({ text: `FSSAI Lic. No.: ${r.fssai_no}`, align: "center" });
  L.push({ rule: true });
  row(`Bill: ${bill.number}`, orderTypeLabel[bill.order_type] ?? bill.order_type);
  L.push({
    text: new Date(bill.created_at).toLocaleString("en-IN", { timeZone: r.timezone, day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" }),
  });
  if (f.guest && bill.guest && (bill.guest.name || bill.guest.phone)) L.push({ text: `Guest: ${[bill.guest.name, bill.guest.phone].filter(Boolean).join(" - ")}` });
  if (f.guest && bill.guest?.address) L.push({ text: `Deliver to: ${bill.guest.address}` });
  if (snap.settings.loyalty && bill.guest?.phone) L.push({ text: "Points will be added after sync" });
  L.push({ rule: true });
  bill.items.forEach((it, i) => {
    const amt = (c.lines[i]?.subtotal ?? it.price * it.qty).toFixed(2);
    L.push({ text: plain(it.name) || "Item" });
    L.push({ text: lr(`  ${f.rate ? `${it.qty} x ${it.price.toFixed(2)}` : `x ${it.qty}`}`, amt, W) });
    if (it.options_text) L.push({ text: `  ${it.options_text}` });
  });
  L.push({ rule: true });
  row("Subtotal", m(c.subtotal));
  if (c.discount > 0) row("Discount", `-${m(c.discount)}`);
  if (c.service_charge > 0) row(snap.settings.sc_label, m(c.service_charge));
  for (const t of c.taxes.filter((x) => x.amount !== 0)) row(`${t.name} (${t.rate}%)`, m(t.amount));
  if (Math.abs(c.rounding) >= 0.005) row("Rounding", m(c.rounding));
  if (Math.abs(bill.due - bill.grand_total) >= 0.005) row("Cash rounding", m(bill.due - bill.grand_total));
  L.push({ text: lr("TOTAL", m(bill.due), Math.floor(W / 2)), big: true });
  if (c.tax_included > 0 && Math.round((c.tax_total - c.tax_included) * 100) === 0) row("Prices include tax", m(c.tax_included));
  L.push({ rule: true });
  row(`Paid (${bill.method_name})`, m(bill.due), true);
  if (bill.tendered != null && bill.tendered > bill.due) row("Change", m(bill.tendered - bill.due), true);
  L.push({ rule: true }, { text: r.footer || "Thank you - visit again", align: "center" }, { cut: true });
  return { lines: L, width: W };
}

/** Kitchen tickets for an offline bill, one per station (the packing charge is left off). */
export function offlineKotLines(bill: OfflineBill, snap: Snapshot): { lines: Line[]; width: number } {
  const f = billFormat(snap.receipt.format);
  const items = bill.items.filter((i) => i.product_id !== snap.settings.packing?.product_id);
  const stations = [...new Set(items.map((i) => i.station))];
  return kotLines(
    stations.map((s) => ({
      station: s,
      number: "KOT",
      createdAt: bill.created_at,
      where: orderTypeLabel[bill.order_type] ?? bill.order_type,
      token: null,
      bill: bill.number,
      items: items
        .filter((i) => i.station === s)
        .map((i) => ({ name: i.options_text ? `${i.name} (${i.options_text})` : i.name, qty: i.qty, note: i.note ?? null, cancelled: false })),
    })),
    { paper: f.paper, timezone: snap.receipt.timezone, large: f.kot_text === "large" },
  );
}
