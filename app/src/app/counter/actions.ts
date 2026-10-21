"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

export type UnlockResult = { ok: true; next: string } | { ok: false; error: string };

/**
 * Unlocks a shared counter tablet with a staff PIN. The database checks the PIN,
 * counts wrong tries (5 wrong in 5 minutes pauses the tablet; 15 in a day locks
 * it until a manager clears it) and records who unlocked it. From then on every
 * bill is recorded in that person's name.
 */
export async function unlockWithPin(pin: string): Promise<UnlockResult> {
  if (!/^\d{4,6}$/.test(pin)) return { ok: false, error: "A PIN is 4 to 6 digits." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pin_unlock", { p_pin: pin });
  if (error) return { ok: false, error: friendlyDbError(error) };
  const res = (data ?? {}) as { ok?: boolean; error?: string; can_bill?: boolean };
  if (!res.ok) return { ok: false, error: res.error ?? "Wrong PIN." };
  revalidatePath("/", "layout");
  return { ok: true, next: res.can_bill ? "/pos" : "/dashboard" };
}

/** Called while the tablet is in use. Returns false once the session has ended. */
export async function keepCounterAlive(): Promise<boolean> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pin_touch");
  return !error && data === true;
}

/** Locks the counter: the next person must enter their own PIN. */
export async function lockCounter() {
  const supabase = await createClient();
  const { error } = await supabase.rpc("pin_lock");
  if (error) throw new Error("The tablet could not be locked. Check the internet connection and try again.");
  revalidatePath("/", "layout");
  redirect("/counter");
}

/** Signs a removed counter tablet out, so it can be used normally again. */
export async function signOutCounter() {
  const supabase = await createClient();
  const { data: state } = await supabase.rpc("my_account_state");
  // A working counter is signed out by a manager removing it in Settings, never from the PIN screen.
  if (state === "device_locked") redirect("/counter");
  await supabase.auth.signOut();
  revalidatePath("/", "layout");
  redirect("/login");
}
