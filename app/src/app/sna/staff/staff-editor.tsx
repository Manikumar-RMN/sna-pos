"use client";

import { useState, useTransition } from "react";
import { saveStaff } from "../actions";

export type SnaStaff = { id: string; full_name: string; email: string; role: string; is_active: boolean };
const ROLES = ["sales", "implementer", "support", "admin"];

export function StaffEditor({ staff }: { staff: SnaStaff[] }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [role, setRole] = useState("sales");
  const run = (p: ReturnType<typeof saveStaff>) =>
    start(async () => {
      const r = await p;
      setMsg(r.ok ? r.message : r.error);
    });

  return (
    <div className="mt-4 space-y-4">
      {msg && <div className="card p-3 text-sm font-semibold">{msg}</div>}
      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <tbody>
            {staff.map((s) => (
              <tr key={s.id} className="border-b" style={{ borderColor: "var(--color-line)" }}>
                <td className="px-4 py-2.5 font-semibold">{s.full_name}</td>
                <td className="px-4 py-2.5">{s.email}</td>
                <td className="px-4 py-2.5">
                  <select className="field h-9" defaultValue={s.role} disabled={pending} onChange={(e) => run(saveStaff(s.email, s.full_name, e.target.value, s.is_active))}>
                    {ROLES.map((r) => (
                      <option key={r} value={r}>
                        {r}
                      </option>
                    ))}
                  </select>
                </td>
                <td className="px-4 py-2.5">
                  <button className="text-xs font-semibold" style={{ color: s.is_active ? "var(--color-bad)" : "var(--color-ok)" }} disabled={pending} onClick={() => run(saveStaff(s.email, s.full_name, s.role, !s.is_active))}>
                    {s.is_active ? "Switch off" : "Switch on"}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <form
        className="card grid gap-2 p-4 sm:grid-cols-[1fr_1fr_auto_auto]"
        onSubmit={(e) => {
          e.preventDefault();
          run(saveStaff(email, name, role, true));
        }}
      >
        <input className="field" type="email" placeholder="Their sign-in email" value={email} onChange={(e) => setEmail(e.target.value)} required />
        <input className="field" placeholder="Full name" value={name} onChange={(e) => setName(e.target.value)} required />
        <select className="field" value={role} onChange={(e) => setRole(e.target.value)}>
          {ROLES.map((r) => (
            <option key={r} value={r}>
              {r}
            </option>
          ))}
        </select>
        <button className="btn btn-pay h-11 min-h-0 px-5 text-sm" disabled={pending}>
          Add
        </button>
      </form>
    </div>
  );
}
