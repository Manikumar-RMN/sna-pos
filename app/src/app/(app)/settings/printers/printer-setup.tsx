"use client";

import { useEffect, useState } from "react";
import { readDevicePrint, saveDevicePrint, type DevicePrint } from "@/lib/device-print";

export function PrinterSetup({ stations }: { stations: string[] }) {
  const [v, setV] = useState<DevicePrint>({ bills: false, stations: [], kotHere: true });
  const [saved, setSaved] = useState(false);
  useEffect(() => setV(readDevicePrint()), []);

  function update(next: DevicePrint) {
    setV(next);
    saveDevicePrint(next);
    setSaved(true);
  }

  return (
    <div className="space-y-4">
      <section className="card p-5">
        <h2 className="text-base font-bold">This device prints</h2>
        <label className="mt-4 flex items-start gap-3 text-sm">
          <input type="checkbox" className="mt-0.5 h-5 w-5" checked={v.bills} onChange={(e) => update({ ...v, bills: e.target.checked })} />
          <span>
            <b>Customer bills</b>, straight after payment
            <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
              For the counter. The bill can always be printed again from Bills.
            </span>
          </span>
        </label>
        <label className="mt-4 flex items-start gap-3 text-sm">
          <input type="checkbox" className="mt-0.5 h-5 w-5" checked={v.kotHere} onChange={(e) => update({ ...v, kotHere: e.target.checked })} />
          <span>
            <b>KOT</b>, when the KOT button is pressed on this device
            <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
              For a counter that hands the ticket to the kitchen. Switch it off if the kitchen has its own printer with the Kitchen screen open.
            </span>
          </span>
        </label>
        <div className="mt-5 text-sm font-bold">Kitchen tickets (KOT) for</div>
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          Keep the Kitchen screen open on this device. New tickets for the ticked stations print by themselves.
        </p>
        <div className="mt-2 flex flex-wrap gap-2">
          {stations.map((s) => {
            const on = v.stations.includes(s);
            return (
              <label key={s} className="flex items-center gap-2 rounded-lg border px-3 py-2 text-sm" style={{ borderColor: on ? "var(--color-brand)" : "var(--color-line)" }}>
                <input
                  type="checkbox"
                  className="h-4 w-4"
                  checked={on}
                  onChange={(e) => update({ ...v, stations: e.target.checked ? [...v.stations, s] : v.stations.filter((x) => x !== s) })}
                />
                {s}
              </label>
            );
          })}
        </div>
        {saved && (
          <p className="mt-3 text-xs" role="status" style={{ color: "var(--color-ok)" }}>
            Saved on this device.
          </p>
        )}
      </section>

      <section className="card p-5 text-sm">
        <h2 className="text-base font-bold">Print without the print window</h2>
        <ol className="mt-2 list-decimal space-y-1.5 pl-5" style={{ color: "var(--color-ink-2)" }}>
          <li>Connect the 80 mm receipt printer and install its driver. Make it the <b>default printer</b> of this computer.</li>
          <li>
            Open SNA POS in Google Chrome started with <code className="rounded px-1" style={{ background: "var(--color-ground)" }}>--kiosk-printing</code>{" "}
            (add it to the Chrome shortcut). Chrome then prints straight to the default printer with no window.
          </li>
          <li>Set the paper size to 80 mm and margins to none once, in the first print window.</li>
        </ol>
        <p className="mt-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Coming next: the SNA Print Helper, a small app that finds the printers on this computer so you can send bills and each
          station&rsquo;s tickets to a chosen printer without changing the default.
        </p>
        <button className="btn mt-4 border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => window.print()}>
          Test print this page
        </button>
      </section>
    </div>
  );
}
