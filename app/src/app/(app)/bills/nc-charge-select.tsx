"use client";

import { useEffect, useState } from "react";
import { listNcTargets } from "./actions";

/**
 * Winsar "NC KOT Charge To": who bears the cost of a no-charge bill. Shows nothing when the outlet has not set up any
 * charge-to accounts (Settings → No-charge accounts). When it has, the person must choose one; `onCount` tells the screen
 * how many there are so it can hold the button back until one is chosen.
 */
export function NcChargeSelect({ value, onChange, onCount }: { value: string; onChange: (id: string) => void; onCount?: (n: number) => void }) {
  const [list, setList] = useState<{ id: string; name: string }[] | null>(null);
  useEffect(() => {
    let live = true;
    listNcTargets()
      .then((r) => {
        if (!live) return;
        setList(r);
        onCount?.(r.length);
      })
      .catch(() => live && setList([]));
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  if (!list || list.length === 0) return null;
  return (
    <select className="field mt-2 h-10 w-full text-sm" aria-label="Charge to" value={value} onChange={(e) => onChange(e.target.value)}>
      <option value="">Charge to… (choose)</option>
      {list.map((t) => (
        <option key={t.id} value={t.id}>
          {t.name}
        </option>
      ))}
    </select>
  );
}
