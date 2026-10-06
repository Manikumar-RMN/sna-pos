import { redirect } from "next/navigation";
import { createConsoleClient as createClient } from "@/lib/supabase/server";
import { StaffEditor, type SnaStaff } from "./staff-editor";

export default async function SnaStaffPage() {
  const supabase = await createClient();
  const { data: me } = await supabase.rpc("sna_me");
  if ((me as { role?: string } | null)?.role !== "admin") redirect("/sna");
  const { data, error } = await supabase.rpc("sna_staff_list");
  return (
    <div>
      <h1 className="text-2xl font-bold">SNA staff</h1>
      <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
        Sales set licences, record sales and approve upgrades, modules and outlets. Implementers set up approved outlets. Support can create clients, keep
        contacts and write notes. Admins do everything. A new person first makes a sign-in on the restaurant sign-in page (Owner tab, then &ldquo;I have an
        invite code&rdquo;; they need no code and join no restaurant), then you add them here with the same email.
      </p>
      {error && <div className="card mt-3 p-3 text-sm">{error.message}</div>}
      <StaffEditor staff={(data ?? []) as unknown as SnaStaff[]} />
    </div>
  );
}
