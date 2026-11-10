import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { signOut } from "@/app/login/actions";
import { SetupForms } from "./setup-forms";
import { SNA_CONTACT_EMAIL } from "@/lib/sna-contact";

export default async function SetupPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: state } = await supabase.rpc("my_account_state");
  if (state === "active") redirect("/dashboard");
  if (state === "device_locked" || state === "device_removed") redirect("/login");
  if (state === "must_change_password") redirect("/account/password");
  // SNA staff without a restaurant of their own work in the SNA console, which has its own
  // sign-in. This restaurant-side sign-in is of no use to them: say so, and let them leave it,
  // so they can sign in here as a restaurant owner or staff member instead.
  const snaOnly = state === "new" && !!(await supabase.rpc("sna_me")).data;
  if (snaOnly) {
    return (
      <main className="min-h-screen px-4 py-10">
        <div className="mx-auto w-full max-w-lg">
          <h1 className="text-xl font-bold tracking-tight">This is an SNA console account</h1>
          <div className="card mt-4 space-y-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
            <p>
              {user.email} is an SNA staff sign-in. It has no restaurant, so there is nothing to open here.
            </p>
            <Link href="/sna" className="btn btn-primary w-full">
              Open the SNA console
            </Link>
            <form action={signOut}>
              <button type="submit" className="btn w-full" style={{ border: "1px solid var(--color-line)", color: "var(--color-ink-2)" }}>
                Sign out here, to sign in to a restaurant
              </button>
            </form>
          </div>
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen px-4 py-10">
      <div className="mx-auto w-full max-w-lg">
        <h1 className="text-xl font-bold tracking-tight">
          {state === "deactivated" ? "Your access is switched off" : "Join your restaurant"}
        </h1>

        {state === "deactivated" ? (
          <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
            Your restaurant&rsquo;s owner or manager has switched off your access. If you think this is a mistake,
            ask them to switch it back on from the Staff screen.
          </div>
        ) : (
          <div className="mt-4">
            <SetupForms email={user.email ?? ""} contact={SNA_CONTACT_EMAIL} />
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
