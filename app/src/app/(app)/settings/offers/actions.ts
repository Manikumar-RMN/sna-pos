"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";

export type OfferInput = {
  id: string | null;
  name: string;
  days: number[];
  start_time: string;
  end_time: string;
  kind: "percent_off" | "price";
  value: number;
  product_ids: string[];
  category_ids: string[];
  branch_id: string | null;
  valid_from: string | null;
  valid_to: string | null;
  is_active: boolean;
};

function clean(message: string) {
  return message.replace(/^.*?ERROR:\s*/i, "").trim();
}

/** Saves a happy hour / time-based price. The database checks every field. */
export async function saveOffer(input: OfferInput): Promise<{ error: string | null }> {
  const user = await getCurrentUser();
  if (!user || !can(user, "menu.manage")) return { error: "Changing offers needs the “Manage menu” permission." };
  if (!input.name.trim()) return { error: "Give the offer a name, for example Happy hour." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_price_rule", { p: JSON.parse(JSON.stringify(input)) });
  if (error) return { error: clean(error.message) };
  revalidatePath("/settings/offers");
  revalidatePath("/pos");
  return { error: null };
}

export async function deleteOffer(id: string): Promise<{ error: string | null }> {
  const user = await getCurrentUser();
  if (!user || !can(user, "menu.manage")) return { error: "Changing offers needs the “Manage menu” permission." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("delete_price_rule", { p_id: id });
  if (error) return { error: clean(error.message) };
  revalidatePath("/settings/offers");
  revalidatePath("/pos");
  return { error: null };
}
