import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { BusinessForm } from "../settings-forms";
import { NoAccess, SectionHead } from "../section-head";

export default async function BillDetailsSettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage")) return <NoAccess />;
  const supabase = await createClient();
  const [{ data: rest }, { data: bs }] = await Promise.all([
    supabase.from("restaurants").select("fssai_no, sac_code").limit(1).maybeSingle(),
    supabase.from("branch_settings").select("receipt_header, receipt_footer, auto_print_kot").limit(1).maybeSingle(),
  ]);
  const isIndia = user.country_code === "IN";
  return (
    <div className="space-y-4">
      <SectionHead title="Bill details">{isIndia ? "FSSAI licence, SAC code, receipt wording and the Kitchen screen." : "Receipt wording and the Kitchen screen."}</SectionHead>
      <BusinessForm
        part="pos"
        canEdit
        taxIdLabel=""
        taxIdHint=""
        initial={{
          legal_name: "", trading_name: "", tax_registration_no: "", contact_phone: "",
          branch_name: "", address_line1: "", address_line2: "", city: "", state_or_region: "", postal_code: "", phone: "",
          receipt_header: bs?.receipt_header ?? "",
          receipt_footer: bs?.receipt_footer ?? "",
          auto_print_kot: bs?.auto_print_kot ?? true,
          ...(isIndia ? { fssai_no: rest?.fssai_no ?? "", sac_code: rest?.sac_code ?? "996331" } : {}),
        }}
      />
    </div>
  );
}
