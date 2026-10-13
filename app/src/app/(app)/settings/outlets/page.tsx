import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../../upgrade-note";
import { SectionHead } from "../section-head";
import { OutletsEditor } from "./outlets-editor";
import { ChainTools } from "./chain";

export default async function OutletsSettings() {
  const user = await requireUser();
  if (!has(user, "multi_outlet")) {
    return (
      <div>
        <SectionHead title="Outlets">Several outlets with one central menu and a price per outlet.</SectionHead>
        <UpgradeNote feature="Several outlets" />
      </div>
    );
  }
  const supabase = await createClient();
  const [{ data: branches }, { data: products }, { data: prices }, { data: users }, { data: links }] = await Promise.all([
    supabase.from("branches").select("id, name, code, city, is_central_kitchen, region, royalty_percent").is("deleted_at", null).order("created_at"),
    supabase.from("products").select("id, name, price, is_available, categories(name)").is("deleted_at", null).order("name"),
    supabase.from("branch_prices").select("branch_id, product_id, price, is_available"),
    supabase.from("users").select("id, full_name, is_active, roles(name)").is("deleted_at", null).order("full_name"),
    supabase.from("user_branches").select("user_id, branch_id"),
  ]);
  const outlets = branches ?? [];

  return (
    <div>
      <SectionHead title="Outlets">
        One menu for every outlet. Set a different price or mark an item sold out for one outlet only. New outlets are added by the SNA team — ask in{" "}
        <Link href="/settings/plan" className="font-bold" style={{ color: "var(--color-brand)" }}>
          Plan and modules
        </Link>
        .
      </SectionHead>
      <OutletsEditor
        currency={user.currency_code}
        canPrice={can(user, "menu.price_change")}
        canMenu={can(user, "menu.manage")}
        canPeople={can(user, "user.manage")}
        canSettings={can(user, "settings.manage") && has(user, "central_kitchen")}
        outlets={outlets.map((b) => ({ id: b.id, name: b.name, code: b.code, city: b.city, central: !!b.is_central_kitchen }))}
        products={(products ?? []).map((p) => ({
          id: p.id,
          name: p.name,
          category: (p.categories as unknown as { name: string } | null)?.name ?? "",
          price: Number(p.price),
          available: p.is_available ?? true,
        }))}
        overrides={(prices ?? []).map((x) => ({ branch: x.branch_id, product: x.product_id, price: x.price == null ? null : Number(x.price), available: x.is_available }))}
        people={(users ?? []).map((u) => ({ id: u.id, name: u.full_name, role: (u.roles as unknown as { name: string } | null)?.name ?? "", active: u.is_active }))}
        access={(links ?? []).map((l) => ({ user: l.user_id, branch: l.branch_id }))}
      />
      <ChainTools
        outlets={outlets.map((b) => ({ id: b.id, name: b.name, region: b.region, royalty: Number(b.royalty_percent ?? 0) }))}
        products={(products ?? []).map((p) => ({ id: p.id, name: p.name, price: Number(p.price) }))}
        currency={user.currency_code}
        canSettings={can(user, "settings.manage")}
        canPrice={can(user, "menu.price_change")}
        canReport={can(user, "report.view_sales")}
        today={new Intl.DateTimeFormat("en-CA", { timeZone: user.timezone || "Asia/Kolkata" }).format(new Date())}
      />
    </div>
  );
}
