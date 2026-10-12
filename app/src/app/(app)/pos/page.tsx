import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { getLicence } from "@/lib/licence";
import { OpenShiftForm } from "../shift/shift-panel";
import { PosTerminal, type AddTo, type PackingRule } from "./pos-terminal";
import { loadMenu, subCategoryParents } from "./menu-data";
import { byTableNumber } from "@/lib/table-order";

export default async function PosPage({ searchParams }: { searchParams: Promise<{ add?: string }> }) {
  const user = await requireUser();
  const supabase = await createClient();
  const { add } = await searchParams;

  if (!can(user, "order.create")) {
    return (
      <div className="mx-auto max-w-md">
        <h1 className="text-xl font-bold tracking-tight">Billing</h1>
        <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          Your role does not include taking orders. Ask an owner or manager for the <span className="font-semibold">Cashier</span> role.
        </div>
      </div>
    );
  }

  // RLS scopes every query below to the signed-in user's restaurant.
  const [
    items,
    { data: methods },
    { data: shift, settings },
    { data: tables },
    { data: openTabs },
    { data: groups },
    { data: country },
  ] = await Promise.all([
    loadMenu(),
    supabase.from("payment_methods").select("id, name, kind, ask_reference, upi_id").eq("is_active", true).not("kind", "in", "(gift_card,loyalty)").order("display_order"),
    // One read of this outlet's settings: whether shifts are used, and its packing charge rule.
    // Shifts are optional: when they are off, the first bill opens the drawer automatically.
    supabase
      .from("branch_settings")
      .select("shifts_enabled, packing_product_id, packing_per, packing_takeaway, packing_delivery, order_types, default_order_type")
      .eq("branch_id", user.branch_id)
      .maybeSingle()
      .then(async (bs) => ({
        settings: bs.data,
        data: bs.data?.shifts_enabled ? (await supabase.from("shifts").select("id").eq("status", "open").limit(1).maybeSingle()).data : { id: "auto" },
      })),
    supabase.from("dining_tables").select("id, table_number").eq("is_active", true).order("table_number"),
    supabase
      .from("orders")
      .select("id, bill_number, dining_table_id")
      .in("payment_status", ["unpaid", "partial"])
      .neq("status", "voided")
      .not("dining_table_id", "is", null)
      .order("created_at"),
    supabase.from("tax_groups").select("is_price_inclusive").eq("is_active", true),
    supabase.from("countries").select("tax_system_name, has_senior_discount").eq("code", user.country_code).maybeSingle(),
  ]);

  if (!shift) {
    return (
      <div className="mx-auto max-w-md">
        <h1 className="mb-4 text-xl font-bold tracking-tight">Billing</h1>
        <OpenShiftForm canOpen={can(user, "shift.open")} compact />
      </div>
    );
  }

  let addTo: AddTo | null = null;
  if (add) {
    const { data: o } = await supabase
      .from("orders")
      .select("id, bill_number, status, payment_status, dining_tables!orders_dining_table_id_fkey(table_number)")
      .eq("id", add)
      .maybeSingle();
    if (!o || o.status === "voided" || !["unpaid", "partial"].includes(o.payment_status ?? "")) {
      return (
        <div className="mx-auto max-w-md">
          <h1 className="text-xl font-bold tracking-tight">Add items</h1>
          <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
            That bill is already paid or voided, so items cannot be added to it.{" "}
            <Link href="/pos" className="font-semibold" style={{ color: "var(--color-brand)" }}>
              Start a new bill
            </Link>
            .
          </div>
        </div>
      );
    }
    addTo = { id: o.id, billNumber: o.bill_number, table: o.dining_tables?.table_number ?? null };
  }

  // The packing charge is an ordinary menu item. If it is not on today's menu (e.g. marked unavailable), there is no packing charge.
  const packingItem = settings?.packing_product_id ? items.find((x) => x.id === settings.packing_product_id) : undefined;
  const packing: PackingRule | null =
    settings && packingItem
      ? {
          productId: packingItem.id,
          price: packingItem.price,
          per: settings.packing_per === "item" ? "item" : "bill",
          takeaway: !!settings.packing_takeaway,
          delivery: !!settings.packing_delivery,
        }
      : null;

  if (items.every((x) => x.id === packing?.productId)) {
    return (
      <div className="mx-auto max-w-md">
        <h1 className="text-xl font-bold tracking-tight">Billing</h1>
        <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          There is nothing to sell yet. Add categories and items on the{" "}
          <Link href="/settings/menu" className="font-semibold" style={{ color: "var(--color-brand)" }}>
            Menu
          </Link>{" "}
          screen, then come back here to bill.
        </div>
      </div>
    );
  }

  const tableOrdersWaiting = has(user, "qr_ordering")
    ? ((await supabase.from("qr_orders").select("id", { count: "exact", head: true }).eq("status", "pending")).count ?? 0)
    : 0;

  // Every unpaid or part-paid bill of each table, oldest first.
  const openByTable = new Map<string, { id: string; billNumber: string }[]>();
  for (const o of openTabs ?? []) {
    if (!o.dining_table_id) continue;
    const list = openByTable.get(o.dining_table_id) ?? [];
    list.push({ id: o.id, billNumber: o.bill_number });
    openByTable.set(o.dining_table_id, list);
  }

  return (
    <PosTerminal
      orderTypes={(settings?.order_types ?? []).filter((t): t is "dine_in" | "takeaway" | "delivery" => t === "dine_in" || t === "takeaway" || t === "delivery")}
      startType={settings?.default_order_type}
      key={addTo?.id ?? "new"}
      currency={user.currency_code}
      canDiscount={can(user, "order.discount")}
      canPay={can(user, "payment.take")}
      showSenior={!!country?.has_senior_discount}
      upiPayee={user.country_code === "IN" ? user.trading_name : null}
      pricesIncludeTax={(groups ?? []).some((g) => g.is_price_inclusive)}
      taxName={country?.tax_system_name ?? "tax"}
      menu={items}
      paymentMethods={methods ?? []}
      tables={[...(tables ?? [])].sort(byTableNumber).map((t) => ({
        id: t.id,
        number: t.table_number,
        busy: openByTable.has(t.id),
        openBills: openByTable.get(t.id) ?? [],
      }))}
      packing={packing}
      addTo={addTo}
      allowHold={has(user, "courses")}
      customerDisplay={has(user, "customer_display") ? user.trading_name : null}
      tableOrdersWaiting={tableOrdersWaiting}
      licenceLockAt={(await getLicence()).lock_at ?? null}
      categoryParents={await subCategoryParents()}
    />
  );
}
