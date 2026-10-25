import { OutletSwitcher, type OutletInfo } from "../../outlet/outlet-switcher";
import type { OutletScope } from "@/lib/reports-pack";

/**
 * Says which outlet a report covers. People who work in several outlets also get the outlet picker here,
 * to switch between one outlet and All outlets; the page then reads again for the new choice.
 */
export function OutletBanner({ scope, info, showPicker }: { scope: OutletScope; info: OutletInfo | null; showPicker: boolean }) {
  return (
    <div className="card mb-4 flex flex-wrap items-center justify-between gap-2 p-3">
      <div>
        <div className="text-sm font-bold">{scope.label}</div>
        {scope.all && (
          <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            Totals include all outlets.
          </div>
        )}
      </div>
      {showPicker && info ? (
        <div className="flex items-center gap-2">
          <OutletSwitcher info={info} onGreen={false} />
        </div>
      ) : null}
    </div>
  );
}
