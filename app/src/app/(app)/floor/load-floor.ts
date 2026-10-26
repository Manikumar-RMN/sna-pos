import { createClient } from "@/lib/supabase/server";
import { parseFloorRows, type FloorRow } from "@/lib/table-status";

/**
 * The floor facts for the signed-in outlet (public.floor_status, migration 134), for server pages.
 * If the database function is not there yet or fails, the answer is an empty list and the screens fall back to plain free / busy
 * from the bills they already load: table colours are a help, never a reason the order screen cannot open.
 *
 * (The rpc name is called through a loose type because database.types.ts has no entry for floor_status until it is regenerated.)
 */
export async function loadFloor(): Promise<FloorRow[]> {
  const supabase = await createClient();
  const loose = supabase as unknown as { rpc: (fn: string) => Promise<{ data: unknown; error: { message?: string } | null }> };
  const { data, error } = await loose.rpc("floor_status");
  if (error) return [];
  return parseFloorRows(data);
}
