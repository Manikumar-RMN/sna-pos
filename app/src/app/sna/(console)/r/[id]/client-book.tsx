"use client";

import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { ConfirmButton } from "@/app/(app)/settings/confirm-button";
import { addNote, addSale, cancelSale, removeContact, saveAccount, saveContact, setFollowUp, setReminder, setSalePaid, type SnaResult } from "../../actions";
import { ACCOUNT_CHOICES, CONTACT_KINDS, NOTE_KINDS, SALE_KINDS, accountChoice, indiaDateTime, labelOf, shortDate, toneStyle, type Client, type Contact, type LicenceNow, type SalesExtra } from "../../crm";

/** Runs a save and shows what the server said, in words, next to the form. */
function useSave() {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  function run(p: Promise<SnaResult>, after?: () => void) {
    start(async () => {
      const res = await p;
      setMsg({ ok: res.ok, text: res.ok ? res.message : res.error });
      if (res.ok) after?.();
    });
  }
  return { pending, msg, run };
}

function Said({ msg }: { msg: { ok: boolean; text: string } | null }) {
  if (!msg) return null;
  return (
    <p role="status" className="text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
      {msg.text}
    </p>
  );
}

function Field({ label, htmlFor, children, hint }: { label: string; htmlFor: string; children: React.ReactNode; hint?: string }) {
  return (
    <div>
      <label htmlFor={htmlFor} className="mb-1 block text-xs font-bold" style={{ color: "var(--color-ink-2)" }}>
        {label}
      </label>
      {children}
      {hint && (
        <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
          {hint}
        </p>
      )}
    </div>
  );
}

const ghost = { border: "1px solid var(--color-line)", color: "var(--color-ink-2)" } as const;
const dark = { background: "var(--color-ink)", color: "#fff" } as const;

// ---------------------------------------------------------------- Overview

