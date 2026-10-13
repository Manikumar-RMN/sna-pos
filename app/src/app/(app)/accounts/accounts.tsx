"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import { saveAccount, settleAccount, statement, type Statement } from "./actions";

export type Account = { id: string; name: string; phone: string | null; company: string | null; limit: number | null; balance: number; last: string | null };
type Method = { id: string; name: string; kind: string };

const iso = (d: Date) => d.toISOString().slice(0, 10);

export function Accounts({ accounts, methods, currency, canManage, canPay }: { accounts: Account[]; methods: Method[]; currency: string; canManage: boolean; canPay: boolean }) {
  const m = (n: number) => money(n, currency);
  const router = useRouter();
  const [editing, setEditing] = useState<Account | "new" | null>(null);
  const [settling, setSettling] = useState<Account | null>(null);
  const [viewing, setViewing] = useState<Account | null>(null);
  const [q, setQ] = useState("");
  const total = accounts.reduce((s, a) => s + Number(a.balance), 0);
  const shown = accounts.filter((a) => !q.trim() || `${a.name} ${a.phone ?? ""} ${a.company ?? ""}`.toLowerCase().includes(q.trim().toLowerCase()));

  if (viewing) return <StatementView account={viewing} currency={currency} onBack={() => setViewing(null)} />;

  return (
    <div className="mx-auto max-w-4xl space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold tracking-tight">Customer accounts</h1>
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Eat now, pay later — canteen staff, companies, regulars. Charge a bill to an account from the bill screen. Outstanding: <b>{m(total)}</b>
          </p>
        </div>
        {canManage && (
          <button className="btn btn-primary" style={{ minHeight: 40, padding: "0 14px" }} onClick={() => setEditing("new")}>
            + New account
          </button>
        )}
      </div>
      <input className="field" placeholder="Search name, phone or company" value={q} onChange={(e) => setQ(e.target.value)} />
      <div className="card overflow-hidden">
        {shown.length === 0 && (
          <p className="p-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
            No accounts yet.
          </p>
        )}
        {shown.map((a) => {
          const over = a.limit != null && Number(a.balance) > Number(a.limit);
          return (
            <div key={a.id} className="flex flex-wrap items-center justify-end gap-3 px-4 py-3" style={{ borderBottom: "1px solid var(--color-line)" }}>
              <div className="min-w-0 flex-1">
                <div className="text-sm font-semibold">
                  {a.name}
                  {a.company && <span className="ml-2 text-xs font-normal" style={{ color: "var(--color-ink-3)" }}>{a.company}</span>}
                </div>
                <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                  {a.phone ?? "No phone"} · limit {a.limit == null ? "closed" : m(Number(a.limit))}
                </div>
              </div>
              <div className="text-right text-sm">
                <div className="font-bold" style={{ color: over ? "var(--color-bad)" : undefined }}>{m(Number(a.balance))}</div>
                <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>owed</div>
              </div>
              <button className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setViewing(a)}>
                Statement
              </button>
              {canPay && Number(a.balance) > 0 && (
                <button className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-brand)", color: "var(--color-brand)" }} onClick={() => setSettling(a)}>
                  Receive payment
                </button>
              )}
              {canManage && (
                <button className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setEditing(a)}>
                  Edit
                </button>
              )}
            </div>
          );
        })}
      </div>

      {editing && <EditAccount account={editing === "new" ? null : editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); router.refresh(); }} />}
      {settling && (
        <SettleDialog account={settling} methods={methods} currency={currency} onClose={() => setSettling(null)} onSaved={() => { setSettling(null); router.refresh(); }} />
      )}
    </div>
  );
}

