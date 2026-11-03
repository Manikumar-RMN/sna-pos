import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { todayIn } from "@/lib/format";
import type { GroupRow, RatePlan } from "@/lib/fo";
import { UpgradeNote } from "../../upgrade-note";
import { GroupsClient } from "./groups-client";

export default async function GroupsPage({ searchParams }: { searchParams: Promise<{ past?: string }> }) {
  const { past } = await searchParams;
  const user = await requireUser();
  if (!has(user, "front_office")) return <div className="mx-auto max-w-md"><UpgradeNote feature="Front office and housekeeping" /></div>;
  if (!(can(user, "fo.view") || can(user, "fo.manage"))) return <div className="card mx-auto max-w-md p-5 text-sm">Your role does not include group bookings.</div>;
  const supabase = await createClient();
  const [list, setup, rates] = await Promise.all([
    supabase.rpc("fo_groups_list", { p_include_past: past === "1" }),
    supabase.rpc("fo_setup"),
    supabase.rpc("fo_rate_setup"),
  ]);
  const types = ((setup.data as unknown as { room_types: { id: string; name: string; max_occupancy: number; active: boolean }[] } | null)?.room_types ?? []).filter((t) => t.active);
  const plans = ((rates.data as unknown as { plans: RatePlan[] } | null)?.plans ?? []).filter((p) => p.active);
  return (
    <div className="mx-auto max-w-4xl">
      <GroupsClient
        groups={(list.data ?? []) as unknown as GroupRow[]} types={types} plans={plans.map((p) => ({ id: p.id, code: p.code, name: p.name }))}
        today={todayIn(user.timezone)} canManage={can(user, "fo.manage")} showPast={past === "1"}
      />
    </div>
  );
}
