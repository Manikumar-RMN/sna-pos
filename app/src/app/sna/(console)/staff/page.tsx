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
      <h1 className="text-2xl font-bold">Our team</h1>
      <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
        Who can sign in to this console, and what each person may do. Add a new person with their email: they get a temporary password and sign in at the SNA console.
      </p>
      {error && <div className="card mt-3 p-3 text-sm">{error.message}</div>}
      <StaffEditor staff={(data ?? []) as unknown as SnaStaff[]} myEmail={String((me as { email?: string } | null)?.email ?? "").toLowerCase()} />
    </div>
  );
}
