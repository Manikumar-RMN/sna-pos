import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../upgrade-note";
import { FrontOfficeBoard } from "./board";
import type { DaySheet, RoomCard } from "@/lib/fo";
import { friendlyDbError } from "@/lib/db-error";

export default async function FrontOfficePage() {
  const user = await requireUser();
  const canView = can(user, "fo.view") || can(user, "fo.manage") || can(user, "fo.housekeeping");
  if (!canView) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include the front office. An owner can give the &ldquo;See the room board&rdquo; right in Settings → Security profiles.
      </div>
    );
  }
  if (!has(user, "front_office")) {
    return (
      <div className="mx-auto max-w-md">
        <UpgradeNote feature="Front office and housekeeping" />
      </div>
    );
  }

  const supabase = await createClient();
  const [rooms, sheet, setup] = await Promise.all([
    supabase.rpc("fo_room_board"),
    supabase.rpc("fo_day_sheet", {}),
    supabase.rpc("fo_setup"),
  ]);
  const err = rooms.error ?? sheet.error;
  if (err) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-bad)" }}>
        {friendlyDbError(err)}
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-6xl">
      <div className="mb-3 flex items-center justify-between gap-3">
        <h1 className="text-xl font-extrabold">Front office</h1>
        <div className="flex flex-wrap gap-2">
          <Link href="/front-office/chart" className="btn h-10 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }}>Stay chart</Link>
          <Link href="/front-office/housekeeping" className="btn h-10 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }}>Housekeeping</Link>
          <Link href="/front-office/guests" className="btn h-10 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }}>Guests</Link>
          {can(user, "fo.manage") && (
            <Link href="/front-office/setup" className="btn h-10 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }}>
              Rooms and rates
            </Link>
          )}
        </div>
      </div>
      <FrontOfficeBoard
        rooms={(rooms.data ?? []) as unknown as RoomCard[]}
        sheet={sheet.data as unknown as DaySheet}
        roomTypes={((setup.data as unknown as { room_types: { id: string; code: string; name: string; base_rate: number; max_occupancy: number; active: boolean }[] } | null)?.room_types ?? []).filter((t) => t.active)}
        currency={user.currency_code}
        canManage={can(user, "fo.manage")}
        canHousekeep={can(user, "fo.housekeeping") || can(user, "fo.manage")}
        canAudit={can(user, "fo.night_audit")}
      />
    </div>
  );
}
