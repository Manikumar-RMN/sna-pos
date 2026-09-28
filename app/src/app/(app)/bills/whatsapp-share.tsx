"use client";

import { useState, useTransition } from "react";
import { shareBillLink } from "./actions";

/** Calling code for each country we sell in (used when a phone number is typed without one). */
const DIAL: Record<string, string> = { IN: "91", AE: "971", MY: "60", SG: "65", ID: "62", TH: "66", PH: "63" };

/** Local number → international digits for WhatsApp (e.g. 98400 12345 in India → 919840012345). */
export function waNumber(raw: string, country: string): string {
  let d = raw.replace(/[^0-9+]/g, "");
  if (d.startsWith("+")) return d.slice(1);
  if (d.startsWith("00")) return d.slice(2);
  d = d.replace(/^0+/, "");
  const code = DIAL[country] ?? "";
  return d.startsWith(code) && d.length > 10 ? d : code + d;
}

/**
 * Sends the e-bill on WhatsApp: opens WhatsApp (app or web) with the message ready; the cashier taps Send.
 * No WhatsApp Business account is needed for this. Automatic sending needs the WhatsApp Business API later.
 */
export function WhatsAppShare({ orderId, country, text }: { orderId: string; country: string; text: string }) {
  const [phone, setPhone] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function send() {
    setError(null);
    start(async () => {
      const r = await shareBillLink(orderId);
      if (!r.ok) return setError(r.error);
      const to = phone.trim() || r.phone || "";
      if (!to) return setError("Enter the guest's WhatsApp number.");
      const msg = `${text}\nView your bill: ${r.url}\nThank you!`;
      window.open(`https://wa.me/${waNumber(to, country)}?text=${encodeURIComponent(msg)}`, "_blank", "noopener");
    });
  }

  return (
    <div className="card mb-4 flex flex-wrap items-end gap-2 p-4">
      <label className="min-w-0 flex-1">
        <span className="mb-1.5 block text-sm font-semibold">Send bill on WhatsApp</span>
        <input
          className="field"
          type="tel"
          inputMode="tel"
          placeholder="Guest's number (leave empty to use the customer on the bill)"
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
        />
      </label>
      <button className="btn btn-primary" disabled={pending} onClick={send}>
        {pending ? "…" : "Send"}
      </button>
      {error && <p role="alert" className="w-full text-sm font-semibold" style={{ color: "var(--color-bad)" }}>{error}</p>}
    </div>
  );
}
