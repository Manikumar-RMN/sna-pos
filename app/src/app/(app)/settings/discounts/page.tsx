import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { SectionHead } from "../section-head";
import { Discounts, type DiscountRow } from "./discounts";

export default async function DiscountsPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const [{ data: rows }, { data: cap }, { data: branches }] = await Promise.all([
    supabase.rpc("list_discount_presets_admin"),
    supabase.rpc("get_discount_settings"),
    supabase.from("branches").select("id, name").order("name"),
  ]);
  const max = (cap as { max_discount_percent: number | null }[] | null)?.[0]?.max_discount_percent ?? null;

  return (
    <div className="space-y-4">
      <SectionHead title="Discounts">
        Set up the discounts your staff may give: Member 10%, Staff 20%, Service recovery. They appear as buttons in the bill&rsquo;s
        Discount box, so nobody has to type a number. A maximum keeps any discount, typed or saved, within your rules.
      </SectionHead>
      <Discounts
        canEdit={can(user, "settings.manage")}
        currency={user.currency_code}
        rows={(rows ?? []) as unknown as DiscountRow[]}
        maxPercent={max === null ? null : Number(max)}
        branches={branches ?? []}
      />
    </div>
  );
}