function EditAccount({ account, onClose, onSaved }: { account: Account | null; onClose: () => void; onSaved: () => void }) {
  const [name, setName] = useState(account?.name ?? "");
  const [phone, setPhone] = useState(account?.phone ?? "");
  const [company, setCompany] = useState(account?.company ?? "");
  const [limit, setLimit] = useState(account?.limit != null ? String(account.limit) : "5000");
  const [open, setOpen] = useState(account ? account.limit != null : true);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <div className="fixed inset-0 z-50 grid place-items-center p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="card w-full max-w-sm p-5" style={{ background: "var(--color-surface)" }} role="dialog" aria-label="Customer account">
        <h3 className="mb-3 text-lg font-bold">{account ? "Edit account" : "New account"}</h3>
        <label className="block text-sm font-semibold">
          Name
          <input className="field mt-1" value={name} onChange={(e) => setName(e.target.value)} maxLength={80} autoFocus />
        </label>
        {!account && (
          <label className="mt-3 block text-sm font-semibold">
            Phone
            <input className="field mt-1" inputMode="tel" value={phone} onChange={(e) => setPhone(e.target.value)} maxLength={20} />
          </label>
        )}
        <label className="mt-3 block text-sm font-semibold">
          Company / group <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>(optional)</span>
          <input className="field mt-1" value={company} onChange={(e) => setCompany(e.target.value)} maxLength={80} placeholder="Infosys canteen" />
        </label>
        <label className="mt-3 flex items-center gap-2 text-sm">
          <input type="checkbox" className="h-4 w-4" checked={open} onChange={(e) => setOpen(e.target.checked)} />
          Account open for new charges
        </label>
        {open && (
          <label className="mt-3 block text-sm font-semibold">
            Credit limit
            <input className="field mt-1" inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value)} />
          </label>
        )}
        {error && (
          <p className="mt-3 text-sm" role="alert" style={{ color: "var(--color-bad)" }}>
            {error}
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button className="btn" style={{ flex: "none", padding: "0 16px" }} onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn btn-primary"
            style={{ flex: 1 }}
            disabled={pending}
            onClick={() =>
              start(async () => {
                const r = await saveAccount(account?.id ?? null, name, phone, open ? Number(limit) || 0 : null, company);
                if (r.error) return setError(r.error);
                onSaved();
              })
            }
          >
            {pending ? "Saving…" : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}

function SettleDialog({ account, methods, currency, onClose, onSaved }: { account: Account; methods: Method[]; currency: string; onClose: () => void; onSaved: () => void }) {
  const [methodId, setMethodId] = useState(methods[0]?.id ?? "");
  const [amount, setAmount] = useState(String(Number(account.balance)));
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <div className="fixed inset-0 z-50 grid place-items-center p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="card w-full max-w-sm p-5" style={{ background: "var(--color-surface)" }} role="dialog" aria-label="Receive payment">
        <h3 className="text-lg font-bold">Receive payment</h3>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          {account.name} owes {money(Number(account.balance), currency)}.
        </p>
        <div className="mt-3 flex flex-wrap gap-1.5">
          {methods.map((x) => (
            <button
              key={x.id}
              className="rounded-lg border px-3 py-2 text-sm font-semibold"
              style={{ borderColor: methodId === x.id ? "var(--color-brand)" : "var(--color-line)", background: methodId === x.id ? "var(--color-brand-soft)" : "transparent" }}
              onClick={() => setMethodId(x.id)}
              aria-pressed={methodId === x.id}
            >
              {x.name}
            </button>
          ))}
        </div>
        <label className="mt-3 block text-sm font-semibold">
          Amount
          <input className="field mt-1" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
        </label>
        <label className="mt-3 block text-sm font-semibold">
          Note <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>(optional)</span>
          <input className="field mt-1" value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} placeholder="September bill, UTR 1234" />
        </label>
        {error && (
          <p className="mt-3 text-sm" role="alert" style={{ color: "var(--color-bad)" }}>
            {error}
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button className="btn" style={{ flex: "none", padding: "0 16px" }} onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn btn-primary"
            style={{ flex: 1 }}
            disabled={pending}
            onClick={() =>
              start(async () => {
                const r = await settleAccount(account.id, methodId, Number(amount) || 0, note);
                if (r.error) return setError(r.error);
                onSaved();
              })
            }
          >
            {pending ? "Saving…" : "Receive"}
          </button>
        </div>
      </div>
    </div>
  );
}

function StatementView({ account, currency, onBack }: { account: Account; currency: string; onBack: () => void }) {
  const m = (n: number) => money(n, currency);
  const now = new Date();
  const [from, setFrom] = useState(iso(new Date(now.getFullYear(), now.getMonth(), 1)));
  const [to, setTo] = useState(iso(now));
  const [st, setSt] = useState<Statement | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const load = () =>
    start(async () => {
      const r = await statement(account.id, from, to);
      if (!r.ok) return setError(r.error);
      setError(null);
      setSt(r.data);
    });
  return (
    <div className="mx-auto max-w-3xl">
      <div className="no-print mb-3 flex flex-wrap items-end gap-2">
        <button className="btn" style={{ flex: "none", padding: "0 12px", minHeight: 40 }} onClick={onBack}>
          ← Accounts
        </button>
        <label className="text-sm font-semibold">
          From
          <input type="date" className="field mt-1" value={from} onChange={(e) => setFrom(e.target.value)} />
        </label>
        <label className="text-sm font-semibold">
          To
          <input type="date" className="field mt-1" value={to} onChange={(e) => setTo(e.target.value)} />
        </label>
        <button className="btn btn-primary" style={{ minHeight: 40 }} disabled={pending} onClick={load}>
          {pending ? "Loading…" : "Show statement"}
        </button>
        {st && (
          <button className="btn" style={{ minHeight: 40 }} onClick={() => window.print()}>
            Print
          </button>
        )}
      </div>
      {error && <p className="text-sm" style={{ color: "var(--color-bad)" }}>{error}</p>}
      {st && (
        <div className="card p-5">
          <h2 className="text-lg font-bold">Statement — {st.customer.name}</h2>
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            {st.customer.company ? `${st.customer.company} · ` : ""}
            {st.from} to {st.to}
          </p>
          <table className="mt-3 w-full text-sm">
            <thead>
              <tr className="text-left" style={{ color: "var(--color-ink-3)" }}>
                <th className="py-1">Date</th>
                <th>Details</th>
                <th className="text-right">Charge</th>
                <th className="text-right">Paid</th>
                <th className="text-right">Balance</th>
              </tr>
            </thead>
            <tbody>
              <tr className="border-t" style={{ borderColor: "var(--color-line)" }}>
                <td className="py-1.5" colSpan={4}>
                  Opening balance
                </td>
                <td className="text-right font-semibold">{m(Number(st.opening))}</td>
              </tr>
              {st.entries.map((e, i) => (
                <tr key={i} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                  <td className="py-1.5">{new Date(e.at).toLocaleDateString("en-IN", { day: "numeric", month: "short" })}</td>
                  <td>
                    {e.kind === "charge" ? (
                      e.order_id ? (
                        <Link href={`/bills/${e.order_id}`} className="underline">
                          Bill {e.bill}
                        </Link>
                      ) : (
                        "Charge"
                      )
                    ) : e.kind === "settlement" ? (
                      `Payment${e.method ? ` (${e.method})` : ""}`
                    ) : (
                      "Adjustment"
                    )}
                    {e.note && <span style={{ color: "var(--color-ink-3)" }}> — {e.note}</span>}
                  </td>
                  <td className="text-right">{Number(e.amount) > 0 ? m(Number(e.amount)) : ""}</td>
                  <td className="text-right">{Number(e.amount) < 0 ? m(-Number(e.amount)) : ""}</td>
                  <td className="text-right">{m(Number(e.balance))}</td>
                </tr>
              ))}
              <tr className="border-t font-bold" style={{ borderColor: "var(--color-line)" }}>
                <td className="py-1.5" colSpan={4}>
                  Closing balance (owed)
                </td>
                <td className="text-right">{m(Number(st.closing))}</td>
              </tr>
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
