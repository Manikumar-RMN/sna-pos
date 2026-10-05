import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { signOut } from "@/app/login/actions";
import { SetupForms } from "./setup-forms";

export default async function SetupPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: state } = await supabase.rpc("my_account_state");
  if (state === "active") redirect("/dashboard");
  if (state === "device_locked" || state === "device_removed") redirect("/counter");
  if (state === "must_change_password") redirect("/account/password");
  // SNA staff without a restaurant of their own work in the SNA console.
  if (state === "new") {
    const { data: sna } = await supabase.rpc("sna_me");
    if (sna) redirect("/sna/login");
  }

  const { data: countries } = await supabase
    .from("countries")
    .select("code, name, tax_system_name, tax_id_label, compliance_note")
    .eq("is_supported", true)
    .order("name");

  return (
    <main className="min-h-screen px-4 py-10">
      <div className="mx-auto w-full max-w-lg">
        <h1 className="text-xl font-bold tracking-tight">
          {state === "deactivated" ? "Your access is switched off" : "Welcome to SNA POS"}
        </h1>

        {state === "deactivated" ? (
          <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
            Your restaurant&rsquo;s owner or manager has switched off your access. If you think this is a mistake,
            ask them to switch it back on from the Staff screen.
          </div>
        ) : (
          <div className="mt-4">
            <SetupForms
              email={user.email ?? ""}
              countries={(countries ?? []).map((c) => ({
                code: c.code,
                name: c.name,
                taxName: c.tax_system_name ?? "Tax",
                taxIdLabel: c.tax_id_label ?? "Tax number",
                note: c.compliance_note ?? "",
              }))}
            />
          </div>
        )}

        <form action={signOut} className="mt-6 text-center">
          <button type="submit" className="text-sm font-semibold" style={{ color: "var(--color-ink-3)" }}>
            Sign out
          </button>
        </form>
      </div>
    </main>
  );
}
