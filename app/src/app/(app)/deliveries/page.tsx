import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Deliveries, type Delivery } from "./deliveries";

/** Own delivery: which bills are waiting, out with a rider, delivered; riders hand over cash. */
export default async function DeliveriesPage() {
  const user = await requireUser();
  if (!can(user, "order.create")) {
    return (
      <div className="card mx-auto mt-4 max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include taking orders. Ask an owner or manager.
      </div>
    );
  }
  const supabase = await createClient();
  const [{ data: list }, { data: riders }] = await Promise.all([
    supabase.rpc("deliveries_list"),
    supabase.from("riders").select("id, name, phone, is_active").order("name"),
  ]);
  return (
    <Deliveries
      currency={user.currency_code}
      canSettle={can(user, "payment.take")}
      deliveries={(list ?? []) as unknown as Delivery[]}
      riders={riders ?? []}
    />
  );
}
