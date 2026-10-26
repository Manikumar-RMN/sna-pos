"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { findCustomer, setGuestDetails, type RegularGuest } from "./actions";
import { useOnline } from "@/lib/use-online";
import { regularChipText } from "./loyalty-math";

/**
 * Token number and the guest's name, phone and delivery address, shown above
 * the bill, with a small form to add or correct them.
 */
export function GuestDetails({
  orderId,
  token,
  guest,
  delivery,
  canEdit,
  showPoints = false,
}: {
  orderId: string;
  /** Token number for the day, if the outlet uses tokens. */
  token: number | null;
  guest: { name: string | null; phone: string | null; address: string | null } | null;
  /** Delivery bills also carry an address. */
  delivery: boolean;
  /** False on voided bills, closed days, and for staff who cannot take orders. */
  canEdit: boolean;
  /** Loyalty module on: the chip also shows the guest's points. */
  showPoints?: boolean;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [address, setAddress] = useState("");
  const [error, setError] = useState<string | null>(null);
  const online = useOnline();
  const [regular, setRegular] = useState<RegularGuest | null>(null);

  // Regular-guest hint: looked up from the saved phone, and again (after a pause) as a new phone is typed. Hint only; never blocks saving.
  const lookupPhone = open ? phone : guest?.phone ? `+${guest.phone}` : "";
  useEffect(() => {
    if (!online || lookupPhone.replace(/\D/g, "").length < 7) {
      setRegular(null);
      return;
    }
    let live = true;
    const t = setTimeout(() => {
      findCustomer(lookupPhone)
        .then((g) => live && setRegular(g))
        .catch(() => live && setRegular(null));
    }, 500);
    return () => {
      live = false;
      clearTimeout(t);
    };
  }, [lookupPhone, online]);
  const chip = regular ? regularChipText(regular, showPoints) : null;

  const hasGuest = !!(guest?.name || guest?.phone || guest?.address);
  if (token == null && !hasGuest && !canEdit) return null;

  function openForm() {
    // Start from what is on the bill now.
    setName(guest?.name ?? "");
    setPhone(guest?.phone ? `+${guest.phone}` : "");
    setAddress(guest?.address ?? "");
    setError(null);
    setOpen(true);
  }
  function save() {
    setError(null);
    start(async () => {
      const res = await setGuestDetails({ orderId, name, phone, address: delivery ? address : null });
      if (!res.ok) return setError(res.error);
      setOpen(false);
      router.refresh();
    });
  }

  const editButton = canEdit && !open && (
    <button type="button" className="shrink-0 text-sm font-semibold" style={{ color: "var(--color-brand)" }} onClick={openForm}>
      {hasGuest ? "Change guest details" : "+ Guest details"}
    </button>
  );

  // Nothing to show yet: only the small link, so the bill screen stays as it was.
  if (token == null && !hasGuest && !open) {
    return <div className="no-print mx-auto mb-2 max-w-sm text-right">{editButton}</div>;
  }

  return (
    <div className="no-print card mx-auto mb-3 max-w-sm p-3 text-sm">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          {token != null && <div className="text-base font-bold">Token {token}</div>}
          {(guest?.name || guest?.phone) && <div>{[guest.name, guest.phone ? `+${guest.phone}` : null].filter(Boolean).join(" · ")}</div>}
          {chip && !open && (
            <div className="mt-1">
              <span className="inline-block rounded-full px-2 py-0.5 text-xs font-semibold" style={{ background: "var(--color-brand-soft)", color: "var(--color-brand-strong)" }} data-testid="regular-guest-chip">
                {chip}
              </span>
            </div>
          )}
          {guest?.address && <div style={{ color: "var(--color-ink-2)" }}>Deliver to: {guest.address}</div>}
          {open && !hasGuest && token == null && <div className="font-bold">Guest details</div>}
        </div>
        {editButton}
      </div>

      {open && (
        <div className="mt-3 space-y-2 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
          <input className="field h-10 text-sm" placeholder="Guest name" aria-label="Guest name" maxLength={80} value={name} onChange={(e) => setName(e.target.value)} />
          <input
            className="field h-10 text-sm"
            type="tel"
            inputMode="tel"
            placeholder="Phone"
            aria-label="Guest phone"
            maxLength={20}
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
          />
          {open && chip && (
            <p className="text-xs font-semibold" role="status" style={{ color: "var(--color-brand-strong)" }}>
              {chip}
            </p>
          )}
          {delivery && (
            <input
              className="field h-10 text-sm"
              placeholder="Delivery address"
              aria-label="Delivery address"
              maxLength={300}
              value={address}
              onChange={(e) => setAddress(e.target.value)}
            />
          )}
          {error && (
            <p className="rounded-lg px-3 py-2 text-xs" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
              {error}
            </p>
          )}
          <div className="flex gap-2">
            <button type="button" className="btn flex-1 border text-sm" style={{ borderColor: "var(--color-line)" }} disabled={pending} onClick={() => setOpen(false)}>
              Cancel
            </button>
            <button type="button" className="btn btn-primary flex-1 text-sm" disabled={pending} onClick={save}>
              {pending ? "Saving…" : "Save"}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
