"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { MEAL_PLAN_LABEL, type RatePlan } from "@/lib/fo";
import { deleteRateRule, saveRatePlan, saveRateRule } from "../actions";

type RT = { id: string; code: string; name: string; active: boolean };

/** Rate plans: a named price list (room only, with breakfast, …) with a rate per room type, optional weekend, single and season rates. */
export function RatePlans({ plans, roomTypes, currency }: { plans: RatePlan[]; roomTypes: RT[]; currency: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [code, setCode] = useState("");
  const [name, setName] = useState("");
  const [meal, setMeal] = useState("EP");
  const [open, setOpen] = useState<string | null>(plans[0]?.id ?? null);
  const typeName = (id: string) => roomTypes.find((t) => t.id === id)?.name ?? "";

  function act(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>, after?: () => void) {
    setMsg(null);
    start(async () => {
      const r = await fn();
      setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error ?? "That did not work." });
      if (r.ok) { after?.(); router.refresh(); }
    });
  }

  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">Rate plans</h2>
      <p className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
        A rate plan is a price list a guest can be booked on, for example Room only or With breakfast. Each room type gets a weekday rate. Weekend (Friday and Saturday nights), single-guest and season rates are optional. The standard room rate above always stays available.
      </p>
      {msg && (
        <div role="status" className="mt-2 rounded-xl px-3 py-2 text-sm font-semibold" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{msg.text}</div>
      )}
      <ul className="mt-2 space-y-2">
        {plans.length === 0 && <li className="text-sm" style={{ color: "var(--color-ink-3)" }}>No rate plans yet. Bookings use the room type&apos;s standard rate.</li>}
        {plans.map((p) => (
          <li key={p.id} className="rounded-xl p-2" style={{ border: "1px solid var(--color-line)", opacity: p.active ? 1 : 0.55 }}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <button className="text-left text-sm" onClick={() => setOpen(open === p.id ? null : p.id)} aria-expanded={open === p.id}>
                <b>{p.code}</b> · {p.name} · <span style={{ color: "var(--color-ink-3)" }}>{MEAL_PLAN_LABEL[p.meal_plan]} · {p.rules.length} rate{p.rules.length === 1 ? "" : "s"}</span>
              </button>
              <button className="text-xs underline" disabled={pending} onClick={() => act(() => saveRatePlan({ id: p.id, code: p.code, name: p.name, mealPlan: p.meal_plan, description: p.description ?? "", active: !p.active }))}>
                {p.active ? "Switch off" : "Switch on"}
              </button>
            </div>
            {open === p.id && (
              <div className="mt-2 space-y-2">
                <ul className="divide-y text-sm">
                  {p.rules.length === 0 && <li className="py-1 text-xs" style={{ color: "var(--color-ink-3)" }}>No rates yet. Add one below.</li>}
                  {p.rules.map((r) => (
                    <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 py-1.5">
                      <span>
                        <b>{typeName(r.room_type_id)}</b> · {r.rate} {currency}
                        {r.weekend_rate != null ? ` · weekend ${r.weekend_rate}` : ""}
                        {r.single_rate != null ? ` · single ${r.single_rate}` : ""}
                        {r.extra_adult > 0 ? ` · extra adult ${r.extra_adult}` : ""}
                        {r.extra_child > 0 ? ` · child ${r.extra_child}` : ""}
                        <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>{r.valid_from || r.valid_to ? `${r.valid_from ?? "any time"} to ${r.valid_to ?? "no end"}` : "All year"} · {r.included_adults} adults included</span>
                      </span>
                      <button className="text-xs underline" disabled={pending} onClick={() => { if (window.confirm("Remove this rate? Stays already booked keep their rates.")) act(() => deleteRateRule(r.id)); }}>Remove</button>
                    </li>
                  ))}
                </ul>
                <RuleForm plan={p} roomTypes={roomTypes} currency={currency} pending={pending} act={act} />
              </div>
            )}
          </li>
        ))}
      </ul>
      <div className="mt-3 grid gap-2 sm:grid-cols-[90px_1fr_1fr_auto]">
        <input className="field h-10 text-sm" placeholder="Code" value={code} onChange={(e) => setCode(e.target.value)} aria-label="Plan code" />
        <input className="field h-10 text-sm" placeholder="Name (Room with breakfast)" value={name} onChange={(e) => setName(e.target.value)} aria-label="Plan name" />
        <select className="field h-10 text-sm" value={meal} onChange={(e) => setMeal(e.target.value)} aria-label="Meal plan">
          {Object.entries(MEAL_PLAN_LABEL).map(([k, v]) => <option key={k} value={k}>{k} · {v}</option>)}
        </select>
        <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" disabled={pending || !code.trim() || !name.trim()}
          onClick={() => act(() => saveRatePlan({ id: null, code, name, mealPlan: meal, description: "", active: true }), () => { setCode(""); setName(""); })}>Add plan</button>
      </div>
    </section>
  );
}

