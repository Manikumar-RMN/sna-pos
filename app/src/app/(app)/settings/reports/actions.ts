"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import type { Json } from "@/lib/supabase/database.types";

export type Result = { ok: true; message?: string } | { ok: false; error: string };

export type ScheduleInput = { time: string; days: number[]; emails: string[]; phoneAlert: boolean; active: boolean };

const isId = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f-]{36}$/i.test(v);

/** Add (id null) or change a daily-summary schedule for the outlet in use. The database checks every value. */
export async function saveReportSchedule(id: string | null, input: ScheduleInput): Promise<Result> {
  if (id !== null && !isId(id)) return { ok: false, error: "That schedule is not here any more. Refresh the page." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_report_schedule", {
    p_id: id as string,
    p: {
      time: String(input.time ?? ""),
      days: (Array.isArray(input.days) ? input.days : []).map(Number).filter((d) => Number.isInteger(d)),
      emails: (Array.isArray(input.emails) ? input.emails : []).map(String).slice(0, 20),
      phone_alert: input.phoneAlert === true,
      active: input.active !== false,
    } as Json,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/reports");
  return { ok: true, message: "Saved." };
}

/** Switches one schedule on or off; nothing else on it is touched. */
export async function setReportScheduleActive(id: string, on: boolean): Promise<Result> {
  if (!isId(id)) return { ok: false, error: "That schedule is not here any more. Refresh the page." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_report_schedule_active", { p_id: id, p_on: on === true });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/reports");
  return { ok: true, message: on ? "Switched on." : "Switched off. Nothing is sent until you switch it on again." };
}

export async function removeReportSchedule(id: string): Promise<Result> {
  if (!isId(id)) return { ok: false, error: "That schedule is not here any more. Refresh the page." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("remove_report_schedule", { p_id: id });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/reports");
  return { ok: true, message: "Removed." };
}

/** Sends this schedule's summary straight away, marked as a test. */
export async function sendReportNow(id: string): Promise<Result> {
  if (!isId(id)) return { ok: false, error: "That schedule is not here any more. Refresh the page." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("send_report_now", { p_id: id });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/reports");
  const answer = (data ?? {}) as { message?: unknown; ok?: unknown };
  const message = typeof answer.message === "string" && answer.message ? answer.message : "Sent.";
  // The database says when nothing could go out (for example email not set up yet): that is not a success.
  return answer.ok === false ? { ok: false, error: message } : { ok: true, message };
}
