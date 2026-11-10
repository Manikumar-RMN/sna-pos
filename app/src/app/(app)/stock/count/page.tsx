import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { todayIn } from "@/lib/format";
import { UpgradeNote } from "../../upgrade-note";
import type { Level } from "../stock-manager";
import { CountSheet } from "../count-sheet";

export default async function StockCountPage() {
  const user = await requireUser();
  if (!can(user, "stock.adjust") && !can(user, "stock.manage")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role cannot count stock. An owner can give the &ldquo;Record wastage and stock counts&rdquo; right in Settings → Security profiles.
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
  const supabase = await createClient();
  const today = todayIn(user.timezone);
  const { data: report } = await supabase.rpc("stock_report", { p_from: today, p_to: today });
  const levels = ((report ?? { levels: [] }) as unknown as { levels: Level[] }).levels;
  const openedAt = new Date().toISOString();
  return (
    <div className="mx-auto max-w-4xl">
      <Link href="/stock" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← Stock
      </Link>
      <h1 className="mt-2 text-xl font-bold tracking-tight">Stock count · {user.branch_name}</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Count what is on the shelf and type it in. Leave an ingredient empty if you did not count it: it stays as it is. Stock is corrected
        for this outlet only.
      </p>
      <CountSheet
        openedAt={openedAt}
        currency={user.currency_code}
        rows={levels.map((l) => ({
          id: l.id,
          name: l.name,
          unit: l.unit,
          cost: Number(l.cost),
          expected: Number(l.stock),
          category: l.category ?? "",
        }))}
      />
    </div>
  );
}
