"use server";

import { redirect } from "next/navigation";
import { createConsoleClient } from "@/lib/supabase/server";

export type ConsolePasswordState = { error: string | null };

/** Save a new password for the person signed in to the SNA console. */
export async function changeConsolePassword(_prev: ConsolePasswordState, formData: FormData): Promise<ConsolePasswordState> {
  const password = String(formData.get("password") ?? "");
  const confirm = String(formData.get("confirm") ?? "");
  if (password.length < 8) return { error: "Use a password of at least 8 characters." };
  if (password.length > 72) return { error: "Use a password of at most 72 characters." };
  if (password !== confirm) return { error: "The two passwords do not match." };

  const supabase = await createConsoleClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/sna/login");
  // Only SNA staff reach this. (The console layout checks too; the database is the real guard.)
  if (!(await supabase.rpc("sna_me")).data) redirect("/sna/login");

  const { error } = await supabase.auth.updateUser({ password });
  if (error) {
    return { error: /different|same/i.test(error.message) ? "Choose a password different from the one you have now." : error.message };
  }
  redirect("/sna");
}
