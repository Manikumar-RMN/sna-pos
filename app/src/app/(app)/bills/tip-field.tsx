"use client";

import { parseTip, suggestTip, tipText } from "./tip";

/**
 * Optional tip box for the payment panel. It only collects a number; the server (pay_order, p_tip) records it as a memo.
 * A tip is NOT part of the bill or of the payment, so it never changes "Take ..." or the change due, and it does not
 * go into the shift cash or the day close.
 *
 * Wiring (see docs/handover/WS-C/tip-wiring.md): hold `const [tip, setTip] = useState("")` in BillActions, render
 * <TipField value={tip} onChange={setTip} base={balance} disabled={pending} />, disable the pay button while
 * `tipError(tip)` (from ./tip) is not null, pass `tip: tipForRequest(tip)` to payBill, and clear the box after a successful payment.
 */
export function TipField({
  value,
  onChange,
  base,
  disabled,
  offline,
  percents = [5, 10, 15],
}: {
  value: string;
  onChange: (v: string) => void;
  /** The amount being paid now; only used to suggest a percentage. */
  base?: number;
  disabled?: boolean;
  /** Offline there is no tip (the offline bill cannot carry one). */
  offline?: boolean;
  percents?: number[];
}) {
  const parsed = parseTip(value);
  if (offline) {
    return (
      <p className="mt-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
        Tips need an internet connection.
      </p>
    );
  }
  return (
    <div className="mt-2" data-testid="tip-field">
      <div className="flex items-center gap-2">
        <label className="text-xs font-semibold" htmlFor="tip-amount">
          Tip <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>(optional)</span>
        </label>
        <input
          id="tip-amount"
          className="field h-10 w-28 text-right text-sm"
          inputMode="decimal"
          placeholder="0"
          value={value}
          disabled={disabled}
          aria-invalid={!parsed.ok}
          onChange={(e) => onChange(e.target.value)}
        />
        {base !== undefined && base > 0 && (
          <div className="flex gap-1">
            {percents.map((p) => (
              <button
                key={p}
                type="button"
                className="rounded-lg border px-2 py-1.5 text-xs font-semibold"
                style={{ borderColor: "var(--color-line)" }}
                disabled={disabled}
                onClick={() => onChange(tipText(suggestTip(base, p)))}
              >
                {p}%
              </button>
            ))}
            {value !== "" && (
              <button type="button" className="rounded-lg px-2 py-1.5 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }} disabled={disabled} onClick={() => onChange("")}>
                Clear
              </button>
            )}
          </div>
        )}
      </div>
      {!parsed.ok ? (
        <p className="mt-1 text-[11px]" role="alert" style={{ color: "var(--color-bad)" }}>
          {parsed.error}
        </p>
      ) : (
        <p className="mt-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
          Recorded for the report only. It is not added to the bill or the cash drawer.
        </p>
      )}
    </div>
  );
}
