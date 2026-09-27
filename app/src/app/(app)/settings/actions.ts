"use server";

import { randomBytes, randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient as createPlainClient } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";
import type { Database, Json } from "@/lib/supabase/database.types";

export type Result = { ok: true; message?: string } | { ok: false; error: string };

export type TaxComponent = { name: string; rate: number; compound: boolean; applies_when: "always" | "intra_region" | "inter_region" };

function done(message: string): Result {
  revalidatePath("/settings");
  revalidatePath("/pos");
  revalidatePath("/menu");
  revalidatePath("/", "layout");
  return { ok: true, message };
}

/** Restaurant, branch, receipt, service charge and rounding. The database validates each value. */
export async function saveSettings(settings: Record<string, string | boolean | number>): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("update_settings", { p_settings: settings as unknown as Json });
  if (error) return { ok: false, error: error.message };
  return done("Settings saved.");
}

/** Create (groupId null) or change a tax group. The change applies to new bills from today. */
export async function saveTaxGroup(groupId: string | null, name: string, components: TaxComponent[]): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_tax_group", {
    // null creates a new group.
    p_group_id: groupId as string,
    p_name: name,
    p_components: components as unknown as Json,
  });
  if (error) return { ok: false, error: error.message };
  return done("Tax saved. New bills use it from now on; past bills keep the tax they were charged.");
}

export async function setPricesIncludeTax(inclusive: boolean): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_prices_include_tax", { p_inclusive: inclusive });
  if (error) return { ok: false, error: error.message };
  return done(inclusive ? "Menu prices now include tax." : "Tax is now added on top of menu prices.");
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
    : await supabase.from("dining_tables").insert({ restaurant_id: user.restaurant_id, branch_id: branch.id, table_number: num, seats });
  if (error) return { ok: false, error: error.message };
  return done(`Table ${num} added.`);
}

export async function removeTable(id: string): Promise<Result> {
  const supabase = await createClient();
  const { count } = await supabase
    .from("orders")
    .select("id", { count: "exact", head: true })
    .eq("dining_table_id", id)
    .in("payment_status", ["unpaid", "partial"])
    .neq("status", "voided");
  if ((count ?? 0) > 0) return { ok: false, error: "This table has an unpaid bill. Settle it first." };
  const { error } = await supabase.from("dining_tables").update({ is_active: false }).eq("id", id);
  if (error) return { ok: false, error: error.message };
  return done("Table removed.");
}

export async function setPaymentMethod(id: string, active: boolean): Promise<Result> {
  const user = await getCurrentUser();
  if (!user || !can(user, "settings.manage")) return { ok: false, error: "Only an owner or manager can change payment methods." };
  const supabase = await createClient();
  if (!active) {
    const { count } = await supabase.from("payment_methods").select("id", { count: "exact", head: true }).eq("is_active", true);
    if ((count ?? 0) <= 1) return { ok: false, error: "Keep at least one payment method switched on." };
  }
  const { error } = await supabase.from("payment_methods").update({ is_active: active }).eq("id", id);
  if (error) return { ok: false, error: error.message };
  return done(active ? "Payment method switched on." : "Payment method switched off.");
}

/** "Ask for a reference" (UPI transaction ID, card last 4) and the UPI ID shown to customers. */
export async function savePaymentOptions(id: string, askReference: boolean, upiId: string): Promise<Result> {
  const user = await getCurrentUser();
  if (!user || !can(user, "settings.manage")) return { ok: false, error: "Only an owner or manager can change payment methods." };
  const upi = upiId.trim();
  if (upi && !/^[A-Za-z0-9._-]{2,200}@[A-Za-z][A-Za-z0-9]{1,63}$/.test(upi)) {
    return { ok: false, error: "A UPI ID looks like yourshop@okbank." };
  }
  const supabase = await createClient();
  const { error } = await supabase.from("payment_methods").update({ ask_reference: askReference, upi_id: upi || null }).eq("id", id);
  if (error) return { ok: false, error: error.message };
  return done("Payment method saved.");
}

/* ---------- shared counter tablets ---------- */

/**
 * Turns the tablet this is pressed on into a shared counter. A dedicated sign-in
 * is created for the tablet itself. It has no permissions of its own: staff
 * unlock it with their PIN, and every bill is recorded in their name. The
 * manager is signed out of this tablet as part of the switch.
 */
export async function setUpThisTabletAsCounter(name: string): Promise<Result> {
  const user = await getCurrentUser();
  if (!user || !can(user, "settings.manage")) return { ok: false, error: "Only an owner or manager can set up a counter tablet." };
  if (user.device_name) return { ok: false, error: "This tablet is already a counter." };
  const label = name.trim();
  if (!label) return { ok: false, error: "Give the tablet a name, e.g. Counter 1." };

  const email = `counter-${randomUUID()}@devices.sna-pos.app`;
  const password = randomBytes(24).toString("base64url");
  const plain = createPlainClient<Database>(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: signUp, error: signUpError } = await plain.auth.signUp({ email, password });
  if (signUpError || !signUp.user) return { ok: false, error: `Could not create the tablet's sign-in: ${signUpError?.message ?? "unknown error"}` };
  let session = signUp.session;
  if (!session) {
    const { data: signIn } = await plain.auth.signInWithPassword({ email, password });
    session = signIn.session;
  }
  if (!session) {
    return { ok: false, error: "Supabase asks new sign-ins to confirm their email, so the tablet cannot sign in. Switch off email confirmation for now, or ask SNA support." };
  }

  const supabase = await createClient();
  const { data: mgr } = await supabase.auth.getSession();
  const { data: deviceId, error: regError } = await supabase.rpc("register_counter_device", { p_auth_user_id: signUp.user.id, p_name: label });
  if (regError) return { ok: false, error: regError.message };

  // Switch this browser from the manager to the tablet's own sign-in.
  const { error: setError } = await supabase.auth.setSession({ access_token: session.access_token, refresh_token: session.refresh_token });
  if (setError) {
    await supabase.rpc("remove_counter_device", { p_device_id: deviceId });
    return { ok: false, error: "This tablet could not switch to the counter sign-in. Nothing was changed. Try again." };
  }
  // End the manager's session on this tablet (best effort: it is no longer stored here anyway).
  if (mgr.session) {
    const old = createPlainClient<Database>(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    await old.auth.setSession({ access_token: mgr.session.access_token, refresh_token: mgr.session.refresh_token });
    await old.auth.signOut({ scope: "local" });
  }
  revalidatePath("/", "layout");
  redirect("/counter");
}

export async function removeCounter(deviceId: string): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("remove_counter_device", { p_device_id: deviceId });
  if (error) return { ok: false, error: error.message };
  return done("Counter removed. That tablet can no longer be unlocked.");
}

/** After 15 wrong PINs in a day a tablet stays locked until a manager clears it. */
export async function clearCounterLock(deviceId: string): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("clear_pin_lockout", { p_device_id: deviceId });
  if (error) return { ok: false, error: error.message };
  return done("PIN lock cleared. Staff can unlock that tablet again.");
}
