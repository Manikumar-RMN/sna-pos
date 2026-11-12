import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { dateTime, money } from "@/lib/format";
import { OpenShiftForm, ShiftPanel, type ShiftFigures } from "./shift-panel";
import { DayPanel, type DayStatus } from "./day-panel";

export default async function ShiftPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const canSeeMoney = can(user, "shift.close") || can(user, "report.view_financial");

  const [{ data: current }, { data: history }, { data: day }, { count: pendingKots }] = await Promise.all([
    supabase.rpc("current_shift"),
    supabase
      .from("shifts")
      .select("id, opened_at, closed_at, opening_float, expected_cash, counted_cash, cash_variance, opened_by, closed_by, notes")
      .eq("status", "closed")
      .order("closed_at", { ascending: false })
      .limit(10),
    supabase.rpc("day_status"),
    // Kitchen tickets still waiting or being cooked (shown as a warning on day close).
    supabase.from("kitchen_tickets").select("id", { count: "exact", head: true }).in("status", ["new", "preparing"]),
  ]);
  const shiftsOn = !!(day as unknown as { shifts_enabled?: boolean } | null)?.shifts_enabled;
  // Shifts off: the automatic drawer is not shown as a shift; cash is counted when the day is closed.
  const figures = shiftsOn ? (current as unknown as ShiftFigures | null) : null;

  const { data: movements } = figures
    ? await supabase
        .from("cash_movements")
        .select("direction, amount, reason, created_at, recorded_by")
        .eq("shift_id", figures.shift_id)
        .order("created_at")
    : { data: [] as { direction: string; amount: number; reason: string; created_at: string; recorded_by: string }[] };

  const peopleIds = [
    ...(history ?? []).flatMap((h) => [h.opened_by, h.closed_by]),
    ...(movements ?? []).map((m) => m.recorded_by),
  ].filter(Boolean) as string[];
  const { data: people } = peopleIds.length
    ? await supabase.from("users").select("id, full_name").in("id", [...new Set(peopleIds)])
    : { data: [] as { id: string; full_name: string }[] };
  const nameOf = (id: string | null) => (people ?? []).find((p) => p.id === id)?.full_name ?? "—";

  const tz = user.timezone;
  const c = user.currency_code;

  return (
    <div className="mx-auto max-w-3xl">
      <h1 className="text-xl font-bold tracking-tight">{shiftsOn ? "Shift and day close" : "Day close"}</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        {!shiftsOn
          ? "Shifts are off, so billing starts straight away. Count the drawer when you close the day. Turn shifts on in Settings → Day and sessions if each cashier should count their own drawer."
          : figures
            ? `Open since ${dateTime(figures.opened_at, tz)} · opened by ${figures.opened_by ?? "—"}`
            : "No shift is open. Bills can only be taken while a shift is open."}
      </p>

      {figures && !canSeeMoney && (
        <div className="card mb-4 p-4 text-sm" style={{ color: "var(--color-ink-2)" }}>
          The shift is open — you can take bills. {figures.bills} bill{figures.bills === 1 ? "" : "s"} so far.
          An owner or manager counts the drawer and closes the shift at the end of the day.
        </div>
      )}

      {figures ? (
        <ShiftPanel
          figures={figures}
          currency={c}
          canMoveCash={can(user, "cash.movement")}
          canClose={can(user, "shift.close")}
          canSeeMoney={canSeeMoney}
        />
      ) : shiftsOn ? (
        <OpenShiftForm canOpen={can(user, "shift.open")} />
      ) : null}

      {day && (can(user, "day.close") || can(user, "day.reopen") || can(user, "report.view_sales") || can(user, "payment.take")) && (
        <DayPanel status={{ ...(day as unknown as DayStatus), pending_kots: pendingKots ?? 0 }} currency={c} canAsk={can(user, "payment.take")} />
      )}

      {figures && (movements ?? []).length > 0 && canSeeMoney && (
        <div className="card mt-4 p-4 text-sm">
          <h2 className="mb-2 font-bold">Cash in / out this shift</h2>
          <ul className="space-y-1">
            {(movements ?? []).map((m, i) => (
              <li key={i} className="flex justify-between gap-3">
                <span style={{ color: "var(--color-ink-2)" }}>
                  {dateTime(m.created_at, tz)} · {m.reason} · {nameOf(m.recorded_by)}
                </span>
                <span className="tabular-nums font-semibold" style={{ color: m.direction === "in" ? "var(--color-ok)" : "var(--color-bad)" }}>
                  {m.direction === "in" ? "+" : "−"}
                  {money(m.amount, c)}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {canSeeMoney && shiftsOn && (history ?? []).length > 0 && (
        <>
          <h2 className="mb-2 mt-8 text-base font-bold">Recent closed shifts</h2>
          <div className="card overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr style={{ color: "var(--color-ink-3)" }}>
                  <th className="px-3 py-2 text-left text-xs font-semibold">Closed</th>
                  <th className="px-3 py-2 text-left text-xs font-semibold">By</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">Expected</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">Counted</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">Difference</th>
                </tr>
              </thead>
              <tbody>
                {(history ?? []).map((h) => {
                  const v = Number(h.cash_variance ?? 0);
                  return (
                    <tr key={h.id} style={{ borderTop: "1px solid var(--color-line)" }}>
                      <td className="px-3 py-2">{dateTime(h.closed_at, tz)}</td>
                      <td className="px-3 py-2">{nameOf(h.closed_by)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{money(h.expected_cash, c)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{money(h.counted_cash, c)}</td>
                      <td
                        className="px-3 py-2 text-right font-semibold tabular-nums"
                        style={{ color: Math.abs(v) < 0.005 ? "var(--color-ok)" : "var(--color-bad)" }}
                      >
                        {Math.abs(v) < 0.005 ? "Exact" : `${v > 0 ? "+" : "−"}${money(Math.abs(v), c)}`}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
