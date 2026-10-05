"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { createApiKey, revokeApiKey } from "../actions";
import { ConfirmButton } from "../confirm-button";

type Key = { id: string; name: string; prefix: string; created_at: string; last_used_at: string | null; revoked_at: string | null };

export function ApiKeys({ keys }: { keys: Key[] }) {
  const router = useRouter();
  const [name, setName] = useState("");
  const [fresh, setFresh] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const d = (s: string | null) => (s ? new Date(s).toLocaleString("en-IN", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "never");
  return (
    <section className="card space-y-3 p-4">
      <div className="flex flex-wrap gap-2">
        <input className="field min-w-0 flex-1" placeholder="Key name, e.g. Tally sync" maxLength={60} value={name} onChange={(e) => setName(e.target.value)} />
        <button
          className="btn btn-primary"
          disabled={pending || !name.trim()}
          onClick={() =>
            start(async () => {
              setError(null);
              const r = await createApiKey(name);
              if (!r.ok) return setError(r.error);
              setFresh(r.key);
              setName("");
              router.refresh();
            })
          }
        >
          Create key
        </button>
      </div>
      {fresh && (
        <div className="rounded-xl p-3 text-sm" style={{ background: "var(--color-warn-soft)" }} role="status">
          <b>Copy this key now — it will not be shown again.</b>
          <div className="mt-1 break-all font-mono text-xs">{fresh}</div>
          <button className="mt-2 text-xs font-bold" style={{ color: "var(--color-brand)" }} onClick={() => navigator.clipboard.writeText(fresh)}>Copy</button>
        </div>
      )}
      {error && <p role="alert" className="text-sm font-semibold" style={{ color: "var(--color-bad)" }}>{error}</p>}
      <ul className="space-y-2 text-sm">
        {keys.map((k) => (
          <li key={k.id} className="flex flex-wrap items-center justify-between gap-2 border-t pt-2" style={{ borderColor: "var(--color-line)" }}>
            <div>
              <b>{k.name}</b> <span className="font-mono text-xs">{k.prefix}…</span>
              <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                Made {d(k.created_at)} · last used {d(k.last_used_at)}{k.revoked_at ? ` · removed ${d(k.revoked_at)}` : ""}
              </div>
            </div>
            {!k.revoked_at && (
              <ConfirmButton
                className="text-xs font-bold"
                question={`Remove key "${k.name}"? Software using it stops working at once.`}
                disabled={pending}
                onConfirm={() =>
                  start(async () => {
                    await revokeApiKey(k.id);
                    router.refresh();
                  })
                }
              >
                Remove
              </ConfirmButton>
            )}
          </li>
        ))}
        {keys.length === 0 && <li style={{ color: "var(--color-ink-3)" }}>No keys yet.</li>}
      </ul>
    </section>
  );
}