export function AccountPanel({ c, now, canEdit }: { c: Client; now: LicenceNow; canEdit: boolean }) {
  const { pending, msg, run } = useSave();
  const rem = useSave();
  const [status, setStatus] = useState(accountChoice(c.status));
  const [start, setStart] = useState(c.licence_start ?? "");
  const [end, setEnd] = useState(c.licence_expiry ?? "");
  const [am, setAm] = useState(c.account_manager ?? "");
  const [sp, setSp] = useState(c.sales_person ?? "");
  const [su, setSu] = useState(c.support_person ?? "");
  const staffName = (id: string | null) => c.staff.find((s) => s.id === id)?.full_name ?? "Not assigned";

  const people = (id: string, value: string, set: (v: string) => void) => (
    <select id={id} className="field" value={value} onChange={(e) => set(e.target.value)} disabled={!canEdit}>
      <option value="">Not assigned</option>
      {c.staff.map((s) => (
        <option key={s.id} value={s.id}>
          {s.full_name} ({s.role})
        </option>
      ))}
    </select>
  );

  return (
    <div className="grid gap-4 lg:grid-cols-3">
      <form
        className="card space-y-4 p-5 lg:col-span-2"
        onSubmit={(e) => {
          e.preventDefault();
          run(saveAccount({ restaurantId: c.id, status, licenceStart: start, licenceExpiry: end, accountManager: am, salesPerson: sp, supportPerson: su }));
        }}
      >
        <h2 className="font-display text-lg font-bold">Licence and who looks after this client</h2>
        <LicenceBox c={c} now={now} />
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label="Account" htmlFor="acc-status" hint="Leave on Normal. The end date does the rest.">
            <select id="acc-status" className="field" value={status} onChange={(e) => setStatus(e.target.value)} disabled={!canEdit}>
              {ACCOUNT_CHOICES.map((s) => (
                <option key={s.key} value={s.key}>
                  {s.label}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Licence starts" htmlFor="acc-start">
            <input id="acc-start" type="date" className="field" value={start} onChange={(e) => setStart(e.target.value)} disabled={!canEdit} />
          </Field>
          <Field label="Licence ends" htmlFor="acc-end">
            <input id="acc-end" type="date" className="field" value={end} min={start || undefined} onChange={(e) => setEnd(e.target.value)} disabled={!canEdit} />
          </Field>
          <Field label="Account manager" htmlFor="acc-am">
            {people("acc-am", am, setAm)}
          </Field>
          <Field label="Sales person" htmlFor="acc-sp">
            {people("acc-sp", sp, setSp)}
          </Field>
          <Field label="Support person" htmlFor="acc-su">
            {people("acc-su", su, setSu)}
          </Field>
        </div>
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          How it works: the restaurant sees a reminder twice a day from 15 days before <b>Licence ends</b>. The end date can be used in full; at 6 a.m. the
          next morning (restaurant&rsquo;s time) it becomes read-only: no new bills, but open bills can be paid and the day closed. Move the end date and it
          works again at once. With no end date nothing is limited.
        </p>
        {canEdit ? (
          <div className="flex flex-wrap items-center gap-3">
            <button type="submit" className="btn px-5" style={dark} disabled={pending}>
              {pending ? "Saving…" : "Save"}
            </button>
            <Said msg={msg} />
          </div>
        ) : (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            Only Sales and Admin can change these. Account manager: {staffName(c.account_manager)}.
          </p>
        )}

        <div className="border-t pt-4" style={{ borderColor: "var(--color-line)" }}>
          <h3 className="text-sm font-bold">Renewal reminder shown to the restaurant</h3>
          {!c.licence_expiry ? (
            <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
              No reminder: there is no licence end date.
            </p>
          ) : (
            <div className="mt-2 flex flex-wrap items-center gap-3">
              <span className="rounded-full px-3 py-1 text-xs font-bold" style={now.reminder_off ? toneStyle.plain : now.state === "warn" ? toneStyle.warn : toneStyle.ok}>
                {now.reminder_off ? "Switched off for this end date" : now.state === "warn" ? "Showing now, twice a day" : now.state === "locked" ? "Not showing: already read-only" : "On: starts 15 days before the end date"}
              </span>
              {canEdit && (
                <button type="button" className="btn h-10 min-h-0 px-4 text-sm" style={ghost} disabled={rem.pending} onClick={() => rem.run(setReminder(c.id, now.reminder_off))}>
                  {now.reminder_off ? "Switch the reminder on" : "Payment received: switch the reminder off"}
                </button>
              )}
              <Said msg={rem.msg} />
            </div>
          )}
          <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Switching the reminder off does not move the end date: the restaurant still becomes read-only after {c.licence_expiry ? shortDate(c.licence_expiry) : "the end date"}.
            To renew, record the sale on the Sales history tab and tick &ldquo;Move the licence end date&rdquo;.
          </p>
        </div>
      </form>

      <div className="card p-5">
        <h2 className="font-display text-lg font-bold">How much they use SNA POS</h2>
        <dl className="mt-3 space-y-2 text-sm">
          {[
            ["Outlets", String(c.usage.outlets)],
            ["People with access", String(c.usage.people)],
            ["Last bill made", c.usage.last_bill ? shortDate(c.usage.last_bill) : "No bills yet"],
            ["Bills in the last 30 days", String(c.usage.bills_30d)],
            ["Sold so far", money(Number(c.sales_total), c.currency)],
            ["Not yet paid", money(Number(c.sales_unpaid), c.currency)],
          ].map(([k, v]) => (
            <div key={k} className="flex items-baseline justify-between gap-3">
              <dt style={{ color: "var(--color-ink-3)" }}>{k}</dt>
              <dd className="font-semibold tabular-nums">{v}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Only counts and dates are shown here. SNA staff do not see the restaurant&rsquo;s bills or takings.
        </p>
      </div>
    </div>
  );
}

/** In one line: what the restaurant is experiencing right now. */
function LicenceBox({ c, now }: { c: Client; now: LicenceNow }) {
  let tone: keyof typeof toneStyle = "ok";
  let text = "";
  if (now.state === "locked") {
    tone = "bad";
    text =
      now.reason === "ended"
        ? `Read-only now. The licence ended on ${shortDate(c.licence_expiry)}. New bills are refused; open bills can still be paid.`
        : `Read-only now, because the account is ${now.reason}. New bills are refused; open bills can still be paid.`;
  } else if (!c.licence_expiry) {
    tone = "plain";
    text = "No licence end date: this restaurant is not limited and sees no reminder. Set the end date when the order comes in.";
  } else if (now.state === "warn") {
    tone = "warn";
    text = `Ends on ${shortDate(c.licence_expiry)} (${now.days_left === 0 ? "today" : `${now.days_left} ${now.days_left === 1 ? "day" : "days"} left`}). Read-only from ${now.lock_at ? indiaDateTime(now.lock_at) : "the next morning"} India time.`;
  } else {
    text = `Working normally. Ends on ${shortDate(c.licence_expiry)} (${now.days_left} days left).`;
  }
  return (
    <div role="status" className="rounded-2xl px-4 py-3 text-sm font-semibold" style={toneStyle[tone]}>
      {text}
    </div>
  );
}

// ---------------------------------------------------------------- Contacts

type Draft = { id: string | null; kind: string; fullName: string; jobTitle: string; phone: string; email: string };
const emptyDraft: Draft = { id: null, kind: "contact", fullName: "", jobTitle: "", phone: "", email: "" };

export function ContactsPanel({ c }: { c: Client }) {
  const { pending, msg, run } = useSave();
  const [draft, setDraft] = useState<Draft | null>(null);
  const edit = (k: Contact) => setDraft({ id: k.id, kind: k.kind, fullName: k.full_name, jobTitle: k.job_title ?? "", phone: k.phone ?? "", email: k.email ?? "" });
  const set = (patch: Partial<Draft>) => setDraft((d) => (d ? { ...d, ...patch } : d));

  return (
    <div className="space-y-4">
      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left" style={{ color: "var(--color-ink-3)" }}>
              <th className="px-4 py-2">Type</th>
              <th className="px-4 py-2">Name</th>
              <th className="px-4 py-2">Position</th>
              <th className="px-4 py-2">Phone</th>
              <th className="px-4 py-2">Email</th>
              <th className="px-4 py-2">
                <span className="sr-only">Actions</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {c.owner && (
              <tr className="border-t" style={{ borderColor: "var(--color-line)" }}>
                <td className="px-4 py-2.5">
                  <span className="rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle.ok}>
                    Owner account
                  </span>
                </td>
                <td className="px-4 py-2.5 font-semibold">{c.owner.full_name}</td>
                <td className="px-4 py-2.5" style={{ color: "var(--color-ink-3)" }}>
                  Signed up with this account
                </td>
                <td className="px-4 py-2.5">{c.owner.phone ?? ""}</td>
                <td className="px-4 py-2.5">{c.owner.email ?? ""}</td>
                <td className="px-4 py-2.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
                  From the app
                </td>
              </tr>
            )}
            {c.contacts.map((k) => (
              <tr key={k.id} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                <td className="px-4 py-2.5">{labelOf(CONTACT_KINDS, k.kind)}</td>
                <td className="px-4 py-2.5 font-semibold">{k.full_name}</td>
                <td className="px-4 py-2.5">{k.job_title ?? ""}</td>
                <td className="px-4 py-2.5">{k.phone ?? ""}</td>
                <td className="px-4 py-2.5">{k.email ?? ""}</td>
                <td className="whitespace-nowrap px-4 py-2.5 text-right">
                  <button type="button" className="rounded-lg px-2 py-1.5 text-xs font-semibold" style={{ color: "var(--color-brand)" }} onClick={() => edit(k)} disabled={pending}>
                    Change
                  </button>
                  <ConfirmButton question={`Remove ${k.full_name}?`} onConfirm={() => run(removeContact(c.id, k.id))} disabled={pending}>
                    Remove
                  </ConfirmButton>
                </td>
              </tr>
            ))}
            {!c.owner && c.contacts.length === 0 && (
              <tr>
                <td colSpan={6} className="px-4 py-6 text-center" style={{ color: "var(--color-ink-3)" }}>
                  No contacts yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {draft ? (
        <form
          className="card space-y-4 p-5"
          onSubmit={(e) => {
            e.preventDefault();
            run(saveContact({ restaurantId: c.id, ...draft }), () => setDraft(null));
          }}
        >
          <h2 className="font-display text-lg font-bold">{draft.id ? "Change contact" : "New contact"}</h2>
          <div className="grid gap-4 sm:grid-cols-3">
            <Field label="Type" htmlFor="ct-kind">
              <select id="ct-kind" className="field" value={draft.kind} onChange={(e) => set({ kind: e.target.value })}>
                {CONTACT_KINDS.map((k) => (
                  <option key={k.key} value={k.key}>
                    {k.label}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Name" htmlFor="ct-name">
              <input id="ct-name" className="field" value={draft.fullName} maxLength={120} required onChange={(e) => set({ fullName: e.target.value })} />
            </Field>
            <Field label="Position (optional)" htmlFor="ct-title">
              <input id="ct-title" className="field" value={draft.jobTitle} maxLength={120} onChange={(e) => set({ jobTitle: e.target.value })} />
            </Field>
            <Field label="Phone" htmlFor="ct-phone" hint="Phone or email: at least one.">
              <input id="ct-phone" className="field" type="tel" inputMode="tel" value={draft.phone} maxLength={25} onChange={(e) => set({ phone: e.target.value })} />
            </Field>
            <Field label="Email" htmlFor="ct-email">
              <input id="ct-email" className="field" type="email" value={draft.email} maxLength={200} onChange={(e) => set({ email: e.target.value })} />
            </Field>
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <button type="submit" className="btn px-5" style={dark} disabled={pending}>
              {pending ? "Saving…" : "Save contact"}
            </button>
            <button type="button" className="btn px-4" style={ghost} onClick={() => setDraft(null)} disabled={pending}>
              Cancel
            </button>
            <Said msg={msg} />
          </div>
        </form>
      ) : (
        <div className="flex flex-wrap items-center gap-3">
          <button type="button" className="btn px-5" style={dark} onClick={() => setDraft(emptyDraft)}>
            Add a contact
          </button>
          <Said msg={msg} />
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- Notes and follow-up

export function NotesPanel({ c }: { c: Client }) {
  const { pending, msg, run } = useSave();
  const follow = useSave();
  const [kind, setKind] = useState("call");
  const [body, setBody] = useState("");
  const [next, setNext] = useState("");
  const [followDate, setFollowDate] = useState(c.next_contact ?? "");
  const due = !!c.next_contact && c.next_contact <= c.today;

  return (
    <div className="grid gap-4 lg:grid-cols-3">
      <div className="space-y-4 lg:col-span-2">
        <form
          className="card space-y-4 p-5"
          onSubmit={(e) => {
            e.preventDefault();
            run(addNote(c.id, kind, body, next), () => {
              setBody("");
              setNext("");
            });
          }}
        >
          <h2 className="font-display text-lg font-bold">Add a note</h2>
          <div className="grid gap-4 sm:grid-cols-3">
            <Field label="What was it?" htmlFor="nt-kind" hint="Anything but a plain note counts as contact today.">
              <select id="nt-kind" className="field" value={kind} onChange={(e) => setKind(e.target.value)}>
                {NOTE_KINDS.map((k) => (
                  <option key={k.key} value={k.key}>
                    {k.label}
                  </option>
                ))}
              </select>
            </Field>
            <div className="sm:col-span-2">
              <Field label="Next follow-up (optional)" htmlFor="nt-next">
                <input id="nt-next" type="date" className="field" value={next} min={c.today} onChange={(e) => setNext(e.target.value)} />
              </Field>
            </div>
          </div>
          <Field label="Note" htmlFor="nt-body">
            <textarea
              id="nt-body"
              className="field"
              style={{ minHeight: 110, paddingTop: 12, paddingBottom: 12 }}
              value={body}
              maxLength={2000}
              required
              onChange={(e) => setBody(e.target.value)}
              placeholder="What was said, what was agreed, what to do next"
            />
          </Field>
          <div className="flex flex-wrap items-center gap-3">
            <button type="submit" className="btn px-5" style={dark} disabled={pending || body.trim() === ""}>
              {pending ? "Saving…" : "Add"}
            </button>
            <Said msg={msg} />
          </div>
        </form>

        <div className="card p-5">
          <h2 className="font-display text-lg font-bold">Notes</h2>
          <ul className="mt-2 divide-y" style={{ borderColor: "var(--color-line)" }}>
            {c.notes.map((n) => (
              <li key={n.id} className="py-3" style={{ borderColor: "var(--color-line)" }}>
                <div className="flex flex-wrap items-center gap-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                  <span className="rounded-full px-2 py-0.5 font-bold" style={n.kind === "note" ? toneStyle.plain : toneStyle.ok}>
                    {labelOf(NOTE_KINDS, n.kind)}
                  </span>
                  <span>{indiaDateTime(n.created_at)}</span>
                  {n.by && <span>· {n.by}</span>}
                </div>
                <p className="mt-1 whitespace-pre-wrap break-words text-sm">{n.body}</p>
              </li>
            ))}
            {c.notes.length === 0 && (
              <li className="py-3 text-sm" style={{ color: "var(--color-ink-3)" }}>
                Nothing written yet.
              </li>
            )}
          </ul>
          <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Notes are kept as written. To correct one, add a new note.
          </p>
        </div>
      </div>

      <form
        className="card h-fit space-y-4 p-5"
        onSubmit={(e) => {
          e.preventDefault();
          follow.run(setFollowUp(c.id, followDate));
        }}
      >
        <h2 className="font-display text-lg font-bold">Follow-up</h2>
        <dl className="space-y-2 text-sm">
          <div className="flex items-baseline justify-between gap-3">
            <dt style={{ color: "var(--color-ink-3)" }}>Last contact</dt>
            <dd className="font-semibold">{c.last_contact ? shortDate(c.last_contact) : "Never"}</dd>
          </div>
          <div className="flex items-baseline justify-between gap-3">
            <dt style={{ color: "var(--color-ink-3)" }}>Next follow-up</dt>
            <dd className="font-semibold" style={due ? { color: "var(--color-bad)" } : undefined}>
              {c.next_contact ? `${shortDate(c.next_contact)}${due ? " (due)" : ""}` : "None"}
            </dd>
          </div>
        </dl>
        <Field label="Change the follow-up date" htmlFor="fu-date" hint="A call, visit or message clears a follow-up that was due.">
          <input id="fu-date" type="date" className="field" value={followDate} min={c.today} onChange={(e) => setFollowDate(e.target.value)} />
        </Field>
        <div className="flex flex-wrap items-center gap-2">
          <button type="submit" className="btn px-4" style={dark} disabled={follow.pending || followDate === ""}>
            Save date
          </button>
          {c.next_contact && (
            <button
              type="button"
              className="btn px-4"
              style={ghost}
              disabled={follow.pending}
              onClick={() => follow.run(setFollowUp(c.id, ""), () => setFollowDate(""))}
            >
              Clear
            </button>
          )}
        </div>
        <Said msg={follow.msg} />
      </form>
    </div>
  );
}

// ---------------------------------------------------------------- Sales history

export function SalesPanel({ c, extra, canEdit }: { c: Client; extra: SalesExtra; canEdit: boolean }) {
  const { pending, msg, run } = useSave();
  const row = useSave();
  const blank = {
    kind: "new",
    description: "",
    amount: "",
    saleDate: c.today,
    periodFrom: "",
    periodTo: "",
    invoiceNo: "",
    paidOn: "",
    note: "",
    extendLicence: false,
    modules: [] as string[],
    switchOn: true,
  };
  const moduleName = (key: string) => extra.catalog.find((m) => m.key === key)?.name ?? key;
  const toggleModule = (key: string) =>
    setF((x) => {
      const has = x.modules.includes(key);
      // Basic and Professional are one choice: picking one drops the other.
      const rest = x.modules.filter((k) => k !== key && !((key === "basic" && k === "professional") || (key === "professional" && k === "basic")));
      return { ...x, modules: has ? rest : [...rest, key] };
    });
  const [f, setF] = useState(blank);
  const [open, setOpen] = useState(false);
  const [cancelling, setCancelling] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const set = (patch: Partial<typeof blank>) => setF((x) => ({ ...x, ...patch }));
  const licenceKind = f.kind === "new" || f.kind === "renewal";

  return (
    <div className="space-y-4">
      <div className="grid gap-3 sm:grid-cols-3">
        {[
          ["Sold so far", money(Number(c.sales_total), c.currency)],
          ["Not yet paid", money(Number(c.sales_unpaid), c.currency)],
          ["Licence ends", c.licence_expiry ? shortDate(c.licence_expiry) : "Not set"],
        ].map(([k, v]) => (
          <div key={k} className="card p-4">
            <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              {k}
            </div>
            <div className="mt-1 text-xl font-bold tabular-nums">{v}</div>
          </div>
        ))}
      </div>

      {canEdit &&
        (open ? (
          <form
            className="card space-y-4 p-5"
            onSubmit={(e) => {
              e.preventDefault();
              run(addSale({ restaurantId: c.id, ...f }), () => {
                setF(blank);
                setOpen(false);
              });
            }}
          >
            <h2 className="font-display text-lg font-bold">Record a sale</h2>
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="What kind" htmlFor="sl-kind">
                <select id="sl-kind" className="field" value={f.kind} onChange={(e) => set({ kind: e.target.value })}>
                  {SALE_KINDS.map((k) => (
                    <option key={k.key} value={k.key}>
                      {k.label}
                    </option>
                  ))}
                </select>
              </Field>
              <div className="sm:col-span-2">
                <Field label="What was sold" htmlFor="sl-desc">
                  <input id="sl-desc" className="field" value={f.description} maxLength={200} required placeholder="e.g. Professional, 12 months" onChange={(e) => set({ description: e.target.value })} />
                </Field>
              </div>
              <Field label={`Amount (${c.currency})`} htmlFor="sl-amount">
                <input id="sl-amount" className="field" inputMode="decimal" value={f.amount} required onChange={(e) => set({ amount: e.target.value })} />
              </Field>
              <Field label="Sale date" htmlFor="sl-date">
                <input id="sl-date" type="date" className="field" value={f.saleDate} max={c.today} required onChange={(e) => set({ saleDate: e.target.value })} />
              </Field>
              <Field label="Invoice number" htmlFor="sl-inv">
                <input id="sl-inv" className="field" value={f.invoiceNo} maxLength={60} placeholder="As printed on the invoice" onChange={(e) => set({ invoiceNo: e.target.value })} />
              </Field>
              <Field label="Period from (optional)" htmlFor="sl-from">
                <input id="sl-from" type="date" className="field" value={f.periodFrom} onChange={(e) => set({ periodFrom: e.target.value })} />
              </Field>
              <Field label="Period to (optional)" htmlFor="sl-to">
                <input id="sl-to" type="date" className="field" value={f.periodTo} min={f.periodFrom || undefined} onChange={(e) => set({ periodTo: e.target.value })} />
              </Field>
              <Field label="Paid on (leave empty if not paid)" htmlFor="sl-paid">
                <input id="sl-paid" type="date" className="field" value={f.paidOn} max={c.today} onChange={(e) => set({ paidOn: e.target.value })} />
              </Field>
            </div>
            <fieldset>
              <legend className="mb-1 block text-xs font-bold" style={{ color: "var(--color-ink-2)" }}>
                Modules bought on this invoice
              </legend>
              <div className="flex flex-wrap gap-2">
                {extra.catalog.map((m) => {
                  const on = f.modules.includes(m.key);
                  return (
                    <label
                      key={m.key}
                      className="flex min-h-11 cursor-pointer items-center gap-2 rounded-xl px-3 text-sm font-semibold"
                      style={on ? { background: "var(--color-ink)", color: "#fff" } : { background: "var(--color-surface)", border: "1px solid var(--color-line)", color: "var(--color-ink-2)" }}
                    >
                      <input type="checkbox" className="h-4 w-4" checked={on} onChange={() => toggleModule(m.key)} />
                      {m.name}
                      {m.on && <span className="text-[11px] font-normal">(has it)</span>}
                    </label>
                  );
                })}
              </div>
              {f.modules.length > 0 && (
                <label className="mt-3 flex items-start gap-3 text-sm">
                  <input type="checkbox" className="mt-1 h-5 w-5" checked={f.switchOn} onChange={(e) => set({ switchOn: e.target.checked })} />
                  <span>
                    <b>Switch these on for the client now.</b>{" "}
                    <span style={{ color: "var(--color-ink-3)" }}>Professional edition and add-ons are switched on. Nothing is ever switched off from a sale.</span>
                  </span>
                </label>
              )}
            </fieldset>
            <Field label="Note (optional)" htmlFor="sl-note">
              <input id="sl-note" className="field" value={f.note} maxLength={500} onChange={(e) => set({ note: e.target.value })} />
            </Field>
            <label className="flex items-start gap-3 text-sm">
              <input type="checkbox" className="mt-1 h-5 w-5" checked={f.extendLicence} onChange={(e) => set({ extendLicence: e.target.checked })} />
              <span>
                <b>Move the licence end date to &ldquo;Period to&rdquo;.</b>{" "}
                <span style={{ color: "var(--color-ink-3)" }}>
                  {licenceKind ? "Tick this for a new licence or a renewal: the restaurant works until that date, and the reminder starts again 15 days before it." : "Usually left off for add-ons, hardware and services."}
                </span>
              </span>
            </label>
            <div className="flex flex-wrap items-center gap-3">
              <button type="submit" className="btn px-5" style={dark} disabled={pending}>
                {pending ? "Saving…" : "Save sale"}
              </button>
              <button type="button" className="btn px-4" style={ghost} onClick={() => setOpen(false)} disabled={pending}>
                Cancel
              </button>
              <Said msg={msg} />
            </div>
          </form>
        ) : (
          <div className="flex flex-wrap items-center gap-3">
            <button type="button" className="btn px-5" style={dark} onClick={() => setOpen(true)}>
              Record a sale
            </button>
            <Said msg={msg} />
          </div>
        ))}

      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left" style={{ color: "var(--color-ink-3)" }}>
              <th className="px-4 py-2">Date</th>
              <th className="px-4 py-2">Invoice</th>
              <th className="px-4 py-2">What and modules</th>
              <th className="px-4 py-2">Period</th>
              <th className="px-4 py-2 text-right">Amount</th>
              <th className="px-4 py-2">Paid</th>
              <th className="px-4 py-2">
                <span className="sr-only">Actions</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {c.sales.map((s) => (
              <tr key={s.id} className="border-t align-top" style={{ borderColor: "var(--color-line)", opacity: s.cancelled ? 0.6 : 1 }}>
                <td className="whitespace-nowrap px-4 py-2.5">{shortDate(s.sale_date)}</td>
                <td className="whitespace-nowrap px-4 py-2.5 font-semibold">{s.invoice_no ?? <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>No invoice</span>}</td>
                <td className="px-4 py-2.5">
                  <div className="font-semibold" style={s.cancelled ? { textDecoration: "line-through" } : undefined}>
                    {s.description}
                  </div>
                  <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                    {labelOf(SALE_KINDS, s.kind)}
                    {s.by ? ` · ${s.by}` : ""}
                    {s.note ? ` · ${s.note}` : ""}
                  </div>
                  {(extra.modules[s.id] ?? []).length > 0 && (
                    <div className="mt-1 flex flex-wrap gap-1">
                      {(extra.modules[s.id] ?? []).map((k) => (
                        <span key={k} className="rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle.plain}>
                          {moduleName(k)}
                        </span>
                      ))}
                    </div>
                  )}
                  {s.cancelled && (
                    <div className="text-xs font-semibold" style={{ color: "var(--color-bad)" }}>
                      Cancelled: {s.cancel_reason}
                    </div>
                  )}
                </td>
                <td className="whitespace-nowrap px-4 py-2.5">
                  {s.period_from || s.period_to ? `${s.period_from ? shortDate(s.period_from) : "…"} to ${s.period_to ? shortDate(s.period_to) : "…"}` : ""}
                </td>
                <td className="whitespace-nowrap px-4 py-2.5 text-right tabular-nums" style={s.cancelled ? { textDecoration: "line-through" } : undefined}>
                  {money(Number(s.amount), s.currency)}
                </td>
                <td className="whitespace-nowrap px-4 py-2.5">
                  {s.cancelled ? (
                    ""
                  ) : s.paid_on ? (
                    <span className="rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle.ok}>
                      Paid {shortDate(s.paid_on)}
                    </span>
                  ) : (
                    <span className="rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle.warn}>
                      Not paid
                    </span>
                  )}
                </td>
                <td className="px-4 py-2.5 text-right">
                  {canEdit && !s.cancelled && (
                    <div className="flex flex-wrap justify-end gap-1">
                      <button
                        type="button"
                        className="rounded-lg px-2 py-1.5 text-xs font-semibold"
                        style={{ color: "var(--color-brand)" }}
                        disabled={row.pending}
                        onClick={() => row.run(setSalePaid(c.id, s.id, s.paid_on ? "" : c.today))}
                      >
                        {s.paid_on ? "Mark not paid" : "Mark paid today"}
                      </button>
                      <button
                        type="button"
                        className="rounded-lg px-2 py-1.5 text-xs font-semibold"
                        style={{ color: "var(--color-bad)" }}
                        disabled={row.pending}
                        onClick={() => {
                          setCancelling(cancelling === s.id ? null : s.id);
                          setReason("");
                        }}
                      >
                        Cancel entry
                      </button>
                    </div>
                  )}
                  {cancelling === s.id && (
                    <form
                      className="mt-2 flex flex-wrap justify-end gap-2"
                      onSubmit={(e) => {
                        e.preventDefault();
                        row.run(cancelSale(c.id, s.id, reason), () => setCancelling(null));
                      }}
                    >
                      <label htmlFor={`why-${s.id}`} className="sr-only">
                        Reason for cancelling
                      </label>
                      <input id={`why-${s.id}`} className="field h-10 w-56" style={{ minHeight: 40 }} placeholder="Reason, e.g. entered twice" value={reason} maxLength={300} required onChange={(e) => setReason(e.target.value)} />
                      <button type="submit" className="btn h-10 min-h-0 px-3 text-xs" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }} disabled={row.pending || reason.trim().length < 3}>
                        Cancel this entry
                      </button>
                    </form>
                  )}
                </td>
              </tr>
            ))}
            {c.sales.length === 0 && (
              <tr>
                <td colSpan={7} className="px-4 py-6 text-center" style={{ color: "var(--color-ink-3)" }}>
                  Nothing sold yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      <Said msg={row.msg} />
      <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
        Each line is one invoice SNA raised, with the modules bought on it. The invoice itself is made outside SNA POS; this is the record of it. A wrong entry
        is cancelled with a reason and stays in the list. Cancelling does not move the licence end date back or switch anything off.
        {!canEdit && " Only Sales and Admin can record sales."}
      </p>
    </div>
  );
}
