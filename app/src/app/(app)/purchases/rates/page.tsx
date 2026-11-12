import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { todayIn } from "@/lib/format";
import { UpgradeNote } from "../../upgrade-note";
import { RateBoard, type RateRow } from "./rate-board";

export default async function RatesPage({ searchParams }: { searchParams: Promise<{ from?: string }> }) {
  const from = (await searchParams).from;
  const fromSettings = from === "settings";
  const embedded = from === "embedded";
  const user = await requireUser();
  const canManage = can(user, "stock.manage");
  if (!canManage && !can(user, "stock.view")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include stock or purchases. An owner can change this in Settings → Security profiles.
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
  const [{ data: ings }, { data: sups }, { data: rates }] = await Promise.all([
    supabase.from("ingredients").select("id, name, unit, is_active").order("name"),
    supabase.from("suppliers").select("id, name, is_active").order("name"),
    supabase.from("supplier_rates").select("id, supplier_id, ingredient_id, rate, valid_from, valid_to, notes").is("ended_at", null).order("valid_from", { ascending: false }).limit(500),
  ]);
  const ing = new Map<string, { name: string; unit: string }>((ings ?? []).map((i) => [i.id, { name: i.name, unit: i.unit }]));
  const sup = new Map((sups ?? []).map((s) => [s.id, s.name]));
  const rows: RateRow[] = (rates ?? []).map((r) => ({
    id: r.id,
    supplier: sup.get(r.supplier_id) ?? "Supplier",
    item: ing.get(r.ingredient_id)?.name ?? "Ingredient",
    unit: ing.get(r.ingredient_id)?.unit ?? "",
    rate: Number(r.rate),
    from: r.valid_from,
    to: r.valid_to,
    notes: r.notes,
  }));
  return (
    <div className="mx-auto max-w-4xl">
      {!embedded && (
        <Link href={fromSettings ? "/settings" : "/purchases"} className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
          {fromSettings ? "← Setup" : "← Purchases"}
        </Link>
      )}
      <h1 className="mt-2 text-xl font-bold tracking-tight">Agreed supplier rates</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        The price a supplier has agreed for an ingredient. New deliveries from that supplier start from this price, and the Rate variance report shows where the price paid was different. Rates are before tax and per stock unit.
      </p>
      <RateBoard
        canManage={canManage}
        currency={user.currency_code}
        today={todayIn(user.timezone)}
        suppliers={(sups ?? []).filter((s) => s.is_active).map((s) => ({ id: s.id, name: s.name }))}
        ingredients={(ings ?? []).filter((i) => i.is_active).map((i) => ({ id: i.id, name: i.name, unit: i.unit }))}
        rates={rows}
      />
    </div>
  );
}
