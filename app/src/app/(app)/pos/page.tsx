import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { getLicence } from "@/lib/licence";
import { OpenShiftForm } from "../shift/shift-panel";
import { PosTerminal, type AddTo, type OptionGroup, type PackingRule } from "./pos-terminal";
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
    { data: menu },
    { data: methods },
    { data: shift, settings },
    { data: tables },
    { data: openTabs },
    { data: groups },
    { data: country },
    { data: links },
    { data: optGroups },
    { data: optItems },
    { data: sizeRows },
  ] = await Promise.all([
    supabase
      .from("v_menu")
      .select("id, name, short_name, price, category_id, category_name, category_order, is_veg, display_order, is_available, name_local, parent_id, variant_name, is_combo")
      .eq("is_available", true)
      .order("category_order")
      .order("display_order")
      .order("name"),
    supabase.from("payment_methods").select("id, name, kind, ask_reference, upi_id").eq("is_active", true).not("kind", "in", "(gift_card,loyalty)").order("display_order"),
    // One read of this outlet's settings: whether shifts are used, and its packing charge rule.
    // Shifts are optional: when they are off, the first bill opens the drawer automatically.
    supabase
      .from("branch_settings")
      .select("shifts_enabled, packing_product_id, packing_per, packing_takeaway, packing_delivery")
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
    supabase.from("product_modifier_groups").select("product_id, modifier_group_id"),
    supabase.from("modifier_groups").select("id, name, min_select, max_select, is_required, is_active").eq("is_active", true),
    supabase.from("modifier_items").select("id, modifier_group_id, name, price_delta, display_order, product_id").eq("is_active", true).order("display_order").order("name"),
    // Dishes that have sizes (even sold-out ones): such a dish is sold only through one of its sizes.
    supabase.from("products").select("parent_id").not("parent_id", "is", null).is("deleted_at", null),
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

  const onSale = new Set((menu ?? []).map((x) => x.id as string));
  // Option groups per menu item, in the order the kitchen expects: required choices first.
  const groupById = new Map(
    (optGroups ?? []).map((g) => {
      const min = Math.max(g.min_select ?? 0, g.is_required ? 1 : 0);
      const group: OptionGroup = {
        id: g.id,
        name: g.name,
        min,
        max: Math.max(g.max_select ?? 1, min, 1),
        options: (optItems ?? [])
          // A combo choice that is a dish shows only while that dish is on sale (not sold out).
          .filter((i) => i.modifier_group_id === g.id && (!i.product_id || onSale.has(i.product_id)))
          .map((i) => ({ id: i.id, name: i.name, price: Number(i.price_delta ?? 0) })),
      };
      return [g.id, group];
    }),
  );
  const groupsFor = (productId: string) =>
    (links ?? [])
      .filter((l) => l.product_id === productId)
      .map((l) => groupById.get(l.modifier_group_id))
      .filter((g): g is OptionGroup => !!g && g.options.length > 0)
      .sort((a, b) => b.min - a.min || a.name.localeCompare(b.name));

  const hasSizes = new Set((sizeRows ?? []).map((r) => r.parent_id as string));
  const live = (menu ?? []).filter((x) => x.id && x.name && x.category_id);
  // The sizes on sale for each dish, cheapest first.
  const sizesFor = (dishId: string) =>
    live
      .filter((x) => x.parent_id === dishId)
      .map((x) => ({ id: x.id as string, name: (x.variant_name ?? x.name) as string, price: Number(x.price) }))
      .sort((a, b) => a.price - b.price || a.name.localeCompare(b.name));
  const items = live
    // A dish with sizes, all of them sold out, is not on sale.
    .filter((x) => !hasSizes.has(x.id as string) || sizesFor(x.id as string).length > 0)
    .map((x) => ({
      id: x.id as string,
      name: x.name as string,
      short_name: x.short_name,
      price: Number(x.price),
      category_id: x.category_id as string,
      category_name: x.category_name ?? "",
      is_veg: x.is_veg,
      groups: groupsFor(x.id as string),
      name_local: x.name_local,
      /** Set on a size: the dish it belongs to. Sizes are not shown as cards of their own. */
      variantOf: (x.parent_id as string | null) ?? null,
      /** Set on a dish that has sizes: tapping it asks which size. */
      variants: hasSizes.has(x.id as string) ? sizesFor(x.id as string) : undefined,
      /** A combo / meal deal: shown with a "combo" mark. */
      isCombo: !!x.is_combo,
    }));

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

/** Sub-category id → its main category, for the billing screen's category tabs. */
async function subCategoryParents(): Promise<Record<string, { id: string; name: string }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("categories").select("id, name, parent_id").is("deleted_at", null);
  if (error || !data) return {};
  const names = new Map(data.map((c) => [c.id, c.name]));
  const out: Record<string, { id: string; name: string }> = {};
  for (const c of data) if (c.parent_id && names.has(c.parent_id)) out[c.id] = { id: c.parent_id, name: names.get(c.parent_id)! };
  return out;
}
