"use client";

import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { chainReport, setOutletRegion, setRegionPrice, type ChainRow, type RegionRow } from "./chain-actions";

type Outlet = { id: string; name: string; region: string | null; royalty: number };

/** Chains and franchises: regions, royalty, one price per region, and the chain report. */
export function ChainTools({
  outlets,
  products,
  currency,
  canSettings,
  canPrice,
  canReport,
  today,
}: {
  outlets: Outlet[];
  products: { id: string; name: string; price: number }[];
  currency: string;
  canSettings: boolean;
  canPrice: boolean;
  canReport: boolean;
  today: string;
}) {
  const m = (n: number) => money(n, currency);
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [rows, setRows] = useState(outlets.map((o) => ({ ...o, region: o.region ?? "", royalty: String(o.royalty) })));
  const regions = [...new Set(outlets.map((o) => o.region).filter((r): r is string => !!r))].sort();
  const [rp, setRp] = useState({ region: regions[0] ?? "", product: products[0]?.id ?? "", price: "" });
  const [from, setFrom] = useState(today.slice(0, 8) + "01");
  const [to, setTo] = useState(today);
  const [report, setReport] = useState<{ outlets: ChainRow[]; regions: RegionRow[] } | null>(null);
  const say = (r: { error: string | null }, ok: string) => setMsg(r.error ? { ok: false, text: r.error } : { ok: true, text: ok });

  return (
    <div className="mt-6 space-y-4">
      <section className="card p-4">
        <h2 className="text-sm font-bold">Regions and franchise royalty</h2>
        <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Group outlets into regions to price them together. For a franchise outlet, enter the royalty percent of its sales (before tax) that it owes you.
        </p>
        <div className="mt-3 space-y-2">
          {rows.map((o, i) => (
            <div key={o.id} className="flex flex-wrap items-center gap-2 text-sm">
              <span className="w-40 truncate font-semibold">{o.name}</span>
              <input className="field w-36" placeholder="Region" maxLength={40} value={o.region} disabled={!canSettings} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, region: e.target.value } : x)))} aria-label={`Region of ${o.name}`} />
              <input className="field w-24" inputMode="decimal" value={o.royalty} disabled={!canSettings} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, royalty: e.target.value } : x)))} aria-label={`Royalty percent of ${o.name}`} />
              <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>% royalty</span>
              {canSettings && (
                <button className="btn border" style={{ borderColor: "var(--color-line)", minHeight: 38 }} disabled={pending} onClick={() => start(async () => say(await setOutletRegion(o.id, o.region, Number(o.royalty) || 0), `${o.name} saved.`))}>
                  Save
                </button>
              )}
            </div>
          ))}
        </div>
      </section>

      {canPrice && regions.length > 0 && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">One price for a whole region</h2>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <select className="field w-36" value={rp.region} onChange={(e) => setRp({ ...rp, region: e.target.value })} aria-label="Region">
              {regions.map((r) => <option key={r} value={r}>{r}</option>)}
            </select>
            <select className="field w-56" value={rp.product} onChange={(e) => setRp({ ...rp, product: e.target.value })} aria-label="Dish">
              {products.map((p) => <option key={p.id} value={p.id}>{p.name} ({m(p.price)})</option>)}
            </select>
            <input className="field w-28" inputMode="decimal" placeholder="Price" value={rp.price} onChange={(e) => setRp({ ...rp, price: e.target.value })} aria-label="Price in this region" />
            <button
              className="btn btn-primary"
              disabled={pending || !rp.region || !rp.product}
              onClick={() =>
                start(async () => {
                  const r = await setRegionPrice(rp.region, rp.product, rp.price.trim() === "" ? null : Number(rp.price));
                  say(r, rp.price.trim() === "" ? `Back to the main menu price in ${r.outlets} outlets.` : `Price set in ${r.outlets} outlets of ${rp.region}.`);
                })
              }
            >
              Set for region
            </button>
          </div>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>Leave the price empty to go back to the main menu price in that region.</p>
        </section>
      )}

      {msg && <p className="text-sm" role="status" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>{msg.text}</p>}

      {canReport && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Chain report</h2>
          <div className="mt-2 flex flex-wrap items-end gap-2">
            <label className="text-xs font-semibold">From <input type="date" className="field mt-1" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
            <label className="text-xs font-semibold">To <input type="date" className="field mt-1" value={to} onChange={(e) => setTo(e.target.value)} /></label>
            <button
              className="btn btn-primary"
              disabled={pending}
              onClick={() =>
                start(async () => {
                  const r = await chainReport(from, to);
                  if (r.error) setMsg({ ok: false, text: r.error });
                  else setReport({ outlets: r.outlets, regions: r.regions });
                })
              }
            >
              Show
            </button>
          </div>
          {report && (
            <div className="mt-3 overflow-x-auto">
              <table className="w-full text-left text-sm tabular-nums">
                <thead style={{ color: "var(--color-ink-3)" }}>
                  <tr>
                    <th className="py-1">Outlet</th>
                    <th className="py-1">Region</th>
                    <th className="py-1 text-right">Bills</th>
                    <th className="py-1 text-right">Sales</th>
                    <th className="py-1 text-right">Average bill</th>
                    <th className="py-1 text-right">Royalty</th>
                  </tr>
                </thead>
                <tbody>
                  {report.outlets.map((o) => (
                    <tr key={o.branch_id} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                      <td className="py-2">{o.outlet}</td>
                      <td className="py-2">{o.region}</td>
                      <td className="py-2 text-right">{o.bills}</td>
                      <td className="py-2 text-right">{m(Number(o.sales))}</td>
                      <td className="py-2 text-right">{m(Number(o.average_bill))}</td>
                      <td className="py-2 text-right">{Number(o.royalty) > 0 ? `${m(Number(o.royalty))} (${Number(o.royalty_percent)}%)` : "—"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {report.regions.length > 1 && (
                <table className="mt-4 w-full text-left text-sm tabular-nums">
                  <thead style={{ color: "var(--color-ink-3)" }}>
                    <tr>
                      <th className="py-1">Region</th>
                      <th className="py-1 text-right">Outlets</th>
                      <th className="py-1 text-right">Bills</th>
                      <th className="py-1 text-right">Sales</th>
                      <th className="py-1 text-right">Royalty</th>
                    </tr>
                  </thead>
                  <tbody>
                    {report.regions.map((r) => (
                      <tr key={r.region} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                        <td className="py-2 font-semibold">{r.region}</td>
                        <td className="py-2 text-right">{r.outlets}</td>
                        <td className="py-2 text-right">{r.bills}</td>
                        <td className="py-2 text-right">{m(Number(r.sales))}</td>
                        <td className="py-2 text-right">{m(Number(r.royalty))}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
              <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>Sales are after discounts and before tax. Complimentary and voided bills are left out.</p>
            </div>
          )}
        </section>
      )}
    </div>
  );
}
