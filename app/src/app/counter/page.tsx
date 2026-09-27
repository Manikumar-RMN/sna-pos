import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PinPad } from "./pin-pad";

export const dynamic = "force-dynamic";

export default async function CounterPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: state } = await supabase.rpc("my_account_state");
  if (state === "active") redirect("/pos");
  if (state !== "device_locked" && state !== "device_removed") redirect("/setup");

  const { data: info } = await supabase.rpc("my_device_state");
  const d = (info ?? {}) as { device_name?: string; restaurant?: string };

  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-10">
      <div className="w-full max-w-xs text-center">
        <div
          className="mx-auto mb-3 grid h-12 w-12 place-items-center rounded-xl text-sm font-bold text-white"
          style={{ background: "var(--color-brand)" }}
        >
          SNA
        </div>
        {state === "device_removed" ? (
          <>
            <h1 className="text-lg font-bold">This counter was removed</h1>
            <p className="mt-2 text-sm" style={{ color: "var(--color-ink-2)" }}>
              A manager removed this tablet from the restaurant&rsquo;s counters. Ask them to set it up again from
              Settings → Counter tablets.
            </p>
            <PinPad removed />
          </>
        ) : (
          <>
            <h1 className="text-lg font-bold">{d.restaurant ?? "SNA POS"}</h1>
            <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
              {d.device_name ?? "Counter"} · enter your PIN
            </p>
            <PinPad />
          </>
        )}
      </div>
    </main>
  );
}
