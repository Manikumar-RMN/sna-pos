import Link from "next/link";
import { createConsoleClient as createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import { toneStyle } from "../crm";
import { UnpaidTable, type UnpaidRow } from "./unpaid-table";

type Unpaid = {
  today: string;
  totals: { currency: string; total: number; count: number; overdue: number }[];
  rows: UnpaidRow[];
};

/** Everything SNA has sold that has not been paid yet, across all clients, oldest first. */
export default async function SnaMoney() {
  const supabase = await createClient();
  const [{ data: me }, { data, error }] = await Promise.all([supabase.rpc("sna_me"), supabase.rpc("sna_unpaid")]);
  const role = (me as { role?: string } | null)?.role ?? "support";
  const u = (data ?? null) as unknown as Unpaid | null;
  const canEdit = role === "admin" || role === "sales";
  const rows = u?.rows ?? [];
  const overdue = rows.filter((r) => r.days_overdue !== null).length;

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-2xl font-bold">Money owed to SNA</h1>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          Every sale not yet marked paid, across all clients. Oldest first. A sale with a due date is overdue the day after it; one without a due date shows how long ago it was sold.
        </p>
      </div>
      {error && <div className="card p-3 text-sm">{error.message}</div>}

      <div className="grid grid-cols-2 gap-2 lg:grid-cols-4">
        {(u?.totals ?? []).map((t) => (
          <div key={t.currency} className="card p-3">
            <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Unpaid in {t.currency}
            </div>
            <div className="mt-0.5 text-2xl font-bold tabular-nums">{money(Number(t.total), t.currency)}</div>
            <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
              {t.count} {t.count === 1 ? "sale" : "sales"}
              {t.overdue > 0 ? ` · ${t.overdue} overdue` : ""}
            </div>
          </div>
        ))}
        <div className="card p-3">
          <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
            Overdue
          </div>
          <div className="mt-0.5 text-2xl font-bold tabular-nums" style={overdue > 0 ? { color: "var(--color-bad)" } : undefined}>
            {overdue}
          </div>
          <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            past the due date you set
          </div>
        </div>
      </div>

      {rows.length === 0 ? (
        <div className="card p-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
          <span className="rounded-full px-3 py-1 text-xs font-bold" style={toneStyle.ok}>
            All paid
          </span>
          <p className="mt-3">Nothing is waiting to be paid. Record a sale on a client&rsquo;s Sales history tab and it will show here until it is marked paid.</p>
          <Link href="/sna" className="mt-2 inline-block font-semibold" style={{ color: "var(--color-brand)" }}>
            Back to clients
          </Link>
        </div>
      ) : (
        <UnpaidTable rows={rows} today={u?.today ?? ""} canEdit={canEdit} />
      )}
    </div>
  );
}
