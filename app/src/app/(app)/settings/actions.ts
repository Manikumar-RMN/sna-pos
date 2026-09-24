"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";

export type Result = { ok: true; message?: string } | { ok: false; error: string };

function done(message: string): Result {
  revalidatePath("/settings");
  revalidatePath("/pos");
  revalidatePath("/", "layout");
  return { ok: true, message };
}

/** Restaurant, branch and receipt details. The database validates the GSTIN. */
export async function saveSettings(settings: Record<string, string | boolean>): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("update_settings", { p_settings: settings });
  if (error) return { ok: false, error: error.message };
  return done("Settings saved.");
}

export async function addTable(tableNumber: string, seats: number): Promise<Result> {
  const user = await getCurrentUser();
  if (!user || !can(user, "settings.manage")) return { ok: false, error: "Only an owner can change tables." };
  const num = tableNumber.trim();
  if (!num) return { ok: false, error: "Enter a table number or name." };
  if (!(seats > 0 && seats < 100)) return { ok: false, error: "Enter the number of seats." };
  const supabase = await createClient();
  const { data: branch } = await supabase.from("branches").select("id").is("deleted_at", null).order("created_at").limit(1).maybeSingle();
  if (!branch) return { ok: false, error: "No branch found." };

  const { data: existing } = await supabase.from("dining_tables").select("id, is_active").eq("table_number", num).maybeSingle();
  if (existing?.is_active) return { ok: false, error: `Table ${num} already exists.` };
  const { error } = existing
    ? await supabase.from("dining_tables").update({ is_active: true, seats }).eq("id", existing.id)
    : await supabase.from("dining_tables").insert({
        restaurant_id: user.restaurant_id,
        branch_id: branch.id,
        table_number: num,
        seats,
      });
  if (error) return { ok: false, error: error.message };
  return done(`Table ${num} added.`);
}

export async function removeTable(id: string): Promise<Result> {
  const supabase = await createClient();
  const { count } = await supabase
    .from("orders")
    .select("id", { count: "exact", head: true })
    .eq("dining_table_id", id)
    .eq("payment_status", "unpaid")
    .neq("status", "voided");
  if ((count ?? 0) > 0) return { ok: false, error: "This table has an unpaid bill. Settle it first." };
  const { error } = await supabase.from("dining_tables").update({ is_active: false }).eq("id", id);
  if (error) return { ok: false, error: error.message };
  return done("Table removed.");
}

export async function setPaymentMethod(id: string, active: boolean): Promise<Result> {
  const supabase = await createClient();
  if (!active) {
    const { count } = await supabase
      .from("payment_methods")
      .select("id", { count: "exact", head: true })
      .eq("is_active", true);
    if ((count ?? 0) <= 1) return { ok: false, error: "Keep at least one payment method switched on." };
  }
  const { error } = await supabase.from("payment_methods").update({ is_active: active }).eq("id", id);
  if (error) return { ok: false, error: error.message };
  return done(active ? "Payment method switched on." : "Payment method switched off.");
}

export async function setTaxRate(groupId: string, rate: number): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_tax_rate", { p_tax_group_id: groupId, p_total_rate: rate });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/menu");
  return done("Tax rate updated. New bills use it from now on; past bills keep the tax they were charged.");
}

export async function addTaxGroup(name: string, rate: number): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("create_tax_group", { p_name: name, p_total_rate: rate });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/menu");
  return done("Tax group added. You can now choose it for menu items.");
}
