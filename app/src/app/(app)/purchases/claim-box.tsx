"use client";

import { setInputTaxClaim } from "./actions";
import { Msg, useRun } from "./ui";

/**
 * Whether the restaurant claims the tax on purchases back. When it does (and the supplier's tax
 * number is on file) the tax is kept out of the stock cost; otherwise it becomes part of the cost.
 */
export function ClaimBox({ claimTax, canSet }: { claimTax: boolean; canSet: boolean }) {
  const { pending, msg, run } = useRun();
  return (
    <div className="mt-3 rounded-xl border p-3 text-xs" style={{ color: "var(--color-ink-2)" }}>
      <label className="flex items-start gap-2 text-sm font-semibold">
        <input type="checkbox" className="mt-1" checked={claimTax} disabled={!canSet || pending} onChange={(e) => run(() => setInputTaxClaim(e.target.checked))} />
        <span>We claim the tax on purchases back from the tax office</span>
      </label>
      <p className="mt-1">
        {claimTax
          ? "Tax on a delivery is kept out of the ingredient cost only when the supplier has a tax number saved. Otherwise it is added to the cost."
          : "Tax on a delivery is added to the ingredient cost."}{" "}
        Many restaurants cannot claim it (for example, small restaurants in India at 5% GST). Ask your accountant before switching this on.
        {!canSet && " Only the owner can change this."}
      </p>
      <Msg msg={msg} />
    </div>
  );
}
