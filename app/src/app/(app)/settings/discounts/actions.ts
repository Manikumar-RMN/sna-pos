"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";
import { friendlyDbError } from "@/lib/db-error";

export type DiscountInput = {
  id: string | null;
  name: string;
  kind: "percent" | "amount";
  value: number;
  valid_from: string | null;
  valid_to: string | null;
  order_types: string[];
  outlet_ids: string[] | null;
  is_active: boolean;
};

function clean(message: string) {
  return message.replace(/^.*?ERROR:\s*/i, "").trim();
}

async function guard() {
  const user = await getCurrentUser();
  return user && can(user, "settings.manage") ? user : null;
}

/** Saves one named discount. The database checks every field. */
export async function saveDiscount(input: DiscountInput): Promise<{ error: string | null }> {
  if (!(await guard())) return { error: "Changing discounts needs the “Manage settings” permission." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_discount_preset", {
    // The database function needs p_id sent even for a new discount (null).
    p_id: input.id as string,
    p_name: input.name,
    p_kind: input.kind,
    p_value: input.value,
    p_valid_from: input.valid_from ?? undefined,
    p_valid_to: input.valid_to ?? undefined,
    p_order_types: input.order_types,
    p_outlet_ids: input.outlet_ids ?? undefined,
    p_active: input.is_active,
  });
  if (error) return { error: clean(friendlyDbError(error)) };
  revalidatePath("/settings/discounts");
  return { error: null };
}

/** The largest discount allowed on a bill, as a percent. Empty = no limit. Owners can go above it. */
export async function saveMaxDiscount(percent: number | null): Promise<{ error: string | null }> {
  if (!(await guard())) return { error: "Changing discounts needs the “Manage settings” permission." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_max_discount", { p_percent: percent as number });
  if (error) return { error: clean(friendlyDbError(error)) };
  revalidatePath("/settings/discounts");
  return { error: null };
}
