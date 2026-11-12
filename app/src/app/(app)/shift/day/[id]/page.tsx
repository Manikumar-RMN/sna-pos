import Link from "next/link";
import { notFound } from "next/navigation";
import { has, requireUser } from "@/lib/auth";
import { WhatsAppSummary } from "./whatsapp-summary";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import { dateTime, money } from "@/lib/format";
import { PrintButton } from "../../../print-button";
import { paidLaterNote, voidedAfterCloseNote } from "../../figures";

type Z = {
  business_date: string;
  branch: string;
  status: string;
  opened_at: string;
  closed_at: string | null;
  closed_by: string | null;
  bills: number;
  first_bill: string | null;
  last_bill: string | null;
  gross_sales: number;
  discounts: number;
  service_charge: number;
  tax: number;
  tax_included: number;
  rounding: number;
  total_billed: number;
  voided_bills: number;
  voided_value: number;
  /** Complimentary bills and staff meals (closed at 0.00). Reports saved before change 089 do not have them. */
  complimentary_bills?: number;
  complimentary_value?: number;
  staff_meal_bills?: number;
  staff_meal_value?: number;
  unpaid_bills: number;
  /** Still to collect on the unpaid bills. Reports saved before this was added do not have it. */
  unpaid_amount?: number;
  payments: { method: string; count: number; amount: number }[];
  taxes: { component: string; rate: number; taxable: number; tax: number }[];
  credit_notes: { count: number; amount: number; tax: number; list: { number: string; amount: number; bill: string; reason: string }[] };
  shifts: {
    opened_at: string;
    closed_at: string | null;
    opened_by: string | null;
    expected_cash: number;
    counted_cash: number | null;
    variance: number | null;
    /** Bills voided after the shift closed. Older saved reports do not have these. */
    voided_after_close?: number;
    voided_after_close_value?: number;
    /** Bills unpaid when the shift closed that were paid in a later shift. Older saved reports do not have these. */
    paid_later?: number;
    paid_later_value?: number;
  }[];
  by_type: { type: string; bills: number; total: number }[];
  /** Added with meal sessions; older saved reports do not have it. */
  sessions?: { session: string; bills: number; total: number }[];
  net_sales_after_credit_notes: number;
  reopen_count: number;
};

