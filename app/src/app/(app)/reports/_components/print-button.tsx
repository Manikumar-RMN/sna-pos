"use client";

/** Opens the browser's print dialog. The print layout (see globals.css) hides the menus, filters and buttons. */
export function PrintButton({ label = "Print" }: { label?: string }) {
  return (
    <button type="button" onClick={() => window.print()} className="rpt-btn">
      {label}
    </button>
  );
}
