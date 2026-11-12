"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import type { RightGroup } from "@/lib/permissions";
import { ConfirmButton } from "../confirm-button";
import { copyRoleRights, deleteRole, saveRole } from "./actions";

type RoleView = { id: string; name: string; locked: boolean; people: number; rights: string[] };

export function SecurityEditor({ isOwner, groups, roles }: { isOwner: boolean; groups: RightGroup[]; roles: RoleView[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [selectedId, setSelectedId] = useState<string | null>(roles.find((r) => !r.locked)?.id ?? roles[0]?.id ?? null);
  const [creating, setCreating] = useState(false);
  const selected = creating ? null : roles.find((r) => r.id === selectedId) ?? null;

  const [name, setName] = useState(selected?.name ?? "");
  const [ticked, setTicked] = useState<Set<string>>(new Set(selected?.rights ?? []));
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  // "Start from a copy of..." (new profile) and "Copy rights from..." (existing profile)
  const [copyFrom, setCopyFrom] = useState("");
  const [copyMode, setCopyMode] = useState<"add" | "replace">("add");

  const allKeys = groups.flatMap((g) => g.rights.map((r) => r.key));
  const locked = !!selected?.locked;
  const readOnly = !isOwner || locked;
  const dirty =
    creating ||
    (selected !== null && (name.trim() !== selected.name || ticked.size !== selected.rights.length || selected.rights.some((k) => !ticked.has(k))));

  function open(r: RoleView) {
    setCreating(false);
    setSelectedId(r.id);
    setName(r.name);
    setTicked(new Set(r.rights));
    setConfirmDelete(false);
    setMessage(null);
    setCopyFrom("");
  }
  function startNew() {
    setCreating(true);
    setSelectedId(null);
    setName("");
    setTicked(new Set(["order.create"]));
    setConfirmDelete(false);
    setMessage(null);
    setCopyFrom("");
  }
  /** The rights a profile effectively has (the Owner always has them all). */
  function rightsOf(r: RoleView): string[] {
    return r.locked ? allKeys : r.rights;
  }
  /** New profile: tick the boxes of the chosen profile as a starting point. Nothing is saved until "Create profile". */
  function startFromCopy(id: string) {
    setCopyFrom(id);
    const src = roles.find((r) => r.id === id);
    if (src) setTicked(new Set(rightsOf(src)));
    else setTicked(new Set(["order.create"]));
  }
  /** Existing profile: copy another profile's rights into it right now (saved in the database, audited). */
  function applyCopy() {
    if (!selected || !copyFrom) return;
    const src = roles.find((r) => r.id === copyFrom);
    if (!src) return;
    setMessage(null);
    start(async () => {
      const res = await copyRoleRights(src.id, selected.id, copyMode);
      if (!res.ok) {
        setMessage({ ok: false, text: res.error });
        return;
      }
      setTicked(new Set(copyMode === "replace" ? rightsOf(src) : [...selected.rights, ...rightsOf(src)]));
      setCopyFrom("");
      const bits = [`${res.added.length} added`, copyMode === "replace" ? `${res.removed.length} removed` : null].filter(Boolean).join(", ");
      setMessage({ ok: true, text: `Copied from ${src.name} (${bits}). ${selected.name} now has ${res.total} rights.` });
      router.refresh();
    });
  }
  function toggle(key: string) {
    if (readOnly) return;
    setTicked((s) => {
      const n = new Set(s);
      if (n.has(key)) n.delete(key);
      else n.add(key);
      return n;
    });
  }
  function toggleGroup(g: RightGroup) {
    if (readOnly) return;
    const keys = g.rights.map((r) => r.key);
    const allOn = keys.every((k) => ticked.has(k));
    setTicked((s) => {
      const n = new Set(s);
      for (const k of keys) {
        if (allOn) n.delete(k);
        else n.add(k);
      }
      return n;
    });
  }
  function save() {
    setMessage(null);
    start(async () => {
      const res = await saveRole(creating ? null : selectedId, name, [...ticked]);
      if (!res.ok) {
        setMessage({ ok: false, text: res.error });
        return;
      }
      setCreating(false);
      if (res.id) setSelectedId(res.id);
      setMessage({ ok: true, text: "Saved. People with this role get the new rights straight away." });
      router.refresh();
    });
  }
  function remove() {
    if (!selected) return;
    setMessage(null);
    start(async () => {
      const res = await deleteRole(selected.id);
      if (!res.ok) {
        setMessage({ ok: false, text: res.error });
        return;
      }
      const next = roles.find((r) => r.id !== selected.id && !r.locked) ?? roles.find((r) => r.id !== selected.id);
      setConfirmDelete(false);
      if (next) open(next);
      setMessage({ ok: true, text: "Profile removed." });
      router.refresh();
    });
  }

  const shownRights = locked ? new Set(allKeys) : ticked;

  return (
    <div className="flex flex-col gap-4 lg:flex-row lg:items-start">
      <div className="card flex flex-col gap-1 p-2 lg:w-64 lg:shrink-0">
        {roles.map((r) => {
          const on = !creating && r.id === selectedId;
          return (
            <button
              key={r.id}
              type="button"
              onClick={() => open(r)}
              className="flex min-h-[60px] items-center justify-between rounded-2xl px-3.5 text-left"
              style={on ? { background: "var(--color-brand)", color: "#fff" } : { color: "var(--color-ink)" }}
            >
              <span className="flex flex-col">
                <span className="text-[15px] font-bold">{r.name}</span>
                <span className="text-xs" style={{ color: on ? "rgba(255,255,255,0.78)" : "var(--color-ink-3)" }}>
                  {r.people} {r.people === 1 ? "person" : "people"}
                </span>
              </span>
              <span className="text-xs font-bold">{r.locked ? "All rights" : `${r.rights.length} rights`}</span>
            </button>
          );
        })}
        {isOwner && (
          <button
            type="button"
            onClick={startNew}
            className="mt-1 min-h-12 rounded-2xl border-[1.5px] border-dashed text-sm font-bold"
            style={
              creating
                ? { borderColor: "var(--color-brand)", color: "var(--color-brand)", background: "var(--color-brand-soft)" }
                : { borderColor: "var(--color-line)", color: "var(--color-ink-3)" }
            }
          >
            + New profile
          </button>
        )}
      </div>

      <div className="card min-w-0 flex-1 p-5">
        {!selected && !creating ? (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            Choose a profile on the left.
          </p>
        ) : (
          <>
            <div className="mb-4 flex flex-wrap items-end gap-3">
              <label className="flex min-w-[220px] flex-1 flex-col gap-1.5 text-sm font-bold">
                Profile name
                <input
                  className="field"
                  value={name}
                  maxLength={40}
                  onChange={(e) => setName(e.target.value)}
                  disabled={readOnly}
                  placeholder="e.g. Captain, Head cashier"
                />
              </label>
              {!readOnly && (
                <button type="button" className="btn btn-pay" onClick={save} disabled={pending || !dirty || !name.trim()}>
                  {pending ? "Saving…" : creating ? "Create profile" : "Save changes"}
                </button>
              )}
            </div>

            {creating && isOwner && (
              <label className="mb-4 flex flex-col gap-1.5 text-sm font-bold">
                Start from a copy of…
                <select className="field max-w-xs" value={copyFrom} onChange={(e) => startFromCopy(e.target.value)}>
                  <option value="">Nothing (start empty)</option>
                  {roles.map((r) => (
                    <option key={r.id} value={r.id}>
                      {r.name}
                    </option>
                  ))}
                </select>
                <span className="text-xs font-medium" style={{ color: "var(--color-ink-3)" }}>
                  Ticks the same rights as that profile. You can change them before you create the profile.
                </span>
              </label>
            )}

            {!creating && isOwner && !locked && selected && (
              <div className="mb-4 flex flex-wrap items-end gap-3 rounded-2xl border p-3" style={{ borderColor: "var(--color-line)" }}>
                <label className="flex min-w-[200px] flex-col gap-1.5 text-sm font-bold">
                  Copy rights from…
                  <select className="field" value={copyFrom} onChange={(e) => setCopyFrom(e.target.value)} disabled={dirty || pending}>
                    <option value="">Choose a profile</option>
                    {roles
                      .filter((r) => r.id !== selected.id)
                      .map((r) => (
                        <option key={r.id} value={r.id}>
                          {r.name}
                        </option>
                      ))}
                  </select>
                </label>
                <div className="flex gap-2" role="radiogroup" aria-label="How to copy">
                  {(
                    [
                      ["add", "Add to what it has"],
                      ["replace", "Replace all"],
                    ] as const
                  ).map(([k, label]) => (
                    <button
                      key={k}
                      type="button"
                      role="radio"
                      aria-checked={copyMode === k}
                      onClick={() => setCopyMode(k)}
                      className="min-h-11 rounded-2xl border px-3 text-sm font-bold"
                      style={copyMode === k ? { background: "var(--color-brand)", color: "#fff", borderColor: "var(--color-brand)" } : { borderColor: "var(--color-line)", color: "var(--color-ink-2)" }}
                    >
                      {label}
                    </button>
                  ))}
                </div>
                {copyMode === "replace" ? (
                  <ConfirmButton
                    className="btn border text-sm"
                    style={{ borderColor: "var(--color-line)" }}
                    question={`Replace all rights of ${selected.name}?`}
                    yesLabel="Yes, replace"
                    noLabel="Keep"
                    tone="plain"
                    disabled={!copyFrom || dirty || pending}
                    onConfirm={applyCopy}
                  >
                    Copy
                  </ConfirmButton>
                ) : (
                  <button type="button" className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} disabled={!copyFrom || dirty || pending} onClick={applyCopy}>
                    Copy
                  </button>
                )}
                {dirty && (
                  <span className="basis-full text-xs" style={{ color: "var(--color-ink-3)" }}>
                    Save your changes first, then copy.
                  </span>
                )}
              </div>
            )}

            {locked && (
              <p className="mb-4 rounded-2xl px-4 py-3 text-sm" style={{ background: "var(--color-ground)", color: "var(--color-ink-2)" }}>
                The Owner always has every right. This cannot be changed, so the restaurant can never be locked out.
              </p>
            )}
            {!isOwner && !locked && (
              <p className="mb-4 rounded-2xl px-4 py-3 text-sm" style={{ background: "var(--color-ground)", color: "var(--color-ink-2)" }}>
                Only the owner can change profiles. You can see what each one allows.
              </p>
            )}

            <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
              {groups.map((g) => {
                const allOn = g.rights.every((r) => shownRights.has(r.key));
                return (
                  <fieldset key={g.name} className="rounded-2xl border p-3.5" style={{ borderColor: "var(--color-line)", background: "var(--color-surface-2)" }}>
                    <legend className="sr-only">{g.name}</legend>
                    <div className="mb-1 flex items-center justify-between">
                      <span className="text-xs font-extrabold uppercase tracking-wider" style={{ color: "var(--color-ink-3)" }}>
                        {g.name}
                      </span>
                      {!readOnly && (
                        <button type="button" onClick={() => toggleGroup(g)} className="min-h-9 rounded-lg px-2 text-xs font-bold" style={{ color: "var(--color-brand)" }}>
                          {allOn ? "Untick all" : "Tick all"}
                        </button>
                      )}
                    </div>
                    {g.rights.map((r) => {
                      const on = shownRights.has(r.key);
                      return (
                        <label key={r.key} className={`flex min-h-11 items-start gap-3 py-2 text-sm font-semibold ${readOnly ? "" : "cursor-pointer"}`}>
                          <input type="checkbox" className="peer sr-only" checked={on} onChange={() => toggle(r.key)} disabled={readOnly} />
                          <span
                            aria-hidden="true"
                            className="grid h-6 w-6 shrink-0 place-items-center rounded-lg peer-focus-visible:ring-2"
                            style={on ? { background: "var(--color-brand)" } : { background: "#fff", border: "1.5px solid #CDBFA6" }}
                          >
                            {on && (
                              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="3" strokeLinecap="round">
                                <path d="M5 12l5 5 9-10" />
                              </svg>
                            )}
                          </span>
                          <span className="flex flex-col">
                            {r.label}
                            {r.hint && (
                              <span className="text-xs font-medium" style={{ color: "var(--color-ink-3)" }}>
                                {r.hint}
                              </span>
                            )}
                          </span>
                        </label>
                      );
                    })}
                  </fieldset>
                );
              })}
            </div>

            {message && (
              <p
                className="mt-4 rounded-2xl px-4 py-3 text-sm"
                role={message.ok ? "status" : "alert"}
                style={message.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad)" }}
              >
                {message.text}
              </p>
            )}

            {isOwner && selected && !locked && (
              <div className="mt-6 border-t pt-4" style={{ borderColor: "var(--color-line)" }}>
                {confirmDelete ? (
                  <div className="flex flex-wrap items-center gap-3">
                    <span className="text-sm font-semibold">Remove the profile &ldquo;{selected.name}&rdquo;?</span>
                    <button type="button" className="btn text-sm" style={{ background: "var(--color-bad)", color: "#fff" }} onClick={remove} disabled={pending}>
                      Yes, remove
                    </button>
                    <button type="button" className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setConfirmDelete(false)}>
                      Keep it
                    </button>
                  </div>
                ) : (
                  <button type="button" className="text-sm font-bold" style={{ color: "var(--color-bad)" }} onClick={() => setConfirmDelete(true)}>
                    Remove this profile
                  </button>
                )}
                {selected.people > 0 && (
                  <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                    {selected.people} {selected.people === 1 ? "person has" : "people have"} this role. Move them to another role on the Users page first.
                  </p>
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
