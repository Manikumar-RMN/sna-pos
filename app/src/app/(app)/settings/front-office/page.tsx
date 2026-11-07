import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../../upgrade-note";
import type { RatePlan } from "@/lib/fo";
import { SetupForms, type SetupData } from "../../front-office/setup/setup-forms";

export default async function FoSetupPage() {
  const user = await requireUser();
  if (!has(user, "front_office")) {
    return (
      <div className="mx-auto max-w-md">
        <UpgradeNote feature="Front office and housekeeping" />
      </div>
    );
  }
  if (!can(user, "fo.manage")) {
    return <div className="card mx-auto max-w-md p-5 text-sm">Your role cannot change the room setup.</div>;
  }
  const supabase = await createClient();
  const [{ data }, { data: rates }] = await Promise.all([supabase.rpc("fo_setup"), supabase.rpc("fo_rate_setup")]);
  const setup = { ...(data as unknown as SetupData), plans: ((rates as unknown as { plans: RatePlan[] } | null)?.plans ?? []) };
  return (
    <div className="mx-auto max-w-3xl">
      <h1 className="mb-3 text-xl font-extrabold">Front office: rooms and rates</h1>
      <SetupForms data={setup} currency={user.currency_code} />
    </div>
  );
}
