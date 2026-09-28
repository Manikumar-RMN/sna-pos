import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PriceEditor } from "./price-editor";

export default async function SnaPricesPage() {
  const supabase = await createClient();
  const { data: me } = await supabase.rpc("sna_me");
  if ((me as { role?: string } | null)?.role !== "admin") redirect("/sna");
  const [{ data: prices }, { data: modules }, { data: currencies }] = await Promise.all([
    supabase.from("plan_prices").select("item, currency_code, monthly_price"),
    supabase.from("modules").select("key, name, kind").eq("kind", "addon").order("display_order"),
    supabase.from("countries").select("default_currency").eq("is_supported", true),
  ]);
  const curr = [...new Set((currencies ?? []).map((c) => c.default_currency as string))].sort();
  const items = [
    { key: "basic", name: "Basic edition (per outlet)" },
    { key: "professional", name: "Professional edition (per outlet)" },
    ...(modules ?? []).map((m) => ({ key: m.key, name: m.name })),
  ];
  const map: Record<string, string> = {};
  for (const p of prices ?? []) map[`${p.item}|${p.currency_code}`] = p.monthly_price == null ? "" : String(p.monthly_price);
  return (
    <div>
      <h1 className="text-2xl font-bold">Monthly prices</h1>
      <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
        What each restaurant is charged per month, in its own currency. Empty means not priced yet. Changes apply to the monthly figure at once.
      </p>
      <PriceEditor items={items} currencies={curr} initial={map} />
    </div>
  );
}
