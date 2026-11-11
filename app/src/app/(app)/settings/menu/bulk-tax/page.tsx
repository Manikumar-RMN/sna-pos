import Link from "next/link";
import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { NoAccess, SectionHead } from "../../section-head";
import { BulkTax } from "./bulk-tax";

export default async function BulkTaxPage() {
  const user = await requireUser();
  if (!can(user, "tax.manage")) {
    return (
      <div>
        <SectionHead title="Change the tax of a menu group" />
        <NoAccess />
      </div>
    );
  }
  const supabase = await createClient();
  const [{ data: categories }, { data: taxGroups }] = await Promise.all([
    supabase.from("categories").select("id, name, parent_id").is("deleted_at", null).order("display_order").order("name"),
    supabase.from("tax_groups").select("id, name").eq("is_active", true).order("name"),
  ]);
  return (
    <div>
      <Link href="/settings/menu" className="text-sm font-bold" style={{ color: "var(--color-brand)" }}>
        &larr; Menu
      </Link>
      <div className="mt-2">
        <SectionHead title="Change the tax of a menu group">
          Move every dish of a menu group, and its sub-groups, to another tax group in one step. You see how many dishes change first. Bills that
          are already open keep the tax they were rung with.
        </SectionHead>
      </div>
      <BulkTax categories={(categories ?? []).map((c) => ({ id: c.id, name: c.name }))} taxGroups={(taxGroups ?? []).map((t) => ({ id: t.id, name: t.name }))} />
    </div>
  );
}
