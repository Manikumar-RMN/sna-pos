import Link from "next/link";

/**
 * Shown in place of a Professional feature or paid add-on that this restaurant
 * does not have yet. Points the owner to Settings → Plan and modules.
 */
export function UpgradeNote({ feature, addon = false }: { feature: string; addon?: boolean }) {
  return (
    <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
      <div className="font-display text-base font-bold" style={{ color: "var(--color-ink)" }}>
        {feature}
      </div>
      <p className="mt-1">
        {addon
          ? `${feature} is a paid add-on module. The owner can ask for it and the SNA team switches it on.`
          : `${feature} is part of the Professional edition. The owner can ask for the upgrade and the SNA team switches it on in one click.`}
      </p>
      <Link href="/settings/plan" className="btn btn-pay mt-4 inline-flex h-11 min-h-0 items-center px-5 text-sm">
        See plan and modules
      </Link>
    </div>
  );
}
