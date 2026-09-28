import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { ChargesForm } from "../settings-forms";
import { NoAccess, SectionHead } from "../section-head";

export default async function ChargeSettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage") && !can(user, "tax.manage")) return <NoAccess />;
  const supabase = await createClient();
  const [{ data: bs }, { data: country }] = await Promise.all([
    supabase
      .from("branch_settings")
      .select("cash_rounding_mode, service_charge_percent, service_charge_label, service_charge_taxable, service_charge_default_on, rounding_cash_only")
      .limit(1)
      .maybeSingle(),
    supabase.from("countries").select("tax_system_name").eq("code", user.country_code).maybeSingle(),
  ]);
  const isIndia = user.country_code === "IN";

  return (
    <div>
      <SectionHead title="Service charge">The service charge added to bills, and how totals are rounded.</SectionHead>
      <ChargesForm
        canEdit={can(user, "settings.manage")}
        taxName={country?.tax_system_name ?? "Tax"}
        serviceChargeHint={isIndia ? "In India a service charge must be optional for the customer." : ""}
        initial={{
          service_charge_percent: Number(bs?.service_charge_percent ?? 0),
          service_charge_label: bs?.service_charge_label ?? "Service charge",
          service_charge_taxable: bs?.service_charge_taxable ?? !isIndia,
          service_charge_default_on: bs?.service_charge_default_on ?? !isIndia,
          cash_rounding_mode: bs?.cash_rounding_mode ?? "none",
          rounding_cash_only: bs?.rounding_cash_only ?? false,
        }}
      />
    </div>
  );
}
