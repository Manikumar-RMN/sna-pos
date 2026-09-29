"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type ShiftResult = { ok: true; message?: string } | { ok: false; error: string };

function refresh() {
  revalidatePath("/shift");
  revalidatePath("/pos");
  revalidatePath("/dashboard");
}

export async function openShift(openingFloat: number): Promise<ShiftResult> {
  if (!(openingFloat >= 0)) return { ok: false, error: "Enter the cash in the drawer (0 if none)." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("open_shift", { p_opening_float: openingFloat });
  if (error) return { ok: false, error: error.message };
  refresh();
  return { ok: true, message: "Shift opened." };
}

export async function recordCash(input: {
  direction: "in" | "out";
  amount: number;
  reason: string;
}): Promise<ShiftResult> {
  if (!(input.amount > 0)) return { ok: false, error: "Enter an amount." };
  if (input.reason.trim().length < 2) return { ok: false, error: "Enter a reason." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("record_cash_movement", {
    p_direction: input.direction,
    p_amount: input.amount,
    p_reason: input.reason.trim(),
  });
  if (error) return { ok: false, error: error.message };
  refresh();
  return { ok: true, message: input.direction === "in" ? "Cash in recorded." : "Cash out recorded." };
}

export async function closeShift(counted: number, notes: string): Promise<ShiftResult> {
  if (!(counted >= 0)) return { ok: false, error: "Enter the cash you counted in the drawer." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("close_shift", {
    p_counted_cash: counted,
    p_notes: notes.trim() || undefined,
  });
  if (error) return { ok: false, error: error.message };
  refresh();
  const v = Number((data as { variance?: number } | null)?.variance ?? 0);
  const msg =
    Math.abs(v) < 0.005
      ? "Shift closed. The drawer matches exactly."
      : v > 0
        ? `Shift closed. The drawer is over by ${v.toFixed(2)}.`
        : `Shift closed. The drawer is short by ${Math.abs(v).toFixed(2)}.`;
  return { ok: true, message: msg };
}

export async function closeDay(notes: string, counted: number | null = null): Promise<ShiftResult & { dayId?: string }> {
  if (counted != null && !(counted >= 0)) return { ok: false, error: "Enter the cash counted, or leave it empty." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("close_day", { p_notes: notes.trim() || undefined, p_counted_cash: counted ?? undefined });
  if (error) return { ok: false, error: error.message };
  refresh();
  revalidatePath("/bills");
  const z = (data ?? {}) as { business_date?: string; total_billed?: number };
  return { ok: true, message: `Day ${z.business_date ?? ""} closed. Total billed ${Number(z.total_billed ?? 0).toFixed(2)}.` };
}

export async function reopenDay(reason: string): Promise<ShiftResult> {
  if (reason.trim().length < 3) return { ok: false, error: "Write a short reason for reopening the day." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reopen_day", { p_reason: reason.trim() });
  if (error) return { ok: false, error: error.message };
  refresh();
  revalidatePath("/bills");
  return { ok: true, message: `Day ${(data as { business_date?: string } | null)?.business_date ?? ""} is open again. Changes go into that day. Close it again when done.` };
}
