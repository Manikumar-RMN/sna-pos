import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { todayIn } from "@/lib/format";
import { TaxForm, type TaxGroupView } from "../settings-forms";
import { currentComps, pendingRate, type RateRow } from "./schedule";
import { NoAccess, SectionHead } from "../section-head";
import { LiquorCard } from "./liquor-card";

export default async function TaxSettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage") && !can(user, "tax.manage")) return <NoAccess />;
  const supabase = await createClient();
  const today = todayIn(user.timezone);
  const [{ data: groups }, { data: rates }, { data: products }, { data: country }] = await Promise.all([
    supabase.from("tax_groups").select("id, name, is_price_inclusive, separate_bill").eq("is_active", true).order("name"),
    supabase
      .from("tax_rates")
      .select("id, tax_group_id, valid_from, valid_to, tax_rate_components!tax_rate_components_tax_rate_id_fkey(name, rate, is_compound, applies_when, display_order)")
      .order("valid_from", { ascending: false }),
    supabase.from("products").select("tax_group_id").is("deleted_at", null),
    supabase.from("countries").select("tax_system_name").eq("code", user.country_code).maybeSingle(),
  ]);
  const taxName = country?.tax_system_name ?? "Tax";

  // All rows are read: the one running today, and (at most) one waiting for a future date.
  const rateRows = (rates ?? []) as RateRow[];
  const taxGroups: TaxGroupView[] = (groups ?? []).map((g) => ({
    id: g.id,
    name: g.name,
    comps: currentComps(rateRows, g.id, today),
    pending: pendingRate(rateRows, g.id, today),
    items: (products ?? []).filter((p) => p.tax_group_id === g.id).length,
  }));

  return (
    <div>
      <SectionHead title="Taxes">{taxName} rates for your menu. A change applies to new bills from now, or from a date you schedule; past bills keep the tax they were charged.</SectionHead>
      <TaxForm
        canEdit={can(user, "tax.manage")}
        groups={taxGroups}
        isIndia={user.country_code === "IN"}
        taxName={taxName}
        pricesInclude={(groups ?? []).some((g) => g.is_price_inclusive)}
        today={today}
      />
      {user.country_code === "IN" && (groups ?? []).length > 0 && (
        <LiquorCard canEdit={can(user, "tax.manage")} groups={(groups ?? []).map((g) => ({ id: g.id, name: g.name, separate_bill: !!g.separate_bill }))} />
      )}
    </div>
  );
}
