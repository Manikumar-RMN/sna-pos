"use client";

import { useRouter } from "next/navigation";
import { useRef, useState, useTransition } from "react";
import { money } from "@/lib/format";
import { ADJUST_KIND_LABEL, fmtQty, MANUAL_REASONS, parseQty, reasonLabel, REASON_LABEL, type AdjustKind, type IngredientLite } from "@/lib/stock";
import { useOnline } from "@/lib/use-online";
import { adjustStock } from "./actions";

export type RecentAdjust = { id: string; at: string; ingredient: string; unit: string; qty: number; kind: string; reason: string | null; note: string | null };

/** Wastage and manual adjustments. A reason is always required. */
export function WastageForm({ currency, ingredients, recent, timezone, presetIngredient }: { currency: string; ingredients: IngredientLite[]; recent: RecentAdjust[]; timezone: string; presetIngredient?: string }) {
  const router = useRouter();
  const online = useOnline();
  const [pending, start] = useTransition();
  const [ing, setIng] = useState(presetIngredient ?? "");
  const [kind, setKind] = useState<AdjustKind>("wastage");
  const [qty, setQty] = useState("");
  const [reason, setReason] = useState("");
  const [note, setNote] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const clientRef = useRef<string>(crypto.randomUUID());
  const picked = ingredients.find((i) => i.id === ing);
  const q = parseQty(qty);
  const value = picked && q != null ? q * picked.cost : 0;
  const ready = !!picked && q != null && q > 0 && !!reason;

  function save() {
    if (!picked || q == null || q <= 0 || !reason) return;
    setMsg(null);
    start(async () => {
      const r = await adjustStock({ ingredientId: picked.id, kind, qty: q, reason, note, clientRef: clientRef.current });
      setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error });
      if (r.ok) {
        clientRef.current = crypto.randomUUID();
        setQty("");
        setNote("");
        router.refresh();
      }
    });
  }

  const when = (iso: string) =>
    new Date(iso).toLocaleString("en-IN", { timeZone: timezone, day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });

  return (
    <div className="space-y-4">
      <section className="card p-4">
        <h2 className="text-sm font-bold">Wastage / adjust stock</h2>
        <p className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Use this for food thrown away, spilled or used for staff meals, and to correct stock by hand. Choose a reason every time.
        </p>
        <div className="mt-3 grid gap-2 sm:grid-cols-2">
          <select className="field h-10 text-sm" value={ing} onChange={(e) => setIng(e.target.value)} aria-label="Ingredient">
            <option value="">Ingredient…</option>
            {ingredients.map((i) => (
              <option key={i.id} value={i.id}>
                {i.name} ({fmtQty(i.stock)} {i.unit} here)
              </option>
            ))}
          </select>
          <select className="field h-10 text-sm" value={kind} onChange={(e) => setKind(e.target.value as AdjustKind)} aria-label="What happened">
            {(Object.keys(ADJUST_KIND_LABEL) as AdjustKind[]).map((k) => (
              <option key={k} value={k}>
                {ADJUST_KIND_LABEL[k]}
              </option>
            ))}
          </select>
          <input className="field h-10 text-sm" inputMode="decimal" placeholder={picked ? `Quantity (${picked.unit})` : "Quantity"} value={qty} onChange={(e) => setQty(e.target.value)} aria-label="Quantity" />
          <select className="field h-10 text-sm" value={reason} onChange={(e) => setReason(e.target.value)} aria-label="Reason" required>
            <option value="">Reason…</option>
            {MANUAL_REASONS.map((r) => (
              <option key={r} value={r}>
                {REASON_LABEL[r]}
              </option>
            ))}
          </select>
          <input className="field h-10 text-sm sm:col-span-2" placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} />
        </div>
        <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
          <div className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            {picked && q != null && q > 0 ? (
              <>
                Value at today&rsquo;s cost <b className="tabular-nums" style={{ color: "var(--color-ink)" }}>{money(value, currency)}</b>
              </>
            ) : (
              " "
            )}
          </div>
          <button className="btn btn-primary px-5 text-sm" disabled={pending || !online || !ready} onClick={save}>
            {pending ? "Saving…" : "Save"}
          </button>
        </div>
        {!online && (
          <p className="mt-2 text-xs font-semibold" style={{ color: "var(--color-warn)" }}>
            Needs internet.
          </p>
        )}
        {msg && (
          <p className="mt-2 text-sm font-semibold" role={msg.ok ? "status" : "alert"} style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
            {msg.text}
          </p>
        )}
      </section>

      <section className="card overflow-x-auto">
        <h2 className="px-4 pt-3 text-sm font-bold">Recent wastage and adjustments</h2>
        <table className="mt-2 w-full text-sm">
          <thead>
            <tr style={{ color: "var(--color-ink-3)" }}>
              <th className="px-3 py-2 text-left text-xs font-semibold">When</th>
              <th className="px-3 py-2 text-left text-xs font-semibold">Ingredient</th>
              <th className="px-3 py-2 text-right text-xs font-semibold">Qty</th>
              <th className="px-3 py-2 text-left text-xs font-semibold">Reason</th>
              <th className="px-3 py-2 text-left text-xs font-semibold">Note</th>
            </tr>
          </thead>
          <tbody>
            {recent.length === 0 && (
              <tr>
                <td colSpan={5} className="px-3 py-5 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                  Nothing recorded yet.
                </td>
              </tr>
            )}
            {recent.map((r) => (
              <tr key={r.id} style={{ borderTop: "1px solid var(--color-line)" }}>
                <td className="whitespace-nowrap px-3 py-2">{when(r.at)}</td>
                <td className="px-3 py-2">{r.ingredient}</td>
                <td className="px-3 py-2 text-right tabular-nums" style={{ color: r.qty < 0 ? "var(--color-bad)" : "var(--color-ok)" }}>
                  {r.qty > 0 ? "+" : ""}
                  {fmtQty(r.qty)} {r.unit}
                </td>
                <td className="px-3 py-2">{reasonLabel(r.reason)}</td>
                <td className="px-3 py-2" style={{ color: "var(--color-ink-3)" }}>
                  {r.note || "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
    </div>
  );
}
