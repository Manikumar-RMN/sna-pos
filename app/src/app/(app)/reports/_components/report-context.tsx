import Link from "next/link";
import type { ReactNode } from "react";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { isYmd, todayIn } from "@/lib/format";
import { outletScope, resolveRange, type OutletScope } from "@/lib/reports-pack";
import type { OutletInfo } from "../../outlet/outlet-switcher";

type RangeParams = { range?: string; from?: string; to?: string };

export type ReportCtx = {
  user: Awaited<ReturnType<typeof requireUser>>;
  supabase: Awaited<ReturnType<typeof createClient>>;
  from: string;
  to: string;
  range: string;
  /** True when a custom range was cut to the latest 366 days (the most the reports accept). */
  clamped: boolean;
  /** The business day being counted to. */
  today: string;
  /** The calendar date in the restaurant's time zone. */
  calendarToday: string;
  info: OutletInfo | null;
  scope: OutletScope;
  showPicker: boolean;
};

/**
 * Checks the permission, works out the date range (same business-day rule as the main Reports page) and which
 * outlet(s) are chosen. Every report page starts with this. When access is refused, `denied` is the page to show.
 * `need: "financial"` is for reports about discounts, voids and refunds.
 */
export async function loadReport(
  sp: RangeParams,
  opts: { title: string; need?: "financial" },
): Promise<{ ok: true; ctx: ReportCtx } | { ok: false; denied: ReactNode }> {
  const user = await requireUser();
  const deny = (text: string): { ok: false; denied: ReactNode } => ({
    ok: false,
    denied: (
      <div className="mx-auto max-w-md">
        <h1 className="text-xl font-bold tracking-tight">{opts.title}</h1>
        <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          {text}
        </div>
        <Link href="/reports" className="mt-3 inline-block text-xs font-semibold" style={{ color: "var(--color-brand-strong)" }}>
          ← All reports
        </Link>
      </div>
    ),
  });
  if (!can(user, "report.view_sales")) return deny("Your role does not include viewing sales reports.");
  if (opts.need === "financial" && !can(user, "report.view_financial")) {
    return deny("Your role does not include viewing financial reports such as discounts, voids and refunds. Ask the owner if you need access.");
  }

  const supabase = await createClient();
  const { data: latestDay } = await supabase
    .from("business_days")
    .select("business_date, status")
    .order("business_date", { ascending: false })
    .limit(1)
    .maybeSingle();
  const calendarToday = todayIn(user.timezone);
  const today = latestDay?.business_date && isYmd(latestDay.business_date)
    && (latestDay.status === "open" || latestDay.business_date > calendarToday)
    ? latestDay.business_date
    : calendarToday;
  const { from, to, range, clamped } = resolveRange(today, sp);

  const { data: outletData } = await supabase.rpc("my_outlets");
  const info = (outletData as unknown as OutletInfo | null) ?? null;
  const scope = outletScope(info, { id: user.branch_id, name: user.branch_name });
  const showPicker = has(user, "multi_outlet") && (info?.outlets.length ?? 0) > 1;
  return { ok: true, ctx: { user, supabase, from, to, range, clamped: !!clamped, today, calendarToday, info, scope, showPicker } };
}
