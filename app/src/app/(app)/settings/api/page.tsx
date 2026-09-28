import { headers } from "next/headers";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { NoAccess, SectionHead } from "../section-head";
import { ApiKeys } from "./api-keys";

export default async function ApiSettings() {
  const user = await requireUser();
  if (!can(user, "settings.manage") || !has(user, "open_api")) return <NoAccess />;
  const supabase = await createClient();
  const { data: keys } = await supabase
    .from("api_keys")
    .select("id, name, prefix, created_at, last_used_at, revoked_at")
    .order("created_at", { ascending: false });
  const h = await headers();
  const origin = `${h.get("x-forwarded-proto") ?? "https"}://${h.get("host")}`;
  return (
    <div className="space-y-4">
      <SectionHead title="API keys">
        Let other software (accounting, dashboards, your own tools) read your menu, bills, daily sales and stock. Read-only; nothing can be
        changed through the API.
      </SectionHead>
      <ApiKeys keys={keys ?? []} />
      <section className="card space-y-2 p-4 text-sm">
        <h2 className="font-bold">How to call it</h2>
        <pre className="overflow-x-auto rounded-xl p-3 text-xs" style={{ background: "var(--color-surface-2)" }}>
{`curl -H "Authorization: Bearer snapi_…" ${origin}/api/v1/menu
curl -H "Authorization: Bearer snapi_…" "${origin}/api/v1/orders?from=2026-09-01&to=2026-09-28"
curl -H "Authorization: Bearer snapi_…" "${origin}/api/v1/sales?from=2026-09-01&to=2026-09-28"
curl -H "Authorization: Bearer snapi_…" ${origin}/api/v1/stock`}
        </pre>
        <ul className="list-disc pl-5" style={{ color: "var(--color-ink-2)" }}>
          <li>Dates are business dates; at most 31 days per call.</li>
          <li>At most 60 calls a minute per key. Answers are JSON; errors come with status 400, 401, 403 or 429.</li>
          <li>Keep keys secret. Remove a key here to stop it at once.</li>
        </ul>
      </section>
    </div>
  );
}
