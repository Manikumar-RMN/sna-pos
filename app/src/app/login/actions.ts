"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type AuthState = { error: string | null; notice?: string | null };

/**
 * One action handles both sign-in and account creation. Which one runs is
 * decided by the `intent` field, set by whichever button was pressed.
 *
 * STAFF SIGNIN (intent="signin"):
 *   - Input: client_code, username, password
 *   - Flow: Lookup staff via RPC, then verify password with Supabase Auth
 *
 * INVITED STAFF SIGN-UP (intent="signup"):
 *   - Input: email, password, confirm (the password typed a second time)
 *   - Flow: Create the sign-in with Supabase Auth, then /setup asks for the invite code.
 *   - A sign-in alone gives nothing: restaurants are created only by SNA staff from the
 *     SNA console (sna_create_client); the database refuses anyone else.
 *
 * OWNER SIGNIN (intent="signin_email"):
 *   - Input: email, password
 *   - Flow: Sign in with Supabase Auth (existing flow)
 */
export async function authenticate(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const intent = String(formData.get("intent") ?? "signin");
  const clientCode = String(formData.get("clientCode") ?? "").trim();
  const username = String(formData.get("username") ?? "").trim();
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  const confirm = String(formData.get("confirm") ?? "");

  const supabase = await createClient();

  if (intent === "signup") {
    // A sign-in for someone invited to an existing restaurant
    if (!email || !password) {
      return { error: "Enter your email and password." };
    }
    if (password.length < 8) {
      return { error: "Use a password of at least 8 characters." };
    }
    if (password !== confirm) {
      return { error: "The two passwords are not the same. Type the same password in both boxes." };
    }
    const { data, error } = await supabase.auth.signUp({ email, password });
    if (error) {
      return { error: error.message };
    }
    if (!data.session) {
      return {
        error: null,
        notice: "Account created. Check your email to confirm it, then sign in here.",
      };
    }
    revalidatePath("/", "layout");
    redirect("/setup");
  }

  if (intent === "signin_email") {
    // Owner sign in with email
    if (!email || !password) {
      return { error: "Enter your email and password." };
    }
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      return { error: "That email and password do not match an account." };
    }
    revalidatePath("/", "layout");
    redirect("/dashboard");
  }

  // Staff sign in with client_code + username + password
  if (intent === "signin") {
    if (!clientCode || !username || !password) {
      return { error: "Enter your client code, username, and password." };
    }

    // login_staff checks the password itself and only hands back the sign-in
    // email once it matches, so a wrong guess learns nothing -- not even
    // whether that username exists. It also locks the account for five
    // minutes after five wrong passwords, because this path does not go
    // through Supabase Auth's own rate limiting until the step below.
    const { data, error: lookupError } = await supabase.rpc("login_staff", {
      p_client_code: clientCode,
      p_username: username,
      p_password: password,
    });

    if (lookupError) {
      return { error: "Could not reach the server. Check the internet connection." };
    }

    const result = (data ?? null) as
      | { email?: string; error?: string; minutes?: number }
      | null;

    if (!result) {
      return { error: "Could not reach the server. Check the internet connection." };
    }

    if (result.error === "locked") {
      const mins = result.minutes ?? 5;
      return {
        error: `Too many wrong passwords. Try again in ${mins} ${
          mins === 1 ? "minute" : "minutes"
        }.`,
      };
    }

    if (result.error === "inactive") {
      return { error: "This staff member is no longer active. Ask your manager." };
    }

    if (result.error || !result.email) {
      // Deliberately vague: the same message for a wrong code, a wrong
      // username and a wrong password, so none of them can be probed.
      return { error: "Invalid client code, username, or password." };
    }

    // The password is already verified; this is what actually mints the session.
    const { error: authError } = await supabase.auth.signInWithPassword({
      email: result.email,
      password,
    });

    if (authError) {
      return { error: "Invalid client code, username, or password." };
    }

    revalidatePath("/", "layout");
    redirect("/dashboard");
  }

  return { error: "Invalid request." };
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  revalidatePath("/", "layout");
  redirect("/login");
}
