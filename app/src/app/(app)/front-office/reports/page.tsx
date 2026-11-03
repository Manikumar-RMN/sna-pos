import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import type { DaySheet, GstReport, InvoiceRegister, OutstandingReport, PerfReport } from "@/lib/fo";
import { UpgradeNote } from "../../upgrade-note";
import { PrintButton } from "../../print-button";

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const SOURCE: Record<string, string> = { walk_in: "Walk-in", phone: "Phone", email: "Email", ota: "Online agent", corporate: "Corporate", other: "Other" };

/** Management reports for the hotel: sales, who owes what, GST and the invoice register. */
export default async function ReportsPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
  const user = await requireUser();
  if (!has(user, "front_office")) return <div className="mx-auto max-w-md"><UpgradeNote feature="Front office and housekeeping" /></div>;
  if (!(can(user, "fo.view") || can(user, "fo.manage"))) return <div className="card mx-auto max-w-md p-5 text-sm">Your role does not include front office reports.</div>;
  const supabase = await createClient();
  const sp = await searchParams;
  const sheet = (await supabase.rpc("fo_day_sheet", {})).data as unknown as DaySheet | null;
  const today = sheet?.business_date ?? new Date().toISOString().slice(0, 10);
  const from = sp.from && DATE.test(sp.from) ? sp.from : `${today.slice(0, 8)}01`;
  const to = sp.to && DATE.test(sp.to) ? sp.to : today;
  const c = user.currency_code;

  const [perf, os, gst, reg] = await Promise.all([
    supabase.rpc("fo_report_performance", { p_from: from, p_to: to }),
    supabase.rpc("fo_report_outstanding"),
    supabase.rpc("fo_report_gst", { p_from: from, p_to: to }),
    supabase.rpc("fo_invoice_register", { p_from: from, p_to: to }),
  ]);
  const err = perf.error?.message ?? gst.error?.message ?? reg.error?.message ?? null;
  const p = perf.data as unknown as PerfReport | null;
  const o = os.data as unknown as OutstandingReport | null;
  const g = gst.data as unknown as GstReport | null;
  const r = reg.data as unknown as InvoiceRegister | null;

  return (
    <div className="mx-auto max-w-5xl">
      <div className="no-print mb-3 flex flex-wrap items-end justify-between gap-3">
        <Link href="/front-office" className="text-sm underline">← Front office</Link>
        <form className="flex flex-wrap items-end gap-2" method="get">
          <label className="text-xs">From<input type="date" name="from" defaultValue={from} className="field h-10 text-sm" /></label>
          <label className="text-xs">To<input type="date" name="to" defaultValue={to} className="field h-10 text-sm" /></label>
          <button type="submit" className="btn h-10 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }}>Show</button>
        </form>
        <div className="w-32"><PrintButton label="Print" /></div>
      </div>

      <div className="report-root space-y-5">
        <div>
          <h1 className="text-xl font-extrabold">Front office reports</h1>
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>{from} to {to}</p>
        </div>
        {err && <div className="rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{err}</div>}

        {p && (
          <section className="card p-4">
            <h2 className="text-sm font-bold">Sales and occupancy</h2>
            <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-5 text-sm">
              <Stat label="Rooms sold" value={String(p.totals.rooms_sold)} />
              <Stat label="Occupancy" value={`${p.totals.occupancy_pct}%`} />
              <Stat label="ADR" value={money(p.totals.adr, c)} />
              <Stat label="RevPAR" value={money(p.totals.revpar, c)} />
              <Stat label="Room revenue" value={money(p.totals.room_revenue, c)} />
              <Stat label="Other revenue" value={money(p.totals.other_revenue, c)} />
              <Stat label="Tax collected" value={money(p.totals.tax, c)} />
              <Stat label="Rooms in service" value={String(p.rooms_available)} />
            </div>
            <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
              Built from room charges posted by night audit, net of tax. {p.totals.days_with_sales} of {p.days_in_range} days have sales; a day with no audit shows nothing. Occupancy uses today&apos;s count of rooms in service.
            </p>
            {p.days.length > 0 && (
              <div className="mt-3 overflow-x-auto"><table className="w-full text-sm">
                <thead><tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}><th>Date</th><th className="text-right">Rooms</th><th className="text-right">Occ.</th><th className="text-right">ADR</th><th className="text-right">Room revenue</th><th className="text-right">Other</th></tr></thead>
                <tbody>{p.days.map((d) => (
                  <tr key={d.dt}><td>{d.dt}</td><td className="text-right">{d.rooms_sold}</td><td className="text-right">{d.occupancy_pct}%</td><td className="text-right">{money(d.adr, c)}</td><td className="text-right">{money(d.room_revenue, c)}</td><td className="text-right">{money(d.other_revenue, c)}</td></tr>
                ))}</tbody>
              </table></div>
            )}
          </section>
        )}

        {p && p.room_types.length > 0 && (
          <section className="card p-4">
            <h2 className="text-sm font-bold">By room type</h2>
            <table className="mt-2 w-full text-sm">
              <thead><tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}><th>Room type</th><th className="text-right">Rooms sold</th><th className="text-right">ADR</th><th className="text-right">Room revenue</th><th className="text-right">Other</th></tr></thead>
              <tbody>{p.room_types.map((t) => (
                <tr key={t.code}><td>{t.name} ({t.code})</td><td className="text-right">{t.rooms_sold}</td><td className="text-right">{money(t.adr, c)}</td><td className="text-right">{money(t.room_revenue, c)}</td><td className="text-right">{money(t.other_revenue, c)}</td></tr>
              ))}</tbody>
            </table>
          </section>
        )}

        {p && p.sources.length > 0 && (
          <section className="card p-4">
            <h2 className="text-sm font-bold">Bookings by source (arrivals in the range)</h2>
            <table className="mt-2 w-full text-sm">
              <thead><tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}><th>Source</th><th className="text-right">Bookings</th><th className="text-right">Nights</th><th className="text-right">Cancelled</th><th className="text-right">No-shows</th></tr></thead>
              <tbody>{p.sources.map((s) => (
                <tr key={s.source}><td>{SOURCE[s.source] ?? s.source}</td><td className="text-right">{s.bookings}</td><td className="text-right">{s.nights}</td><td className="text-right">{s.cancelled}</td><td className="text-right">{s.no_shows}</td></tr>
              ))}</tbody>
            </table>
          </section>
        )}

        {p && (
          <section className="card p-4">
            <h2 className="text-sm font-bold">Cancellations and no-shows</h2>
            {p.lost.length === 0 ? <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>None in this range.</p> : (
              <table className="mt-2 w-full text-sm">
                <thead><tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}><th>Stay</th><th>Guest</th><th>Arrival</th><th>Why</th><th className="text-right">Nights</th><th className="text-right">Value lost</th></tr></thead>
                <tbody>{p.lost.map((l) => (
                  <tr key={l.stay_no}><td>#{l.stay_no} {l.status === "no_show" ? "no-show" : "cancelled"}</td><td>{l.guest}</td><td>{l.arrival}</td><td>{l.reason ?? "-"}</td><td className="text-right">{l.nights}</td><td className="text-right">{money(l.value, c)}</td></tr>
                ))}</tbody>
              </table>
            )}
          </section>
        )}

        {o && (
          <section className="card p-4">
            <h2 className="text-sm font-bold">Who owes what right now</h2>
            <div className="mt-2 grid grid-cols-3 gap-2 text-sm">
              <Stat label="Guests owe" value={money(o.guest_owed, c)} />
              <Stat label="Advances held" value={money(o.deposits_held, c)} />
              <Stat label="Companies owe" value={money(o.company_owed, c)} />
            </div>
            {o.guests.length > 0 && (
              <table className="mt-3 w-full text-sm">
                <thead><tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}><th>Guest</th><th>Room</th><th>Status</th><th className="text-right">Balance</th></tr></thead>
                <tbody>{o.guests.map((x) => (
                  <tr key={x.stay_id}><td><Link href={`/front-office/stay/${x.stay_id}`} className="underline">{x.guest} (#{x.stay_no})</Link></td><td>{x.room ?? "-"}</td><td>{x.status.replace("_", " ")}</td><td className="text-right">{x.balance < 0 ? `${money(-x.balance, c)} advance` : money(x.balance, c)}</td></tr>
                ))}</tbody>
              </table>
            )}
            {o.companies.length > 0 && (
              <table className="mt-3 w-full text-sm">
                <thead><tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}><th>Company</th><th className="text-right">Credit days</th><th className="text-right">Limit</th><th className="text-right">Owes</th></tr></thead>
                <tbody>{o.companies.map((x) => (
                  <tr key={x.company_id}><td><Link href={`/front-office/companies/${x.company_id}`} className="underline">{x.name}</Link></td><td className="text-right">{x.credit_days}</td><td className="text-right">{x.credit_limit == null ? "-" : money(x.credit_limit, c)}</td><td className="text-right">{money(x.outstanding, c)}</td></tr>
                ))}</tbody>
              </table>
            )}
            {o.guests.length === 0 && o.companies.length === 0 && <p className="mt-2 text-sm" style={{ color: "var(--color-ink-3)" }}>Nothing is outstanding.</p>}
          </section>
        )}

        {g && (
          <section className="card p-4">
            <h2 className="text-sm font-bold">GST summary (from issued invoices)</h2>
            {g.rows.length === 0 ? <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>No invoices issued in this range.</p> : (
              <>
                <table className="mt-2 w-full text-sm">
                  <thead><tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}><th>SAC</th><th className="text-right">Rate</th><th className="text-right">Taxable</th><th className="text-right">CGST</th><th className="text-right">SGST</th><th className="text-right">Tax</th></tr></thead>
                  <tbody>{g.rows.map((x) => (
                    <tr key={`${x.sac}-${x.tax_pct}`}><td>{x.sac}</td><td className="text-right">{x.tax_pct}%</td><td className="text-right">{money(x.taxable, c)}</td><td className="text-right">{money(x.cgst, c)}</td><td className="text-right">{money(x.sgst, c)}</td><td className="text-right">{money(x.tax, c)}</td></tr>
                  ))}</tbody>
                </table>
                <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                  {g.totals.invoices} invoices · taxable {money(g.totals.taxable, c)} · tax {money(g.totals.tax, c)} · B2B {g.totals.b2b_count} ({money(g.totals.b2b_taxable, c)}) · B2C {g.totals.b2c_count} ({money(g.totals.b2c_taxable, c)}). Rates are the hotel&apos;s settings; have an accountant confirm them before filing.
                </p>
              </>
            )}
          </section>
        )}

        {r && (
          <section className="card p-4">
            <h2 className="text-sm font-bold">Invoice register</h2>
            {r.rows.length === 0 ? <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>No invoices in this range.</p> : (
              <div className="mt-2 overflow-x-auto"><table className="w-full text-sm">
                <thead><tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}><th>Invoice</th><th>Date</th><th>Bill to</th><th>GSTIN</th><th className="text-right">Taxable</th><th className="text-right">CGST</th><th className="text-right">SGST</th><th className="text-right">Total</th></tr></thead>
                <tbody>{r.rows.map((x) => (
                  <tr key={x.invoice_no}><td><Link href={`/front-office/stay/${x.stay_id}/invoice`} className="underline">{x.invoice_no}</Link></td><td>{x.date}</td><td>{x.bill_to ?? "-"}</td><td>{x.gstin ?? "-"}</td><td className="text-right">{money(x.taxable, c)}</td><td className="text-right">{money(x.cgst, c)}</td><td className="text-right">{money(x.sgst, c)}</td><td className="text-right">{money(x.total, c)}</td></tr>
                ))}</tbody>
                <tfoot><tr className="font-bold"><td colSpan={4}>{r.totals.count} invoices</td><td className="text-right">{money(r.totals.taxable, c)}</td><td className="text-right" colSpan={2}>{money(r.totals.tax, c)}</td><td className="text-right">{money(r.totals.total, c)}</td></tr></tfoot>
              </table></div>
            )}
          </section>
        )}
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl p-2" style={{ border: "1px solid var(--color-line)" }}>
      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>{label}</div>
      <div className="font-extrabold">{value}</div>
    </div>
  );
}
