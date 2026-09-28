"use client";

import { useState } from "react";
import { waNumber } from "../../../bills/whatsapp-share";

/** Opens WhatsApp with the day summary ready to send (e.g. to the owner). */
export function WhatsAppSummary({ country, text }: { country: string; text: string }) {
  const [phone, setPhone] = useState("");
  return (
    <div className="mt-3 flex gap-2 print:hidden">
      <input className="field flex-1" type="tel" inputMode="tel" placeholder="Owner's WhatsApp number" value={phone} onChange={(e) => setPhone(e.target.value)} />
      <button
        className="btn btn-primary"
        disabled={!phone.trim()}
        onClick={() => window.open(`https://wa.me/${waNumber(phone, country)}?text=${encodeURIComponent(text)}`, "_blank", "noopener")}
      >
        Send on WhatsApp
      </button>
    </div>
  );
}
