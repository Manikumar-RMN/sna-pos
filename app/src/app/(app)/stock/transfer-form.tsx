"use client";

import { useRouter } from "next/navigation";
import { useRef, useState, useTransition } from "react";
import { transferStock } from "../outlet/actions";

/** Central kitchen: send stock from this outlet to another one. */
export function TransferForm({
  from,
  ingredients,
  outlets,
}: {
  from: string;
  ingredients: { id: string; name: string; unit: string; stock: number }[];
  outlets: { id: string; name: string }[];
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const ref = useRef<string>(crypto.randomUUID());
  const [ing, setIng] = useState(ingredients[0]?.id ?? "");
  const [to, setTo] = useState(outlets[0]?.id ?? "");
  const [qty, setQty] = useState("");
  const [note, setNote] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  if (ingredients.length === 0 || outlets.length === 0) return null;
  const unit = ingredients.find((i) => i.id === ing)?.unit ?? "";
  return (
    <div className="card mb-5 p-4">
      <h2 className="font-display text-base font-bold">Send stock from {from}</h2>
      <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
        Takes it out of this outlet&rsquo;s stock and adds it to the other outlet at today&rsquo;s cost.
      </p>
      <form
        className="mt-3 grid gap-2 sm:grid-cols-[1.4fr_0.8fr_1fr_1fr_auto]"
        onSubmit={(e) => {
          e.preventDefault();
          start(async () => {
            const r = await transferStock(ing, qty, to, note, ref.current);
            setMsg({ ok: r.ok, text: r.ok ? `Sent ${qty} ${unit}.` : r.error });
            if (r.ok) {
              setQty("");
              ref.current = crypto.randomUUID();
              setNote("");
              router.refresh();
            }
          });
        }}
      >
        <select className="field" value={ing} onChange={(e) => setIng(e.target.value)}>
          {ingredients.map((i) => (
            <option key={i.id} value={i.id}>
              {i.name} ({Number(i.stock)} {i.unit} here)
            </option>
          ))}
        </select>
        <input className="field" inputMode="decimal" placeholder={`Qty (${unit})`} value={qty} onChange={(e) => setQty(e.target.value)} required />
        <select className="field" value={to} onChange={(e) => setTo(e.target.value)}>
          {outlets.map((o) => (
            <option key={o.id} value={o.id}>
              To {o.name}
            </option>
          ))}
        </select>
        <input className="field" placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
        <button className="btn btn-pay h-11 min-h-0 px-5 text-sm" disabled={pending}>
          Send
        </button>
      </form>
      {msg && (
        <div className="mt-2 text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </div>
      )}
    </div>
  );
}
