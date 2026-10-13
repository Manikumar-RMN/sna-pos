import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../upgrade-note";
import { OnlineOrders, type OnlineOrder } from "./online-orders";
import type { Channel } from "./actions";

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
  const canSettings = can(user, "settings.manage");
  const [{ data }, { data: channels }] = await Promise.all([
    supabase.rpc("online_orders_list"),
    canSettings ? supabase.rpc("online_channels_list") : Promise.resolve({ data: [] }),
  ]);
  return (
    <OnlineOrders
      currency={user.currency_code}
      canAccept={can(user, "order.create")}
      canSettings={canSettings}
      channels={(channels ?? []) as unknown as Channel[]}
      orders={(data ?? []) as unknown as OnlineOrder[]}
    />
  );
}
