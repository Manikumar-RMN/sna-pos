"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type AuthState = { error: string | null; notice?: string | null };

/**
 * One action handles both sign-in and account creation. Which one runs is
 * decided by the `intent` field, set by whichever button was pressed — so both
 * buttons submit the same email and password. (The earlier design put the two
 * buttons in separate forms, which meant the "create account" button submitted
 * no credentials at all.)
 */
export async function authenticate(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const intent = String(formData.get("intent") ?? "signin");
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");

  if (!email || !password) {
    return { error: "Enter your email and password." };
  }

  const supabase = await createClient();

  if (intent === "signup") {
    if (password.length < 8) {
      return { error: "Use a password of at least 8 characters." };
    }
    const { data, error } = await supabase.auth.signUp({ email, password });
    if (error) {
      return { error: error.message };
    }
    // When email confirmation is required, there is no session yet — tell the
    // person plainly instead of silently doing nothing.
    if (!data.session) {
      return {
        error: null,
        notice: "Account created. Check your email to confirm it, then sign in here.",
      };
    }
    revalidatePath("/", "layout");
    redirect("/setup");
  }

  // Sign in. The message is deliberately vague — saying "no such email" would
  // tell an attacker which addresses are registered.
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    return { error: "That email and password do not match an account." };
  }
  revalidatePath("/", "layout");
  redirect("/dashboard");
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  revalidatePath("/", "layout");
  redirect("/login");
}
