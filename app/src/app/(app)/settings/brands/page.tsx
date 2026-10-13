import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { SectionHead } from "../section-head";
import { Brands, Settlement, type Brand } from "./brands";

export default async function BrandsPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const [{ data: brands }, { data: categories }] = await Promise.all([
    supabase.from("brands").select("id, name, legal_name, gstin, commission_percent, is_active").order("display_order").order("name"),
    supabase.from("categories").select("id, name, brand_id").is("deleted_at", null).is("parent_id", null).order("display_order").order("name"),
  ]);
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: user.timezone || "Asia/Kolkata" }).format(new Date());
  return (
    <div className="space-y-4">
      <SectionHead title="Brands and stalls">
        For a cloud kitchen running several brands, or a food court billing several stalls at one counter. Put each main category under
        its brand; the billing screen can then show one brand at a time, and the settlement shows what each brand sold and is owed.
      </SectionHead>
      <Brands
        brands={(brands ?? []).map((b) => ({ ...b, commission_percent: Number(b.commission_percent) })) as Brand[]}
        categories={categories ?? []}
        canEdit={can(user, "settings.manage")}
      />
      {can(user, "report.view_sales") && (brands ?? []).length > 0 && <Settlement currency={user.currency_code} today={today} />}
    </div>
  );
}
