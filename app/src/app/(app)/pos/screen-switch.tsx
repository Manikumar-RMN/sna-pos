"use client";

import { useRouter } from "next/navigation";
import { useTransition } from "react";
import type { ScreenMode } from "@/lib/order-desk";
import { setScreenMode } from "./actions";

/**
 * A small link that changes which billing screen THIS device uses (a cookie, no database setting):
 * "Use classic screen" on the single order screen, "Try the new order screen" on the classic one.
 * `after` is where to go next (the classic equivalent of the bill being looked at, or /pos).
 */
export function ScreenSwitch({ to, after = "/pos" }: { to: ScreenMode; after?: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  return (
    <button
      type="button"
      className="no-print btn border text-xs"
      style={{ borderColor: "var(--color-line)", color: "var(--color-ink-2)" }}
      disabled={pending}
      onClick={() =>
        start(async () => {
          await setScreenMode(to);
          router.replace(after);
          router.refresh();
        })
      }
    >
      {to === "classic" ? "Use classic screen" : "Try the new order screen"}
    </button>
  );
}
