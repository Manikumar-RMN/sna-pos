"use server";

import { createClient } from "@/lib/supabase/server";

export type ForgotState = { error: string | null; sent?: boolean };

/**
 * Sends a password reset email. The reply is the same whether or not the email
 * has an account, so nobody can use this page to find out who is registered.
 * Delivery needs an email service connected to Supabase (Auth → SMTP); until then
 * a manager can reset the password from the Staff screen instead.
 */
export async function requestReset(_prev: ForgotState, formData: FormData): Promise<ForgotState> {
  const email = String(formData.get("email") ?? "").trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return { error: "Enter the email you sign in with." };
  // Fixed address, never taken from the request, so a forged header cannot send the link elsewhere.
  const site = (process.env.NEXT_PUBLIC_SITE_URL || "https://sna-pos.vercel.app").replace(/\/$/, "");
  const supabase = await createClient();
  await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${site}/auth/confirm?next=${encodeURIComponent("/account/password?recovery=1")}`,
  });
  return { error: null, sent: true };
}
