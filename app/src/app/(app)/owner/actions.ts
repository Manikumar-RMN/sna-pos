"use server";

import { createClient } from "@/lib/supabase/server";

export async function savePushSubscription(endpoint: string, p256dh: string, auth: string) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_push_subscription", { p_endpoint: endpoint, p_p256dh: p256dh, p_auth: auth });
  return error ? { ok: false as const, error: error.message } : { ok: true as const };
}

export async function removePushSubscription(endpoint: string) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("remove_push_subscription", { p_endpoint: endpoint });
  return error ? { ok: false as const, error: error.message } : { ok: true as const };
}
