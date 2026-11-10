"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { addPasswordStaff, addPinStaff, cancelInvite, changeRole, copyAccess, removePin, resetPassword, setActive, setPin, type StaffResult } from "./actions";
import { ConfirmButton } from "../confirm-button";

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
type Role = { id: string; name: string; backOffice?: boolean };
const isMadeUpEmail = (e: string | null) => !!e && e.endsWith("@staff.sna-pos.app");

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
  const [secret, setSecret] = useState<{ kind: "pin" | "password"; value: string; name: string; userCode?: string; clientCode?: string } | null>(null);
  const [confirmReset, setConfirmReset] = useState<string | null>(null);
  // "Copy access from..." : the person being set up, and the colleague chosen as the model
  const [copyFor, setCopyFor] = useState<string | null>(null);
  const [copySrc, setCopySrc] = useState("");

  const assignable = roles.filter((r) => r.name !== "Owner");
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [roleId, setRoleId] = useState(assignable.find((r) => r.name === "Cashier")?.id ?? assignable[0]?.id ?? "");
  const [howNoEmail, setHowNoEmail] = useState<"pin" | "password">("pin");
  const roleIsBackOffice = !!assignable.find((r) => r.id === roleId)?.backOffice;
  /** How the new person will sign in: a counter role may use a PIN; anything else gets a user code and password. */
  const way: "pin" | "password" = roleIsBackOffice ? "password" : howNoEmail;

  function run(fn: () => Promise<StaffResult>, after?: () => void) {
    setError(null);
    setNotice(null);
    start(async () => {
      const r = await fn();
      if (!r.ok) return setError(r.error);
      if (r.pin) setSecret({ kind: "pin", value: r.pin, name: r.name ?? "" });
      else if (r.tempPassword) setSecret({ kind: "password", value: r.tempPassword, name: r.name ?? "", userCode: r.userCode, clientCode: r.clientCode });
      else setNotice(r.message ?? "Saved.");
      after?.();
      router.refresh();
    });
  }

  return (
    <div className="space-y-5">
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
              : secret.userCode
                ? `Give this to them privately. On the sign-in page they type restaurant code ${secret.clientCode ?? ""}, username ${secret.userCode} and this password. They must then choose their own password.`
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
                      {s.email && !isMadeUpEmail(s.email) ? ` · ${s.email}` : isMadeUpEmail(s.email) ? " · signs in with user code" : ""}
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
                        {assignable
                          .filter((r) => !s.pinOnly || !r.backOffice || r.id === s.roleId)
                          .map((r) => (
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
                          <ConfirmButton
                            className="whitespace-nowrap rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
                            style={{ borderColor: "var(--color-bad)", color: "var(--color-bad)" }}
                            question={`Remove ${s.name}? They never signed in.`}
                            disabled={pending}
                            onConfirm={() => run(() => cancelInvite(s.id))}
                          >
                            Remove
                          </ConfirmButton>
                        </div>
                      )}
                      {!locked && (s.joined || s.pinOnly) && (
                        <SmallBtn danger={s.active} disabled={pending} onClick={() => run(() => setActive(s.id, !s.active))}>
                          {s.active ? "Switch off access" : "Switch on access"}
                        </SmallBtn>
                      )}
                      {!locked && s.active && (
                        <div className="mt-1.5 flex flex-wrap items-center justify-end gap-1.5">
                          {copyFor === s.id ? (
                            <>
                              <select className="field h-9 w-44 text-sm" aria-label={`Copy access to ${s.name} from`} value={copySrc} onChange={(e) => setCopySrc(e.target.value)}>
                                <option value="">Copy from…</option>
                                {staff
                                  .filter((o) => o.id !== s.id && o.active && o.roleName !== "Owner")
                                  .map((o) => (
                                    <option key={o.id} value={o.id}>
                                      {o.name} ({o.roleName})
                                    </option>
                                  ))}
                              </select>
                              <SmallBtn
                                disabled={pending || !copySrc}
                                onClick={() =>
                                  run(() => copyAccess(copySrc, s.id, s.name), () => {
                                    setCopyFor(null);
                                    setCopySrc("");
                                  })
                                }
                              >
                                Copy role and outlets
                              </SmallBtn>
                              <SmallBtn disabled={pending} onClick={() => setCopyFor(null)}>
                                Cancel
                              </SmallBtn>
                            </>
                          ) : (
                            <SmallBtn
                              disabled={pending}
                              onClick={() => {
                                setCopyFor(s.id);
                                setCopySrc("");
                              }}
                            >
                              Copy access from…
                            </SmallBtn>
                          )}
                        </div>
                      )}
                      {s.active && (s.isMe || s.roleName !== "Owner" || isOwner) && (
                        <div className="mt-1.5 flex flex-wrap justify-end gap-1.5">
                          <SmallBtn disabled={pending} onClick={() => run(() => setPin(s.id, s.name))}>
                            {s.hasPin ? "New PIN" : "Pick a PIN"}
                          </SmallBtn>
                          {s.hasPin && (
                            <ConfirmButton
                              className="whitespace-nowrap rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
                              style={{ borderColor: "var(--color-bad)", color: "var(--color-bad)" }}
                              question={`Remove the PIN for ${s.name}?`}
                              disabled={pending}
                              onConfirm={() => run(() => removePin(s.id))}
                            >
                              Remove PIN
                            </ConfirmButton>
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
          <h2 className="text-base font-bold">Add a person</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Everyone gets their own sign-in, so every bill, discount and void records who did it. Pick a role and how they will sign in.
          </p>
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <input className="field" placeholder="Full name" value={name} onChange={(e) => setName(e.target.value)} />
            <select className="field" value={roleId} onChange={(e) => setRoleId(e.target.value)} aria-label="Role">
              {assignable.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.name}
                </option>
              ))}
            </select>
            <input className="field" placeholder="Phone (optional)" value={phone} onChange={(e) => setPhone(e.target.value)} />
          </div>
          {!roleIsBackOffice && (
            <fieldset className="mt-4 space-y-2 text-sm">
              <legend className="mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
                How will they sign in?
              </legend>
              <label className="flex items-start gap-2">
                <input type="radio" name="how" className="mt-1" checked={howNoEmail === "pin"} onChange={() => setHowNoEmail("pin")} />
                <span>
                  <b>A PIN on the counter tablet</b> <span style={{ color: "var(--color-ink-3)" }}>(billing only; best for cashiers and waiters)</span>
                </span>
              </label>
              <label className="flex items-start gap-2">
                <input type="radio" name="how" className="mt-1" checked={howNoEmail === "password"} onChange={() => setHowNoEmail("password")} />
                <span>
                  <b>A user code and password</b> <span style={{ color: "var(--color-ink-3)" }}>(works on any phone or computer)</span>
                </span>
              </label>
            </fieldset>
          )}
          <p className="mt-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
            {way === "pin"
              ? "They get a PIN to unlock the counter tablet. They cannot purchase, manage stock or change settings."
              : "They get a user code (like EMP003) and a temporary password, and choose their own at first sign-in."}
          </p>
          <button
            className="btn btn-primary mt-4"
            disabled={pending || name.trim().length < 2 || !roleId}
            onClick={() =>
              run(
                () =>
                  way === "pin" ? addPinStaff({ name, roleId, phone }) : addPasswordStaff({ name, roleId, phone }),
                () => {
                  setName("");
                  setPhone("");
                },
              )
            }
          >
            {pending ? "Adding…" : way === "pin" ? "Add and create PIN" : "Add and create password"}
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
    ? { t: "Never signed in", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" }
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
