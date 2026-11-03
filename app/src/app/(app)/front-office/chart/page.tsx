import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { ChartData, ChartStay } from "@/lib/fo";
import { UpgradeNote } from "../../upgrade-note";

const DAY = 86400000;
const shift = (iso: string, n: number) => new Date(Date.parse(iso + "T00:00:00Z") + n * DAY).toISOString().slice(0, 10);
const COLOUR: Record<ChartStay["status"], string> = { reserved: "#6B8FD6", inhouse: "var(--color-brand)", checked_out: "#9AA0A6" };

export default async function ChartPage({ searchParams }: { searchParams: Promise<{ from?: string }> }) {
  const user = await requireUser();
  if (!has(user, "front_office")) return <div className="mx-auto max-w-md"><UpgradeNote feature="Front office and housekeeping" /></div>;
  if (!(can(user, "fo.view") || can(user, "fo.manage"))) return <div className="card mx-auto max-w-md p-5 text-sm">Your role does not include the stay chart.</div>;

  const sp = await searchParams;
  const from = sp.from && /^\d{4}-\d{2}-\d{2}$/.test(sp.from) ? sp.from : undefined;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fo_chart", { p_from: from, p_days: 14 });
  if (error) return <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-bad)" }}>{friendlyDbError(error)}</div>;
  const chart = data as unknown as ChartData;
  const days = Array.from({ length: chart.days }, (_, i) => shift(chart.from, i));

  return (
    <div className="mx-auto max-w-6xl">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-extrabold">Stay chart</h1>
        <div className="flex items-center gap-3 text-sm">
          <Link href={`/front-office/chart?from=${shift(chart.from, -14)}`} className="underline">← Earlier</Link>
          <Link href="/front-office/chart" className="underline">Today</Link>
          <Link href={`/front-office/chart?from=${shift(chart.from, 14)}`} className="underline">Later →</Link>
          <Link href="/front-office" className="underline">Back</Link>
        </div>
      </div>
      <div className="card overflow-x-auto p-2">
        <table className="w-full border-collapse text-xs" style={{ minWidth: 760 }}>
          <thead>
            <tr>
              <th className="sticky left-0 w-24 bg-[var(--color-surface)] p-1 text-left">Room</th>
              {days.map((d) => <th key={d} className="p-1 text-center font-semibold">{d.slice(8)}<span className="block font-normal" style={{ color: "var(--color-ink-3)" }}>{d.slice(5, 7)}</span></th>)}
            </tr>
          </thead>
          <tbody>
            {chart.rooms.map((r) => (
              <tr key={r.room_id} style={{ borderTop: "1px solid var(--color-line)" }}>
                <th className="sticky left-0 bg-[var(--color-surface)] p-1 text-left">{r.room_number}<span className="block font-normal" style={{ color: "var(--color-ink-3)" }}>{r.room_type}</span></th>
                {days.map((d) => {
                  const s = r.stays.find((x) => x.arrival <= d && x.departure > d);
                  if (r.out_of_service && !s) return <td key={d} className="p-0" style={{ background: "repeating-linear-gradient(45deg,#ddd,#ddd 4px,#eee 4px,#eee 8px)" }} title="Out of service" />;
                  if (!s) return <td key={d} className="h-9 p-0" />;
                  const start = s.arrival === d || d === chart.from;
                  return (
                    <td key={d} className="h-9 p-0" style={{ background: COLOUR[s.status], color: "#fff" }} title={`${s.guest_name}, stay ${s.stay_no}: ${s.arrival} to ${s.departure}`}>
                      {start && <Link href={`/front-office/stay/${s.stay_id}`} className="block truncate px-1 font-semibold" style={{ color: "#fff", maxWidth: 90 }}>{s.vip ? "★ " : ""}{s.guest_name}</Link>}
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>Blue: reserved · green: in-house · grey: checked out · ★ VIP. Click a name to open the folio.</p>
      {chart.unassigned.length > 0 && (
        <div className="card mt-3 p-3 text-sm">
          <b>Reserved, room not chosen yet ({chart.unassigned.length})</b>
          <ul className="mt-1 space-y-0.5">
            {chart.unassigned.map((u) => (
              <li key={u.stay_id}><Link href={`/front-office/stay/${u.stay_id}`} className="underline">#{u.stay_no} {u.guest_name}</Link> · {u.room_type} · {u.arrival} → {u.departure}</li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
