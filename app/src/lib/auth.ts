import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type CurrentUser = {
  user_id: string;
  restaurant_id: string;
  full_name: string;
  email: string | null;
  employee_code: string;
  role_id: string;
  role_name: string;
  trading_name: string;
  country_code: string;
  currency_code: string;
  timezone: string;
  permissions: string[];
  must_change_password: boolean | null;
  /** Set when this is a shared counter tablet unlocked with a PIN. */
  device_name: string | null;
  /** "basic" or "professional". */
  edition: string;
  /** Professional features and add-on modules switched on for this restaurant. */
  features: string[];
  /** This person also works for SNA (sales, implementer, support, admin). */
  is_sna_staff: boolean;
  /** The outlet this person is working in now (a counter tablet: its own outlet). */
  branch_id: string;
  branch_name: string;
  outlet_count: number;
  /** Restaurant's second language (shown under English), or null. */
  second_language: string | null;
};

/**
 * Who is signed in, which restaurant they belong to, and what they may do.
 *
 * Returns null when the account exists in Auth but has no restaurant yet —
 * a brand-new signup that has not been through /setup.
 */
// cache(): the layout and the page both ask "who is signed in?" on every screen;
// this makes it one database trip per request instead of two.
export const getCurrentUser = cache(async function getCurrentUser(): Promise<CurrentUser | null> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("v_current_user")
    .select("*")
    .maybeSingle();

  if (error || !data) return null;
  return data as CurrentUser;
});

/**
 * Use in any page that requires a set-up restaurant. A locked counter tablet
 * goes to the PIN screen; a new account goes to setup.
 */
export async function requireUser(): Promise<CurrentUser> {
  const current = await getCurrentUser();
  if (!current) {
    const supabase = await createClient();
    const { data: state } = await supabase.rpc("my_account_state");
    if (state === "device_locked" || state === "device_removed") redirect("/login"); // there is no separate counter page any more
    if (state === "must_change_password") redirect("/account/password");
    if (state === "signed_out") redirect("/login");
    if (state === "new" || state === "deactivated") redirect("/setup");
    // Signed in and active, yet the account could not be read: show the error
    // screen rather than bouncing between pages.
    throw new Error("Your account could not be loaded. Please refresh the page.");
  }
  return current;
}

/**
 * Permission check for the UI.
 *
 * This hides controls; it does not protect data. The database enforces the
 * real rules — a cashier who calls the API directly still cannot void a bill.
 */
export function can(user: CurrentUser, permission: string): boolean {
  return user.permissions?.includes(permission) ?? false;
}

/**
 * Is a Professional feature or paid add-on switched on for this restaurant?
 * The database refuses the action anyway; this keeps the screens tidy.
 */
export function has(user: CurrentUser, feature: string): boolean {
  return user.features?.includes(feature) ?? false;
}
