import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { NoAccess, SectionHead } from "../section-head";
import { DaySettingsForm, SessionsForm, type SessionRow } from "./day-forms";

export default async function DaySettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage")) return <NoAccess />;
  const supabase = await createClient();
  const [{ data: bs }, { data: sessions }] = await Promise.all([
    supabase.from("branch_settings").select("shifts_enabled, day_cutoff, night_audit_mode").eq("branch_id", user.branch_id).maybeSingle(),
    supabase.from("meal_sessions").select("id, branch_id, name, start_time, end_time, days, display_order").order("display_order"),
  ]);
  const own = (sessions ?? []).filter((x) => x.branch_id === user.branch_id);
  const shared = (sessions ?? []).filter((x) => x.branch_id === null);
  const rows: SessionRow[] = (own.length ? own : shared).map((x) => ({
    name: x.name,
    start: String(x.start_time).slice(0, 5),
    end: String(x.end_time).slice(0, 5),
    days: (x.days as number[] | null) ?? [1, 2, 3, 4, 5, 6, 7],
  }));
  return (
    <div className="space-y-4">
      <SectionHead title="Day and sessions">
        How the business day works, and the meal sessions (breakfast, lunch, dinner…) that every bill is tagged with for reports.
      </SectionHead>
      <DaySettingsForm shiftsEnabled={!!bs?.shifts_enabled} cutoff={String(bs?.day_cutoff ?? "04:00").slice(0, 5)} nightAudit={bs?.night_audit_mode === "manual" ? "manual" : "auto"} />
      <SessionsForm
        initial={rows}
        outlet={user.outlet_count > 1 ? { id: user.branch_id, name: user.branch_name, ownTimes: own.length > 0 } : null}
      />
    </div>
  );
}
