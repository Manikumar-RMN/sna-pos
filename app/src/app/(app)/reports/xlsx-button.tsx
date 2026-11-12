"use client";

import { buildXlsx, type XlsxSheet } from "@/lib/xlsx";

/** Builds an Excel (.xlsx) workbook in the browser, one sheet per section, and hands it over as a download. */
export function XlsxButton({ filename, sheets, label = "Excel (.xlsx)", className }: { filename: string; sheets: XlsxSheet[]; label?: string; className?: string }) {
  function download() {
    const bytes = buildXlsx(sheets);
    const blob = new Blob([bytes as BlobPart], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  }
  return (
    <button type="button" onClick={download} className={className ?? "rounded-lg border px-2.5 py-1 text-xs font-semibold"} style={className ? undefined : { borderColor: "var(--color-line)" }}>
      {label}
    </button>
  );
}
