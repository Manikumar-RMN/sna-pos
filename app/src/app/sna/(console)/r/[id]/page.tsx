import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import { RestaurantPanel, type SnaRestaurant } from "./restaurant-panel";
import { AccountPanel, ContactsPanel, NotesPanel, SalesPanel } from "./client-book";
import { clientState, licenceState, shortDate, toneStyle, type Client, type LicenceNow, type SalesExtra } from "../../crm";

const TABS = [
  { key: "overview", label: "Overview" },
  { key: "contacts", label: "Contacts" },
  { key: "notes", label: "Notes and follow-up" },
  { key: "sales", label: "Sales history" },
  { key: "plan", label: "Plan and outlets" },
] as const;
type TabKey = (typeof TABS)[number]["key"];

/** One client: who they are, where their licence stands, and everything SNA has noted or sold. */
export default async function SnaClientPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ tab?: string }> }) {
  const { id } = await params;
  const { tab: asked } = await searchParams;
  const tab: TabKey = TABS.some((t) => t.key === asked) ? (asked as TabKey) : "overview";
  // An address that is not a client id is simply "not found", not a database error on screen.
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) notFound();

  const supabase = await createClient();
  const [{ data, error }, { data: me }, plan, { data: lic0 }, extra] = await Promise.all([
    supabase.rpc("sna_client", { p_id: id }),
    supabase.rpc("sna_me"),
    tab === "plan" ? supabase.rpc("sna_restaurant", { p_id: id }) : Promise.resolve({ data: null, error: null }),
    supabase.rpc("sna_licence", { p_id: id }),
    tab === "sales" ? supabase.rpc("sna_sales_list", { p_id: id }) : Promise.resolve({ data: null, error: null }),
  ]);
  if (error?.message?.includes("not found")) notFound();
  if (error || !data) return <div className="card p-5 text-sm">{error?.message ?? "Could not load."}</div>;
  const c = data as unknown as Client;
  const role = (me as { role?: string } | null)?.role ?? "support";
  const canSell = role === "admin" || role === "sales";
  const lic = licenceState(c.days_left);
  const st = clientState(c.status, c.days_left);
  const now = (lic0 ?? { state: "ok", reminder_off: false }) as unknown as LicenceNow;
  const salesExtra = (extra.data ?? { modules: {}, catalog: [] }) as unknown as SalesExtra;
  const followDue = !!c.next_contact && c.next_contact <= c.today;

  return (
    <div>
      <Link href="/sna" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← All clients
      </Link>

      <div className="card mt-3 p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-2xl font-bold">{c.trading_name}</h1>
            <div className="text-sm" style={{ color: "var(--color-ink-3)" }}>
              {c.legal_name} · {c.country_code} · client code <b style={{ color: "var(--color-ink)" }}>{c.client_code}</b> · set up on {shortDate(c.signed_up)}
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="rounded-full px-3 py-1 text-xs font-bold capitalize" style={toneStyle.plain}>
              {c.edition}
            </span>
            <span className="rounded-full px-3 py-1 text-xs font-bold" style={toneStyle[st.tone]}>
              {st.text}
            </span>
          </div>
        </div>
        <dl className="mt-4 grid grid-cols-2 gap-x-4 gap-y-3 text-sm sm:grid-cols-3 lg:grid-cols-6">
          <Fact label="Licence ends">
            {c.licence_expiry ? shortDate(c.licence_expiry) : "Not set"}
            <div>
              <span className="rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle[lic.tone]}>
                {lic.text}
              </span>
            </div>
          </Fact>
          <Fact label="Next follow-up">
            {c.next_contact ? (
              <span className={followDue ? "font-bold" : undefined} style={followDue ? { color: "var(--color-bad)" } : undefined}>
                {shortDate(c.next_contact)}
                {followDue ? " (due)" : ""}
              </span>
            ) : (
              "None"
            )}
          </Fact>
          <Fact label="Last contact">{c.last_contact ? shortDate(c.last_contact) : "Never"}</Fact>
          <Fact label="Last bill made">{c.usage.last_bill ? shortDate(c.usage.last_bill) : "No bills yet"}</Fact>
          <Fact label="Bills, last 30 days">{c.usage.bills_30d}</Fact>
          <Fact label="Monthly charge">{money(Number(c.monthly), c.currency)}</Fact>
        </dl>
      </div>

      <nav aria-label="Client sections" className="mt-4 overflow-x-auto">
        <ul className="flex min-w-max gap-1">
          {TABS.map((t) => {
            const on = t.key === tab;
            return (
              <li key={t.key}>
                <Link
                  href={`/sna/r/${c.id}?tab=${t.key}`}
                  aria-current={on ? "page" : undefined}
                  className="flex min-h-11 items-center rounded-xl px-4 text-sm font-bold"
                  style={on ? { background: "var(--color-ink)", color: "#fff" } : { background: "var(--color-surface)", color: "var(--color-ink-2)", border: "1px solid var(--color-line)" }}
                >
                  {t.label}
                  {t.key === "contacts" ? ` (${c.contacts.length + (c.owner ? 1 : 0)})` : ""}
                  {t.key === "notes" ? ` (${c.notes.length})` : ""}
                  {t.key === "sales" ? ` (${c.sales.filter((s) => !s.cancelled).length})` : ""}
                </Link>
              </li>
            );
          })}
        </ul>
      </nav>

      <div className="mt-4">
        {tab === "overview" && <AccountPanel c={c} now={now} canEdit={canSell} />}
        {tab === "contacts" && <ContactsPanel c={c} />}
        {tab === "notes" && <NotesPanel c={c} />}
        {tab === "sales" && <SalesPanel c={c} extra={salesExtra} canEdit={canSell} />}
        {tab === "plan" &&
          (plan.data ? (
            <RestaurantPanel r={plan.data as unknown as SnaRestaurant} role={role} />
          ) : (
            <div className="card p-5 text-sm">{plan.error?.message ?? "Could not load."}</div>
          ))}
      </div>
    </div>
  );
}

function Fact({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
        {label}
      </dt>
      <dd className="mt-0.5 font-semibold">{children}</dd>
    </div>
  );
}
