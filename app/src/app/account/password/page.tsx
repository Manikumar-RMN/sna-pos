import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PasswordForm } from "./password-form";

export const dynamic = "force-dynamic";

export default async function PasswordPage({ searchParams }: { searchParams: Promise<{ recovery?: string; to?: string }> }) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { recovery, to } = await searchParams;
  const toConsole = to === "console";

  const { data: state } = await supabase.rpc("my_account_state");
  if (state === "device_locked" || state === "device_removed" || state === "active" && user.email?.endsWith("@devices.sna-pos.app")) {
    redirect("/counter");
  }
  // SNA staff with no restaurant of their own still need to be able to choose a password
  // (a reset link, or "Change password" in the SNA console).
  const snaOnly = state === "new" && !!(await supabase.rpc("sna_me")).data;
  if ((state === "new" && !snaOnly) || state === "deactivated") redirect("/setup");
  const forced = state === "must_change_password";

  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-10">
      <div className="w-full max-w-sm">
        <h1 className="text-xl font-bold tracking-tight">{forced || recovery ? "Choose a new password" : "Change password"}</h1>
        <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
          {forced
            ? "Your manager reset your password. Choose your own before you continue."
            : recovery
              ? "You opened a password reset link. Choose a new password for " + (user.email ?? "your account") + "."
              : "Signed in as " + (user.email ?? "") + "."}
        </p>
        <PasswordForm allowCancel={!forced && !recovery} toConsole={toConsole} />
      </div>
    </main>
  );
}
