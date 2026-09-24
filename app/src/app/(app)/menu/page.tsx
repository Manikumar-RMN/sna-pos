import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { MenuManager } from "./menu-manager";

export default async function MenuPage() {
  const user = await requireUser();
  const supabase = await createClient();

  // RLS scopes all of these to the signed-in user's restaurant.
  const [{ data: categories }, { data: products }, { data: taxGroups }] = await Promise.all([
    supabase
      .from("categories")
      .select("id, name, display_order")
      .is("deleted_at", null)
      .order("display_order")
      .order("name"),
    supabase
      .from("products")
      .select("id, name, price, category_id, tax_group_id, is_veg, is_available")
      .is("deleted_at", null)
      .order("name"),
    supabase
      .from("tax_groups")
      .select("id, name")
      .eq("is_active", true)
      .order("name"),
  ]);

  return (
    <div className="mx-auto max-w-4xl">
      <h1 className="text-xl font-bold tracking-tight">Menu</h1>
      <p className="mt-1 mb-6 text-sm" style={{ color: "var(--color-ink-3)" }}>
        The dishes and prices your restaurant sells. These appear on the billing screen.
      </p>

      <MenuManager
        canManage={can(user, "menu.manage")}
        currency={user.currency_code}
        categories={categories ?? []}
        products={products ?? []}
        taxGroups={taxGroups ?? []}
      />
    </div>
  );
}
