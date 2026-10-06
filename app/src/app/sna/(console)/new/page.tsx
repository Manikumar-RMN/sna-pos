import Link from "next/link";
import { createConsoleClient as createClient } from "@/lib/supabase/server";
import { NewClientForm } from "./new-client-form";

/** SNA staff set up a new restaurant here. This is the only way a restaurant is created. */
export default async function NewClientPage() {
  const supabase = await createClient();
  const [{ data: me }, { data: countries }] = await Promise.all([
    supabase.rpc("sna_me"),
    supabase.from("countries").select("code, name, tax_system_name, tax_id_label, compliance_note").eq("is_supported", true).order("name"),
  ]);
  const role = (me as { role?: string } | null)?.role ?? "support";
  return (
    <div className="mx-auto max-w-3xl">
      <Link href="/sna" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← All clients
      </Link>
      <h1 className="mt-3 text-2xl font-bold">New client</h1>
      <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
        Creates the restaurant, its first outlet, the staff roles, the tax setup for the country and the owner&rsquo;s sign-in. Restaurants cannot be created
        any other way.
      </p>
      <NewClientForm
        canSell={role === "admin" || role === "sales"}
        countries={(countries ?? []).map((c) => ({
          code: c.code,
          name: c.name,
          taxName: c.tax_system_name ?? "Tax",
          taxIdLabel: c.tax_id_label ?? "Tax number",
          note: c.compliance_note ?? "",
        }))}
      />
    </div>
  );
}
