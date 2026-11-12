import Link from "next/link";

/** Shown instead of a bare 404 when a bill cannot be opened: it may belong to another outlet, or the link is old. */
export function BillMissing() {
  return (
    <div className="mx-auto mt-10 max-w-md card p-5 text-center">
      <h1 className="text-base font-bold">This bill is not in this outlet</h1>
      <p className="mt-2 text-sm" style={{ color: "var(--color-ink-3)" }}>
        It may belong to another outlet &mdash; switch outlet at the top of the screen and open it again &mdash; or the link is old.
      </p>
      <Link href="/bills" className="btn btn-primary mt-4 inline-block text-sm">
        Back to bills
      </Link>
    </div>
  );
}
