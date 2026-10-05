import type { Metadata } from "next";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { CONSOLE_COOKIE } from "../console-cookie";
import { ConsoleSignIn } from "./sign-in-form";

export const metadata: Metadata = { title: "SNA console sign-in", robots: { index: false, follow: false } };

/** The SNA console's own sign-in page. Separate from the restaurant app's /login. */
export default async function ConsoleLoginPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (user && (await cookies()).get(CONSOLE_COOKIE)?.value === user.id) {
    const { data: me } = await supabase.rpc("sna_me");
    if (me) redirect("/sna");
  }

  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-10" style={{ background: "var(--color-ink)" }}>
      <div className="w-full max-w-sm">
        <h1 className="font-display text-2xl font-bold text-white">SNA console</h1>
        <p className="mt-1 text-sm" style={{ color: "rgba(255,255,255,0.75)" }}>
          For SNA staff only.
        </p>
        <div className="card mt-5 p-5">
          <ConsoleSignIn />
        </div>
      </div>
    </main>
  );
}
