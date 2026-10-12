import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { SectionHead } from "../section-head";
import { Offers, type Offer } from "./offers";

export default async function OffersPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const [{ data: rules }, { data: categories }, { data: products }, { data: branches }] = await Promise.all([
    supabase.rpc("price_rules_list"),
    supabase.from("categories").select("id, name, parent_id").is("deleted_at", null).order("display_order").order("name"),
    // Sizes follow their dish, so only dishes are listed (not each size); the packing charge never changes.
    supabase.from("products").select("id, name, price, category_id").is("deleted_at", null).is("parent_id", null).eq("is_charge", false).order("name"),
    supabase.from("branches").select("id, name").order("name"),
  ]);

  return (
    <div className="space-y-4">
      <SectionHead title="Happy hours and offers">
        Lower prices on chosen days and times — happy hour 4 to 7 p.m., a weekday lunch offer, a festival week. The billing screen and
        the bill use the offer price automatically while it runs. When two offers cover the same dish, the lower price wins.
      </SectionHead>
      <Offers
        canEdit={can(user, "menu.manage")}
        currency={user.currency_code}
        offers={(rules ?? []) as unknown as Offer[]}
        categories={(categories ?? []).map((c) => ({ id: c.id, name: c.name, parent_id: c.parent_id }))}
        products={(products ?? []).map((p) => ({ id: p.id, name: p.name, price: Number(p.price), category_id: p.category_id }))}
        branches={branches ?? []}
      />
    </div>
  );
}
