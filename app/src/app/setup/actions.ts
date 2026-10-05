"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type SetupState = { error: string | null };

// New restaurants are created by SNA staff from the SNA console (sna_create_client), not from here.

/** A staff member joins the restaurant that invited them. */
export async function joinWithCode(_prev: SetupState, formData: FormData): Promise<SetupState> {
  const code = String(formData.get("code") ?? "").trim();
  if (code.replace(/[^A-Za-z0-9]/g, "").length !== 8) {
    return { error: "The invite code is 8 letters and numbers, like ABCD-2345." };
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc("claim_staff_invite", { p_code: code });
  if (error) return { error: error.message };
  revalidatePath("/", "layout");
  redirect("/dashboard");
}
