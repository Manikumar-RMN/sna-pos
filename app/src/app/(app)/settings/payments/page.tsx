import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { PaymentMethodsForm } from "../settings-forms";
import { NoAccess, SectionHead } from "../section-head";

export default async function PaymentSettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage") && !can(user, "tax.manage")) return <NoAccess />;
  const supabase = await createClient();
  const { data: methods } = await supabase
    .from("payment_methods")
    .select("id, name, kind, is_active, ask_reference, upi_id, collection_mode")
    .not("kind", "in", "(gift_card,loyalty)")
    .order("display_order");

  return (
    <div>
      <SectionHead title="Payment methods">How customers can pay. Payments are recorded; no payment gateway is connected yet.</SectionHead>
      <PaymentMethodsForm canEdit={can(user, "settings.manage")} methods={methods ?? []} />
    </div>
  );
}
