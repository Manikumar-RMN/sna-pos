import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { CountersForm } from "../settings-forms";
import { NoAccess, SectionHead } from "../section-head";

export default async function CounterSettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage") && !can(user, "tax.manage")) return <NoAccess />;
  const supabase = await createClient();
  const { data: counters } = await supabase
    .from("devices")
    .select("id, name, last_seen_at")
    .eq("device_type", "counter")
    .eq("is_active", true)
    .order("created_at");

  return (
    <div>
      <SectionHead title="Counter tablets">Shared tablets that staff unlock with their own PIN.</SectionHead>
      <CountersForm
        canEdit={can(user, "settings.manage")}
        isThisACounter={!!user.device_name}
        devices={(counters ?? []).map((d) => ({ id: d.id, name: d.name, lastSeen: d.last_seen_at }))}
      />
    </div>
  );
}
