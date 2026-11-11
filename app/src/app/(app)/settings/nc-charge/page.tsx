import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { SectionHead } from "../section-head";
import { NcCharge, type NcRow } from "./nc-charge";

export default async function NcChargePage() {
  const user = await requireUser();
  const canEdit = can(user, "settings.manage");
  const supabase = await createClient();
  const { data } = canEdit ? await supabase.rpc("list_nc_charge_targets", { p_all: true }) : { data: [] };
  return (
    <div className="space-y-4">
      <SectionHead title="No-charge accounts">
        Who bears the cost of a free bill: Admin &amp; General, Owner&rsquo;s guests, a manager&rsquo;s name. Once you add one, staff must
        choose it whenever a bill is made no-charge, and the No-charge KOT report shows it.
      </SectionHead>
      {canEdit ? <NcCharge rows={(data ?? []) as unknown as NcRow[]} /> : <p className="text-sm">Ask the owner to change this.</p>}
    </div>
  );
}
