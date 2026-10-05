import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import { RequestRow, type SnaRequest } from "./request-row";
import { clientState, licenceState, shortDate, toneStyle, type ClientList } from "./crm";

const LISTS: { key: keyof ClientList["counts"]; label: string; hint: string }[] = [
  { key: "all", label: "All clients", hint: "every restaurant set up" },
  { key: "new", label: "New", hint: "set up in the last 14 days" },
  { key: "followup", label: "Follow-up due", hint: "today or earlier" },
  { key: "expiring", label: "Expiring", hint: "licence ends within 30 days" },
  { key: "expired", label: "Expired", hint: "end date passed: read-only" },
  { key: "nolicence", label: "No licence date", hint: "not limited until a date is set" },
];

/** The client book: every restaurant from the moment it signs up, newest first. */
export default async function SnaHome({ searchParams }: { searchParams: Promise<{ q?: string; list?: string }> }) {
  const { q, list } = await searchParams;
  const filter = LISTS.some((l) => l.key === list) ? (list as string) : "all";
  const supabase = await createClient();
  const [{ data: me }, { data: reqs, error: reqErr }, { data: book, error: bookErr }] = await Promise.all([
    supabase.rpc("sna_me"),
    supabase.rpc("sna_requests", { p_status: "open" }),
    supabase.rpc("sna_clients", { p_search: q ?? undefined, p_filter: filter }),
  ]);
  const role = (me as { role?: string } | null)?.role ?? "support";
  const requests = (reqs ?? []) as unknown as SnaRequest[];
  const data = (book ?? null) as unknown as ClientList | null;
  const rows = data?.rows ?? [];
  const href = (key: string) => `/sna?list=${key}${q ? `&q=${encodeURIComponent(q)}` : ""}`;

  return (
    <div className="space-y-6">
      <section>
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold">Clients</h1>
            <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
              Every restaurant SNA has set up. Newest first.
            </p>
          </div>
          <Link href="/sna/new" className="btn px-5" style={{ background: "var(--color-ink)", color: "#fff" }}>
            New client
          </Link>
        </div>
        {bookErr && <div className="card mt-3 p-3 text-sm">{bookErr.message}</div>}

        <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-6">
          {LISTS.map((l) => {
            const on = l.key === filter;
            const n = data?.counts?.[l.key] ?? 0;
            const alert = n > 0 && (l.key === "expired" || l.key === "followup" || l.key === "expiring");
            return (
              <Link
                key={l.key}
                href={href(l.key)}
                aria-current={on ? "page" : undefined}
                className="card block p-3"
                style={on ? { borderColor: "var(--color-ink)", boxShadow: "inset 0 0 0 1px var(--color-ink)" } : undefined}
              >
                <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
                  {l.label}
                </div>
                <div className="mt-0.5 text-2xl font-bold tabular-nums" style={alert ? { color: l.key === "expiring" ? "var(--color-warn)" : "var(--color-bad)" } : undefined}>
                  {n}
                </div>
                <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                  {l.hint}
                </div>
              </Link>
            );
          })}
        </div>

        <form className="mt-3 flex flex-wrap gap-2">
          <input type="hidden" name="list" value={filter} />
          <label htmlFor="client-search" className="sr-only">
            Search clients
          </label>
          <input id="client-search" name="q" defaultValue={q ?? ""} className="field h-10 w-72 max-w-full" placeholder="Name or client code" />
          <button className="btn h-10 min-h-0 px-4 text-sm" style={{ background: "var(--color-ink)", color: "#fff" }}>
            Search
          </button>
          {q && (
            <Link href={`/sna?list=${filter}`} className="btn h-10 min-h-0 px-3 text-sm" style={{ color: "var(--color-ink-2)" }}>
              Clear
            </Link>
          )}
        </form>

        <div className="card mt-3 overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left" style={{ color: "var(--color-ink-3)" }}>
                <th className="px-4 py-2">Client</th>
                <th className="px-4 py-2">Set up on</th>
                <th className="px-4 py-2">Plan</th>
                <th className="px-4 py-2">Licence ends</th>
                <th className="px-4 py-2">Last bill</th>
                <th className="px-4 py-2">Follow-up</th>
                <th className="px-4 py-2 text-right">Monthly</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const lic = licenceState(r.days_left);
                const st = clientState(r.status, r.days_left);
                const due = !!r.next_contact && !!data && r.next_contact <= data.today;
                return (
                  <tr key={r.id} className="border-t align-top" style={{ borderColor: "var(--color-line)" }}>
                    <td className="px-4 py-2.5">
                      <Link href={`/sna/r/${r.id}`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
                        {r.trading_name}
                      </Link>
                      {r.is_new && (
                        <span className="ml-2 rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle.ok}>
                          New
                        </span>
                      )}
                      {r.open_requests > 0 && (
                        <span className="ml-2 rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle.warn}>
                          {r.open_requests} open {r.open_requests === 1 ? "request" : "requests"}
                        </span>
                      )}
                      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                        Code {r.client_code} · {r.country_code}
                        {r.owner_name ? ` · ${r.owner_name}` : ""}
                        {r.owner_email ? ` · ${r.owner_email}` : ""}
                      </div>
                    </td>
                    <td className="whitespace-nowrap px-4 py-2.5">{shortDate(r.signed_up)}</td>
                    <td className="px-4 py-2.5">
                      <span className="capitalize">{r.edition}</span>
                      <span className="ml-2 rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle[st.tone]}>
                        {st.text}
                      </span>
                      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {r.outlets} {r.outlets === 1 ? "outlet" : "outlets"}
                      </div>
                    </td>
                    <td className="whitespace-nowrap px-4 py-2.5">
                      {r.licence_expiry ? shortDate(r.licence_expiry) : ""}
                      <div>
                        <span className="rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle[lic.tone]}>
                          {lic.text}
                        </span>
                      </div>
                    </td>
                    <td className="whitespace-nowrap px-4 py-2.5">{r.last_bill ? shortDate(r.last_bill) : <span style={{ color: "var(--color-ink-3)" }}>No bills yet</span>}</td>
                    <td className="whitespace-nowrap px-4 py-2.5">
                      {r.next_contact ? (
                        <span className={due ? "font-bold" : undefined} style={due ? { color: "var(--color-bad)" } : undefined}>
                          {shortDate(r.next_contact)}
                          {due ? " (due)" : ""}
                        </span>
                      ) : (
                        <span style={{ color: "var(--color-ink-3)" }}>None</span>
                      )}
                      {r.account_manager && (
                        <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                          {r.account_manager}
                        </div>
                      )}
                    </td>
                    <td className="px-4 py-2.5 text-right tabular-nums">{money(Number(r.monthly), r.currency)}</td>
                  </tr>
                );
              })}
              {rows.length === 0 && (
                <tr>
                  <td colSpan={7} className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                    {q ? "No client matches that search in this list." : "No clients in this list."}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
          After the licence end date a restaurant is read-only: no new bills. It sees a reminder twice a day from 15 days before. A client with no licence
          date is not limited.
        </p>
      </section>

      <section>
        <h2 className="text-xl font-bold">Open requests</h2>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          Sales approves upgrades, modules and outlets. Upgrades and modules switch on when approved; an approved outlet waits for an implementer.
        </p>
        {reqErr && <div className="card mt-3 p-3 text-sm">{reqErr.message}</div>}
        <div className="card mt-3 divide-y" style={{ borderColor: "var(--color-line)" }}>
          {requests.length === 0 ? (
            <p className="p-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
              Nothing waiting.
            </p>
          ) : (
            requests.map((r) => <RequestRow key={r.id} request={r} role={role} />)
          )}
        </div>
      </section>
    </div>
  );
}
