import Link from "next/link";
import { notFound } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { longDate, money, todayIn } from "@/lib/format";
import { formatPhone, lastVisitText, ledgerKindLabel, parseCustomerDetail, signedPoints, POINTS_DO_NOT_EXPIRE } from "@/lib/customers";
import { friendlyDbError } from "@/lib/db-error";
import { EditForm } from "./edit-form";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** One guest: profile (editable with customer.manage), stat tiles, paid bills, points history. */
export default async function CustomerPage({ params }: { params: Promise<{ id: string }> }) {
  const user = await requireUser();
  if (!can(user, "customer.view") && !can(user, "customer.manage")) {
    return <p className="card mx-auto mt-4 max-w-md p-5 text-sm">Your role cannot open the guest list. Ask an owner or manager.</p>;
  }
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("customer_detail", { p_customer: id });
  if (error) {
    return (
      <div className="mx-auto max-w-2xl space-y-3">
        <Link href="/customers" className="text-sm font-semibold">← Customers</Link>
        <p role="alert" className="card p-4 text-sm font-semibold" style={{ color: "var(--color-bad)" }}>{friendlyDbError(error)}</p>
      </div>
    );
  }
  const c = parseCustomerDetail(data);
  if (!c) notFound();

  const today = todayIn(user.timezone);
  const m = (n: number) => money(n, user.currency_code);
  const loyalty = has(user, "loyalty");
  const erased = c.name === "Deleted guest" && !c.phone;
  const tiles: [string, string][] = [
    ["Visits", String(c.visits)],
    ["Total spend", m(c.spend)],
    ["Average bill", c.visits > 0 ? m(c.avgBill) : "—"],
    ["Last visit", lastVisitText(c.lastVisitOn, today)],
    ...(loyalty ? [["Points", String(c.points)] as [string, string]] : []),
  ];

  return (
    <div className="mx-auto max-w-4xl space-y-4">
      <div>
        <Link href="/customers" className="text-sm font-semibold">← Customers</Link>
        <h1 className="mt-1 text-xl font-bold tracking-tight">{c.name}</h1>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          {formatPhone(c.phone)}{c.firstVisitOn ? ` · first visit ${longDate(c.firstVisitOn)}` : ""}
        </p>
      </div>

      <section className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-5" aria-label="Guest totals">
        {tiles.map(([label, value]) => (
          <div key={label} className="card p-3">
            <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>{label}</div>
            <div className="text-lg font-bold tabular-nums">{value}</div>
          </div>
        ))}
      </section>
      {c.accountBalance !== null && c.accountBalance !== 0 && (
        <p className="card p-3 text-sm">
          Credit account: this guest owes <b>{m(c.accountBalance)}</b>. <Link className="font-semibold underline" href="/accounts">Open customer accounts</Link>
        </p>
      )}

      {!erased && (
        <EditForm
          customer={{ id: c.id, name: c.name, email: c.email ?? "", notes: c.notes ?? "", birthday: c.birthday ?? "", consent: c.marketingConsent, consentGivenAt: c.consentGivenAt }}
          canEdit={can(user, "customer.manage")}
          today={today}
          hasAccountBalance={c.accountBalance !== null && c.accountBalance !== 0}
        />
      )}
      {erased && <p className="card p-4 text-sm" style={{ color: "var(--color-ink-3)" }}>This guest&apos;s personal data was deleted. Bills and totals are kept without a name or phone.</p>}

      <section className="card p-4">
        <h2 className="mb-2 text-sm font-bold">Bills (last 50)</h2>
        {c.bills.length === 0 ? (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No bills yet.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}>
                  <th className="py-1">Bill</th><th>Date</th><th>Outlet</th><th>Paid by</th><th className="text-right">Total</th><th className="text-right">Refunded</th>
                  {loyalty && <th className="text-right">Points</th>}
                </tr>
              </thead>
              <tbody>
                {c.bills.map((b) => (
                  <tr key={b.id} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                    <td className="py-1.5"><Link className="font-semibold underline-offset-2 hover:underline" href={`/bills/${b.id}`}>{b.billNumber || "Bill"}</Link>{!b.isVisit && <span className="ml-1 text-xs" style={{ color: "var(--color-ink-3)" }}>({b.status === "voided" ? "voided" : "not paid"})</span>}</td>
                    <td>{b.businessDate ? longDate(b.businessDate) : "—"}</td>
                    <td>{b.outlet ?? "—"}</td>
                    <td>{b.paymentMode ?? "—"}</td>
                    <td className="text-right tabular-nums">{m(b.total)}</td>
                    <td className="text-right tabular-nums">{b.refunded > 0 ? m(b.refunded) : "—"}</td>
                    {loyalty && (
                      <td className="text-right tabular-nums">
                        {b.pointsEarned > 0 ? `+${b.pointsEarned}` : ""}{b.pointsEarned > 0 && b.pointsRedeemed > 0 ? " / " : ""}{b.pointsRedeemed > 0 ? `−${b.pointsRedeemed}` : ""}
                        {b.pointsEarned <= 0 && b.pointsRedeemed <= 0 ? "—" : ""}
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {loyalty && (
        <section className="card p-4">
          <h2 className="mb-1 text-sm font-bold">Points · balance {c.points}</h2>
          <p className="mb-2 text-xs" style={{ color: "var(--color-ink-3)" }}>{c.expiryNote ?? POINTS_DO_NOT_EXPIRE}</p>
          {c.ledger.length === 0 ? (
            <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No points yet.</p>
          ) : (
            <ul className="space-y-0.5 text-sm">
              {c.ledger.map((l, i) => (
                <li key={i} className="flex justify-between gap-2">
                  <span>
                    {l.at ? new Date(l.at).toLocaleDateString("en-IN", { timeZone: user.timezone, day: "2-digit", month: "short", year: "numeric" }) : ""} · {ledgerKindLabel(l.kind)}
                    {l.billNumber ? ` · ${l.billNumber}` : ""}{l.note ? ` · ${l.note}` : ""}
                  </span>
                  <b className="tabular-nums">{signedPoints(l.points)}</b>
                </li>
              ))}
            </ul>
          )}
        </section>
      )}
    </div>
  );
}
