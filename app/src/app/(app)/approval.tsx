"use client";

const LABELS: Record<string, string> = {
  "order.discount": "give this discount or free bill",
  "order.void": "void or cancel",
  "order.refund": "issue a credit note",
  "payment.take": "take this payment",
  "payment.change_mode": "change the payment mode",
  "day.close": "close the day",
  "day.reopen": "reopen the day",
  "cash.movement": "record cash in / out",
  "shift.close": "close the shift",
  "order.reprint": "reprint this bill or kitchen ticket",
  "order.create": "change this order",
  "menu.price_change": "change prices",
  "loyalty.redeem": "use loyalty points on this bill",
  "customer.manage": "change a guest's details",
  "settings.manage": "do this owner-level action (for example deleting a guest's data)",
};

/** Finds "(order.discount)"-style right names that the database puts in "not allowed" messages. */
export function neededRight(message: string | null | undefined): string | null {
  const m = message?.match(/\(([a-z]+\.[a-z_]+)\)/);
  return m ? m[1] : null;
}

/** The message without the technical right name. */
export function cleanMessage(message: string) {
  return message.replace(/\s*\([a-z]+\.[a-z_]+\)/, "");
}

/**
 * Shown when the signed-in person lacks the right for an action. There is no override: the owner
 * gives the right to the role (Settings → Security profiles) or someone who has it does the action.
 * `onApproved` is kept so existing screens keep compiling; it is never called.
 */
export function ApprovalPrompt({ permission, onCancel }: { permission: string; onApproved?: (approver: string) => void; onCancel: () => void }) {
  return (
    <div className="no-print fixed inset-0 z-50 grid place-items-center p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onCancel()}>
      <div className="card w-full max-w-xs p-5" style={{ background: "var(--color-surface)" }} role="dialog" aria-label="Not allowed">
        <h3 className="text-lg font-bold">Not allowed</h3>
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-2)" }}>
          Your role cannot {LABELS[permission] ?? "do this"}. Ask a manager or the owner to do it, or to add this right to your role in Settings → Security profiles.
        </p>
        <button className="btn btn-primary mt-4 w-full" onClick={onCancel}>
          OK
        </button>
      </div>
    </div>
  );
}
