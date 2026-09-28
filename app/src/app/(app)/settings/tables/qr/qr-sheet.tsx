"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import QRCode from "qrcode";
import { resetTableQr } from "../../actions";

type Code = { table_id: string; table_number: string; token: string };

function Qr({ url }: { url: string }) {
  const [svg, setSvg] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    QRCode.toString(url, { type: "svg", margin: 1, errorCorrectionLevel: "M" }).then((s) => live && setSvg(s));
    return () => {
      live = false;
    };
  }, [url]);
  return <div className="mx-auto h-44 w-44" dangerouslySetInnerHTML={{ __html: svg ?? "" }} aria-label="QR code" />;
}

export function QrSheet({ restaurant, origin, codes }: { restaurant: string; origin: string; codes: Code[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  if (codes.length === 0) return <p className="card p-4 text-sm">Add tables first (Settings → Tables).</p>;
  return (
    <>
      <button className="btn btn-primary mb-4 print:hidden" onClick={() => window.print()}>
        Print
      </button>
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 print:grid-cols-3">
        {codes.map((c) => (
          <div key={c.table_id} className="card break-inside-avoid p-4 text-center">
            <div className="text-sm font-bold">{restaurant}</div>
            <div className="font-display text-2xl font-bold">Table {c.table_number}</div>
            <Qr url={`${origin}/t/${c.token}`} />
            <div className="text-xs">Scan to see the menu and order</div>
            <button
              className="mt-2 text-xs font-semibold print:hidden"
              style={{ color: "var(--color-bad)" }}
              disabled={pending}
              onClick={() => {
                if (!confirm(`Make a new QR code for table ${c.table_number}? The old printed code will stop working.`)) return;
                start(async () => {
                  await resetTableQr(c.table_id);
                  router.refresh();
                });
              }}
            >
              New code
            </button>
          </div>
        ))}
      </div>
    </>
  );
}
