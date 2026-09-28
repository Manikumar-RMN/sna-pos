"use client";

import { useEffect, useState } from "react";
import QRCode from "qrcode";

/** The standard UPI payment link that every UPI app (GPay, PhonePe, Paytm, BHIM) understands. */
export function upiLink(upiId: string, payee: string, amount: number, note: string) {
  const q = new URLSearchParams({ pa: upiId, pn: payee.slice(0, 50), am: amount.toFixed(2), cu: "INR", tn: note.slice(0, 50) });
  return `upi://pay?${q.toString()}`;
}

/** A scan-to-pay QR for the exact amount due. The customer scans it with any UPI app. */
export function UpiQr({
  upiId,
  payee,
  amount,
  note,
  size = 168,
  caption = true,
}: {
  upiId: string;
  payee: string;
  amount: number;
  note: string;
  size?: number;
  caption?: boolean;
}) {
  const [svg, setSvg] = useState<string | null>(null);
  const link = upiLink(upiId, payee, amount, note);
  useEffect(() => {
    let live = true;
    QRCode.toString(link, { type: "svg", margin: 1, errorCorrectionLevel: "M" })
      .then((s) => live && setSvg(s))
      .catch(() => live && setSvg(null));
    return () => {
      live = false;
    };
  }, [link]);
  if (!(amount > 0)) return null;
  return (
    <div className="flex flex-col items-center gap-1 text-center">
      <div
        role="img"
        aria-label={`UPI QR code to pay ${amount.toFixed(2)} to ${upiId}`}
        style={{ width: size, height: size, background: "#fff" }}
        dangerouslySetInnerHTML={svg ? { __html: svg } : undefined}
      />
      {caption && (
        <div className="text-[11px] leading-tight">
          Scan with any UPI app to pay <b>₹{amount.toFixed(2)}</b>
          <br />
          {upiId}
        </div>
      )}
    </div>
  );
}
