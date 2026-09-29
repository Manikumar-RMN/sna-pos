"use server";

import { randomBytes, randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { cookies } from "next/headers";
import { isLang } from "@/lib/i18n";
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
  // Tables belong to the outlet you are working in.
  const branch = { id: user.branch_id };

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
    const { count } = await supabase.from("payment_methods").select("id", { count: "exact", head: true }).eq("is_active", true).not("kind", "in", "(gift_card,loyalty)");
    if ((count ?? 0) <= 1) return { ok: false, error: "Keep at least one payment method switched on." };
  }
  const { error } = await supabase.from("payment_methods").update({ is_active: active }).eq("id", id);
  if (error) return { ok: false, error: error.message };
  return done(active ? "Payment method switched on." : "Payment method switched off.");
}

/**
 * Add (id null) or change a payment method: its name, kind, "ask for a reference"
 * (UPI transaction ID, card last 4) and the UPI ID used for the scan-to-pay QR.
 */
export async function savePaymentOptions(
  id: string | null,
  askReference: boolean,
  upiId: string,
  name?: string,
  kind?: string,
): Promise<Result> {
  const user = await getCurrentUser();
  if (!user || !can(user, "settings.manage")) return { ok: false, error: "Only an owner or manager can change payment methods." };
  const upi = upiId.trim();
  if (upi && !/^[A-Za-z0-9._-]{2,200}@[A-Za-z][A-Za-z0-9]{1,63}$/.test(upi)) {
    return { ok: false, error: "A UPI ID looks like yourshop@okbank." };
  }
  const supabase = await createClient();
  let finalName = name?.trim() ?? "";
  let finalKind = kind ?? "";
  if (id && (!finalName || !finalKind)) {
    const { data: cur } = await supabase.from("payment_methods").select("name, kind").eq("id", id).maybeSingle();
    if (!cur) return { ok: false, error: "Payment method not found." };
    finalName = finalName || cur.name;
    finalKind = finalKind || cur.kind;
  }
  const { error } = await supabase.rpc("save_payment_method", {
    p_id: id as string,
    p_name: finalName,
    p_kind: finalKind,
    p_ask_reference: askReference,
    p_upi_id: upi || undefined,
  });
  if (error) return { ok: false, error: error.message };
  return done(id ? "Payment method saved." : `${finalName} added.`);
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

/** The restaurant's second language, shown under the English words on every device ("" = none). */
export async function setSecondLanguage(lang: string): Promise<Result> {
  if (lang !== "" && !isLang(lang)) return { ok: false, error: "Unknown language." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_second_language", { p_lang: lang });
  if (error) return { ok: false, error: error.message };
  return done(lang ? "Second language saved." : "Second language switched off.");
}

/**
 * This device only: "" follows the restaurant, "none" shows English only, or a language code.
 * Kept in a cookie on the device, so a kitchen tablet can show Hindi while the counter shows Tamil.
 */
export async function setDeviceLanguage(lang: string): Promise<Result> {
  if (lang !== "" && lang !== "none" && !isLang(lang)) return { ok: false, error: "Unknown language." };
  const jar = await cookies();
  if (lang === "") jar.delete("sna_lang2");
  else jar.set("sna_lang2", lang, { path: "/", maxAge: 60 * 60 * 24 * 400, sameSite: "lax", secure: true, httpOnly: true });
  revalidatePath("/", "layout");
  return { ok: true, message: "Saved for this device." };
}

/** New QR code for one table; the old printed code stops working. */
export async function resetTableQr(tableId: string): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("reset_table_qr", { p_table: tableId });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/tables/qr");
  return { ok: true, message: "New QR code made." };
}

/** Open API: a new key (shown once). */
export async function createApiKey(name: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_api_key", { p_name: name });
  if (error) return { ok: false as const, error: error.message };
  revalidatePath("/settings/api");
  return { ok: true as const, key: (data as { key: string }).key };
}

export async function revokeApiKey(id: string): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("revoke_api_key", { p_id: id });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/api");
  return { ok: true, message: "Key removed." };
}

/** Business day: shifts on/off and the time the day ends (after midnight). */
export async function saveDaySettings(shiftsEnabled: boolean, cutoff: string): Promise<Result> {
  if (!/^\d{2}:\d{2}$/.test(cutoff)) return { ok: false, error: "Choose the time the day ends." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_day_settings", { p_shifts_enabled: shiftsEnabled, p_cutoff: cutoff });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/shift");
  return done(shiftsEnabled ? "Saved. Cashiers now open a shift before billing." : "Saved. Billing starts without opening a shift.");
}

/** Meal sessions for the whole restaurant (outletId null) or one outlet. The database refuses overlaps. */
export async function saveSessions(
  outletId: string | null,
  rows: { name: string; start: string; end: string; days: number[] }[],
  clearOutletId: string | null = null,
): Promise<Result> {
  const supabase = await createClient();
  // Switching an outlet back to the shared times removes its own times.
  if (clearOutletId) {
    const { error: e } = await supabase.rpc("save_meal_sessions", { p_branch: clearOutletId, p_sessions: [] as unknown as Json });
    if (e) return { ok: false, error: e.message };
  }
  const { error } = await supabase.rpc("save_meal_sessions", {
    p_branch: outletId as unknown as string,
    p_sessions: rows.map((r) => ({ name: r.name, start: r.start, end: r.end, days: r.days })) as unknown as Json,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/day");
  return { ok: true, message: "Sessions saved. New bills use these times." };
}
