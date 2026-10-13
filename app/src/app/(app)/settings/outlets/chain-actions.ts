"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

export async function setOutletRegion(branchId: string, region: string, royalty: number): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("outlet_set_region", { p_branch: branchId, p_region: region, p_royalty: royalty });
  if (error) return { error: clean(error.message) };
  revalidatePath("/settings/outlets");
  return { error: null };
}

/** One price for a dish in every outlet of a region; an empty price goes back to the main menu price. */
export async function setRegionPrice(region: string, productId: string, price: number | null): Promise<{ error: string | null; outlets?: number }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("region_set_price", { p_region: region, p_product: productId, p_price: price as number });
  if (error) return { error: clean(error.message) };
  revalidatePath("/settings/outlets");
  revalidatePath("/pos");
  return { error: null, outlets: (data as { outlets: number }).outlets };
}

export type ChainRow = { branch_id: string; outlet: string; code: string; region: string; royalty_percent: number; bills: number; sales: number; tax: number; total: number; average_bill: number; royalty: number };
export type RegionRow = { region: string; outlets: number; bills: number; sales: number; total: number; royalty: number };

export async function chainReport(from: string, to: string): Promise<{ error: string | null; outlets: ChainRow[]; regions: RegionRow[] }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("chain_report", { p_from: from, p_to: to });
  if (error) return { error: clean(error.message), outlets: [], regions: [] };
  const d = data as { outlets: ChainRow[]; regions: RegionRow[] };
  return { error: null, outlets: d.outlets ?? [], regions: d.regions ?? [] };
}
