"use server";

import { cookies } from "next/headers";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { CONSOLE_COOKIE } from "../console-cookie";

export type ConsoleSignInState = { error: string | null };

// One message for every failure, so the page never says whether an email belongs to SNA staff.
const NO_MATCH = "That email and password do not match an SNA staff account.";

/** Sign in to the SNA console. Only people in the SNA staff list get in. */
export async function signInToConsole(_prev: ConsoleSignInState, formData: FormData): Promise<ConsoleSignInState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  if (!email || !password) return { error: "Enter your email and password." };

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error || !data.user) return { error: NO_MATCH };

  const { data: me } = await supabase.rpc("sna_me");
  if (!me) {
    // A real account, but not SNA staff: this page must not leave them signed in.
    await supabase.auth.signOut({ scope: "local" });
    return { error: NO_MATCH };
  }

  (await cookies()).set(CONSOLE_COOKIE, data.user.id, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/sna",
    maxAge: 60 * 60 * 12,
  });
  revalidatePath("/sna", "layout");
  redirect("/sna");
}

/** Sign out of the console on this browser and go back to the console's own sign-in page. */
export async function signOutOfConsole() {
  const supabase = await createClient();
  await supabase.auth.signOut({ scope: "local" });
  (await cookies()).delete({ name: CONSOLE_COOKIE, path: "/sna" });
  revalidatePath("/", "layout");
  redirect("/sna/login");
}
