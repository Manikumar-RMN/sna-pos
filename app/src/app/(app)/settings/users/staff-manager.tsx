"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { addPinStaff, cancelInvite, changeRole, inviteStaff, newInviteCode, removePin, resetPassword, setActive, setPin, type StaffResult } from "./actions";

type Staff = {
  id: string;
  name: string;
  code: string;
  email: string | null;
  roleId: string;
  roleName: string;
  active: boolean;
  joined: boolean;
  pinOnly: boolean;
  hasPin: boolean;
  isMe: boolean;
};
type Role = { id: string; name: string };

export function StaffManager({
  staff,
  roles,
  canManage,
  isOwner,
  appUrl,
}: {
  staff: Staff[];
  roles: Role[];
  canManage: boolean;
  isOwner: boolean;
  appUrl: string;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [invite, setInvite] = useState<{ code: string; name: string; email: string } | null>(null);
  const [secret, setSecret] = useState<{ kind: "pin" | "password"; value: string; name: string } | null>(null);
  const [confirmReset, setConfirmReset] = useState<string | null>(null);
  const [pinName, setPinName] = useState("");
  const [pinRole, setPinRole] = useState("");

  const assignable = roles.filter((r) => r.name !== "Owner");
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [phone, setPhone] = useState("");
  const [roleId, setRoleId] = useState(assignable.find((r) => r.name === "Cashier")?.id ?? assignable[0]?.id ?? "");

  function run(fn: () => Promise<StaffResult>, after?: () => void) {
    setError(null);
    setNotice(null);
    start(async () => {
      const r = await fn();
      if (!r.ok) return setError(r.error);
      if (r.code) setInvite({ code: r.code, name: r.name ?? "", email: r.email ?? "" });
      else if (r.pin) setSecret({ kind: "pin", value: r.pin, name: r.name ?? "" });
      else if (r.tempPassword) setSecret({ kind: "password", value: r.tempPassword, name: r.name ?? "" });
      else setNotice(r.message ?? "Saved.");
      after?.();
      router.refresh();
    });
  }

  const pretty = (c: string) => `${c.slice(0, 4)}-${c.slice(4)}`;

  return (
    <div className="space-y-5">
      {invite && (
        <div className="card p-5" style={{ borderColor: "var(--color-brand)", background: "var(--color-brand-soft)" }}>
          <div className="text-sm font-bold">Invite code for {invite.name}</div>
          <div className="my-3 text-3xl font-bold tracking-[0.2em] tabular-nums" style={{ color: "var(--color-brand-strong)" }}>
            {pretty(invite.code)}
          </div>
          <ol className="list-decimal space-y-1 pl-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
            <li>
              Ask {invite.name} to open <b>{appUrl}</b> on their phone or the counter tablet.
            </li>
            <li>
              Tap <b>Create an account</b> using <b>{invite.email}</b> and a password of their own.
            </li>
            <li>
              Enter this code on the next screen. It works once and expires in 7 days.
            </li>
          </ol>
          <p className="mt-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
            This code is shown only now. If it is lost, use “New code” below.
          </p>
          <button className="mt-3 text-xs font-semibold" style={{ color: "var(--color-brand-strong)" }} onClick={() => setInvite(null)}>
            Done
          </button>
        </div>
      )}

      {secret && (
        <div className="card p-5" style={{ borderColor: "var(--color-brand)", background: "var(--color-brand-soft)" }}>
          <div className="text-sm font-bold">
            {secret.kind === "pin" ? `Counter PIN for ${secret.name}` : `Temporary password for ${secret.name}`}
          </div>
          <div className="my-3 font-mono text-3xl font-bold tracking-[0.15em]" style={{ color: "var(--color-brand-strong)" }}>
            {secret.value}
          </div>
          <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
            {secret.kind === "pin"
              ? "Give this PIN to them privately. They type it on the counter tablet to unlock it. No one else in the restaurant has the same PIN."
              : "Give this to them privately. They sign in with their email and this password, and must then choose their own. They have been signed out everywhere."}
          </p>
          <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Shown only now. It cannot be looked up again.
          </p>
          <button className="mt-3 text-xs font-semibold" style={{ color: "var(--color-brand-strong)" }} onClick={() => setSecret(null)}>
            Done
          </button>
        </div>
      )}

      {error && (
        <p className="rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {error}
        </p>
      )}
      {notice && (
        <p className="rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-ok-soft)", color: "var(--color-ok)" }}>
          {notice}
        </p>
      )}

      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr style={{ color: "var(--color-ink-3)" }}>
              <th className="px-4 py-3 text-left text-xs font-semibold">Name</th>
              <th className="px-4 py-3 text-left text-xs font-semibold">Role</th>
              <th className="px-4 py-3 text-left text-xs font-semibold">Status</th>
              {canManage && <th className="px-4 py-3 text-right text-xs font-semibold">Actions</th>}
            </tr>
          </thead>
          <tbody>
            {staff.map((s) => {
              const locked = s.isMe || s.roleName === "Owner";
              return (
                <tr key={s.id} style={{ borderTop: "1px solid var(--color-line)" }}>
                  <td className="px-4 py-3">
                    <div className="font-medium">
                      {s.name} {s.isMe && <span style={{ color: "var(--color-ink-3)" }}>(you)</span>}
                    </div>
                    <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                      {s.code}
                      {s.email ? ` · ${s.email}` : ""}
                    </div>
                  </td>
                  <td className="px-4 py-3">
                    {canManage && !locked ? (
                      <select
                        className="field h-9 w-32 text-sm"
                        value={s.roleId}
                        disabled={pending}
                        onChange={(e) => run(() => changeRole(s.id, e.target.value))}
                      >
                        {assignable.map((r) => (
                          <option key={r.id} value={r.id}>
                            {r.name}
                          </option>
                        ))}
                      </select>
                    ) : (
                      s.roleName
                    )}
                  </td>
                  <td className="px-4 py-3">
                    <Badge joined={s.joined} pinOnly={s.pinOnly} active={s.active} />
                    {s.hasPin && (
                      <div className="mt-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                        Has a counter PIN
                      </div>
                    )}
                  </td>
                  {canManage && (
                    <td className="px-4 py-3 text-right">
                      {!locked && !s.joined && !s.pinOnly && (
                        <div className="flex justify-end gap-1.5">
                          <SmallBtn disabled={pending} onClick={() => run(() => newInviteCode(s.id, s.name, s.email ?? ""))}>
                            New code
                          </SmallBtn>
                          <SmallBtn danger disabled={pending} onClick={() => run(() => cancelInvite(s.id))}>
                            Cancel invite
                          </SmallBtn>
                        </div>
                      )}
                      {!locked && (s.joined || s.pinOnly) && (
                        <SmallBtn danger={s.active} disabled={pending} onClick={() => run(() => setActive(s.id, !s.active))}>
                          {s.active ? "Switch off access" : "Switch on access"}
                        </SmallBtn>
                      )}
                      {s.active && (s.isMe || s.roleName !== "Owner" || isOwner) && (
                        <div className="mt-1.5 flex flex-wrap justify-end gap-1.5">
                          <SmallBtn disabled={pending} onClick={() => run(() => setPin(s.id, s.name))}>
                            {s.hasPin ? "New PIN" : "Pick a PIN"}
                          </SmallBtn>
                          {s.hasPin && (
                            <SmallBtn danger disabled={pending} onClick={() => run(() => removePin(s.id))}>
                              Remove PIN
                            </SmallBtn>
                          )}
                          {s.joined && !s.isMe && (
                            confirmReset === s.id ? (
                              <SmallBtn danger disabled={pending} onClick={() => run(() => resetPassword(s.id, s.name), () => setConfirmReset(null))}>
                                Yes, reset
                              </SmallBtn>
                            ) : (
                              <SmallBtn disabled={pending} onClick={() => setConfirmReset(s.id)}>
                                Reset password
                              </SmallBtn>
                            )
                          )}
                        </div>
                      )}
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {canManage && (
        <section className="card p-5">
          <h2 className="text-base font-bold">Add a staff member</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Each person gets their own sign-in, so every bill, discount and void records who did it.
          </p>
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <input className="field" placeholder="Full name" value={name} onChange={(e) => setName(e.target.value)} />
            <input className="field" type="email" placeholder="Email (they sign in with this)" value={email} onChange={(e) => setEmail(e.target.value)} />
            <input className="field" placeholder="Phone (optional)" value={phone} onChange={(e) => setPhone(e.target.value)} />
            <select className="field" value={roleId} onChange={(e) => setRoleId(e.target.value)}>
              {assignable.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.name}
                </option>
              ))}
            </select>
          </div>
          <button
            className="btn btn-primary mt-4"
            disabled={pending || name.trim().length < 2 || !email.includes("@") || !roleId}
            onClick={() =>
              run(() => inviteStaff({ name, email, roleId, phone }), () => {
                setName("");
                setEmail("");
                setPhone("");
              })
            }
          >
            {pending ? "Creating…" : "Create invite code"}
          </button>
        </section>
      )}

      {canManage && (
        <section className="card p-5">
          <h2 className="text-base font-bold">Add counter-only staff (PIN, no email)</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            For cashiers and waiters who only use the counter tablet. They get a unique PIN and no email sign-in.
          </p>
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <input className="field" placeholder="Full name" value={pinName} onChange={(e) => setPinName(e.target.value)} />
            <select className="field" value={pinRole || roleId} onChange={(e) => setPinRole(e.target.value)}>
              {assignable.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.name}
                </option>
              ))}
            </select>
          </div>
          <button
            className="btn btn-primary mt-4"
            disabled={pending || pinName.trim().length < 2}
            onClick={() => run(() => addPinStaff({ name: pinName, roleId: pinRole || roleId, phone: "" }), () => setPinName(""))}
          >
            {pending ? "Creating…" : "Add and create PIN"}
          </button>
        </section>
      )}
    </div>
  );
}

function Badge({ joined, pinOnly, active }: { joined: boolean; pinOnly: boolean; active: boolean }) {
  const s = pinOnly
    ? active
      ? { t: "Active · PIN only", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" }
      : { t: "Access off", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" }
    : !joined
    ? { t: "Invited — not joined", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" }
    : active
      ? { t: "Active", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" }
      : { t: "Access off", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" };
  return (
    <span className="whitespace-nowrap rounded-full px-2 py-1 text-xs font-semibold" style={{ background: s.bg, color: s.fg }}>
      {s.t}
    </span>
  );
}

function SmallBtn({ children, onClick, disabled, danger }: { children: React.ReactNode; onClick: () => void; disabled?: boolean; danger?: boolean }) {
  return (
    <button
      className="whitespace-nowrap rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
      style={{ borderColor: danger ? "var(--color-bad)" : "var(--color-line)", color: danger ? "var(--color-bad)" : "var(--color-ink-2)" }}
      disabled={disabled}
      onClick={onClick}
    >
      {children}
    </button>
  );
}
