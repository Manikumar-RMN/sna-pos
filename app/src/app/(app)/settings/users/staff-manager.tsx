"use client";

import { useState, useTransition, type ReactNode } from "react";
import { useRouter } from "next/navigation";
import { PasswordInput } from "@/components/password-input";
import { addPasswordStaff, changeRole, copyAccess, resetPassword, setActive, unlockSignIn, updateStaffDetails, type StaffResult } from "./actions";

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
  phone: string;
  department: string;
  designation: string;
  employeeNo: string;
  relievingDate: string;
  isMe: boolean;
  signInLocked?: boolean;
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
  const [secret, setSecret] = useState<{ kind: "password"; value: string; name: string; userCode?: string; clientCode?: string } | null>(null);
  const [confirmReset, setConfirmReset] = useState<string | null>(null);
  // "Copy access from..." : the person being set up, and the colleague chosen as the model
  const [copyFor, setCopyFor] = useState<string | null>(null);
  const [copySrc, setCopySrc] = useState("");
  // The User Master form: the person whose details are open, and the fields being edited
  const [editId, setEditId] = useState<string | null>(null);
  const [form, setForm] = useState({ name: "", phone: "", department: "", designation: "", employeeNo: "", relievingDate: "" });
  const editing = staff.find((x) => x.id === editId) ?? null;
  const [dept, setDept] = useState("");
  const [desig, setDesig] = useState("");
  const [empNo, setEmpNo] = useState("");

  const assignable = roles.filter((r) => r.name !== "Owner");
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [roleId, setRoleId] = useState(assignable.find((r) => r.name === "Cashier")?.id ?? assignable[0]?.id ?? "");
  const roleIsBackOffice = !!assignable.find((r) => r.id === roleId)?.backOffice;
  // The password the manager types for the new person, and the same password again.
  const [pw, setPw] = useState("");
  const [pw2, setPw2] = useState("");
  const pwTouched = pw.length > 0 || pw2.length > 0;
  const pwShort = pwTouched && pw.length < 8;
  const pwMismatch = pwTouched && pw2.length > 0 && pw !== pw2;
  const pwProblem = pwShort
    ? "The password needs at least 8 characters."
    : pwMismatch
      ? "The two passwords are not the same."
      : null;
  const canAdd = name.trim().length >= 2 && !!roleId && (!pwTouched || (pw.length >= 8 && pw === pw2));

  function run(fn: () => Promise<StaffResult>, after?: () => void) {
    setError(null);
    setNotice(null);
    start(async () => {
      const r = await fn();
      if (!r.ok) return setError(r.error);
      if (r.tempPassword) setSecret({ kind: "password", value: r.tempPassword, name: r.name ?? "", userCode: r.userCode, clientCode: r.clientCode });
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
            Temporary password for {secret.name}
          </div>
          <div className="my-3 font-mono text-3xl font-bold tracking-[0.15em]" style={{ color: "var(--color-brand-strong)" }}>
            {secret.value}
          </div>
          <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
            {secret.userCode
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
                    {(s.department || s.designation || s.relievingDate) && (
                      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {[s.designation, s.department].filter(Boolean).join(" · ")}
                        {s.relievingDate ? `${s.designation || s.department ? " · " : ""}relieving ${s.relievingDate}` : ""}
                      </div>
                    )}
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
                  </td>
                  {canManage && (
                    <td className="px-4 py-3 text-right">
                      <SmallBtn
                        disabled={pending}
                        onClick={() => {
                          setEditId(s.id);
                          setForm({ name: s.name, phone: s.phone, department: s.department, designation: s.designation, employeeNo: s.employeeNo, relievingDate: s.relievingDate });
                        }}
                      >
                        Details
                      </SmallBtn>
                      {s.joined && s.active && !s.isMe && (
                        <SmallBtn disabled={pending} onClick={() => run(() => unlockSignIn(s.id))}>
                          Unlock sign-in
                        </SmallBtn>
                      )}
                      {!locked && (
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

      {canManage && editing && (
        <section className="card p-5" aria-label="User details">
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-base font-bold">User details</h2>
              <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
                The person signs in with restaurant code, user code and password. These details are for your records.
              </p>
            </div>
            <button className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }} onClick={() => setEditId(null)}>
              Close
            </button>
          </div>
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <label className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              User code (sign-in username)
              <input className="field mt-1" value={editing.code} readOnly disabled />
            </label>
            <label className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Role
              <input className="field mt-1" value={editing.roleName} readOnly disabled />
            </label>
            <Field label="User name" required>
              <input className="field mt-1" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            </Field>
            <label className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Mobile no
              <input className="field mt-1" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
            </label>
            <label className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Department
              <input className="field mt-1" value={form.department} onChange={(e) => setForm({ ...form, department: e.target.value })} />
            </label>
            <label className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Designation
              <input className="field mt-1" value={form.designation} onChange={(e) => setForm({ ...form, designation: e.target.value })} />
            </label>
            <label className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Employee no
              <input className="field mt-1" value={form.employeeNo} onChange={(e) => setForm({ ...form, employeeNo: e.target.value })} />
            </label>
            <label className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Relieving date (access ends after this day)
              <input className="field mt-1" type="date" value={form.relievingDate} onChange={(e) => setForm({ ...form, relievingDate: e.target.value })} />
            </label>
          </div>
          <div className="mt-4 flex gap-2">
            <button
              className="btn btn-primary"
              disabled={pending || form.name.trim().length < 2}
              onClick={() => run(() => updateStaffDetails({ userId: editing.id, name: form.name, phone: form.phone, department: form.department, designation: form.designation, employeeNo: form.employeeNo, relievingDate: form.relievingDate }), () => setEditId(null))}
            >
              {pending ? "Saving…" : "Save details"}
            </button>
          </div>
        </section>
      )}

      {canManage && (
        <section className="card p-5">
          <h2 className="text-base font-bold">Add a person</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Everyone gets their own sign-in, so every bill, discount and void records who did it. Pick a role. They sign in with the restaurant code, their user code and a password.
          </p>
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <Field label="Full name" required>
              <input id="add-name" className="field mt-1" value={name} onChange={(e) => setName(e.target.value)} autoComplete="off" />
            </Field>
            <Field label="Role" required>
              <select id="add-role" className="field mt-1" value={roleId} onChange={(e) => setRoleId(e.target.value)}>
                {assignable.map((r) => (
                  <option key={r.id} value={r.id}>
                    {r.name}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Mobile">
              <input id="add-phone" className="field mt-1" value={phone} onChange={(e) => setPhone(e.target.value)} autoComplete="off" />
            </Field>
            <Field label="Department">
              <input id="add-dept" className="field mt-1" value={dept} onChange={(e) => setDept(e.target.value)} autoComplete="off" />
            </Field>
            <Field label="Designation">
              <input id="add-desig" className="field mt-1" value={desig} onChange={(e) => setDesig(e.target.value)} autoComplete="off" />
            </Field>
            <Field label="Employee no">
              <input id="add-empno" className="field mt-1" value={empNo} onChange={(e) => setEmpNo(e.target.value)} autoComplete="off" />
            </Field>
          </div>

          <div className="mt-4 rounded-lg p-4" style={{ background: "var(--color-surface-2, var(--color-brand-soft))" }}>
            <div className="text-sm font-bold">Sign-in password</div>
            <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
              Type the password they will use, twice. Leave both boxes empty and the system makes a temporary password that they must change the first time they sign in.
            </p>
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              <Field label="Password" required={pwTouched}>
                <PasswordInput
                  id="add-password"
                  className="field"
                  wrapperClassName="mt-1"
                  value={pw}
                  onChange={(e) => setPw(e.target.value)}
                  autoComplete="new-password"
                  minLength={8}
                  aria-describedby="add-password-help"
                />
              </Field>
              <Field label="Re-enter password" required={pwTouched}>
                <PasswordInput
                  id="add-password2"
                  className="field"
                  wrapperClassName="mt-1"
                  value={pw2}
                  onChange={(e) => setPw2(e.target.value)}
                  autoComplete="new-password"
                  minLength={8}
                  aria-invalid={pwMismatch}
                />
              </Field>
            </div>
            <p id="add-password-help" className="mt-2 text-xs" role={pwProblem ? "alert" : undefined} style={{ color: pwProblem ? "var(--color-bad)" : "var(--color-ink-3)" }}>
              {pwProblem ?? "At least 8 characters."}
            </p>
          </div>

          <p className="mt-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
            <span style={{ color: "var(--color-bad)" }}>*</span> Needed. They get a user code (like EMP003) to sign in with, next to the restaurant code.
          </p>
          <button
            className="btn btn-primary mt-4"
            disabled={pending || !canAdd}
            onClick={() =>
              run(
                () =>
                  addPasswordStaff({ name, roleId, phone, department: dept, designation: desig, employeeNo: empNo, password: pw, confirmPassword: pw2 }),
                () => {
                  setName("");
                  setPhone("");
                  setDept("");
                  setDesig("");
                  setEmpNo("");
                  setPw("");
                  setPw2("");
                },
              )
            }
          >
            {pending ? "Adding…" : pwTouched ? "Add with this password" : "Add and create password"}
          </button>
        </section>
      )}
    </div>
  );
}

/** A labelled box. A red star marks the ones that have to be filled in before the person can be added. */
function Field({ label, required, children }: { label: string; required?: boolean; children: ReactNode }) {
  return (
    <label className="block text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
      {label}
      {required && (
        <span aria-hidden="true" className="ml-0.5" style={{ color: "var(--color-bad)" }}>
          *
        </span>
      )}
      {required && <span className="sr-only"> (needed)</span>}
      {children}
    </label>
  );
}

function Badge({ joined, pinOnly, active }: { joined: boolean; pinOnly: boolean; active: boolean }) {
  const s = pinOnly
    ? active
      ? { t: "No password — add again", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" }
      : { t: "No password — add again", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" }
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
