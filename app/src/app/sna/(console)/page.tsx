import Link from "next/link";
import { createConsoleClient as createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import { RequestRow, type SnaRequest } from "./request-row";
import { clientState, licenceState, shortDate, toneStyle, totalsByCurrency, type ClientList } from "./crm";

const LISTS: { key: keyof ClientList["counts"]; label: string; hint: string }[] = [
  { key: "all", label: "All clients", hint: "every restaurant set up" },
  { key: "new", label: "New", hint: "set up in the last 14 days" },
  { key: "followup", label: "Follow-up due", hint: "today or earlier" },
  { key: "expiring", label: "Expiring", hint: "licence ends within 30 days" },
  { key: "expired", label: "Expired", hint: "end date passed: read-only" },
  { key: "nolicence", label: "No licence date", hint: "not limited until a date is set" },
];

/** The client book: every restaurant SNA has set up, newest first. */
export default async function SnaHome({ searchParams }: { searchParams: Promise<{ q?: string; list?: string }> }) {
  const { q, list } = await searchParams;
  const filter = LISTS.some((l) => l.key === list) ? (list as string) : "all";
  const supabase = await createClient();
  const [{ data: me }, { data: reqs, error: reqErr }, { data: book, error: bookErr }, { data: everyone }] = await Promise.all([
    supabase.rpc("sna_me"),
    supabase.rpc("sna_requests", { p_status: "open" }),
    supabase.rpc("sna_clients", { p_search: q ?? undefined, p_filter: filter }),
    supabase.rpc("sna_clients", { p_filter: "all" }),
  ]);
  const role = (me as { role?: string } | null)?.role ?? "support";
  const requests = (reqs ?? []) as unknown as SnaRequest[];
  const data = (book ?? null) as unknown as ClientList | null;
  const rows = data?.rows ?? [];
  const all = (everyone ?? null) as unknown as ClientList | null;
  const counts = all?.counts ?? data?.counts;
  // Only clients that can still bill count as income: not expired, suspended or cancelled.
  const income = totalsByCurrency((all?.rows ?? []).filter((r) => clientState(r.status, r.days_left).tone !== "bad"));
  const activeClients = Math.max(0, (counts?.all ?? 0) - (counts?.expired ?? 0));
  const needsAction = requests.length + (counts?.followup ?? 0) + (counts?.expired ?? 0);
  const href = (key: string) => `/sna?list=${key}${q ? `&q=${encodeURIComponent(q)}` : ""}`;

  return (
    <div className="space-y-5">
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
      {bookErr && <div className="card p-3 text-sm">{bookErr.message}</div>}

      <div className="grid grid-cols-2 gap-2 lg:grid-cols-4">
        <Stat label="Active clients" value={String(activeClients)} hint={`of ${counts?.all ?? 0} set up`} href={href("all")} />
        <Stat
          label="Monthly income"
          value={income.length === 0 ? "None yet" : money(income[0].total, income[0].currency)}
          hint={income.length > 1 ? income.slice(1).map((i) => money(i.total, i.currency)).join(" · ") : "clients still active"}
        />
        <Stat label="Needs action" value={String(needsAction)} hint="requests, follow-ups, expired" tone={needsAction > 0 ? "bad" : undefined} />
        <Stat label="Expiring soon" value={String(counts?.expiring ?? 0)} hint="licence ends within 30 days" tone={(counts?.expiring ?? 0) > 0 ? "warn" : undefined} href={href("expiring")} />
      </div>

      <section aria-labelledby="action-h" className="card overflow-hidden">
        <div className="flex flex-wrap items-center justify-between gap-2 px-4 py-3" style={{ borderBottom: "1px solid var(--color-line)" }}>
          <h2 id="action-h" className="text-base font-bold">
            Action needed
          </h2>
          <div className="flex flex-wrap gap-2 text-xs font-semibold">
            {(counts?.followup ?? 0) > 0 && (
              <Link href={href("followup")} className="rounded-full px-3 py-1" style={toneStyle.bad}>
                {counts?.followup} follow-up due
              </Link>
            )}
            {(counts?.expired ?? 0) > 0 && (
              <Link href={href("expired")} className="rounded-full px-3 py-1" style={toneStyle.bad}>
                {counts?.expired} licence expired
              </Link>
            )}
          </div>
        </div>
        {reqErr && <p className="p-4 text-sm">{reqErr.message}</p>}
        {requests.length === 0 ? (
          <p className="px-4 py-3 text-sm" style={{ color: "var(--color-ink-3)" }}>
            No requests waiting. Sales approves upgrades, add-ons and outlets here.
          </p>
        ) : (
          <div className="divide-y" style={{ borderColor: "var(--color-line)" }}>
            {requests.map((r) => (
              <RequestRow key={r.id} request={r} role={role} />
            ))}
          </div>
        )}
      </section>

      <section aria-labelledby="book-h">
        <h2 id="book-h" className="sr-only">
          Client list
        </h2>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <nav aria-label="Client lists" className="flex flex-wrap gap-1">
            {LISTS.map((l) => {
              const on = l.key === filter;
              const n = counts?.[l.key] ?? 0;
              return (
                <Link
                  key={l.key}
                  href={href(l.key)}
                  title={l.hint}
                  aria-current={on ? "page" : undefined}
                  className="rounded-full border px-3 py-1.5 text-xs font-bold"
                  style={on ? { background: "var(--color-ink)", color: "#fff", borderColor: "var(--color-ink)" } : { borderColor: "var(--color-line)", color: "var(--color-ink-2)", background: "var(--color-surface)" }}
                >
                  {l.label} <span className="tabular-nums opacity-80">{n}</span>
                </Link>
              );
            })}
          </nav>
          <form className="flex gap-2">
            <input type="hidden" name="list" value={filter} />
            <label htmlFor="client-search" className="sr-only">
              Search clients
            </label>
            <input id="client-search" name="q" defaultValue={q ?? ""} className="field h-10 w-56 max-w-full" placeholder="Name or client code" />
            <button className="btn h-10 min-h-0 px-4 text-sm" style={{ background: "var(--color-ink)", color: "#fff" }}>
              Search
            </button>
            {q && (
              <Link href={`/sna?list=${filter}`} className="btn h-10 min-h-0 px-3 text-sm" style={{ color: "var(--color-ink-2)" }}>
                Clear
              </Link>
            )}
          </form>
        </div>

        <div className="card mt-3 overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
                <th className="px-3 py-2.5">Client</th>
                <th className="px-3 py-2.5">Plan</th>
                <th className="px-3 py-2.5">Licence ends</th>
                <th className="px-3 py-2.5">Last bill</th>
                <th className="px-3 py-2.5">Follow-up</th>
                <th className="px-3 py-2.5 text-right">Monthly</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const lic = licenceState(r.days_left);
                const st = clientState(r.status, r.days_left);
                const due = !!r.next_contact && !!data && r.next_contact <= data.today;
                return (
                  <tr key={r.id} className="border-t align-top" style={{ borderColor: "var(--color-line)" }}>
                    <td className="px-3 py-3">
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
                          {r.open_requests} {r.open_requests === 1 ? "request" : "requests"}
                        </span>
                      )}
                      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {r.client_code} · {r.country_code}
                        {r.owner_name ? ` · ${r.owner_name}` : ""}
                      </div>
                      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                        Set up {shortDate(r.signed_up)}
                      </div>
                    </td>
                    <td className="px-3 py-3">
                      <div className="font-semibold capitalize">{r.edition}</div>
                      <span className="mt-0.5 inline-block rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle[st.tone]}>
                        {st.text}
                      </span>
                      <div className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {r.outlets} {r.outlets === 1 ? "outlet" : "outlets"}
                      </div>
                    </td>
                    <td className="whitespace-nowrap px-3 py-3">
                      {r.licence_expiry ? shortDate(r.licence_expiry) : <span style={{ color: "var(--color-ink-3)" }}>Not set</span>}
                      <div className="mt-0.5">
                        <span className="rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle[lic.tone]}>
                          {lic.text}
                        </span>
                      </div>
                    </td>
                    <td className="whitespace-nowrap px-3 py-3">{r.last_bill ? shortDate(r.last_bill) : <span style={{ color: "var(--color-ink-3)" }}>No bills yet</span>}</td>
                    <td className="whitespace-nowrap px-3 py-3">
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
                    <td className="whitespace-nowrap px-3 py-3 text-right font-semibold tabular-nums">{money(Number(r.monthly), r.currency)}</td>
                  </tr>
                );
              })}
              {rows.length === 0 && (
                <tr>
                  <td colSpan={6} className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
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
    </div>
  );
}

function Stat({ label, value, hint, tone, href }: { label: string; value: string; hint: string; tone?: "bad" | "warn"; href?: string }) {
  const body = (
    <>
      <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
        {label}
      </div>
      <div className="mt-0.5 truncate text-2xl font-bold tabular-nums" style={tone ? { color: tone === "bad" ? "var(--color-bad)" : "var(--color-warn)" } : undefined}>
        {value}
      </div>
      <div className="truncate text-[11px]" style={{ color: "var(--color-ink-3)" }}>
        {hint}
      </div>
    </>
  );
  return href ? (
    <Link href={href} className="card block p-3">
      {body}
    </Link>
  ) : (
    <div className="card p-3">{body}</div>
  );
}
