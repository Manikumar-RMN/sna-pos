import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import { RequestRow, type SnaRequest } from "./request-row";

type Row = {
  id: string;
  trading_name: string;
  legal_name: string;
  country_code: string;
  currency: string;
  edition: string;
  outlets: number;
  modules: string[];
  open_requests: number;
  owner_email: string | null;
  monthly: number;
  created_at: string;
};

export default async function SnaHome({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { q } = await searchParams;
  const supabase = await createClient();
  const [{ data: me }, { data: reqs, error: reqErr }, { data: rows, error: rowErr }] = await Promise.all([
    supabase.rpc("sna_me"),
    supabase.rpc("sna_requests", { p_status: "open" }),
    supabase.rpc("sna_restaurants", { p_search: q ?? undefined }),
  ]);
  const role = (me as { role?: string } | null)?.role ?? "support";
  const requests = (reqs ?? []) as unknown as SnaRequest[];
  const restaurants = (rows ?? []) as unknown as Row[];

  return (
    <div className="space-y-6">
      <section>
        <h1 className="text-2xl font-bold">Open requests</h1>
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

      <section>
        <div className="flex flex-wrap items-end justify-between gap-3">
          <h2 className="text-xl font-bold">Restaurants</h2>
          <form className="flex gap-2">
            <input name="q" defaultValue={q ?? ""} className="field h-10 w-64" placeholder="Search by name" />
            <button className="btn h-10 min-h-0 px-4 text-sm" style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)" }}>
              Search
            </button>
          </form>
        </div>
        {rowErr && <div className="card mt-3 p-3 text-sm">{rowErr.message}</div>}
        <div className="card mt-3 overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left" style={{ color: "var(--color-ink-3)" }}>
                <th className="px-4 py-2">Restaurant</th>
                <th className="px-4 py-2">Country</th>
                <th className="px-4 py-2">Edition</th>
                <th className="px-4 py-2">Outlets</th>
                <th className="px-4 py-2">Add-ons</th>
                <th className="px-4 py-2 text-right">Monthly</th>
                <th className="px-4 py-2">Open</th>
              </tr>
            </thead>
            <tbody>
              {restaurants.map((r) => (
                <tr key={r.id} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                  <td className="px-4 py-2.5">
                    <Link href={`/sna/r/${r.id}`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
                      {r.trading_name}
                    </Link>
                    <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                      {r.owner_email ?? r.legal_name}
                    </div>
                  </td>
                  <td className="px-4 py-2.5">{r.country_code}</td>
                  <td className="px-4 py-2.5 capitalize">{r.edition}</td>
                  <td className="px-4 py-2.5">{r.outlets}</td>
                  <td className="px-4 py-2.5">{r.modules.length}</td>
                  <td className="px-4 py-2.5 text-right tabular-nums">{money(Number(r.monthly), r.currency)}</td>
                  <td className="px-4 py-2.5">{r.open_requests > 0 ? r.open_requests : ""}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