/** End-of-day (Z) report. For a closed day it is the copy saved at closing, so it never changes afterwards. */
export default async function DayReportPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const user = await requireUser();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("day_report", { p_day_id: id });
  if (!error && !data) {
    return (
      <div className="card mx-auto max-w-md p-5 text-center text-sm" role="alert">
        <b>This day is not in this outlet.</b> It may belong to another outlet &mdash; switch outlet at the top of the screen and open it again.
      </div>
    );
  }
  if (error) {
    if (/not found|no such|does not exist/i.test(error.message ?? "")) {
      return (
        <div className="card mx-auto max-w-md p-5 text-center text-sm" role="alert">
          <b>This day is not in this outlet.</b> It may belong to another outlet &mdash; switch outlet at the top of the screen and open it again.
        </div>
      );
    }
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" role="alert">
        {friendlyDbError(error)}
      </div>
    );
  }
  const z = data as unknown as Z;
  const c = user.currency_code;
  const tz = user.timezone;
  const m = (n: number | null | undefined) => money(Number(n ?? 0), c);
  const unpaidAmount = Number(z.unpaid_amount ?? 0);
  const unpaidBills = Number(z.unpaid_bills ?? 0);
  const unpaidLabel = `Not yet paid (${unpaidBills} bill${unpaidBills === 1 ? "" : "s"})`;
  const date = new Date(`${z.business_date}T00:00:00`).toLocaleDateString("en-IN", { weekday: "long", day: "numeric", month: "long", year: "numeric" });

  return (
    <div className="mx-auto max-w-md">
      <style>{`
        @media print {
          body * { visibility: hidden !important; }
          #receipt, #receipt * { visibility: visible !important; }
          #receipt { position: absolute; left: 0; top: 0; width: 80mm; border: 0 !important; box-shadow: none !important; }
          .no-print { display: none !important; }
        }
      `}</style>
      <div id="receipt" className="receipt card p-5 font-mono text-[12px] leading-snug" style={{ background: "#fff", color: "#111" }}>
        <div className="text-center">
          <div className="text-sm font-bold">{user.trading_name}</div>
          <div>{z.branch}</div>
          <div className="mt-2 text-sm font-bold tracking-wide">{z.status === "closed" ? "END-OF-DAY REPORT (Z)" : "DAY SO FAR (X) — NOT CLOSED"}</div>
          <div>{date}</div>
        </div>
        <Rule />
        <Row label="Opened" value={dateTime(z.opened_at, tz)} />
        {z.closed_at && <Row label="Closed" value={`${dateTime(z.closed_at, tz)}${z.closed_by ? ` · ${z.closed_by}` : ""}`} />}
        {z.reopen_count > 0 && <Row label="Reopened" value={`${z.reopen_count} time${z.reopen_count === 1 ? "" : "s"}`} />}
        <Row label="Bills" value={`${z.bills}${z.first_bill ? ` (${z.first_bill} – ${z.last_bill})` : ""}`} />
        <Rule />
        <Row label="Gross sales" value={m(z.gross_sales)} />
        <Row label="Discounts" value={z.discounts > 0 ? `-${m(z.discounts)}` : m(0)} />
        {Number(z.service_charge) > 0 && <Row label="Service charge" value={m(z.service_charge)} />}
        <Row label={Number(z.tax_included) > 0 ? "Tax (incl. in prices)" : "Tax"} value={m(z.tax)} />
        {Math.abs(Number(z.rounding)) >= 0.005 && <Row label="Rounding" value={m(z.rounding)} />}
        <div className="flex justify-between font-bold">
          <span>Total billed</span>
          <span>{m(z.total_billed)}</span>
        </div>
        {unpaidAmount > 0 && <Row label={unpaidLabel} value={m(unpaidAmount)} />}
        {z.credit_notes.count > 0 && (
          <>
            <Row label={`Credit notes (${z.credit_notes.count})`} value={`-${m(z.credit_notes.amount)}`} />
            <div className="flex justify-between font-bold">
              <span>Net after credit notes</span>
              <span>{m(z.net_sales_after_credit_notes)}</span>
            </div>
          </>
        )}
        <Rule />
        <div className="font-bold">Payments</div>
        {z.payments.length === 0 && <div>None</div>}
        {z.payments.map((p, i) => (
          <Row key={i} label={`${p.method} (${p.count})`} value={m(p.amount)} />
        ))}
        {z.taxes.length > 0 && (
          <>
            <Rule />
            <div className="font-bold">Tax by rate</div>
            {z.taxes.map((t, i) => (
              <Row key={i} label={`${t.component} ${Number(t.rate)}% on ${m(t.taxable)}`} value={m(t.tax)} />
            ))}
            {z.credit_notes.count > 0 && <Row label="Tax reversed by credit notes" value={`-${m(z.credit_notes.tax)}`} />}
          </>
        )}
        {z.by_type.length > 0 && (
          <>
            <Rule />
            <div className="font-bold">By order type</div>
            {z.by_type.map((t, i) => (
              <Row key={i} label={`${t.type.replace("_", "-")} (${t.bills})`} value={m(t.total)} />
            ))}
          </>
        )}
        {(z.sessions ?? []).length > 0 && (
          <>
            <Rule />
            <div className="font-bold">By meal session</div>
            {(z.sessions ?? []).map((x, i) => (
              <Row key={i} label={`${x.session} (${x.bills})`} value={m(x.total)} />
            ))}
          </>
        )}
        <Rule />
        <Row label="Voided bills" value={`${z.voided_bills} · ${m(z.voided_value)}`} />
        {(z.complimentary_bills ?? 0) > 0 && <Row label={`Complimentary (${z.complimentary_bills})`} value={m(z.complimentary_value ?? 0)} />}
        {(z.staff_meal_bills ?? 0) > 0 && <Row label={`Staff meals (${z.staff_meal_bills})`} value={m(z.staff_meal_value ?? 0)} />}
        {z.credit_notes.list.map((cn) => (
          <Row key={cn.number} label={`${cn.number} (bill ${cn.bill})`} value={`-${m(cn.amount)}`} />
        ))}
        {z.shifts.length > 0 && (
          <>
            <Rule />
            <div className="font-bold">Cash drawer</div>
            {z.shifts.map((s, i) => {
              const lateVoids = voidedAfterCloseNote(s, c);
              const paidLater = paidLaterNote(s, c);
              return (
                <div key={i} className="mt-1">
                  <div>
                    Shift {i + 1}: {s.opened_by ?? "—"}
                  </div>
                  <Row label="Expected" value={m(s.expected_cash)} />
                  {s.counted_cash != null && <Row label="Counted" value={m(s.counted_cash)} />}
                  {s.variance != null && <Row label="Difference" value={m(s.variance)} />}
                  {lateVoids && <div className="mt-0.5">{lateVoids}</div>}
                  {paidLater && <div className="mt-0.5">{paidLater}</div>}
                </div>
              );
            })}
          </>
        )}
        <Rule />
        <div className="text-center text-[10px]" style={{ color: "#666" }}>
          Printed {dateTime(new Date().toISOString(), tz)} · SNA POS
        </div>
      </div>
      <div className="no-print mt-3 space-y-2">
        <PrintButton label="Print report" />
        {has(user, "whatsapp") && (
          <WhatsAppSummary
            country={user.country_code}
            text={[
              `${user.trading_name} — ${z.branch}, day ${z.business_date}${z.status === "closed" ? " (closed)" : " (so far)"}`,
              `Bills: ${z.bills} · Total billed: ${m(z.total_billed)}`,
              unpaidAmount > 0 ? `${unpaidLabel}: ${m(unpaidAmount)}` : "",
              `Tax: ${m(z.tax + z.tax_included)} · Discounts: ${m(z.discounts)}`,
              ...z.payments.map((p) => `${p.method}: ${m(p.amount)} (${p.count})`),
              z.voided_bills ? `Voided: ${z.voided_bills} bills, ${m(z.voided_value)}` : "",
              z.complimentary_bills ? `Complimentary: ${z.complimentary_bills} bills, ${m(z.complimentary_value ?? 0)}` : "",
              z.staff_meal_bills ? `Staff meals: ${z.staff_meal_bills} bills, ${m(z.staff_meal_value ?? 0)}` : "",
              z.credit_notes?.count ? `Credit notes: ${z.credit_notes.count}, ${m(z.credit_notes.amount)}` : "",
              `Net after credit notes: ${m(z.net_sales_after_credit_notes)}`,
            ]
              .filter(Boolean)
              .join("\n")}
          />
        )}
        <Link href="/shift" className="btn w-full border text-sm" style={{ borderColor: "var(--color-line)" }}>
          Back to Shift and day close
        </Link>
      </div>
    </div>
  );
}

function Rule() {
  return <div className="my-2 border-t border-dashed" style={{ borderColor: "#999" }} />;
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-2">
      <span>{label}</span>
      <span className="whitespace-nowrap text-right">{value}</span>
    </div>
  );
}
