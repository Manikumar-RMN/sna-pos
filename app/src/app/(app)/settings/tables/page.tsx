import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { TablesForm } from "../settings-forms";
import { NoAccess, SectionHead } from "../section-head";
import { byTableNumber } from "@/lib/table-order";

export default async function TableSettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage") && !can(user, "tax.manage")) return <NoAccess />;
  const supabase = await createClient();
  const [{ data: tables }, { data: openTabs }] = await Promise.all([
    supabase.from("dining_tables").select("id, table_number, seats").eq("is_active", true).order("table_number"),
    supabase.from("orders").select("dining_table_id").in("payment_status", ["unpaid", "partial"]).neq("status", "voided").not("dining_table_id", "is", null),
  ]);
  const busy = new Set((openTabs ?? []).map((o) => o.dining_table_id));

  return (
    <div>
      <SectionHead title="Tables">The dine-in tables your staff can bill to.</SectionHead>
      {has(user, "qr_ordering") && can(user, "settings.manage") && (
        <Link href="/settings/tables/qr" className="btn btn-primary mb-4 inline-flex">
          Print table QR codes
        </Link>
      )}
      <TablesForm
        canEdit={can(user, "settings.manage")}
        tables={[...(tables ?? [])].sort(byTableNumber).map((t) => ({ id: t.id, number: t.table_number, seats: t.seats, busy: busy.has(t.id) }))}
      />
    </div>
  );
}
