"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import { chargeToAccount } from "../accounts/actions";

type Acc = { id: string; name: string; phone: string | null; company: string | null; limit: number | null; balance: number };

/** On an unpaid bill: charge what is left to a customer's credit account (pay later). */
export function AccountPanel({ orderId, accounts, currency }: { orderId: string; accounts: Acc[]; currency: string }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();
  const usable = accounts.filter((a) => a.limit != null);
  if (usable.length === 0) return null;
  const shown = usable.filter((a) => !q.trim() || `${a.name} ${a.phone ?? ""} ${a.company ?? ""}`.toLowerCase().includes(q.trim().toLowerCase())).slice(0, 8);
  return (
    <div className="no-print card mx-auto mt-3 max-w-sm p-4">
      {!open ? (
        <button className="w-full text-left text-sm font-semibold" style={{ color: "var(--color-brand)" }} onClick={() => setOpen(true)}>
          Charge to a customer account (pay later) →
        </button>
      ) : (
        <>
          <div className="text-sm font-bold">Charge to account</div>
          <input className="field mt-2" placeholder="Search name, phone or company" value={q} onChange={(e) => setQ(e.target.value)} autoFocus />
          <div className="mt-2 space-y-1.5">
            {shown.map((a) => (
              <button
                key={a.id}
                disabled={pending}
                className="flex w-full items-center justify-between rounded-lg border px-3 py-2 text-left text-sm"
                style={{ borderColor: "var(--color-line)" }}
                onClick={() =>
                  start(async () => {
                    const r = await chargeToAccount(orderId, a.id);
                    if (r.error) return setError(r.error);
                    router.refresh();
                  })
                }
              >
                <span>
                  <span className="font-semibold">{a.name}</span>
                  {a.company && <span className="text-xs" style={{ color: "var(--color-ink-3)" }}> · {a.company}</span>}
                </span>
                <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                  owes {money(Number(a.balance), currency)} of {money(Number(a.limit), currency)}
                </span>
              </button>
            ))}
          </div>
          {error && (
            <p className="mt-2 text-sm" role="alert" style={{ color: "var(--color-bad)" }}>
              {error}
            </p>
          )}
        </>
      )}
    </div>
  );
}
