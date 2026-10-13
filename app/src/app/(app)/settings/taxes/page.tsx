import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { todayIn } from "@/lib/format";
import { TaxForm, type TaxGroupView } from "../settings-forms";
import type { TaxComponent } from "../actions";
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
      .lte("valid_from", today)
      .order("valid_from", { ascending: false }),
    supabase.from("products").select("tax_group_id").is("deleted_at", null),
    supabase.from("countries").select("tax_system_name").eq("code", user.country_code).maybeSingle(),
  ]);
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

  return (
    <div>
      <SectionHead title="Taxes">{taxName} rates for your menu. A change applies to new bills from now; past bills keep the tax they were charged.</SectionHead>
      <TaxForm
        canEdit={can(user, "tax.manage")}
        groups={taxGroups}
        isIndia={user.country_code === "IN"}
        taxName={taxName}
        pricesInclude={(groups ?? []).some((g) => g.is_price_inclusive)}
      />
      {user.country_code === "IN" && (groups ?? []).length > 0 && (
        <LiquorCard canEdit={can(user, "tax.manage")} groups={(groups ?? []).map((g) => ({ id: g.id, name: g.name, separate_bill: !!g.separate_bill }))} />
      )}
    </div>
  );
}
