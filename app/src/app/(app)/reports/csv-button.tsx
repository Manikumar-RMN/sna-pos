"use client";

/** Builds a CSV in the browser and hands it over as a download. */
export function CsvButton({
  filename,
  header,
  rows,
  label = "Download CSV",
}: {
  filename: string;
  header: string[];
  rows: (string | number)[][];
  label?: string;
}) {
  function download() {
    const esc = (v: string | number) => {
      let s = String(v ?? "");
      // Text typed by staff (e.g. a payment reference) must never run as a
      // spreadsheet formula when the file is opened in Excel.
      if (typeof v === "string" && /^[=+\-@\t\r]/.test(s)) s = "'" + s;
      return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    };
    // The byte-order mark makes Excel read ₹ and non-English names correctly.
    const csv = "\uFEFF" + [header, ...rows].map((r) => r.map(esc).join(",")).join("\r\n");
    const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  }
  return (
    <button onClick={download} className="rounded-lg border px-2.5 py-1 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }}>
      {label}
    </button>
  );
}
