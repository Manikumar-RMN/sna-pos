"use client";

export function PrintButton({ label = "Print" }: { label?: string }) {
  return (
    <button className="btn btn-primary w-full" onClick={() => window.print()}>
      {label}
    </button>
  );
}
