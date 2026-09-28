import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { SectionHead } from "../section-head";
import { PlanView, type Plan } from "./plan-view";

export default async function PlanSettings() {
  const user = await requireUser();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("my_plan");
  if (error || !data) {
    return <div className="card p-5 text-sm">Could not load your plan: {error?.message}</div>;
  }
  return (
    <div>
      <SectionHead title="Plan and modules">
        Your edition, the add-on modules you use and your outlets. Ask for a change here; the SNA team switches it on for you.
      </SectionHead>
      <PlanView plan={data as unknown as Plan} isOwner={user.role_name === "Owner"} />
    </div>
  );
}
