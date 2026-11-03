import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import type { DaySheet, RequestList } from "@/lib/fo";
import { UpgradeNote } from "../../upgrade-note";
import { RequestsClient } from "./requests-client";

const SCOPES = ["open", "today", "recent"] as const;

/** Guest requests, messages and wake-up calls: the desk's to-do list. */
export default async function RequestsPage({ searchParams }: { searchParams: Promise<{ scope?: string }> }) {
  const user = await requireUser();
  if (!has(user, "front_office")) return <div className="mx-auto max-w-md"><UpgradeNote feature="Front office and housekeeping" /></div>;
  if (!(can(user, "fo.view") || can(user, "fo.manage") || can(user, "fo.housekeeping"))) return <div className="card mx-auto max-w-md p-5 text-sm">Your role does not include guest requests.</div>;
  const q = (await searchParams).scope;
  const scope = (SCOPES as readonly string[]).includes(q ?? "") ? (q as (typeof SCOPES)[number]) : "open";
  const supabase = await createClient();
  const canWrite = can(user, "fo.manage") || can(user, "fo.housekeeping");
  const [list, sheet] = await Promise.all([
    supabase.rpc("fo_requests_list", { p_scope: scope }),
    canWrite ? supabase.rpc("fo_day_sheet", {}) : Promise.resolve({ data: null }),
  ]);
  const rl = (list.data ?? { today: "", rows: [] }) as unknown as RequestList;
  const ds = sheet.data as unknown as DaySheet | null;
  const stays = ds
    ? [
        ...ds.in_house.map((s) => ({ id: s.stay_id, label: `Room ${s.room_number ?? "-"} · ${s.guest_name} (#${s.stay_no})`, inhouse: true })),
        ...ds.arrivals.map((s) => ({ id: s.stay_id, label: `Arriving · ${s.guest_name} (#${s.stay_no})`, inhouse: false })),
      ]
    : [];
  return (
    <div className="mx-auto max-w-3xl">
      <Link href="/front-office" className="text-sm underline">← Front office</Link>
      <RequestsClient list={rl} scope={scope} stays={stays} canWrite={canWrite} />
    </div>
  );
}
