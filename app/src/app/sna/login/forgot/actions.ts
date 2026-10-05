"use server";

import { createClient } from "@/lib/supabase/server";

export type ConsoleForgotState = { error: string | null; sent?: boolean };

/**
 * Sends a password reset link for the SNA console. The reply is the same whether or not
 * the address is SNA staff, so this page cannot be used to find out who is.
 * Delivery needs an email service connected to Supabase Auth; until then the link only
 * reaches addresses that are members of the Supabase project.
 */
export async function requestConsoleReset(_prev: ConsoleForgotState, formData: FormData): Promise<ConsoleForgotState> {
  const email = String(formData.get("email") ?? "").trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return { error: "Enter the email you sign in with." };
  // Fixed address, never taken from the request, so a forged header cannot send the link elsewhere.
  const site = (process.env.NEXT_PUBLIC_SITE_URL || "https://sna-pos.vercel.app").replace(/\/$/, "");
  const supabase = await createClient();
  await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${site}/auth/confirm?next=${encodeURIComponent("/account/password?recovery=1&to=console")}`,
  });
  return { error: null, sent: true };
}
