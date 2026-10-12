import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Batches, type BatchData } from "./batches";

/** Batches of ready-made goods: what was made, what is left, what expired. */
export default async function BatchesPage() {
  const user = await requireUser();
  if (!can(user, "order.create")) {
    return (
      <div className="card mx-auto mt-4 max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role cannot open this screen. Ask an owner or manager.
      </div>
    );
  }
  const supabase = await createClient();
  const { data } = await supabase.rpc("batches_list");
  return <Batches data={(data ?? { batches: [], dishes: [] }) as unknown as BatchData} />;
}
