import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { ChargesForm, PackingForm, TokensForm } from "../settings-forms";
import { NoAccess, SectionHead } from "../section-head";

export default async function ChargeSettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage") && !can(user, "tax.manage")) return <NoAccess />;
  const supabase = await createClient();
  const [{ data: bs }, { data: country }, { data: taxGroups }] = await Promise.all([
    // These choices belong to the outlet you are working in.
    supabase
      .from("branch_settings")
      .select(
        "cash_rounding_mode, service_charge_percent, service_charge_label, service_charge_taxable, service_charge_default_on, rounding_cash_only, token_numbers, packing_product_id, packing_per, packing_takeaway, packing_delivery",
      )
      .eq("branch_id", user.branch_id)
      .maybeSingle(),
    supabase.from("countries").select("tax_system_name").eq("code", user.country_code).maybeSingle(),
    supabase.from("tax_groups").select("id, name").eq("is_active", true).order("name"),
  ]);
  // The packing charge is a menu item. Its amount, and whether it is on the menu, belong to this outlet
  // (v_menu gives both as they are here); the tax is the menu item's own, so every outlet shares it.
  const [{ data: packing }, { data: chargeItem }] = await Promise.all([
    bs?.packing_product_id
      ? supabase.from("v_menu").select("price, is_available").eq("id", bs.packing_product_id).maybeSingle()
      : Promise.resolve({ data: null }),
    // Found by its mark, not its name, and also while the charge is switched off, so the tax stays chosen.
    supabase.from("products").select("tax_group_id").eq("is_charge", true).is("deleted_at", null).order("created_at").limit(1).maybeSingle(),
  ]);
  const packingOn = !!bs?.packing_product_id && packing?.is_available === true;
  // Switched on here, yet the menu item was deleted or made unavailable on the Menu screen: bills are not getting it.
  const packingLost = !!bs?.packing_product_id && !packingOn;
  const isIndia = user.country_code === "IN";
  const canEdit = can(user, "settings.manage");
  const taxName = country?.tax_system_name ?? "Tax";
  const groups = taxGroups ?? [];
  const packingTax = chargeItem && groups.some((g) => g.id === chargeItem.tax_group_id) ? chargeItem.tax_group_id : null;

  return (
    <div className="space-y-4">
      <SectionHead title="Service charge">The service charge, how totals are rounded, the packing charge and token numbers.</SectionHead>
      <ChargesForm
        canEdit={canEdit}
        taxName={taxName}
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
      <PackingForm
        canEdit={canEdit}
        currency={user.currency_code}
        taxName={taxName}
        taxGroups={groups}
        severalOutlets={user.outlet_count > 1}
        lost={packingLost}
        initial={{
          amount: packingOn ? Number(packing?.price ?? 0) : 0,
          per: bs?.packing_per === "item" ? "item" : "bill",
          taxGroupId: packingTax ?? (groups.length === 1 ? groups[0].id : ""),
          takeaway: bs?.packing_takeaway ?? true,
          delivery: bs?.packing_delivery ?? true,
        }}
      />
      <TokensForm canEdit={canEdit} initial={bs?.token_numbers ?? "off"} />
    </div>
  );
}
