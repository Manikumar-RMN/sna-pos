import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { HkRow } from "@/lib/fo";
import { UpgradeNote } from "../../upgrade-note";
import { HousekeepingBoard } from "./hk-board";

export default async function HousekeepingPage() {
  const user = await requireUser();
  if (!has(user, "front_office")) return <div className="mx-auto max-w-md"><UpgradeNote feature="Front office and housekeeping" /></div>;
  if (!(can(user, "fo.view") || can(user, "fo.manage") || can(user, "fo.housekeeping"))) {
    return <div className="card mx-auto max-w-md p-5 text-sm">Your role does not include housekeeping.</div>;
  }
  const supabase = await createClient();
  const [list, staff] = await Promise.all([
    supabase.rpc("fo_hk_list"),
    supabase.from("users").select("id, full_name").eq("is_active", true).is("deleted_at", null).order("full_name"),
  ]);
  if (list.error) return <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-bad)" }}>{friendlyDbError(list.error)}</div>;
  return (
    <div className="mx-auto max-w-5xl">
      <div className="mb-3 flex items-center justify-between gap-3">
        <h1 className="text-xl font-extrabold">Housekeeping</h1>
        <Link href="/front-office" className="text-sm underline">Back to front office</Link>
      </div>
      <HousekeepingBoard
        rows={(list.data ?? []) as unknown as HkRow[]}
        staff={(staff.data ?? []) as { id: string; full_name: string }[]}
        canAssign={can(user, "fo.manage") || can(user, "fo.housekeeping")}
      />
    </div>
  );
}