function RuleForm({ plan, roomTypes, currency, pending, act }: {
  plan: RatePlan; roomTypes: RT[]; currency: string; pending: boolean;
  act: (fn: () => Promise<{ ok: boolean; error?: string; message?: string }>, after?: () => void) => void;
}) {
  const [typeId, setTypeId] = useState(roomTypes.find((t) => t.active)?.id ?? "");
  const [f, setF] = useState({ rate: "", weekend: "", single: "", included: "2", xa: "0", xc: "0", from: "", to: "" });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const num = (v: string) => (v.trim() === "" ? null : Number(v));
  const valid = typeId && f.rate.trim() !== "" && Number(f.rate) >= 0;
  return (
    <div className="rounded-lg p-2" style={{ background: "var(--color-surface-2)" }}>
      <div className="grid gap-2 sm:grid-cols-4">
        <label className="text-xs sm:col-span-2">Room type
          <select className="field h-10 w-full text-sm" value={typeId} onChange={(e) => setTypeId(e.target.value)}>
            {roomTypes.filter((t) => t.active).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
        </label>
        <label className="text-xs">Weekday rate ({currency})<input className="field h-10 w-full text-sm" inputMode="decimal" value={f.rate} onChange={set("rate")} /></label>
        <label className="text-xs">Weekend rate<input className="field h-10 w-full text-sm" inputMode="decimal" placeholder="same" value={f.weekend} onChange={set("weekend")} /></label>
        <label className="text-xs">Single guest rate<input className="field h-10 w-full text-sm" inputMode="decimal" placeholder="same" value={f.single} onChange={set("single")} /></label>
        <label className="text-xs">Adults included<input className="field h-10 w-full text-sm" inputMode="numeric" value={f.included} onChange={set("included")} /></label>
        <label className="text-xs">Extra adult<input className="field h-10 w-full text-sm" inputMode="decimal" value={f.xa} onChange={set("xa")} /></label>
        <label className="text-xs">Each child<input className="field h-10 w-full text-sm" inputMode="decimal" value={f.xc} onChange={set("xc")} /></label>
        <label className="text-xs">Season from<input type="date" className="field h-10 w-full text-sm" value={f.from} onChange={set("from")} /></label>
        <label className="text-xs">Season to<input type="date" className="field h-10 w-full text-sm" value={f.to} onChange={set("to")} /></label>
        <div className="flex items-end sm:col-span-2">
          <button className="btn btn-primary h-10 min-h-0 w-full px-4 text-sm" disabled={pending || !valid}
            onClick={() => act(() => saveRateRule({
              planId: plan.id, roomTypeId: typeId, rate: Number(f.rate), weekendRate: num(f.weekend), singleRate: num(f.single),
              includedAdults: Number(f.included) || 2, extraAdult: Number(f.xa) || 0, extraChild: Number(f.xc) || 0,
              validFrom: f.from || null, validTo: f.to || null,
            }), () => setF({ ...f, rate: "", weekend: "", single: "", from: "", to: "" }))}>Add rate</button>
        </div>
      </div>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>Leave the season empty for all year. When two rates cover the same night, the one with the shorter season is used.</p>
    </div>
  );
}
