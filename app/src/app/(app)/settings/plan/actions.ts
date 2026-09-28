"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type PlanResult = { ok: true; message: string } | { ok: false; error: string };

/** Owner asks SNA for an upgrade, an add-on module or a new outlet. SNA decides in its console. */
export async function requestPlanChange(input: {
  kind: "upgrade" | "module" | "outlet";
  module?: string;
  outletName?: string;
  outletCity?: string;
  note?: string;
}): Promise<PlanResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("request_plan_change", {
    p_kind: input.kind,
    p_module: input.module ?? undefined,
    p_outlet_name: input.outletName ?? undefined,
    p_outlet_city: input.outletCity ?? undefined,
    p_note: input.note ?? undefined,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/plan");
  return { ok: true, message: "Sent to the SNA team. You will see it switched on here once they approve." };
}

export async function cancelPlanRequest(id: string): Promise<PlanResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_plan_request", { p_id: id });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/plan");
  return { ok: true, message: "Request cancelled." };
}
