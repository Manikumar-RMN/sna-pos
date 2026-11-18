"use client";

import { useState, useTransition } from "react";
import { addSnaStaff, saveStaff } from "../actions";
import { toneStyle } from "../crm";

export type SnaStaff = { id: string; full_name: string; email: string; role: string; is_active: boolean };
const ROLES: { key: string; label: string; does: string }[] = [
  { key: "admin", label: "Admin", does: "Does everything, including prices and this list." },
  { key: "sales", label: "Sales", does: "Sets licences, records sales, approves upgrades, add-ons and outlets." },
  { key: "implementer", label: "Implementer", does: "Sets up approved outlets and takes clients live." },
  { key: "support", label: "Support", does: "Creates clients, keeps contacts and writes notes." },
];

export function StaffEditor({ staff, myEmail }: { staff: SnaStaff[]; myEmail: string }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [role, setRole] = useState("sales");
  const run = (p: ReturnType<typeof saveStaff>) =>
    start(async () => {
      const r = await p;
      setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error });
    });

  return (
    <div className="mt-4 space-y-4">
      {msg && (
        <div role={msg.ok ? "status" : "alert"} className="card p-3 text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </div>
      )}

      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
              <th className="px-4 py-2.5">Name</th>
              <th className="px-4 py-2.5">Sign-in email</th>
              <th className="px-4 py-2.5">Role</th>
              <th className="px-4 py-2.5">Status</th>
            </tr>
          </thead>
          <tbody>
            {staff.map((s) => {
              const me = s.email.toLowerCase() === myEmail;
              return (
                <tr key={s.id} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                  <td className="px-4 py-3 font-semibold">
                    {s.full_name}
                    {me && (
                      <span className="ml-2 rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle.plain}>
                        You
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-3">{s.email}</td>
                  <td className="px-4 py-3">
                    <select
                      aria-label={`Role for ${s.full_name}`}
                      className="field h-9"
                      defaultValue={s.role}
                      disabled={pending || me}
                      title={me ? "You cannot change your own role" : undefined}
                      onChange={(e) => run(saveStaff(s.email, s.full_name, e.target.value, s.is_active))}
                    >
                      {ROLES.map((r) => (
                        <option key={r.key} value={r.key}>
                          {r.label}
                        </option>
                      ))}
                    </select>
                  </td>
                  <td className="px-4 py-3">
                    <span className="rounded-full px-2 py-0.5 text-[11px] font-bold" style={s.is_active ? toneStyle.ok : toneStyle.bad}>
                      {s.is_active ? "Can sign in" : "Switched off"}
                    </span>
                    {!me && (
                      <button className="ml-3 text-xs font-semibold" style={{ color: s.is_active ? "var(--color-bad)" : "var(--color-ok)" }} disabled={pending} onClick={() => run(saveStaff(s.email, s.full_name, s.role, !s.is_active))}>
                        {s.is_active ? "Switch off" : "Switch on"}
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <form
        className="card space-y-3 p-4"
        onSubmit={(e) => {
          e.preventDefault();
          start(async () => {
            const r = await addSnaStaff(email, name, role);
            setMsg(r.ok ? { ok: true, text: r.message ?? "Added." } : { ok: false, text: r.error });
            if (r.ok) {
              setEmail("");
              setName("");
            }
          });
        }}
      >
        <h2 className="text-base font-bold">Add a person</h2>
        <div className="grid gap-3 sm:grid-cols-3">
          <label className="block text-sm">
            <span className="mb-1 block font-semibold">Full name</span>
            <input className="field w-full" value={name} onChange={(e) => setName(e.target.value)} required />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block font-semibold">Sign-in email</span>
            <input className="field w-full" type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block font-semibold">Role</span>
            <select className="field w-full" value={role} onChange={(e) => setRole(e.target.value)}>
              {ROLES.map((r) => (
                <option key={r.key} value={r.key}>
                  {r.label}
                </option>
              ))}
            </select>
          </label>
        </div>
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          {ROLES.find((r) => r.key === role)?.does}
        </p>
        <button className="btn h-11 min-h-0 px-5 text-sm" style={{ background: "var(--color-ink)", color: "#fff" }} disabled={pending}>
          Add person
        </button>
      </form>

      <div className="card p-4">
        <h2 className="text-base font-bold">What each role can do</h2>
        <dl className="mt-2 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
          {ROLES.map((r) => (
            <div key={r.key}>
              <dt className="font-semibold">{r.label}</dt>
              <dd style={{ color: "var(--color-ink-3)" }}>{r.does}</dd>
            </div>
          ))}
        </dl>
      </div>
    </div>
  );
}
