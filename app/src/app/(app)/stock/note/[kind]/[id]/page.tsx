import Link from "next/link";
import { notFound } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import { PrintButton } from "../../../../reports/_components/print-button";
import { PrintStamp } from "../../../../reports/_components/print-stamp";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Line = { name: string; unit: string; qty: number; rate?: number; value?: number; extra?: string };
type Note = { title: string; number: string; day: string; facts: [string, string][]; lines: Line[]; totals: [string, string][]; note: string | null; qtyLabel: string; sign: [string, string]; back: string };

const num = (v: unknown) => Number(v ?? 0);

export default async function StockNotePage({ params }: { params: Promise<{ kind: string; id: string }> }) {
  const { kind, id } = await params;
  if (!UUID.test(id) || !["receipt", "issue", "request", "debit"].includes(kind)) notFound();
  const user = await requireUser();
  if (!can(user, "stock.view") && !can(user, "stock.manage") && !can(user, "stock.adjust")) notFound();
  if (!has(user, "stock")) notFound();
  const supabase = await createClient();
  const c = user.currency_code;
  const { data: ings } = await supabase.from("ingredients").select("id, name, unit");
  const meta = Object.fromEntries((ings ?? []).map((i) => [i.id, i]));
  const { data: staff } = await supabase.from("users").select("id, full_name");
  const who = (uid: string | null | undefined) => (staff ?? []).find((u) => u.id === uid)?.full_name ?? "—";
  let note: Note | null = null;

  if (kind === "receipt") {
    const { data: g } = await supabase.from("goods_receipts").select("*").eq("id", id).maybeSingle();
    if (!g) notFound();
    const [{ data: ls }, { data: sup }] = await Promise.all([
      supabase.from("goods_receipt_lines").select("ingredient_id, qty, unit_cost, line_total, batch_no, expiry_date").eq("goods_receipt_id", id),
      supabase.from("suppliers").select("name").eq("id", g.supplier_id).maybeSingle(),
    ]);
    note = {
      title: "Goods receipt note",
      number: g.number,
      day: g.received_on,
      facts: [
        ["Supplier", sup?.name ?? "—"],
        ["Supplier bill", [g.supplier_bill_no, g.supplier_bill_date].filter(Boolean).join(" · ") || "—"],
        ["Received by", who(g.received_by)],
        ...(g.status === "cancelled" ? ([["Status", "CANCELLED"]] as [string, string][]) : []),
      ],
      lines: (ls ?? []).map((l) => ({
        name: meta[l.ingredient_id]?.name ?? "Item",
        unit: meta[l.ingredient_id]?.unit ?? "",
        qty: num(l.qty),
        rate: num(l.unit_cost),
        value: num(l.line_total),
        extra: [l.batch_no ? `Batch ${l.batch_no}` : "", l.expiry_date ? `Expiry ${l.expiry_date}` : ""].filter(Boolean).join(" · "),
      })),
      totals: [["Items", money(num(g.subtotal), c)], ["Tax", money(num(g.tax_amount), c)], ["Other charges", money(num(g.other_charges), c)], ["Total", money(num(g.total), c)]],
      note: g.notes,
      qtyLabel: "Received",
      sign: ["Received by", "Supplier / checked by"],
      back: "/purchases",
    };
  } else if (kind === "debit") {
    // Debit note: everything sent back to the supplier against one goods receipt.
    const { data: g } = await supabase.from("goods_receipts").select("id, number, supplier_id, supplier_bill_no, supplier_bill_date").eq("id", id).maybeSingle();
    if (!g) notFound();
    const [{ data: rets }, { data: sup }] = await Promise.all([
      supabase.from("goods_returns").select("id, number, returned_on, reason, total, created_by").eq("goods_receipt_id", id).order("created_at"),
      supabase.from("suppliers").select("name, tax_no").eq("id", g.supplier_id).maybeSingle(),
    ]);
    if (!rets || rets.length === 0) notFound();
    const { data: rls } = await supabase.from("goods_return_lines").select("goods_return_id, ingredient_id, qty, unit_cost, line_total, tax_amount").in("goods_return_id", rets.map((r) => r.id));
    const retNo = Object.fromEntries(rets.map((r) => [r.id, r.number]));
    const items = (rls ?? []).reduce((a, l) => a + num(l.line_total), 0);
    const tax = (rls ?? []).reduce((a, l) => a + num(l.tax_amount), 0);
    note = {
      title: "Debit note — goods returned",
      number: rets.map((r) => r.number).join(", "),
      day: rets[rets.length - 1].returned_on,
      facts: [
        ["Supplier", sup?.name ?? "—"],
        ...(sup?.tax_no ? ([["Supplier GSTIN", sup.tax_no]] as [string, string][]) : []),
        ["Against receipt", g.number],
        ["Supplier bill", [g.supplier_bill_no, g.supplier_bill_date].filter(Boolean).join(" · ") || "—"],
        ["Reason", rets.map((r) => r.reason).join("; ")],
        ["Returned by", who(rets[0].created_by)],
      ],
      lines: (rls ?? []).map((l) => ({
        name: meta[l.ingredient_id]?.name ?? "Item",
        unit: meta[l.ingredient_id]?.unit ?? "",
        qty: num(l.qty),
        rate: num(l.unit_cost),
        value: num(l.line_total),
        extra: [rets.length > 1 ? retNo[l.goods_return_id] : "", num(l.tax_amount) > 0 ? `Tax ${money(num(l.tax_amount), c)}` : ""].filter(Boolean).join(" · "),
      })),
      totals: [["Goods", money(items, c)], ["Tax", money(tax, c)], ["Total debited", money(items + tax, c)]],
      note: null,
      qtyLabel: "Returned",
      sign: ["Prepared by", "Supplier acknowledgement"],
      back: "/purchases",
    };
  } else if (kind === "issue") {
    const { data: m } = await supabase.from("material_issues").select("*").eq("id", id).maybeSingle();
    if (!m) notFound();
    const [{ data: ls }, { data: req }] = await Promise.all([
      supabase.from("material_issue_lines").select("ingredient_id, qty, unit_cost, batch_no, expiry_date").eq("issue_id", id),
      m.request_id ? supabase.from("material_requests").select("number").eq("id", m.request_id).maybeSingle() : Promise.resolve({ data: null }),
    ]);
    const lines = (ls ?? []).map((l) => ({ name: meta[l.ingredient_id]?.name ?? "Item", unit: meta[l.ingredient_id]?.unit ?? "", qty: num(l.qty), rate: num(l.unit_cost), value: Math.round(num(l.qty) * num(l.unit_cost) * 100) / 100, extra: [l.batch_no ? `Batch ${l.batch_no}` : "", l.expiry_date ? `Expiry ${l.expiry_date}` : ""].filter(Boolean).join(" · ") }));
    note = {
      title: "Material issue note",
      number: m.number,
      day: m.issued_on,
      facts: [["Issued to", m.department], ["Against request", req?.number ?? "Issued directly"], ["Issued by", who(m.issued_by)]],
      lines,
      totals: [["Total value", money(num(m.value), c)]],
      note: m.note,
      qtyLabel: "Issued",
      sign: ["Issued by", "Received by (" + m.department + ")"],
      back: "/stock/requests",
    };
  } else {
    const { data: m } = await supabase.from("material_requests").select("*").eq("id", id).maybeSingle();
    if (!m) notFound();
    const { data: ls } = await supabase.from("material_request_lines").select("ingredient_id, qty, issued_qty").eq("request_id", id);
    const statusLabel: Record<string, string> = { requested: "Waiting", part_issued: "Part issued", issued: "Issued", rejected: "Rejected", cancelled: "Cancelled" };
    note = {
      title: "Material request",
      number: m.number,
      day: String(m.created_at).slice(0, 10),
      facts: [["Department", m.department], ["Asked by", who(m.requested_by)], ["Status", statusLabel[m.status] ?? m.status], ...(m.reject_reason ? ([["Reason", m.reject_reason]] as [string, string][]) : [])],
      lines: (ls ?? []).map((l) => ({ name: meta[l.ingredient_id]?.name ?? "Item", unit: meta[l.ingredient_id]?.unit ?? "", qty: num(l.qty), extra: num(l.issued_qty) > 0 ? `Issued ${num(l.issued_qty)}` : "" })),
      totals: [],
      note: m.note,
      qtyLabel: "Asked for",
      sign: ["Requested by", "Approved by"],
      back: "/stock/requests",
    };
  }

  const money_cols = note.lines.some((l) => l.rate !== undefined);
  return (
    <div className="report-root mx-auto max-w-3xl">
      <div className="no-print mb-3 flex items-center justify-between gap-2">
        <Link href={note.back} className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
          ← Back
        </Link>
        <PrintButton label="Print" />
      </div>
      <div className="card p-5 text-sm">
        <div className="text-center">
          <div className="text-base font-bold">{user.trading_name}</div>
          <div style={{ color: "var(--color-ink-3)" }}>{user.branch_name}</div>
          <div className="mt-1 text-lg font-bold">{note.title}</div>
        </div>
        <div className="mt-3 grid grid-cols-2 gap-x-6 gap-y-1">
          <div>
            <b>No.</b> {note.number}
          </div>
          <div>
            <b>Date</b> {note.day}
          </div>
          {note.facts.map(([k, v]) => (
            <div key={k}>
              <b>{k}</b> {v}
            </div>
          ))}
        </div>
        <table className="mt-4 w-full">
          <thead>
            <tr style={{ borderBottom: "1px solid var(--color-line)", textAlign: "left" }}>
              <th className="py-1.5">#</th>
              <th>Item</th>
              <th className="text-right">{note.qtyLabel}</th>
              {money_cols && <th className="text-right">Rate</th>}
              {money_cols && <th className="text-right">Value</th>}
            </tr>
          </thead>
          <tbody>
            {note.lines.map((l, i) => (
              <tr key={i} style={{ borderBottom: "1px solid var(--color-line)" }}>
                <td className="py-1.5">{i + 1}</td>
                <td>
                  {l.name}
                  {l.extra ? <span style={{ color: "var(--color-ink-3)" }}> · {l.extra}</span> : null}
                </td>
                <td className="text-right tabular-nums">
                  {l.qty} {l.unit}
                </td>
                {money_cols && <td className="text-right tabular-nums">{money(l.rate ?? 0, c)}</td>}
                {money_cols && <td className="text-right tabular-nums">{money(l.value ?? 0, c)}</td>}
              </tr>
            ))}
          </tbody>
        </table>
        {note.totals.length > 0 && (
          <div className="mt-3 ml-auto w-56 space-y-0.5">
            {note.totals.map(([k, v], i) => (
              <div key={k} className={`flex justify-between ${i === note.totals.length - 1 ? "font-bold" : ""}`}>
                <span>{k}</span>
                <span className="tabular-nums">{v}</span>
              </div>
            ))}
          </div>
        )}
        {note.note ? (
          <p className="mt-3">
            <b>Note</b> {note.note}
          </p>
        ) : null}
        <div className="mt-12 grid grid-cols-2 gap-10 text-center">
          <div style={{ borderTop: "1px solid var(--color-ink-2)", paddingTop: 4 }}>{note.sign[0]}</div>
          <div style={{ borderTop: "1px solid var(--color-ink-2)", paddingTop: 4 }}>{note.sign[1]}</div>
        </div>
        <div className="mt-4 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Printed: <PrintStamp timezone={user.timezone} />
        </div>
      </div>
    </div>
  );
}
