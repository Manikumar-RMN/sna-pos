import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { BusinessForm } from "../settings-forms";
import { NoAccess, SectionHead } from "../section-head";

export default async function CompanySettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage") && !can(user, "tax.manage")) return <NoAccess />;
  const supabase = await createClient();
  const [{ data: rest }, { data: branch }, { data: bs }, { data: country }] = await Promise.all([
    supabase.from("restaurants").select("legal_name, trading_name, tax_registration_no, contact_phone, fssai_no, sac_code").limit(1).maybeSingle(),
    supabase.from("branches").select("name, address_line1, address_line2, city, state_or_region, postal_code, phone").is("deleted_at", null).order("created_at").limit(1).maybeSingle(),
    supabase.from("branch_settings").select("receipt_header, receipt_footer, auto_print_kot").limit(1).maybeSingle(),
    supabase.from("countries").select("tax_id_label, compliance_note").eq("code", user.country_code).maybeSingle(),
  ]);
  const isIndia = user.country_code === "IN";

  return (
    <div className="space-y-4">
      <SectionHead title="Company">Your business name, outlet address and what is printed on every bill.</SectionHead>
      {country?.compliance_note && (
        <div className="rounded-2xl px-4 py-3 text-sm" role="note" style={{ background: "var(--color-warn-soft)", color: "var(--color-ink-2)" }}>
          <b>Before you go live:</b> {country.compliance_note}
        </div>
      )}
      <BusinessForm
        canEdit={can(user, "settings.manage")}
        taxIdLabel={country?.tax_id_label ?? "Tax number"}
        taxIdHint={isIndia ? "15 characters, e.g. 29ABCDE1234F1Z5. Leave empty if not registered." : "Printed on every receipt. Leave empty if not registered."}
        initial={{
          legal_name: rest?.legal_name ?? "",
          trading_name: rest?.trading_name ?? "",
          tax_registration_no: rest?.tax_registration_no ?? "",
          contact_phone: rest?.contact_phone ?? "",
          branch_name: branch?.name ?? "",
          address_line1: branch?.address_line1 ?? "",
          address_line2: branch?.address_line2 ?? "",
          city: branch?.city ?? "",
          state_or_region: branch?.state_or_region ?? "",
          postal_code: branch?.postal_code ?? "",
          phone: branch?.phone ?? "",
          receipt_header: bs?.receipt_header ?? "",
          receipt_footer: bs?.receipt_footer ?? "",
          auto_print_kot: bs?.auto_print_kot ?? true,
          ...(isIndia ? { fssai_no: rest?.fssai_no ?? "", sac_code: rest?.sac_code ?? "996331" } : {}),
        }}
      />
    </div>
  );
}
