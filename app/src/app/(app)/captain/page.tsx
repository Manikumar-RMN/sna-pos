import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { byTableNumber } from "@/lib/table-order";
import { OpenShiftForm } from "../shift/shift-panel";
import { loadMenu, subCategoryParents } from "../pos/menu-data";
import { Captain, type CaptainTable } from "./captain";

/** Captain app: waiters take orders on a phone at the table and send them to the kitchen. No payment here. */
export default async function CaptainPage() {
  const user = await requireUser();
  if (!can(user, "order.create")) {
    return (
      <div className="card mx-auto mt-4 max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include taking orders. Ask an owner or manager.
      </div>
    );
  }
  const supabase = await createClient();
  const [{ data: bs }, { data: tables }, { data: open }, items, parents] = await Promise.all([
    supabase.from("branch_settings").select("shifts_enabled, packing_product_id").eq("branch_id", user.branch_id).maybeSingle(),
    supabase.from("dining_tables").select("id, table_number, seats").eq("is_active", true),
    supabase
      .from("orders")
      .select("id, bill_number, dining_table_id, grand_total, created_at, covers")
      .in("payment_status", ["unpaid", "partial"])
      .neq("status", "voided")
      .not("dining_table_id", "is", null)
      .order("created_at"),
    loadMenu(),
    subCategoryParents(),
  ]);
  if (bs?.shifts_enabled) {
    const { data: shift } = await supabase.from("shifts").select("id").eq("status", "open").limit(1).maybeSingle();
    if (!shift) {
      return (
        <div className="mx-auto max-w-md">
          <h1 className="mb-4 text-xl font-bold tracking-tight">Captain</h1>
          <OpenShiftForm canOpen={can(user, "shift.open")} compact />
        </div>
      );
    }
  }

  const list: CaptainTable[] = (tables ?? [])
    .slice()
    .sort(byTableNumber)
    .map((t) => ({
      id: t.id,
      number: t.table_number,
      seats: t.seats ?? null,
      bills: (open ?? [])
        .filter((o) => o.dining_table_id === t.id)
        .map((o) => ({ id: o.id, billNumber: o.bill_number, total: Number(o.grand_total ?? 0), since: o.created_at, covers: o.covers ?? null })),
    }));

  return (
    <Captain
      currency={user.currency_code}
      tables={list}
      menu={items.filter((x) => x.id !== bs?.packing_product_id)}
      categoryParents={parents}
    />
  );
}
