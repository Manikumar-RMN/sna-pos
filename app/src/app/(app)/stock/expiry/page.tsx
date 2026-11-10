import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import { money } from "@/lib/format";
import { UpgradeNote } from "../../upgrade-note";
import { dayLabel } from "../../purchases/helpers";

type Item = { ingredient: string; unit: string; batch_no: string | null; expiry_date: string; received_on: string; receipt: string; remaining: number; value: number; days_left: number; status: "expired" | "soon" | "ok" };

const STATUS = {
  expired: { label: "Expired", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
  soon: { label: "Expiring soon", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  ok: { label: "Fine", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
} as const;

export default async function ExpiryPage({ searchParams }: { searchParams: Promise<{ days?: string }> }) {
  const user = await requireUser();
  if (!can(user, "stock.manage")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include managing stock. An owner can change this in Settings → Security profiles.
      </div>
    );
  }
  if (!has(user, "stock")) {
    return (
      <div className="mx-auto max-w-md">
        <UpgradeNote feature="Stock and recipes" />
      </div>
    );
  }
  const sp = await searchParams;
  const days = [7, 14, 30, 60, 90].includes(Number(sp.days)) ? Number(sp.days) : 30;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("expiry_report", { p_days: days });
  const m = (n: number) => money(n, user.currency_code);
  const items = ((data as { items?: Item[] } | null)?.items ?? []).map((i) => ({ ...i, remaining: Number(i.remaining), value: Number(i.value), days_left: Number(i.days_left) }));
  const sum = (s: Item["status"]) => items.filter((i) => i.status === s).reduce((a, i) => a + i.value, 0);
  return (
    <div className="mx-auto max-w-4xl">
      <Link href="/stock" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← Stock
      </Link>
      <h1 className="mt-2 text-xl font-bold tracking-tight">Expiry · {user.branch_name}</h1>
      <p className="mt-1 mb-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Batches that are still on the shelf, soonest expiry first. The stock you hold is counted as the newest deliveries (first in, first out). Enter a batch number and best-before date when you receive goods.
      </p>
      <div className="mb-4 flex flex-wrap items-center gap-1.5">
        <span className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
          Expiring within
        </span>
        {[7, 14, 30, 60, 90].map((d) => (
          <Link key={d} href={`/stock/expiry?days=${d}`} scroll={false} aria-current={d === days ? "true" : undefined} className="btn border px-3 text-sm" style={d === days ? { background: "var(--color-brand)", color: "#fff", borderColor: "var(--color-brand)" } : { borderColor: "var(--color-line)" }}>
            {d} days
          </Link>
        ))}
      </div>
      {error ? (
        <div className="card p-4 text-sm" style={{ color: "var(--color-bad)" }}>
          Could not load the expiry list: {friendlyDbError(error)}
        </div>
      ) : (
        <>
          <div className="mb-4 grid gap-3 sm:grid-cols-2">
            <div className="card p-4">
              <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
                Expired, still on the shelf
              </div>
              <div className="font-display mt-1 text-2xl font-bold tabular-nums" style={{ color: sum("expired") > 0 ? "var(--color-bad)" : undefined }}>
                {m(sum("expired"))}
              </div>
            </div>
            <div className="card p-4">
              <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
                Expiring within {days} days
              </div>
              <div className="font-display mt-1 text-2xl font-bold tabular-nums">{m(sum("soon"))}</div>
            </div>
          </div>
          <div className="card overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr style={{ color: "var(--color-ink-3)" }}>
                  <th className="px-3 py-2 text-left text-xs font-semibold">Ingredient</th>
                  <th className="px-3 py-2 text-left text-xs font-semibold">Batch</th>
                  <th className="px-3 py-2 text-left text-xs font-semibold">Best before</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">On shelf</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">Value</th>
                  <th className="px-3 py-2 text-left text-xs font-semibold">Status</th>
                </tr>
              </thead>
              <tbody>
                {items.length === 0 && (
                  <tr>
                    <td colSpan={6} className="px-3 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                      No batch with an expiry date is on the shelf.
                    </td>
                  </tr>
                )}
                {items.map((i, k) => {
                  const s = STATUS[i.status];
                  return (
                    <tr key={k} style={{ borderTop: "1px solid var(--color-line)" }}>
                      <td className="px-3 py-2">{i.ingredient}</td>
                      <td className="px-3 py-2">
                        {i.batch_no ?? "—"}
                        <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                          {i.receipt} · {dayLabel(i.received_on)}
                        </div>
                      </td>
                      <td className="px-3 py-2">
                        {dayLabel(i.expiry_date)}
                        <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                          {i.days_left < 0 ? `${-i.days_left} day${i.days_left === -1 ? "" : "s"} ago` : i.days_left === 0 ? "today" : `in ${i.days_left} day${i.days_left === 1 ? "" : "s"}`}
                        </div>
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums">
                        {i.remaining} {i.unit}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums">{m(i.value)}</td>
                      <td className="px-3 py-2">
                        <span className="rounded-full px-2 py-0.5 text-xs font-bold" style={{ background: s.bg, color: s.fg }}>
                          {s.label}
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <p className="mt-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
            To take expired stock off the shelf, record it as wastage on the Stock screen.
          </p>
        </>
      )}
    </div>
  );
}
