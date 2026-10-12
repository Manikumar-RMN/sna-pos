"use client";

import { useEffect, useState } from "react";
import { readDevicePrint, saveDevicePrint, type DevicePrint } from "@/lib/device-print";
import { lr, sendToRawbt } from "@/lib/rawbt";

export function PrinterSetup({ stations, paper }: { stations: string[]; paper: "58" | "80" }) {
  const [v, setV] = useState<DevicePrint>({ bills: false, stations: [], kotHere: true, method: "browser" });
  const [saved, setSaved] = useState(false);
  useEffect(() => setV(readDevicePrint()), []);

  function update(next: DevicePrint) {
    setV(next);
    saveDevicePrint(next);
    setSaved(true);
  }

  function rawbtTest() {
    const w = paper === "58" ? 32 : 48;
    sendToRawbt(
      [
        { text: "SNA POS", align: "center", big: true },
        { text: "RawBT test print", align: "center" },
        { rule: true },
        { text: lr("2 x Masala Dosa", "180.00", w) },
        { text: lr("TOTAL", "Rs.180.00", Math.floor(w / 2)), big: true },
        { rule: true },
        { text: `${paper} mm paper, ${w} characters a line`, align: "center" },
        { cut: true },
      ],
      w,
    );
  }

  return (
    <div className="space-y-4">
      <section className="card p-5">
        <h2 className="text-base font-bold">How this device prints</h2>
        <div className="mt-3 grid gap-2 sm:grid-cols-2" role="radiogroup" aria-label="How this device prints">
          {(
            [
              ["browser", "Print window (computer)", "Windows or Mac with a receipt printer driver. Uses the browser's print."],
              ["rawbt", "RawBT app (Android)", "Android tablet or phone with a Bluetooth, USB or Wi-Fi receipt printer."],
            ] as const
          ).map(([key, label, hint]) => {
            const on = v.method === key;
            return (
              <label
                key={key}
                className="flex items-start gap-3 rounded-2xl border px-3.5 py-2.5 text-sm"
                style={on ? { borderColor: "var(--color-brand)", background: "var(--color-brand-soft)" } : { borderColor: "var(--color-line)" }}
              >
                <input type="radio" name="print_method" className="mt-0.5 h-5 w-5 shrink-0" checked={on} onChange={() => update({ ...v, method: key })} />
                <span>
                  <span className="block font-semibold">{label}</span>
                  <span className="block text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                    {hint}
                  </span>
                </span>
              </label>
            );
          })}
        </div>
        {v.method === "rawbt" && (
          <div className="mt-4 rounded-xl p-3 text-sm" style={{ background: "var(--color-ground)" }}>
            <ol className="list-decimal space-y-1.5 pl-5" style={{ color: "var(--color-ink-2)" }}>
              <li>
                Install <b>RawBT</b> from the Google Play Store on this tablet or phone.
              </li>
              <li>Open RawBT, choose the printer (pair Bluetooth printers in Android settings first) and print its own test page.</li>
              <li>
                Come back here and press <b>Test print with RawBT</b>. The first time, Android asks which app to use: choose RawBT and{" "}
                <b>Always</b>.
              </li>
            </ol>
            <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
              Bills and KOTs print in the printer&rsquo;s own letters, {paper === "58" ? "32" : "48"} to a line ({paper} mm paper, Settings → Bill layout).
              Names in Tamil or other scripts are left out; the English name prints. Android opens RawBT only just after a tap, so if a bill or KOT
              does not print by itself, press <b>Print</b> on the same screen. On the Kitchen screen, new tickets wait for one tap on{" "}
              <b>Print new tickets</b>.
            </p>
            <button className="btn btn-primary mt-3 px-4 text-sm" onClick={rawbtTest}>
              Test print with RawBT
            </button>
          </div>
        )}
      </section>

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
