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
      const s = String(v ?? "");
      return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    };
    const csv = [header, ...rows].map((r) => r.map(esc).join(",")).join("\n");
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
