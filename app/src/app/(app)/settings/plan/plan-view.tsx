"use client";

import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { cancelPlanRequest, requestPlanChange } from "./actions";

import { useTz } from "../../tz";
type Module = { key: string; name: string; description: string; kind: "professional" | "addon"; on: boolean };
type Request = {
  id: string;
  kind: "upgrade" | "module" | "outlet";
  module_key: string | null;
  outlet_name: string | null;
  status: string;
  created_at: string;
  decision_note: string | null;
};
export type Plan = {
  edition: "basic" | "professional";
  currency: string;
  prices: Record<string, number | null>;
  modules: Module[];
  outlets: number;
  requests: Request[];
};

const STATUS: Record<string, string> = {
  requested: "Waiting for SNA",
  approved: "Approved — being set up",
  done: "Done",
  rejected: "Not approved",
  cancelled: "Cancelled",
};

export function PlanView({ plan, isOwner }: { plan: Plan; isOwner: boolean }) {
  const tz = useTz();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [outletOpen, setOutletOpen] = useState(false);
  const [outletName, setOutletName] = useState("");
  const [outletCity, setOutletCity] = useState("");

  const pro = plan.edition === "professional";
  const open = (kind: string, key?: string | null) =>
    plan.requests.some((r) => r.kind === kind && (key == null || r.module_key === key) && (r.status === "requested" || r.status === "approved"));
  const price = (k: string) => (plan.prices[k] == null ? null : money(Number(plan.prices[k]), plan.currency));
  const moduleName = (k: string | null) => plan.modules.find((m) => m.key === k)?.name ?? k ?? "";

  function run(p: Promise<{ ok: boolean; message?: string; error?: string }>) {
    start(async () => {
      const r = await p;
      setMsg({ ok: r.ok, text: (r.ok ? r.message : r.error) ?? "" });
    });
  }

  const addons = plan.modules.filter((m) => m.kind === "addon");

  return (
    <div className="space-y-5">
      {msg && (
        <div className="card p-3 text-sm font-semibold" style={{ color: msg.ok ? "var(--color-brand)" : "var(--color-bad)" }}>
          {msg.text}
        </div>
      )}

      <div className="card p-5">
        <h3 className="font-display text-lg font-bold">Add-on modules</h3>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          Charged monthly.
        </p>
        <ul className="mt-3 divide-y" style={{ borderColor: "var(--color-line)" }}>
          {addons.map((m) => (
            <li key={m.key} className="flex flex-wrap items-center justify-between gap-3 py-3">
              <div className="min-w-0">
                <div className="font-semibold">{m.name}</div>
                <div className="text-sm" style={{ color: "var(--color-ink-3)" }}>
                  {m.description}
                  {price(m.key) ? ` · ${price(m.key)}/month` : ""}
                </div>
              </div>
              {m.on ? (
                <span className="rounded-full px-3 py-1 text-xs font-bold" style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)" }}>
                  On
                </span>
              ) : isOwner ? (
                <button
                  className="btn h-10 min-h-0 px-4 text-sm"
                  style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)" }}
                  disabled={pending || open("module", m.key)}
                  onClick={() => run(requestPlanChange({ kind: "module", module: m.key }))}
                >
                  {open("module", m.key) ? "Requested" : "Ask to switch on"}
                </button>
              ) : null}
            </li>
          ))}
        </ul>
      </div>

      <div className="card p-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h3 className="font-display text-lg font-bold">Outlets</h3>
            <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
              New outlets are approved by SNA sales and set up by an SNA implementer.
              {!pro ? " Several outlets need the Professional edition." : ""}
            </p>
          </div>
          {isOwner && pro && !outletOpen && (
            <button className="btn h-10 min-h-0 px-4 text-sm" style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)" }} onClick={() => setOutletOpen(true)}>
              + Ask for a new outlet
            </button>
          )}
        </div>
        {outletOpen && (
          <form
            className="mt-3 grid gap-2 sm:grid-cols-[1fr_1fr_auto]"
            onSubmit={(e) => {
              e.preventDefault();
              run(
                requestPlanChange({ kind: "outlet", outletName, outletCity }).then((r) => {
                  if (r.ok) {
                    setOutletOpen(false);
                    setOutletName("");
                    setOutletCity("");
                  }
                  return r;
                }),
              );
            }}
          >
            <input className="field" placeholder="Outlet name, e.g. Anna Nagar" value={outletName} onChange={(e) => setOutletName(e.target.value)} required maxLength={80} />
            <input className="field" placeholder="City" value={outletCity} onChange={(e) => setOutletCity(e.target.value)} maxLength={60} />
            <button className="btn btn-pay h-11 min-h-0 px-5 text-sm" disabled={pending}>
              Send request
            </button>
          </form>
        )}
      </div>

      {plan.requests.length > 0 && (
        <div className="card p-5">
          <h3 className="font-display text-lg font-bold">Your requests</h3>
          <ul className="mt-2 divide-y" style={{ borderColor: "var(--color-line)" }}>
            {plan.requests.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5 text-sm">
                <div>
                  <span className="font-semibold">
                    {r.kind === "upgrade" ? "Upgrade to Professional" : r.kind === "module" ? moduleName(r.module_key) : `New outlet: ${r.outlet_name}`}
                  </span>
                  <span style={{ color: "var(--color-ink-3)" }}>
                    {" "}
                    · {new Date(r.created_at).toLocaleDateString("en-IN", { timeZone: tz })} · {STATUS[r.status] ?? r.status}
                    {r.decision_note ? ` — ${r.decision_note}` : ""}
                  </span>
                </div>
                {isOwner && r.status === "requested" && (
                  <button className="text-xs font-semibold" style={{ color: "var(--color-bad)" }} disabled={pending} onClick={() => run(cancelPlanRequest(r.id))}>
                    Cancel
                  </button>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
