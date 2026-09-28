import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { SectionHead } from "../section-head";
import { PrinterSetup } from "./printer-setup";

export default async function PrinterSettings() {
  await requireUser();
  const supabase = await createClient();
  const { data } = await supabase.from("products").select("kitchen_station").is("deleted_at", null);
  const stations = [...new Set((data ?? []).map((p) => (p.kitchen_station ?? "").trim() || "Kitchen"))].sort();
  if (!stations.includes("Kitchen")) stations.unshift("Kitchen");

  return (
    <div>
      <SectionHead title="Printers">
        Choose what THIS device prints. A counter prints bills; a kitchen or bar device prints its station&rsquo;s tickets as they arrive.
      </SectionHead>
      <PrinterSetup stations={stations} />
    </div>
  );
}
