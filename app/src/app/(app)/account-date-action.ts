"use server";

import { createClient } from "@/lib/supabase/server";

export type AccountDateInfo = { date: string; oldDay: boolean } | null;

/** The business (account) date the next bill of this outlet will carry. Null if it cannot be read. */
export async function readAccountDate(): Promise<AccountDateInfo> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("account_date");
  if (error || !data) return null;
  const v = data as { date?: string; old_day?: boolean };
  return v.date ? { date: v.date, oldDay: !!v.old_day } : null;
}
