import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../upgrade-note";
import { OnlineOrders, type OnlineOrder } from "./online-orders";

/** Orders from Swiggy, Zomato or the restaurant's website, waiting to be accepted. */
export default async function OnlineOrdersPage() {
  const user = await requireUser();
  if (!has(user, "open_api")) {
    return (
      <div className="mx-auto max-w-xl">
        <h1 className="mb-3 text-xl font-bold">Online orders</h1>
        <UpgradeNote feature="Open API (online orders)" />
      </div>
    );
  }
  const supabase = await createClient();
  const { data } = await supabase.rpc("online_orders_list");
  return <OnlineOrders currency={user.currency_code} canAccept={can(user, "order.create")} orders={(data ?? []) as unknown as OnlineOrder[]} />;
}
