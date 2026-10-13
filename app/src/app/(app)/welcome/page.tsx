import Link from "next/link";
import { redirect } from "next/navigation";
import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
// The guide shows the real settings sections one after another, so what an owner
// learns here is exactly what they will find under Settings later.
import CompanySettings from "../settings/company/page";
import TaxSettings from "../settings/taxes/page";
import MenuPage from "../settings/menu/page";
import TableSettings from "../settings/tables/page";
import PaymentSettings from "../settings/payments/page";
import StaffPage from "../settings/users/page";

type StepKey = "company" | "taxes" | "menu" | "tables" | "payments" | "staff" | "done";
/** done: we can see it has been filled in. ready: set up for the country already, only needs a look. todo: still empty. */
type StepState = "done" | "ready" | "todo";

const ORDER: StepKey[] = ["company", "taxes", "menu", "tables", "payments", "staff", "done"];

/**
 * Setup guide for a new restaurant: the six things to fill in before the first
 * bill, in order, each with a line on why it matters. Every step can be skipped
 * and the guide can be left and opened again from Home.
 */
export default async function WelcomeGuide({ searchParams }: { searchParams: Promise<{ step?: string }> }) {
  const user = await requireUser();
  // The guide is for the person setting the restaurant up. Everyone else has nothing to do here.
  if (!can(user, "settings.manage")) redirect("/dashboard");

  const sp = await searchParams;
  const supabase = await createClient();
  const [branch, products, tables, staff, country, orders] = await Promise.all([
    supabase.from("branches").select("address_line1").eq("id", user.branch_id).maybeSingle(),
    supabase.from("products").select("id", { count: "exact", head: true }).is("deleted_at", null),
    supabase.from("dining_tables").select("id", { count: "exact", head: true }).eq("is_active", true).eq("is_kiosk", false),
    supabase.from("users").select("id", { count: "exact", head: true }).is("deleted_at", null),
    supabase.from("countries").select("name, tax_system_name").eq("code", user.country_code).maybeSingle(),
    supabase.from("orders").select("id", { count: "exact", head: true }),
  ]);
  const taxName = country.data?.tax_system_name ?? "Tax";
  const countryName = country.data?.name ?? "your country";

  const steps: Record<StepKey, { title: string; why: string; optional?: boolean; state: StepState }> = {
    company: {
      title: "Your business",
      why: "The name, address and tax number printed at the top of every bill. Fill in the address at least.",
      state: (branch.data?.address_line1 ?? "").trim() ? "done" : "todo",
    },
    taxes: {
      title: "Taxes",
      why: `${taxName} for ${countryName} is set up for you already. Check the rates, and say whether your menu prices already include tax.`,
      state: "ready",
    },
    menu: {
      title: "Menu",
      why: "Add a category, then the dishes in it with their prices. A few dishes are enough to start; add the rest later.",
      state: (products.count ?? 0) > 0 ? "done" : "todo",
    },
    tables: {
      title: "Tables",
      why: "Only if guests sit down and eat. A takeaway counter can skip this.",
      optional: true,
      state: (tables.count ?? 0) > 0 ? "done" : "todo",
    },
    payments: {
      title: "Payments",
      why: "The usual ways to pay are switched on already. Switch off what you do not take, and add your UPI ID to print a scan-to-pay QR on bills.",
      state: "ready",
    },
    staff: {
      title: "Staff",
      why: "Add the people who will use SNA POS, so every bill carries the right name. You can do this later.",
      optional: true,
      state: (staff.count ?? 0) > 1 ? "done" : "todo",
    },
    done: { title: "Ready", why: "", state: "ready" },
  };

  // No step named: carry on at the first thing that is still empty.
  const asked = ORDER.includes(sp.step as StepKey) ? (sp.step as StepKey) : null;
  const current: StepKey = asked ?? ORDER.find((k) => k !== "done" && steps[k].state === "todo" && !steps[k].optional) ?? "done";
  const at = ORDER.indexOf(current);
  const prev = at > 0 ? ORDER[at - 1] : null;
  const next = at < ORDER.length - 1 ? ORDER[at + 1] : null;
  const step = steps[current];
  const href = (k: StepKey) => `/welcome?step=${k}`;

  return (
    <div className="mx-auto max-w-6xl">
      <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold">Set up {user.trading_name}</h1>
          <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Six short steps before your first bill. Skip any of them and come back later: everything here is also under Settings.
          </p>
        </div>
        <Link href="/dashboard" className="text-sm font-bold" style={{ color: "var(--color-brand)" }}>
          Finish later
        </Link>
      </div>

      <nav aria-label="Setup steps" className="mb-4 overflow-x-auto">
        <ol className="flex min-w-max gap-2">
          {ORDER.map((k, i) => {
            const s = steps[k];
            const here = k === current;
            const ticked = k !== "done" && s.state === "done";
            return (
              <li key={k}>
                <Link
                  href={href(k)}
                  aria-current={here ? "step" : undefined}
                  className="flex min-h-11 items-center gap-2 rounded-full px-3 text-sm font-semibold"
                  style={
                    here
                      ? { background: "var(--color-brand)", color: "#fff" }
                      : { background: "var(--color-surface)", color: "var(--color-ink-2)", border: "1px solid var(--color-line)" }
                  }
                >
                  <span
                    aria-hidden
                    className="flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold"
                    style={
                      ticked
                        ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" }
                        : here
                          ? { background: "rgba(255,255,255,0.22)", color: "#fff" }
                          : { background: "var(--color-ground)", color: "var(--color-ink-3)" }
                    }
                  >
                    {ticked ? "✓" : i + 1}
                  </span>
                  {s.title}
                  {ticked && <span className="sr-only"> (done)</span>}
                </Link>
              </li>
            );
          })}
        </ol>
      </nav>

      {current !== "done" && (
        <div className="mb-4 rounded-2xl px-4 py-3 text-sm" role="note" style={{ background: "var(--color-brand-soft)", color: "var(--color-ink)" }}>
          <b>
            Step {at + 1} of {ORDER.length}: {step.title}
            {step.optional ? " (optional)" : ""}.
          </b>{" "}
          {step.why}
        </div>
      )}

      <section className="min-w-0">
        {current === "company" && <CompanySettings />}
        {current === "taxes" && <TaxSettings />}
        {current === "menu" && <MenuPage />}
        {current === "tables" && <TableSettings />}
        {current === "payments" && <PaymentSettings />}
        {current === "staff" && <StaffPage />}
        {current === "done" && (
          <Finish
            rows={ORDER.filter((k) => k !== "done").map((k) => ({ key: k, title: steps[k].title, state: steps[k].state, optional: !!steps[k].optional }))}
            canBill={can(user, "order.create")}
            hasBilled={(orders.count ?? 0) > 0}
          />
        )}
      </section>

      {current !== "done" && (
        <div className="card mt-6 flex flex-wrap items-center justify-between gap-3 p-4">
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            Each box above has its own Save button. Save first, then go on.
          </p>
          <div className="flex flex-wrap gap-2">
            {prev && (
              <Link href={href(prev)} className="btn" style={{ border: "1px solid var(--color-line)", color: "var(--color-ink-2)" }}>
                Back
              </Link>
            )}
            {next && (
              <Link href={href(next)} className="btn btn-primary">
                {next === "done" ? "Finish" : `Next: ${steps[next].title}`}
              </Link>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function Finish({
  rows,
  canBill,
  hasBilled,
}: {
  rows: { key: StepKey; title: string; state: StepState; optional: boolean }[];
  canBill: boolean;
  hasBilled: boolean;
}) {
  const missing = rows.filter((r) => r.state === "todo" && !r.optional);
  const label = (r: { state: StepState; optional: boolean }) =>
    r.state === "done" ? "Done" : r.state === "ready" ? "Set up for you" : r.optional ? "Skipped (optional)" : "Still empty";
  return (
    <div className="space-y-4">
      <div className="card p-5">
        <h2 className="text-xl font-bold">{missing.length === 0 ? "You are ready to bill" : "Almost there"}</h2>
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          {missing.length === 0
            ? "Make one test bill now, print it, and look at it the way a customer would."
            : "Fill in the steps marked Still empty before you bill. Tap one to open it."}
        </p>
        <ul className="mt-4 divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
          {rows.map((r) => (
            <li key={r.key} className="flex items-center justify-between gap-3 py-2.5" style={{ borderColor: "var(--color-line)" }}>
              <Link href={`/welcome?step=${r.key}`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
                {r.title}
              </Link>
              <span
                className="rounded-full px-2.5 py-1 text-xs font-bold"
                style={
                  r.state === "todo" && !r.optional
                    ? { background: "var(--color-warn-soft)", color: "var(--color-warn)" }
                    : r.state === "todo"
                      ? { background: "var(--color-ground)", color: "var(--color-ink-3)" }
                      : { background: "var(--color-ok-soft)", color: "var(--color-ok)" }
                }
              >
                {label(r)}
              </span>
            </li>
          ))}
        </ul>
        <div className="mt-5 flex flex-wrap gap-2">
          {canBill && (
            <Link href="/pos" className="btn btn-primary">
              {hasBilled ? "Open billing" : "Make your first bill"}
            </Link>
          )}
          <Link href="/dashboard" className="btn" style={{ border: "1px solid var(--color-line)", color: "var(--color-ink-2)" }}>
            Go to Home
          </Link>
        </div>
      </div>

      <div className="card p-5">
        <h2 className="text-base font-bold">Worth doing in your first week</h2>
        <ul className="mt-3 space-y-2 text-sm">
          {[
            { href: "/settings/bill", text: "Bill layout", hint: "add your logo and choose what prints on the bill" },
            { href: "/settings/printers", text: "Printers", hint: "paper width and a test print on each device" },
            { href: "/settings/charges", text: "Service charge", hint: "service charge, packing charge and token numbers" },
            { href: "/settings/reports", text: "Daily summary", hint: "get the day's figures sent to you every night" },
          ].map((x) => (
            <li key={x.href}>
              <Link href={x.href} className="font-semibold" style={{ color: "var(--color-brand)" }}>
                {x.text}
              </Link>
              <span style={{ color: "var(--color-ink-3)" }}>: {x.hint}</span>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
