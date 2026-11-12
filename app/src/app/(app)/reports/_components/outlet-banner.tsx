import { OutletSwitcher, type OutletInfo } from "../../outlet/outlet-switcher";
import type { OutletScope } from "@/lib/reports-pack";

/**
 * Says which outlet a report covers. People who work in several outlets also get the outlet picker here,
 * to switch between one outlet and All outlets; the page then reads again for the new choice.
 */
export function OutletBanner({ scope, info, showPicker }: { scope: OutletScope; info: OutletInfo | null; showPicker: boolean }) {
  // The outlet is already named in the line above the filters, so this is just the picker (and a note for "All outlets").
  return (
    <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
        {scope.all ? "Totals include all outlets." : ""}
      </div>
      {showPicker && info ? (
        <div className="flex items-center gap-2">
          <OutletSwitcher info={info} onGreen={false} />
        </div>
      ) : null}
    </div>
  );
}
