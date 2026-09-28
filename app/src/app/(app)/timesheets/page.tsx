import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { ClockButton, EntryRow } from "./timesheet-parts";

export default async function TimesheetsPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
  const user = await requireUser();
  if (!has(user, "timesheets")) {
    return <p className="card p-5 text-sm">Staff timesheets is part of the Professional edition. Ask for it in Settings → Plan and modules.</p>;
  }
  const sp = await searchParams;
  const today = new Date().toISOString().slice(0, 10);
  const from = /^\d{4}-\d{2}-\d{2}$/.test(sp.from ?? "") ? sp.from! : new Date(Date.now() - 6 * 86400000).toISOString().slice(0, 10);
  const to = /^\d{4}-\d{2}-\d{2}$/.test(sp.to ?? "") ? sp.to! : today;
  const manager = can(user, "user.manage");
  const supabase = await createClient();
  const [{ data: mine }, { data: entries }] = await Promise.all([
    supabase.from("time_entries").select("id, clock_in").eq("user_id", user.user_id).is("clock_out", null).maybeSingle(),
    supabase
      .from("time_entries")
      .select("id, user_id, clock_in, clock_out, edit_reason, users!time_entries_user_id_fkey(full_name)")
      .gte("clock_in", `${from}T00:00:00`)
      .lte("clock_in", `${to}T23:59:59`)
      .order("clock_in", { ascending: false })
      .limit(500),
  ]);
  const visible = (entries ?? []).filter((e) => manager || e.user_id === user.user_id);
  const hours = (a: string, b: string | null) => (b ? (new Date(b).getTime() - new Date(a).getTime()) / 3600000 : 0);
  const totals = new Map<string, number>();
  for (const e of visible) {
    const n = (e.users as unknown as { full_name: string } | null)?.full_name ?? "—";
    totals.set(n, (totals.get(n) ?? 0) + hours(e.clock_in, e.clock_out));
  }

  return (
    <div className="mx-auto max-w-4xl space-y-4">
      <h1 className="text-xl font-bold tracking-tight">Timesheets</h1>
      <ClockButton clockedInAt={mine?.clock_in ?? null} timezone={user.timezone} name={user.full_name} />

      <form className="card flex flex-wrap items-end gap-2 p-4">
        <label className="text-sm">From <input className="field" type="date" name="from" defaultValue={from} /></label>
        <label className="text-sm">To <input className="field" type="date" name="to" defaultValue={to} /></label>
        <button className="btn btn-primary">Show</button>
      </form>

      <section className="card p-4">
        <h2 className="mb-2 text-sm font-bold">Hours {from} to {to}</h2>
        <ul className="grid gap-1 text-sm sm:grid-cols-2">
          {[...totals.entries()].map(([n, h]) => (
            <li key={n} className="flex justify-between"><span>{n}</span><b className="tabular-nums">{h.toFixed(2)} h</b></li>
          ))}
          {totals.size === 0 && <li style={{ color: "var(--color-ink-3)" }}>No entries.</li>}
        </ul>
      </section>

      <section className="card overflow-x-auto p-4">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}>
              <th className="py-1">Person</th><th>In</th><th>Out</th><th className="text-right">Hours</th><th></th>
            </tr>
          </thead>
          <tbody>
            {visible.map((e) => (
              <EntryRow
                key={e.id}
                entry={{
                  id: e.id,
                  person: (e.users as unknown as { full_name: string } | null)?.full_name ?? "—",
                  clockIn: e.clock_in,
                  clockOut: e.clock_out,
                  reason: e.edit_reason,
                  hours: hours(e.clock_in, e.clock_out),
                }}
                canFix={manager}
                timezone={user.timezone}
              />
            ))}
          </tbody>
        </table>
      </section>
    </div>
  );
}
