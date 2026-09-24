"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import { payBill, refundBill, voidBill } from "./actions";

type Method = { id: string; name: string; kind: string };

export function BillActions({
  orderId,
  state,
  grandTotal,
  paidTotal,
  refunded,
  currency,
  methods,
  canPay,
  canVoid,
  canRefund,
  shiftOpen,
}: {
  orderId: string;
  state: "paid" | "unpaid" | "voided" | "refunded" | "part-refunded";
  grandTotal: number;
  paidTotal: number;
  refunded: number;
  currency: string;
  methods: Method[];
  canPay: boolean;
  canVoid: boolean;
  canRefund: boolean;
  shiftOpen: boolean;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const [methodId, setMethodId] = useState(methods[0]?.id ?? "");
  const [tendered, setTendered] = useState("");
  const [refundAmt, setRefundAmt] = useState("");
  const [refundReason, setRefundReason] = useState("");
  const [voidReason, setVoidReason] = useState("");
  const [confirm, setConfirm] = useState<null | "void" | "refund">(null);

  const remaining = Math.max(0, Math.round((paidTotal - refunded) * 100) / 100);
  const isCash = methods.find((m) => m.id === methodId)?.kind === "cash";
  const change = isCash && Number(tendered) > grandTotal ? Number(tendered) - grandTotal : 0;

  const showPay = state === "unpaid" && canPay;
  const showRefund = canRefund && (state === "paid" || state === "part-refunded") && remaining > 0;
  const showVoid = canVoid && state !== "voided" && refunded === 0;

  function run(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>) {
    setError(null);
    setNotice(null);
    start(async () => {
      const res = await fn();
      if (!res.ok) {
        setError(res.error ?? "Something went wrong.");
        return;
      }
      setNotice(res.message ?? "Done.");
      setConfirm(null);
      setVoidReason("");
      setRefundReason("");
      setRefundAmt("");
      setTendered("");
      router.refresh();
    });
  }

  if (!showPay && !showRefund && !showVoid && !notice) return null;

  return (
    <div className="no-print mx-auto mt-4 max-w-sm space-y-3">
      {notice && (
        <p className="rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-ok-soft)", color: "var(--color-ok)" }}>
          {notice}
        </p>
      )}
      {error && (
        <p className="rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {error}
        </p>
      )}

      {showPay && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Take payment</h2>
          {!shiftOpen ? (
            <p className="mt-2 text-sm" style={{ color: "var(--color-ink-2)" }}>
              Open a shift on the Shift screen before taking payments.
            </p>
          ) : (
            <>
              <div className="mt-3 grid grid-cols-3 gap-1.5">
                {methods.map((m) => (
                  <button
                    key={m.id}
                    onClick={() => setMethodId(m.id)}
                    className="rounded-lg border px-2 py-2 text-xs font-semibold"
                    style={{
                      borderColor: methodId === m.id ? "var(--color-brand)" : "var(--color-line)",
                      background: methodId === m.id ? "var(--color-brand-soft)" : "transparent",
                      color: methodId === m.id ? "var(--color-brand-strong)" : "var(--color-ink-2)",
                    }}
                  >
                    {m.name}
                  </button>
                ))}
              </div>
              {isCash && (
                <div className="mt-2 flex items-center gap-2">
                  <input
                    className="field h-10 flex-1 text-sm"
                    inputMode="decimal"
                    placeholder="Cash received"
                    value={tendered}
                    onChange={(e) => setTendered(e.target.value)}
                  />
                  <span className="text-sm">
                    Change <b>{money(change, currency)}</b>
                  </span>
                </div>
              )}
              <button
                className="btn btn-primary mt-3 w-full"
                disabled={pending || !methodId}
                onClick={() =>
                  run(() =>
                    payBill({
                      orderId,
                      paymentMethodId: methodId,
                      tendered: isCash && tendered !== "" ? Number(tendered) : null,
                    }),
                  )
                }
              >
                {pending ? "Saving…" : `Take ${money(grandTotal, currency)}`}
              </button>
            </>
          )}
        </section>
      )}

      {showRefund && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Refund</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Up to {money(remaining, currency)} can be refunded. The bill stays on record.
          </p>
          <input
            className="field mt-3 h-10 text-sm"
            inputMode="decimal"
            placeholder={`Amount (max ${remaining.toFixed(2)})`}
            value={refundAmt}
            onChange={(e) => setRefundAmt(e.target.value)}
          />
          <input
            className="field mt-2 h-10 text-sm"
            placeholder="Reason (required)"
            value={refundReason}
            onChange={(e) => setRefundReason(e.target.value)}
          />
          {confirm === "refund" ? (
            <div className="mt-3 flex gap-2">
              <button className="btn flex-1 border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setConfirm(null)}>
                Cancel
              </button>
              <button
                className="btn flex-1 text-sm text-white"
                style={{ background: "var(--color-bad)" }}
                disabled={pending}
                onClick={() => run(() => refundBill({ orderId, amount: Number(refundAmt), reason: refundReason }))}
              >
                {pending ? "Saving…" : `Confirm refund ${money(Number(refundAmt) || 0, currency)}`}
              </button>
            </div>
          ) : (
            <button
              className="btn mt-3 w-full border text-sm"
              style={{ borderColor: "var(--color-line)" }}
              disabled={!(Number(refundAmt) > 0) || refundReason.trim().length < 3}
              onClick={() => setConfirm("refund")}
            >
              Refund…
            </button>
          )}
        </section>
      )}

      {showVoid && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Void bill</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Cancels the whole bill. It stays visible in reports, marked Voided, with your name and reason.
            {paidTotal > 0 ? " Any money taken is treated as returned to the customer." : ""}
          </p>
          <input
            className="field mt-3 h-10 text-sm"
            placeholder="Reason (required)"
            value={voidReason}
            onChange={(e) => setVoidReason(e.target.value)}
          />
          {confirm === "void" ? (
            <div className="mt-3 flex gap-2">
              <button className="btn flex-1 border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setConfirm(null)}>
                Cancel
              </button>
              <button
                className="btn flex-1 text-sm text-white"
                style={{ background: "var(--color-bad)" }}
                disabled={pending}
                onClick={() => run(() => voidBill({ orderId, reason: voidReason }))}
              >
                {pending ? "Saving…" : "Confirm void"}
              </button>
            </div>
          ) : (
            <button
              className="btn mt-3 w-full border text-sm"
              style={{ borderColor: "var(--color-bad)", color: "var(--color-bad)" }}
              disabled={voidReason.trim().length < 3}
              onClick={() => setConfirm("void")}
            >
              Void…
            </button>
          )}
        </section>
      )}
    </div>
  );
}
