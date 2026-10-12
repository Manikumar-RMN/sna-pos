import type { Metadata } from "next";
import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { ReadyBoard, type ReadyOrder } from "./ready-board";

export const metadata: Metadata = { title: "Order status" };
export const dynamic = "force-dynamic";

/**
 * Order-ready screen for a TV or tablet facing the guests (QSR, food court, café).
 * An order is "Preparing" while any of its kitchen tickets is new or being made, and "Ready" when
 * every ticket is ready. It leaves the screen when it is marked served, or 20 minutes after it was ready.
 * Guests see only the token (or the end of the bill number) and the guest's first name, never prices.
 */
export default async function ReadyPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const since = new Date(Date.now() - 6 * 3600 * 1000).toISOString();
  const { data: tickets } = await supabase
    .from("kitchen_tickets")
    .select("order_id, status, ready_at")
    .in("status", ["new", "preparing", "ready", "served"])
    .gte("created_at", since);

  const byOrder = new Map<string, { statuses: string[]; readyAt: number }>();
  for (const t of tickets ?? []) {
    const o = byOrder.get(t.order_id) ?? { statuses: [], readyAt: 0 };
    o.statuses.push(t.status);
    if (t.ready_at) o.readyAt = Math.max(o.readyAt, new Date(t.ready_at).getTime());
    byOrder.set(t.order_id, o);
  }
  const now = Date.now();
  const preparing: string[] = [];
  const ready: { id: string; readyAt: number }[] = [];
  for (const [id, o] of byOrder) {
    if (o.statuses.every((s) => s === "served")) continue;
    if (o.statuses.some((s) => s === "new" || s === "preparing")) preparing.push(id);
    else if (now - o.readyAt < 20 * 60000) ready.push({ id, readyAt: o.readyAt });
  }
  const ids = [...preparing, ...ready.map((r) => r.id)];
  const { data: orders } = ids.length
    ? await supabase.from("orders").select("id, bill_number, token_no, guest_name, order_type, status, created_at").in("id", ids)
    : { data: [] as { id: string; bill_number: string; token_no: number | null; guest_name: string | null; order_type: string; status: string; created_at: string }[] };
  const om = new Map((orders ?? []).filter((o) => o.status !== "voided").map((o) => [o.id, o]));

  const label = (id: string): ReadyOrder | null => {
    const o = om.get(id);
    if (!o) return null;
    const tail = o.bill_number.split("-").pop() ?? o.bill_number;
    const first = (o.guest_name ?? "").trim().split(/\s+/)[0] ?? "";
    return { id, token: o.token_no != null ? String(o.token_no) : tail, isToken: o.token_no != null, name: first.slice(0, 14), createdAt: o.created_at };
  };
  const prep = preparing.map(label).filter((x): x is ReadyOrder => !!x).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  const done = ready
    .sort((a, b) => b.readyAt - a.readyAt)
    .map((r) => label(r.id))
    .filter((x): x is ReadyOrder => !!x);

  return <ReadyBoard restaurant={user.trading_name} preparing={prep} ready={done} />;
}
