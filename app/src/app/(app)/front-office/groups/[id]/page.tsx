import { notFound } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import type { GroupView, RatePlan } from "@/lib/fo";
import { UpgradeNote } from "../../../upgrade-note";
import { GroupDetail } from "./group-detail";

export default async function GroupPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const user = await requireUser();
  if (!has(user, "front_office")) return <div className="mx-auto max-w-md"><UpgradeNote feature="Front office and housekeeping" /></div>;
  if (!(can(user, "fo.view") || can(user, "fo.manage"))) return <div className="card mx-auto max-w-md p-5 text-sm">Your role does not include group bookings.</div>;
  const supabase = await createClient();
  const [view, setup, rates] = await Promise.all([supabase.rpc("fo_group_view", { p_group: id }), supabase.rpc("fo_setup"), supabase.rpc("fo_rate_setup")]);
  const data = view.data as unknown as GroupView | null;
  if (!data) notFound();
  const types = ((setup.data as unknown as { room_types: { id: string; name: string; max_occupancy: number; active: boolean }[] } | null)?.room_types ?? []).filter((t) => t.active);
  const plans = ((rates.data as unknown as { plans: RatePlan[] } | null)?.plans ?? []).filter((p) => p.active).map((p) => ({ id: p.id, code: p.code, name: p.name }));
  return (
    <div className="mx-auto max-w-4xl">
      <GroupDetail data={data} types={types} plans={plans} currency={user.currency_code} canManage={can(user, "fo.manage")} />
    </div>
  );
}
