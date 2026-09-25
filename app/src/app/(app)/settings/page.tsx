import Link from "next/link";
import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { BusinessForm, ChargesForm, PaymentMethodsForm, TablesForm, TaxForm, type TaxGroupView } from "./settings-forms";
import type { TaxComponent } from "./actions";

export default async function SettingsPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [
    { data: rest },
    { data: branch },
    { data: bs },
    { data: tables },
    { data: groups },
    { data: rates },
    { data: products },
    { data: methods },
    { data: openTabs },
    { data: country },
  ] = await Promise.all([
    supabase.from("restaurants").select("legal_name, trading_name, tax_registration_no, contact_phone").limit(1).maybeSingle(),
    supabase.from("branches").select("name, address_line1, address_line2, city, state_or_region, postal_code, phone").is("deleted_at", null).order("created_at").limit(1).maybeSingle(),
    supabase
      .from("branch_settings")
      .select("receipt_header, receipt_footer, cash_rounding_mode, auto_print_kot, service_charge_percent, service_charge_label, service_charge_taxable, service_charge_default_on, rounding_cash_only")
      .limit(1)
      .maybeSingle(),
    supabase.from("dining_tables").select("id, table_number, seats").eq("is_active", true).order("table_number"),
    supabase.from("tax_groups").select("id, name, is_price_inclusive").eq("is_active", true).order("name"),
    supabase
      .from("tax_rates")
      .select("id, tax_group_id, valid_from, valid_to, tax_rate_components(name, rate, is_compound, applies_when, display_order)")
      .lte("valid_from", today)
      .order("valid_from", { ascending: false }),
    supabase.from("products").select("tax_group_id").is("deleted_at", null),
    supabase.from("payment_methods").select("id, name, is_active").order("display_order"),
    supabase.from("orders").select("dining_table_id").eq("payment_status", "unpaid").neq("status", "voided").not("dining_table_id", "is", null),
    supabase.from("countries").select("code, tax_system_name, tax_id_label, compliance_note").eq("code", user.country_code).maybeSingle(),
  ]);

  const isIndia = user.country_code === "IN";
  const taxName = country?.tax_system_name ?? "Tax";

  const compsFor = (gid: string): TaxComponent[] => {
    const r = (rates ?? []).find((x) => x.tax_group_id === gid && (!x.valid_to || x.valid_to >= today));
    return [...(r?.tax_rate_components ?? [])]
      .sort((a, b) => a.display_order - b.display_order)
      .map((c) => ({
        name: c.name,
        rate: Number(c.rate),
        compound: c.is_compound,
        applies_when: (c.applies_when as TaxComponent["applies_when"]) ?? "always",
      }));
  };

  const taxGroups: TaxGroupView[] = (groups ?? []).map((g) => ({
    id: g.id,
    name: g.name,
    comps: compsFor(g.id),
    items: (products ?? []).filter((p) => p.tax_group_id === g.id).length,
  }));
  const busy = new Set((openTabs ?? []).map((o) => o.dining_table_id));
  const isOwner = can(user, "settings.manage");

  return (
    <div className="mx-auto max-w-4xl space-y-5">
      <div>
        <h1 className="text-xl font-bold tracking-tight">Settings</h1>
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          Your business details, receipt, {taxName}, tables and payment methods. Staff are on the{" "}
          <Link href="/settings/users" className="font-semibold" style={{ color: "var(--color-brand)" }}>
            Staff
          </Link>{" "}
          screen.
        </p>
      </div>

      {country?.compliance_note && (
        <div className="rounded-lg px-4 py-3 text-sm" role="note" style={{ background: "var(--color-warn-soft)", color: "var(--color-ink-2)" }}>
          <b>Before you go live:</b> {country.compliance_note}
        </div>
      )}

      <BusinessForm
        canEdit={isOwner}
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
        }}
      />

      <div className="grid gap-5 lg:grid-cols-2">
        <div className="space-y-5">
          <TaxForm
            canEdit={can(user, "tax.manage")}
            groups={taxGroups}
            isIndia={isIndia}
            taxName={taxName}
            pricesInclude={(groups ?? []).some((g) => g.is_price_inclusive)}
          />
          <ChargesForm
            canEdit={isOwner}
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
        </div>
        <div className="space-y-5">
          <TablesForm canEdit={isOwner} tables={(tables ?? []).map((t) => ({ id: t.id, number: t.table_number, seats: t.seats, busy: busy.has(t.id) }))} />
          <PaymentMethodsForm canEdit={isOwner} methods={methods ?? []} />
        </div>
      </div>
    </div>
  );
}
