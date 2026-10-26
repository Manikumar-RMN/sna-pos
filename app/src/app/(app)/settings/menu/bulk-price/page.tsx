import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { NoAccess, SectionHead } from "../../section-head";
import { BulkPrice } from "./bulk-price";
import { loadBulkPriceHistory } from "./actions";

export default async function BulkPricePage() {
  const user = await requireUser();
  if (!can(user, "menu.price_change")) {
    return (
      <div>
        <SectionHead title="Change many prices at once" />
        <NoAccess />
      </div>
    );
  }
  const supabase = await createClient();
  const [{ data: categories }, { data: products }, history] = await Promise.all([
    supabase.from("categories").select("id, name, parent_id").is("deleted_at", null).order("display_order").order("name"),
    supabase.from("products").select("id, name, category_id").is("deleted_at", null).order("name"),
    loadBulkPriceHistory(),
  ]);

  return (
    <div>
      <Link href="/settings/menu" className="text-sm font-bold" style={{ color: "var(--color-brand)" }}>
        &larr; Menu
      </Link>
      <div className="mt-2">
        <SectionHead title="Change many prices at once">
          Raise or lower a whole category, or the dishes you pick, by a percentage or an amount. You see every new price first. Bills that are already open keep the price they were rung at, and a change can be undone.
        </SectionHead>
      </div>
      <BulkPrice
        currency={user.currency_code}
        showOutlets={has(user, "multi_outlet")}
        categories={(categories ?? []).map((c) => ({ id: c.id, name: c.name, parent_id: c.parent_id ?? null }))}
        products={(products ?? []).map((p) => ({ id: p.id, name: p.name, category_id: p.category_id }))}
        history={history.ok ? history.rows : []}
        historyError={history.ok ? null : history.error}
      />
    </div>
  );
}
