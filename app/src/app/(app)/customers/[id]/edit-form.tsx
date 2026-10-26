"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ApprovalPrompt, cleanMessage, neededRight } from "../../approval";
import { ConfirmButton } from "../../settings/confirm-button";
import { forgetCustomer, updateCustomer } from "../actions";

type Customer = { id: string; name: string; email: string; notes: string; birthday: string; consent: boolean; consentGivenAt: string | null };

/** Profile form. Phone is not editable (it is how the guest is found on a bill). Without customer.manage the form is read-only. */
export function EditForm({ customer, canEdit, today, hasAccountBalance }: { customer: Customer; canEdit: boolean; today: string; hasAccountBalance: boolean }) {
  const router = useRouter();
  const [name, setName] = useState(customer.name);
  const [email, setEmail] = useState(customer.email);
  const [notes, setNotes] = useState(customer.notes);
  const [birthday, setBirthday] = useState(customer.birthday);
  const [consent, setConsent] = useState(customer.consent);
  const [reason, setReason] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [approval, setApproval] = useState<{ permission: string } | null>(null);
  const [pending, start] = useTransition();

  const dirty = name !== customer.name || email !== customer.email || notes !== customer.notes || birthday !== customer.birthday || consent !== customer.consent;

  function save() {
    setMsg(null);
    start(async () => {
      const r = await updateCustomer(customer.id, { name, email, notes, birthday, consent });
      setMsg(r.ok ? { ok: true, text: r.message } : { ok: false, text: r.error });
      if (r.ok) router.refresh();
    });
  }

  function forget() {
    setMsg(null);
    start(async () => {
      const r = await forgetCustomer(customer.id, reason);
      if (!r.ok) {
        const need = neededRight(r.error);
        if (need) setApproval({ permission: need });
        setMsg({ ok: false, text: cleanMessage(r.error) });
        return;
      }
      setMsg({ ok: true, text: r.message });
      router.refresh();
    });
  }

  return (
    <section className="card space-y-3 p-4">
      {approval && (
        <ApprovalPrompt
          permission={approval.permission}
          onCancel={() => setApproval(null)}
          onApproved={() => {
            setApproval(null);
            forget();
          }}
        />
      )}
      <h2 className="text-sm font-bold">Guest details</h2>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block text-sm">
          <span className="mb-1 block font-semibold">Name</span>
          <input className="field" value={name} maxLength={80} disabled={!canEdit} onChange={(e) => setName(e.target.value)} />
        </label>
        <label className="block text-sm">
          <span className="mb-1 block font-semibold">Email (optional)</span>
          <input className="field" type="email" value={email} maxLength={120} disabled={!canEdit} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label className="block text-sm">
          <span className="mb-1 block font-semibold">Birthday (optional)</span>
          <input className="field" type="date" value={birthday} max={today} disabled={!canEdit} onChange={(e) => setBirthday(e.target.value)} />
        </label>
        <label className="block text-sm sm:col-span-2">
          <span className="mb-1 block font-semibold">Notes (optional)</span>
          <textarea className="field" rows={2} value={notes} maxLength={500} disabled={!canEdit} onChange={(e) => setNotes(e.target.value)} />
        </label>
      </div>
      <label className="flex items-start gap-2 text-sm">
        <input type="checkbox" className="mt-1" checked={consent} disabled={!canEdit} onChange={(e) => setConsent(e.target.checked)} />
        <span>
          <span className="font-semibold">Guest agreed to receive offers</span>
          {customer.consentGivenAt && customer.consent && (
            <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>Agreed on {new Date(customer.consentGivenAt).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</span>
          )}
          <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>Tick only when the guest said yes to offers and messages.</span>
        </span>
      </label>
      {canEdit && (
        <div className="flex flex-wrap items-center gap-3">
          <button className="btn btn-primary" disabled={pending || !dirty} onClick={save}>Save guest</button>
          {msg && <p role="status" className="text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>{msg.text}</p>}
        </div>
      )}
      {!canEdit && <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>Your role can see this guest but not change it.</p>}

      {canEdit && (
        <div className="space-y-2 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
          <h3 className="text-sm font-bold">Delete guest data</h3>
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            For a guest who asks us to erase their data. The name, phone, email, birthday and notes are removed from the guest and from their bills, and any points are cleared.
            Bill amounts and reports stay. This cannot be undone.
            {hasAccountBalance ? " This guest owes money on a credit account: settle it first, or the delete is refused." : ""}
          </p>
          <div className="flex flex-wrap items-center gap-2">
            <input className="field max-w-xs" placeholder="Reason (required)" aria-label="Reason for deleting the guest data" maxLength={200} value={reason} onChange={(e) => setReason(e.target.value)} />
            <ConfirmButton question={`Delete the data of ${customer.name}?`} yesLabel="Yes, delete" disabled={pending || reason.trim().length < 3} onConfirm={forget} className="rounded-lg border px-3 py-2 text-xs font-semibold">
              Delete guest data
            </ConfirmButton>
          </div>
        </div>
      )}
    </section>
  );
}
