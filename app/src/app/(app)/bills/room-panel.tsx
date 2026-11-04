"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { chargeToRoom } from "../accounts/actions";

type Guest = { stay_id: string; stay_no: number; room_number: string; guest: string };

/** On an unpaid bill: charge what is left to the folio of a guest who is in the hotel. */
export function RoomPanel({ orderId, guests }: { orderId: string; guests: Guest[] }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();
  if (guests.length === 0) return null;
  const shown = guests.filter((g) => !q.trim() || `${g.room_number} ${g.guest}`.toLowerCase().includes(q.trim().toLowerCase())).slice(0, 8);
  return (
    <div className="no-print card mx-auto mt-3 max-w-sm p-4">
      {!open ? (
        <button className="w-full text-left text-sm font-semibold" style={{ color: "var(--color-brand)" }} onClick={() => setOpen(true)}>
          Charge to room (hotel guest) →
        </button>
      ) : (
        <>
          <div className="text-sm font-bold">Charge to room</div>
          <input className="field mt-2" placeholder="Room number or guest name" value={q} onChange={(e) => setQ(e.target.value)} autoFocus />
          <div className="mt-2 space-y-1.5">
            {shown.map((g) => (
              <button
                key={g.stay_id}
                disabled={pending}
                className="flex w-full items-center justify-between rounded-lg border px-3 py-2 text-left text-sm"
                style={{ borderColor: "var(--color-line)" }}
                onClick={() =>
                  start(async () => {
                    const r = await chargeToRoom(orderId, g.stay_id);
                    if (r.error) return setError(r.error);
                    router.refresh();
                  })
                }
              >
                <span className="font-semibold">Room {g.room_number}</span>
                <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>{g.guest}</span>
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
