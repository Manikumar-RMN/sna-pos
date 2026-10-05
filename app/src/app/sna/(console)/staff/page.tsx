import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
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
        Sales approve upgrades, modules and outlets. Implementers set up approved outlets. Support can look only. Admins do everything.
        A new person first signs up on SNA POS with their email (they do not create a restaurant), then you add them here.
      </p>
      {error && <div className="card mt-3 p-3 text-sm">{error.message}</div>}
      <StaffEditor staff={(data ?? []) as unknown as SnaStaff[]} />
    </div>
  );
}
