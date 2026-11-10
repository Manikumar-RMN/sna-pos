"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

export type ListResult = { ok: true; message: string } | { ok: false; error: string };

export async function addListItem(kind: "category" | "department", name: string): Promise<ListResult> {
  const n = name.trim();
  if (!n) return { ok: false, error: "Enter a name." };
  if (n.length > 40) return { ok: false, error: "Use up to 40 letters." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_stock_list_item", { p_kind: kind, p_name: n });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock", "layout");
  return { ok: true, message: `${n} added.` };
}

export async function setListItemActive(id: string, active: boolean): Promise<ListResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_stock_list_item_active", { p_id: id, p_active: active });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock", "layout");
  return { ok: true, message: active ? "Switched on." : "Switched off. Items already using it keep it." };
}

export async function startLists(): Promise<ListResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("seed_stock_lists_from_use");
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock", "layout");
  return { ok: true, message: "Lists started from what you already use." };
}
