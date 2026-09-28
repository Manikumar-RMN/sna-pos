import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import { TableOrderCard, AutoRefresh } from "./table-order-card";

type QrItem = { product_id: string; qty: number; note?: string; options?: string[] };

export default async function TableOrdersPage() {
  const user = await requireUser();
  if (!has(user, "qr_ordering")) {
    return <p className="card p-5 text-sm">QR table ordering is an add-on. Ask for it in Settings → Plan and modules.</p>;
  }
  const supabase = await createClient();
  const { data: rows } = await supabase
    .from("qr_orders")
    .select("id, items, estimated_total, guest_name, guest_note, status, created_at, reject_reason, dining_tables!qr_orders_dining_table_id_fkey(table_number)")
    .gte("created_at", new Date(Date.now() - 12 * 3600 * 1000).toISOString())
    .order("created_at", { ascending: false })
    .limit(60);
  const list = rows ?? [];
  const productIds = [...new Set(list.flatMap((r) => (r.items as unknown as QrItem[]).map((i) => i.product_id)))];
  const optionIds = [...new Set(list.flatMap((r) => (r.items as unknown as QrItem[]).flatMap((i) => i.options ?? [])))];
  const [{ data: products }, { data: options }] = await Promise.all([
    productIds.length ? supabase.from("products").select("id, name").in("id", productIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    optionIds.length ? supabase.from("modifier_items").select("id, name").in("id", optionIds) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
  ]);
  const pName = new Map((products ?? []).map((p) => [p.id, p.name]));
  const oName = new Map((options ?? []).map((o) => [o.id, o.name]));
  const canAct = can(user, "order.create");
  const pending = list.filter((r) => r.status === "pending");
  const done = list.filter((r) => r.status !== "pending");

  const view = (r: (typeof list)[number]) => ({
    id: r.id,
    table: (r.dining_tables as unknown as { table_number: string } | null)?.table_number ?? "?",
    guest: r.guest_name,
    note: r.guest_note,
    total: money(Number(r.estimated_total ?? 0), user.currency_code),
    at: new Date(r.created_at).toLocaleTimeString("en-IN", { timeZone: user.timezone ?? "Asia/Kolkata", hour: "2-digit", minute: "2-digit" }),
    status: r.status as "pending" | "accepted" | "rejected",
    reason: r.reject_reason,
    lines: (r.items as unknown as QrItem[]).map((i) => ({
      qty: i.qty,
      name: pName.get(i.product_id) ?? "Item",
      options: (i.options ?? []).map((o) => oName.get(o) ?? "").filter(Boolean).join(", "),
    })),
  });

  return (
    <div className="mx-auto max-w-3xl space-y-4">
      <AutoRefresh seconds={10} />
      <div>
        <h1 className="text-xl font-bold tracking-tight">Table orders</h1>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          Orders guests sent from the table QR. Accept to add them to the table&apos;s bill and send them to the kitchen. This page refreshes itself.
        </p>
      </div>
      {pending.length === 0 && <p className="card p-5 text-sm">No table orders waiting.</p>}
      <div className="grid gap-3 sm:grid-cols-2">
        {pending.map((r) => (
          <TableOrderCard key={r.id} order={view(r)} canAct={canAct} />
        ))}
      </div>
      {done.length > 0 && (
        <details className="card p-4">
          <summary className="cursor-pointer text-sm font-bold">Earlier today ({done.length})</summary>
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            {done.map((r) => (
              <TableOrderCard key={r.id} order={view(r)} canAct={false} />
            ))}
          </div>
        </details>
      )}
    </div>
  );
}
