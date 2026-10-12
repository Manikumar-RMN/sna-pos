import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { loadMenu, subCategoryParents } from "../pos/menu-data";
import { PreOrders, type PreOrder } from "./pre-orders";

/** Pre-orders: cakes and party orders booked for later, with an advance. */
export default async function PreOrdersPage({ searchParams }: { searchParams: Promise<{ show?: string }> }) {
  const user = await requireUser();
  const { show } = await searchParams;
  if (!can(user, "order.create")) {
    return (
      <div className="card mx-auto mt-4 max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include taking orders. Ask an owner or manager.
      </div>
    );
  }
  const supabase = await createClient();
  const done = show === "done";
  const [{ data: list }, { data: methods }, menu, parents, { data: tz }] = await Promise.all([
    supabase.rpc("pre_orders_list", { p_status: done ? "all" : "booked" }),
    supabase.from("payment_methods").select("id, name, kind").eq("is_active", true).not("kind", "in", "(gift_card,loyalty,advance)").order("display_order"),
    loadMenu(),
    subCategoryParents(),
    supabase.from("branches").select("timezone").eq("id", user.branch_id).maybeSingle(),
  ]);
  const all = (list ?? []) as unknown as PreOrder[];
  return (
    <PreOrders
      currency={user.currency_code}
      canPay={can(user, "payment.take")}
      showDone={done}
      orders={done ? all.filter((o) => o.status !== "booked") : all}
      methods={methods ?? []}
      menu={menu}
      categoryParents={parents}
      timezone={tz?.timezone || "Asia/Kolkata"}
    />
  );
}
