"use client";

import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { addOutletRequest, createOutlet, setEdition, setModule } from "../../actions";
import { RequestRow, requestLabel, type SnaRequest } from "../../request-row";

type Mod = { key: string; name: string; kind: "professional" | "addon"; on: boolean; price: number | null };
export type SnaRestaurant = {
  id: string;
  trading_name: string;
  legal_name: string;
  country_code: string;
  currency: string;
  edition: "basic" | "professional";
  timezone: string;
  created_at: string;
  contact_email: string | null;
  contact_phone: string | null;
  monthly: number;
  modules: Mod[];
  prices: Record<string, number | null>;
  branches: { id: string; name: string; code: string; city: string | null; is_active: boolean }[];
  requests: SnaRequest[];
  events: { event: string; details: Record<string, unknown>; created_at: string; by: string | null }[];
};

export function RestaurantPanel({ r, role }: { r: SnaRestaurant; role: string }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [note, setNote] = useState("");
  const sales = role === "admin" || role === "sales";
  const builder = role === "admin" || role === "implementer";
  const pro = r.edition === "professional";

  function run(p: Promise<{ ok: boolean; message?: string; error?: string }>) {
    start(async () => {
      const res = await p;
      setMsg({ ok: res.ok, text: (res.ok ? res.message : res.error) ?? "" });
    });
  }

  const openReqs = r.requests.filter((q) => q.status === "requested" || q.status === "approved");
  const approvedOutlets = r.requests.filter((q) => q.kind === "outlet" && q.status === "approved");

  return (
    <div className="mt-3 space-y-5">
      <div className="card p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold">{r.trading_name}</h1>
            <div className="text-sm" style={{ color: "var(--color-ink-3)" }}>
              {r.legal_name} · {r.country_code} · since {new Date(r.created_at).toLocaleDateString()}
              {r.contact_email ? ` · ${r.contact_email}` : ""}
              {r.contact_phone ? ` · ${r.contact_phone}` : ""}
            </div>
          </div>
          <div className="text-right">
            <div className="text-xs font-bold uppercase" style={{ color: "var(--color-ink-3)" }}>
              Monthly charge
            </div>
            <div className="font-display text-2xl font-bold tabular-nums">{money(Number(r.monthly), r.currency)}</div>
          </div>
        </div>
        {msg && (
          <div className="mt-3 text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
            {msg.text}
          </div>
        )}
      </div>

      <div className="card p-5">
        <h2 className="font-display text-lg font-bold">Edition</h2>
        <div className="mt-2 flex flex-wrap items-center gap-3">
          <span className="rounded-full px-3 py-1 text-sm font-bold" style={{ background: pro ? "var(--color-brand-soft)" : "var(--color-surface-2)", color: pro ? "var(--color-brand)" : "var(--color-ink-2)" }}>
            {pro ? "Professional" : "Basic"}
          </span>
          {sales && (
            <>
              <input className="field h-10 w-56" placeholder="Note, e.g. paid on invoice 123" value={note} onChange={(e) => setNote(e.target.value)} />
              {pro ? (
                <button className="btn h-10 min-h-0 px-4 text-sm" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }} disabled={pending} onClick={() => run(setEdition(r.id, "basic", note))}>
                  Move to Basic
                </button>
              ) : (
                <button className="btn btn-pay h-10 min-h-0 px-4 text-sm" disabled={pending} onClick={() => run(setEdition(r.id, "professional", note))}>
                  Upgrade to Professional
                </button>
              )}
            </>
          )}
        </div>
      </div>

      <div className="card p-5">
        <h2 className="font-display text-lg font-bold">Add-on modules</h2>
        <ul className="mt-2 divide-y" style={{ borderColor: "var(--color-line)" }}>
          {r.modules
            .filter((m) => m.kind === "addon")
            .map((m) => (
              <li key={m.key} className="flex flex-wrap items-center justify-between gap-2 py-2.5 text-sm">
                <div>
                  <span className="font-semibold">{m.name}</span>
                  <span style={{ color: "var(--color-ink-3)" }}>{m.price != null ? ` · ${money(Number(m.price), r.currency)}/month` : " · price not set"}</span>
                </div>
                {sales ? (
                  <button
                    className={m.on ? "btn h-9 min-h-0 px-3 text-xs" : "btn btn-pay h-9 min-h-0 px-3 text-xs"}
                    style={m.on ? { background: "var(--color-bad-soft)", color: "var(--color-bad)" } : undefined}
                    disabled={pending}
                    onClick={() => run(setModule(r.id, m.key, !m.on, note))}
                  >
                    {m.on ? "Switch off" : "Switch on"}
                  </button>
                ) : (
                  <span className="text-xs font-bold">{m.on ? "On" : "Off"}</span>
                )}
              </li>
            ))}
        </ul>
      </div>

      <div className="card p-5">
        <h2 className="font-display text-lg font-bold">Outlets</h2>
        <ul className="mt-2 text-sm">
          {r.branches.map((b) => (
            <li key={b.id} className="py-1">
              <span className="font-semibold">{b.name}</span> <span style={{ color: "var(--color-ink-3)" }}>· code {b.code}{b.city ? ` · ${b.city}` : ""}</span>
            </li>
          ))}
        </ul>
        {approvedOutlets.map((q) => (
          <OutletForm key={q.id} request={q} canBuild={builder} pro={pro} pending={pending} run={run} />
        ))}
        {sales && <NewOutletRequest restaurantId={r.id} pending={pending} run={run} />}
      </div>

      {openReqs.length > 0 && (
        <div className="card divide-y" style={{ borderColor: "var(--color-line)" }}>
          <h2 className="px-4 pt-4 font-display text-lg font-bold">Open requests</h2>
          {openReqs.map((q) => (
            <RequestRow key={q.id} request={q} role={role} />
          ))}
        </div>
      )}

      <div className="card p-5">
        <h2 className="font-display text-lg font-bold">History</h2>
        <ul className="mt-2 space-y-1 text-sm">
          {r.events.map((e, i) => (
            <li key={i}>
              <span style={{ color: "var(--color-ink-3)" }}>{new Date(e.created_at).toLocaleString()}</span> · <span className="font-semibold">{e.event}</span>
              {e.by ? ` · ${e.by}` : ""}
              {e.details && (e.details as { note?: string }).note ? ` — ${(e.details as { note?: string }).note}` : ""}
            </li>
          ))}
          {r.events.length === 0 && <li style={{ color: "var(--color-ink-3)" }}>Nothing yet.</li>}
        </ul>
        <p className="mt-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Past requests: {r.requests.filter((q) => !openReqs.includes(q)).map((q) => `${requestLabel(q)} (${q.status})`).join(" · ") || "none"}
        </p>
      </div>
    </div>
  );
}

