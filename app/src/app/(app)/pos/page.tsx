import Link from "next/link";
import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { OpenShiftForm } from "../shift/shift-panel";
import { PosTerminal } from "./pos-terminal";

export default async function PosPage() {
  const user = await requireUser();
  const supabase = await createClient();

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
  const [{ data: menu }, { data: methods }, { data: shift }, { data: tables }, { data: openTabs }, { data: groups }, { data: country }] =
    await Promise.all([
      supabase
        .from("v_menu")
        .select("id, name, short_name, price, category_id, category_name, category_order, is_veg, display_order, is_available")
        .eq("is_available", true)
        .order("category_order")
        .order("display_order")
        .order("name"),
      supabase.from("payment_methods").select("id, name, kind").eq("is_active", true).order("display_order"),
      supabase.from("shifts").select("id").eq("status", "open").limit(1).maybeSingle(),
      supabase.from("dining_tables").select("id, table_number").eq("is_active", true).order("table_number"),
      supabase
        .from("orders")
        .select("dining_table_id")
        .eq("payment_status", "unpaid")
        .neq("status", "voided")
        .not("dining_table_id", "is", null),
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

  const items = (menu ?? [])
    .filter((x) => x.id && x.name && x.category_id)
    .map((x) => ({
      id: x.id as string,
      name: x.name as string,
      short_name: x.short_name,
      price: Number(x.price),
      category_id: x.category_id as string,
      category_name: x.category_name ?? "",
      is_veg: x.is_veg,
    }));

  if (items.length === 0) {
    return (
      <div className="mx-auto max-w-md">
        <h1 className="text-xl font-bold tracking-tight">Billing</h1>
        <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          There is nothing to sell yet. Add categories and items on the{" "}
          <Link href="/menu" className="font-semibold" style={{ color: "var(--color-brand)" }}>
            Menu
          </Link>{" "}
          screen, then come back here to bill.
        </div>
      </div>
    );
  }

  const busy = new Set((openTabs ?? []).map((o) => o.dining_table_id as string));

  return (
    <PosTerminal
      currency={user.currency_code}
      canDiscount={can(user, "order.discount")}
      showSenior={!!country?.has_senior_discount}
      pricesIncludeTax={(groups ?? []).some((g) => g.is_price_inclusive)}
      taxName={country?.tax_system_name ?? "tax"}
      menu={items}
      paymentMethods={methods ?? []}
      tables={(tables ?? []).map((t) => ({ id: t.id, number: t.table_number, busy: busy.has(t.id) }))}
    />
  );
}
