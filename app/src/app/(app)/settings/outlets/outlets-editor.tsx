"use client";

import { useMemo, useState, useTransition } from "react";
import { setCentralKitchen, setOutletPrice, setUserOutlets } from "../../outlet/actions";

type Outlet = { id: string; name: string; code: string; city: string | null; central: boolean };
type Product = { id: string; name: string; category: string; price: number; available: boolean };
type Override = { branch: string; product: string; price: number | null; available: boolean | null };

export function OutletsEditor({
  currency,
  canPrice,
  canMenu,
  canPeople,
  canSettings,
  outlets,
  products,
  overrides,
  people,
  access,
}: {
  currency: string;
  canPrice: boolean;
  canMenu: boolean;
  canPeople: boolean;
  canSettings: boolean;
  outlets: Outlet[];
  products: Product[];
  overrides: Override[];
  people: { id: string; name: string; role: string; active: boolean }[];
  access: { user: string; branch: string }[];
}) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [search, setSearch] = useState("");
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const ov = useMemo(() => new Map(overrides.map((o) => [`${o.branch}|${o.product}`, o])), [overrides]);

  const run = (p: Promise<{ ok: boolean; message?: string; error?: string }>) =>
    start(async () => {
      const r = await p;
      setMsg({ ok: r.ok, text: (r.ok ? r.message : r.error) ?? "" });
    });

  const shown = products.filter((p) => !search || p.name.toLowerCase().includes(search.toLowerCase()) || p.category.toLowerCase().includes(search.toLowerCase()));

  return (
    <div className="space-y-5">
      {msg && (
        <div className="card p-3 text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </div>
      )}

      <div className="card p-5">
        <h3 className="font-display text-lg font-bold">Your outlets</h3>
        <ul className="mt-2 divide-y" style={{ borderColor: "var(--color-line)" }}>
          {outlets.map((o) => (
            <li key={o.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5 text-sm">
              <div>
                <span className="font-semibold">{o.name}</span>
                <span style={{ color: "var(--color-ink-3)" }}>
                  {" "}
                  · bill numbers start {o.code}
                  {o.city ? ` · ${o.city}` : ""}
                </span>
              </div>
              {canSettings ? (
                <label className="flex items-center gap-2 text-xs font-semibold">
                  <input type="checkbox" checked={o.central} disabled={pending} onChange={(e) => run(setCentralKitchen(o.id, e.target.checked))} />
                  Central kitchen
                </label>
              ) : o.central ? (
                <span className="text-xs font-bold">Central kitchen</span>
              ) : null}
            </li>
          ))}
        </ul>
      </div>

      <div className="card p-5">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h3 className="font-display text-lg font-bold">Prices per outlet</h3>
            <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
              Leave a box empty to use the menu price. Untick to mark the item sold out in that outlet only.
            </p>
          </div>
          <input className="field h-10 w-56" placeholder="Search dishes" value={search} onChange={(e) => setSearch(e.target.value)} />
        </div>
        <div className="mt-3 overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left" style={{ color: "var(--color-ink-3)" }}>
                <th className="py-2 pr-3">Dish</th>
                <th className="py-2 pr-3 text-right">Menu price</th>
                {outlets.map((o) => (
                  <th key={o.id} className="py-2 pr-3">
                    {o.name}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {shown.map((p) => (
                <tr key={p.id} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                  <td className="py-2 pr-3">
                    <div className="font-semibold">{p.name}</div>
                    <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                      {p.category}
                      {!p.available ? " · sold out everywhere" : ""}
                    </div>
                  </td>
                  <td className="py-2 pr-3 text-right tabular-nums">
                    {currency} {p.price.toFixed(2)}
                  </td>
                  {outlets.map((o) => {
                    const k = `${o.id}|${p.id}`;
                    const cur = ov.get(k);
                    const draft = drafts[k] ?? (cur?.price == null ? "" : String(cur.price));
                    const avail = cur?.available ?? true;
                    return (
                      <td key={o.id} className="py-2 pr-3">
                        <div className="flex items-center gap-2">
                          <input
                            className="field h-9 w-24"
                            inputMode="decimal"
                            placeholder={p.price.toFixed(2)}
                            value={draft}
                            disabled={!canPrice || pending}
                            onChange={(e) => setDrafts({ ...drafts, [k]: e.target.value })}
                            onBlur={() => {
                              const before = cur?.price == null ? "" : String(cur.price);
                              if (draft !== before) run(setOutletPrice(p.id, o.id, draft, cur?.available ?? null));
                            }}
                          />
                          <input
                            type="checkbox"
                            title="Available in this outlet"
                            checked={avail}
                            disabled={!canMenu || pending}
                            onChange={(e) => run(setOutletPrice(p.id, o.id, cur?.price == null ? "" : String(cur.price), e.target.checked ? null : false))}
                          />
                        </div>
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {canPeople && (
        <div className="card p-5">
          <h3 className="font-display text-lg font-bold">Who works where</h3>
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            Tick the outlets each person may work in. Owners work everywhere. Nobody ticked means every outlet.
          </p>
          <div className="mt-3 overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left" style={{ color: "var(--color-ink-3)" }}>
                  <th className="py-2 pr-3">Person</th>
                  {outlets.map((o) => (
                    <th key={o.id} className="py-2 pr-3">
                      {o.name}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {people
                  .filter((u) => u.active)
                  .map((u) => {
                    const rows = access.filter((a) => a.user === u.id).map((a) => a.branch);
                    // No rows = every outlet.
                    const mine = rows.length === 0 ? outlets.map((x) => x.id) : rows;
                    return (
                      <tr key={u.id} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                        <td className="py-2 pr-3">
                          <span className="font-semibold">{u.name}</span> <span style={{ color: "var(--color-ink-3)" }}>· {u.role}</span>
                        </td>
                        {outlets.map((o) => (
                          <td key={o.id} className="py-2 pr-3">
                            <input
                              type="checkbox"
                              checked={u.role === "Owner" || mine.includes(o.id)}
                              disabled={u.role === "Owner" || pending}
                              onChange={(e) => {
                                const next = e.target.checked ? [...mine, o.id] : mine.filter((b) => b !== o.id);
                                run(setUserOutlets(u.id, next));
                              }}
                            />
                          </td>
                        ))}
                      </tr>
                    );
                  })}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
