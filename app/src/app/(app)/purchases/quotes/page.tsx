import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import { todayIn } from "@/lib/format";
import { UpgradeNote } from "../../upgrade-note";
import { isUuid } from "../helpers";
import { QuoteBoard, type RfqDetail, type RfqSummary } from "./quote-board";

export default async function QuotesPage({ searchParams }: { searchParams: Promise<{ id?: string }> }) {
  const user = await requireUser();
  if (!can(user, "stock.manage")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include purchases. An owner can give the &ldquo;Manage stock&rdquo; right in Settings → Security profiles.
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
  const supabase = await createClient();
  const open = sp.id && isUuid(sp.id) ? sp.id : null;
  const [{ data: list, error }, { data: ings }, { data: sups }, detail] = await Promise.all([
    supabase.rpc("list_rfqs", {}),
    supabase.from("ingredients").select("id, name, unit, is_active").order("name"),
    supabase.from("suppliers").select("id, name, is_active, blocked").order("name"),
    open ? supabase.rpc("get_rfq", { p_rfq: open }) : Promise.resolve({ data: null, error: null }),
  ]);
  return (
    <div className="mx-auto max-w-5xl">
      <Link href="/purchases" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← Purchases
      </Link>
      <h1 className="mt-2 text-xl font-bold tracking-tight">Compare supplier quotes</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Ask two or more suppliers to price the same list, type in their rates as they reply, and see the cheapest for each item. Choosing a supplier for each item makes the purchase orders for you.
      </p>
      {error ? (
        <div className="card p-5 text-sm" role="alert">
          Could not load the requests. {friendlyDbError(error)}
        </div>
      ) : (
        <QuoteBoard
          requests={(list ?? []) as unknown as RfqSummary[]}
          detail={detail.error ? null : ((detail.data ?? null) as unknown as RfqDetail | null)}
          detailError={detail.error ? friendlyDbError(detail.error) : null}
          currency={user.currency_code}
          today={todayIn(user.timezone)}
          suppliers={(sups ?? []).filter((s) => s.is_active && !s.blocked).map((s) => ({ id: s.id, name: s.name }))}
          ingredients={(ings ?? []).filter((i) => i.is_active).map((i) => ({ id: i.id, name: i.name, unit: i.unit }))}
        />
      )}
    </div>
  );
}
