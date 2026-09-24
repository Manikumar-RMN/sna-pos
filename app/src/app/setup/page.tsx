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
            <SetupForms email={user.email ?? ""} />
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
