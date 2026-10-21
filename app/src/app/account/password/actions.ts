"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

export type PasswordState = { error: string | null };

export async function changePassword(_prev: PasswordState, formData: FormData): Promise<PasswordState> {
  const password = String(formData.get("password") ?? "");
  const confirm = String(formData.get("confirm") ?? "");
  if (password.length < 8) return { error: "Use a password of at least 8 characters." };
  if (password.length > 72) return { error: "Use a password of at most 72 characters." };
  if (password !== confirm) return { error: "The two passwords do not match." };

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  // A counter tablet's own sign-in must never get a password someone knows.
  const { data: state } = await supabase.rpc("my_account_state");
  if (state === "device_locked" || state === "device_removed" || user.email?.endsWith("@devices.sna-pos.app")) {
    redirect("/counter");
  }

  const { error } = await supabase.auth.updateUser({ password });
  if (error) {
    return {
      error: /different|same/i.test(error.message)
        ? "Choose a password different from the temporary one."
        : friendlyDbError(error),
    };
  }
  // Clears the "must change password" flag set by a manager's reset, and logs it.
  const { error: flagError } = await supabase.rpc("password_changed");
  if (flagError) return { error: "Your password was saved, but the account could not be updated. Refresh the page and sign in with the new password." };
  revalidatePath("/", "layout");
  // SNA staff who came from the console, or who have no restaurant, go back to the console
  // (it asks for its own sign-in if they are not signed in there); everyone else to their restaurant.
  if ((formData.get("to") === "console" || state === "new") && (await supabase.rpc("sna_me")).data) redirect("/sna");
  redirect("/dashboard");
}