type Runner = (p: Promise<{ ok: boolean; message?: string; error?: string }>) => void;

function OutletForm({ request, canBuild, pro, pending, run }: { request: SnaRequest; canBuild: boolean; pro: boolean; pending: boolean; run: Runner }) {
  const [name, setName] = useState(request.outlet_name ?? "");
  const [code, setCode] = useState("");
  const [city, setCity] = useState(request.outlet_city ?? "");
  const [address, setAddress] = useState("");
  const [phone, setPhone] = useState("");
  return (
    <div id={`outlet-${request.id}`} className="mt-4 rounded-2xl border p-4" style={{ borderColor: "var(--color-line)", background: "var(--color-surface-2)" }}>
      <div className="text-sm font-semibold">Approved: {request.outlet_name} — set it up</div>
      {!pro && <p className="mt-1 text-sm" style={{ color: "var(--color-bad)" }}>Upgrade the restaurant to Professional first.</p>}
      {canBuild ? (
        <form
          className="mt-3 grid gap-2 sm:grid-cols-2"
          onSubmit={(e) => {
            e.preventDefault();
            run(createOutlet({ requestId: request.id, name, code, city, address, phone }));
          }}
        >
          <input className="field" placeholder="Outlet name" value={name} onChange={(e) => setName(e.target.value)} required />
          <input className="field uppercase" placeholder="Code, 2–4 letters (starts bill numbers)" value={code} onChange={(e) => setCode(e.target.value)} required maxLength={4} />
          <input className="field" placeholder="City" value={city} onChange={(e) => setCity(e.target.value)} />
          <input className="field" placeholder="Phone" value={phone} onChange={(e) => setPhone(e.target.value)} />
          <input className="field sm:col-span-2" placeholder="Address" value={address} onChange={(e) => setAddress(e.target.value)} />
          <button className="btn btn-pay h-11 min-h-0 px-5 text-sm sm:col-span-2" disabled={pending || !pro}>
            Add outlet
          </button>
        </form>
      ) : (
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>An implementer sets this up.</p>
      )}
    </div>
  );
}

function NewOutletRequest({ restaurantId, pending, run }: { restaurantId: string; pending: boolean; run: Runner }) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [city, setCity] = useState("");
  const [note, setNote] = useState("");
  if (!open)
    return (
      <button className="btn mt-3 h-10 min-h-0 px-4 text-sm" style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)" }} onClick={() => setOpen(true)}>
        + Outlet request (sold by sales)
      </button>
    );
  return (
    <form
      className="mt-3 grid gap-2 sm:grid-cols-[1fr_1fr_1fr_auto]"
      onSubmit={(e) => {
        e.preventDefault();
        run(addOutletRequest(restaurantId, name, city, note));
        setOpen(false);
      }}
    >
      <input className="field" placeholder="Outlet name" value={name} onChange={(e) => setName(e.target.value)} required />
      <input className="field" placeholder="City" value={city} onChange={(e) => setCity(e.target.value)} />
      <input className="field" placeholder="Note" value={note} onChange={(e) => setNote(e.target.value)} />
      <button className="btn btn-pay h-11 min-h-0 px-4 text-sm" disabled={pending}>
        Add request
      </button>
    </form>
  );
}
