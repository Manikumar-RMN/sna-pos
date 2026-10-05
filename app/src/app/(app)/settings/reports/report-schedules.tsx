"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { dateTime, longDate } from "@/lib/format";
import { ConfirmButton } from "../confirm-button";
import { removeReportSchedule, saveReportSchedule, sendReportNow, setReportScheduleActive } from "./actions";

export type Schedule = {
  id: string;
  /** "HH:MM" on the outlet's clock. */
  time: string;
  /** 1 = Monday … 7 = Sunday. */
  days: number[];
  emails: string[];
  phone_alert: boolean;
  active: boolean;
  last_sent_at: string | null;
  last_for_date: string | null;
  last_result: string | null;
  last_email_result: string | null;
  /** Why a send did not happen (missed, limit reached, error, email refused), and when. */
  last_problem: string | null;
  last_problem_at: string | null;
  /** The email was handed over a while ago and the email service never answered. Worked out on the server. */
  unconfirmed: boolean;
};

/** "off": no email service yet. "trial": it only delivers to the email account's own address. "on": working. */
export type EmailMode = "off" | "trial" | "on";

type Draft = { id: string | null; time: string; days: number[]; emails: string[]; entry: string; phoneAlert: boolean; active: boolean };
type Note = { ok: boolean; text: string };

const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const EVERY_DAY = [1, 2, 3, 4, 5, 6, 7];
const MAX_EMAILS = 5;
const MAX_SCHEDULES = 5;
// The same rule the database uses.
const EMAIL = /^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/;
const isTime = (v: string) => /^([01]\d|2[0-3]):[0-5]\d$/.test(v);

const minutes = (hhmm: string) => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3, 5));

/** "23:30" → "11:30 pm". */
function clock(hhmm: string): string {
  const h = Number(hhmm.slice(0, 2));
  return `${((h + 11) % 12) + 1}:${hhmm.slice(3, 5)} ${h < 12 ? "am" : "pm"}`;
}

function daysLabel(days: number[]): string {
  const d = [...days].sort((a, b) => a - b);
  if (d.length === 7) return "Every day";
  const run = d.length > 2 && d.every((x, i) => i === 0 || x === d[i - 1] + 1);
  return run ? `${DAYS[d[0] - 1]} to ${DAYS[d[d.length - 1] - 1]}` : d.map((x) => DAYS[x - 1]).join(", ");
}

/**
 * Which day's figures a send at this time carries. The database decides the same way
 * (app.report_day_back): in the 12 hours after the business day ends it is the day that has
 * just ended; later it is the day still running, which after midnight is the one about to end.
 */
function about(time: string, cutoff: string): "day_before" | "ending_night" | "same_day" {
  if ((minutes(time) - minutes(cutoff) + 1440) % 1440 < 720) return "day_before";
  return minutes(time) < minutes(cutoff) ? "ending_night" : "same_day";
}

/** What the last send (or the last attempt) came to, and whether it is bad news. */
function lastOutcome(s: Schedule, timezone: string): { text: string; bad: boolean } {
  const problemIsNewer = !!s.last_problem_at && (!s.last_sent_at || Date.parse(s.last_problem_at) >= Date.parse(s.last_sent_at));
  // The app reporting that the email service refused the email leaves exactly this note (public.report_sent).
  const emailRefused = problemIsNewer && s.last_problem === "The email was not sent." && !!s.last_sent_at && !!s.last_email_result;
  // It never went out: missed, a limit, or an error.
  if (problemIsNewer && !emailRefused) return { text: `${dateTime(s.last_problem_at, timezone)}: ${s.last_problem ?? "Not sent."}`, bad: true };
  if (!s.last_sent_at) return { text: "Not sent yet.", bad: false };
  const when = `Last sent ${dateTime(s.last_sent_at, timezone)}${s.last_for_date ? ` (figures of ${longDate(s.last_for_date)})` : ""}: `;
  // The database first notes "email on its way"; a few seconds later the app reports what the email service said.
  if (s.last_email_result) {
    const phone = s.phone_alert && (s.last_result ?? "").startsWith("Phone alert sent") ? "Phone alert sent. " : "";
    return { text: when + phone + s.last_email_result, bad: emailRefused };
  }
  if (s.unconfirmed) return { text: `${when}${s.last_result ?? ""} The email service has not confirmed it. Send a test to check.`, bad: true };
  return { text: when + (s.last_result ?? ""), bad: /could not be sent|nothing was sent/i.test(s.last_result ?? "") };
}

function Msg({ m }: { m: Note | null }) {
  if (!m) return null;
  return (
    <p role={m.ok ? "status" : "alert"} className="text-sm font-semibold" style={{ color: m.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
      {m.text}
    </p>
  );
}

export function ReportSchedules({
  schedules,
  cutoff,
  timezone,
  phoneAlertAvailable,
  emailMode,
  outletName,
}: {
  schedules: Schedule[];
  /** When the business day ends, "HH:MM". */
  cutoff: string;
  timezone: string;
  /** The Owner mobile app module is on. */
  phoneAlertAvailable: boolean;
  emailMode: EmailMode;
  /** Set when the restaurant has several outlets: schedules belong to the outlet in use. */
  outletName: string | null;
}) {
  const router = useRouter();
  const [draft, setDraft] = useState<Draft | null>(null);
  const [formNote, setFormNote] = useState<Note | null>(null);
  const [rowNote, setRowNote] = useState<{ id: string; note: Note } | null>(null);
  const [pending, start] = useTransition();
  // The email result arrives a few seconds after a test; look once more then.
  const later = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(
    () => () => {
      if (later.current) clearTimeout(later.current);
    },
    [],
  );

  // The form opens under the list: bring it into view and put the cursor in it, or on a phone nothing seems to happen.
  const form = useRef<HTMLElement | null>(null);
  const timeInput = useRef<HTMLInputElement | null>(null);
  const formKey = draft ? (draft.id ?? "new") : null;
  useEffect(() => {
    if (!formKey) return;
    form.current?.scrollIntoView({ block: "nearest", behavior: "smooth" });
    timeInput.current?.focus({ preventScroll: true });
  }, [formKey]);

  const blank = (): Draft => ({ id: null, time: "23:30", days: EVERY_DAY, emails: [], entry: "", phoneAlert: false, active: true });
  const edit = (s: Schedule): Draft => ({ id: s.id, time: s.time, days: s.days, emails: s.emails, entry: "", phoneAlert: s.phone_alert, active: s.active });

  function open(d: Draft) {
    setFormNote(null);
    setRowNote(null);
    setDraft(d);
  }

  /** Moves what is typed in the box into the list. Returns the new list, or null (with a message) when something is wrong. */
  function withEntry(d: Draft): string[] | null {
    const typed = d.entry
      .split(/[\s,;]+/)
      .map((x) => x.trim().toLowerCase())
      .filter(Boolean);
    const bad = typed.find((x) => x.length > 254 || !EMAIL.test(x));
    if (bad) {
      setFormNote({ ok: false, text: `"${bad.slice(0, 80)}" does not look like an email address.` });
      return null;
    }
    const all = [...new Set([...d.emails, ...typed])];
    if (all.length > MAX_EMAILS) {
      setFormNote({ ok: false, text: `A schedule can go to ${MAX_EMAILS} email addresses at most. Add another schedule for more.` });
      return null;
    }
    return all;
  }

  function addEntry() {
    if (!draft) return;
    const all = withEntry(draft);
    if (!all) return;
    setFormNote(null);
    setDraft({ ...draft, emails: all, entry: "" });
  }

  function save() {
    if (!draft || pending) return;
    // An address typed but not yet added is taken along, so pressing Save straight away does not lose it.
    const emails = withEntry(draft);
    if (!emails) return;
    if (!isTime(draft.time)) return setFormNote({ ok: false, text: "Choose the time to send the summary." });
    if (draft.days.length === 0) return setFormNote({ ok: false, text: "Choose at least one day of the week." });
    if (emails.length === 0 && !draft.phoneAlert) return setFormNote({ ok: false, text: "Add at least one email address, or tick the phone alert." });
    const sending = { id: draft.id, input: { time: draft.time, days: draft.days, emails, phoneAlert: draft.phoneAlert, active: draft.active } };
    start(async () => {
      const r = await saveReportSchedule(sending.id, sending.input);
      if (!r.ok) return setFormNote({ ok: false, text: r.error });
      setFormNote(null);
      setDraft(null);
      router.refresh();
    });
  }

  function act(id: string, run: () => Promise<{ ok: true; message?: string } | { ok: false; error: string }>, refreshLater = false) {
    if (pending) return;
    start(async () => {
      const r = await run();
      setRowNote({ id, note: r.ok ? { ok: true, text: r.message ?? "Done." } : { ok: false, text: r.error } });
      router.refresh();
      if (r.ok && refreshLater) {
        if (later.current) clearTimeout(later.current);
        later.current = setTimeout(() => router.refresh(), 6000);
      }
    });
  }

  const d = draft;
  const busy = pending || !!d;
  const small = "min-h-9 rounded-lg border px-3 text-xs font-bold";
  const smallStyle = { borderColor: "var(--color-line)", color: "var(--color-ink-2)" };

  return (
    <>
      {emailMode === "off" && (
        <div className="card p-4 text-sm" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }} role="status">
          <b>Email is not switched on for SNA POS yet.</b> You can set everything up now; the emails start going out as soon as it is switched
          on. Phone alerts already work.
        </div>
      )}
      {emailMode === "trial" && (
        <div className="card p-4 text-sm" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }} role="status">
          <b>Email is in trial mode.</b> For now it only reaches the address the SNA POS email account was opened with; other addresses are
          refused until SNA adds its own sending address.
        </div>
      )}

      <section className="card space-y-3 p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-base font-bold">{outletName ? `Schedules for ${outletName}` : "Schedules"}</h2>
          {!d && (
            <button className="btn btn-primary" disabled={pending || schedules.length >= MAX_SCHEDULES} onClick={() => open(blank())}>
              + Add a schedule
            </button>
          )}
        </div>
        {outletName && (
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Each outlet has its own schedules and sends its own figures. Switch outlet at the top to set up another one.
          </p>
        )}

        {schedules.length === 0 && !d && (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            Nothing is sent yet. Add a schedule: choose a time, the days, and who should get it.
          </p>
        )}

        <ul className="space-y-2">
          {schedules.map((s) => {
            const editing = d?.id === s.id;
            const what = about(s.time, cutoff);
            const last = lastOutcome(s, timezone);
            const people = s.emails.length + (s.phone_alert ? 1 : 0);
            return (
              <li key={s.id} className="rounded-xl border p-3" style={{ borderColor: "var(--color-line)" }}>
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0" style={{ opacity: s.active || editing ? 1 : 0.65 }}>
                    <div className="text-base font-bold">
                      {clock(s.time)}{" "}
                      <span className="font-semibold" style={{ color: "var(--color-ink-2)" }}>
                        · {daysLabel(s.days)}
                      </span>
                      {!s.active && (
                        <span className="ml-2 rounded-md px-1.5 py-0.5 text-xs font-bold" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
                          Switched off
                        </span>
                      )}
                    </div>
                    <div className="break-words text-sm" style={{ color: "var(--color-ink-2)" }}>
                      To: {[...s.emails, ...(s.phone_alert ? ["phone alert"] : [])].join(", ")}
                    </div>
                    <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                      {what === "day_before"
                        ? "Carries the complete figures of the day before."
                        : what === "ending_night"
                          ? "Carries the figures of the business day that is about to end, up to the time it is sent."
                          : "Carries that day's figures up to the time it is sent."}
                    </div>
                    <div className="mt-1 text-xs font-semibold" style={{ color: last.bad ? "var(--color-bad)" : "var(--color-ink-3)" }}>
                      {last.text}
                    </div>
                  </div>
                  {!editing && (
                    <div className="flex flex-wrap items-center gap-1.5">
                      <ConfirmButton
                        className={small}
                        style={smallStyle}
                        tone="plain"
                        question={`Send a test to ${people === 1 ? "1 person" : `all ${people}`} now?`}
                        yesLabel="Yes, send"
                        noLabel="Not now"
                        disabled={busy}
                        onConfirm={() => act(s.id, () => sendReportNow(s.id), true)}
                      >
                        Send a test now
                      </ConfirmButton>
                      <button className={small} style={smallStyle} disabled={busy} onClick={() => act(s.id, () => setReportScheduleActive(s.id, !s.active))}>
                        {s.active ? "Switch off" : "Switch on"}
                      </button>
                      <button className={small} style={smallStyle} disabled={busy} onClick={() => open(edit(s))}>
                        Change
                      </button>
                      <ConfirmButton
                        className="min-h-9 rounded-lg px-2 text-xs font-bold"
                        question={`Remove the ${clock(s.time)} schedule?`}
                        disabled={busy}
                        onConfirm={() => act(s.id, () => removeReportSchedule(s.id))}
                      >
                        Remove
                      </ConfirmButton>
                    </div>
                  )}
                </div>
                {rowNote?.id === s.id && !editing && (
                  <div className="mt-2">
                    <Msg m={rowNote.note} />
                  </div>
                )}
              </li>
            );
          })}
        </ul>
        {schedules.length >= MAX_SCHEDULES && !d && (
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            {MAX_SCHEDULES} schedules is the most an outlet can have. Change or remove one to add another.
          </p>
        )}
      </section>

      {d && (
        <section ref={form} className="card space-y-4 p-4" aria-label={d.id ? "Change the schedule" : "New schedule"}>
          <h2 className="text-base font-bold">{d.id ? "Change the schedule" : "New schedule"}</h2>

          <label className="block text-sm">
            <span className="mb-1 block font-semibold">Send at</span>
            <input ref={timeInput} type="time" className="field w-40" value={d.time} onChange={(e) => setDraft({ ...d, time: e.target.value })} />
            {isTime(d.time) && (
              <span className="mt-1 block text-xs" style={{ color: "var(--color-ink-3)" }}>
                {about(d.time, cutoff) === "day_before"
                  ? `At ${clock(d.time)} it carries the complete figures of the day before.`
                  : about(d.time, cutoff) === "ending_night"
                    ? `At ${clock(d.time)} the business day is about to end (it ends at ${clock(cutoff)}), so it carries that day's figures up to then. For the complete day, choose a time after ${clock(cutoff)}.`
                    : `At ${clock(d.time)} it carries that day's figures up to then; bills made later that night are not in it. For the complete day, choose a time after the day ends (${clock(cutoff)}), for example the next morning.`}{" "}
                It goes out within 5 minutes of the time.
              </span>
            )}
          </label>

          <div className="text-sm">
            <span className="mb-1 block font-semibold">Send it on these days</span>
            <div className="flex flex-wrap items-center gap-1.5">
              {DAYS.map((name, k) => {
                const on = d.days.includes(k + 1);
                return (
                  <button
                    key={name}
                    type="button"
                    aria-pressed={on}
                    onClick={() => setDraft({ ...d, days: on ? d.days.filter((x) => x !== k + 1) : [...d.days, k + 1].sort((a, b) => a - b) })}
                    className="min-h-9 rounded-lg border px-3 text-xs font-semibold"
                    style={on ? { background: "var(--color-brand-soft)", borderColor: "var(--color-brand)" } : { borderColor: "var(--color-line)", color: "var(--color-ink-3)" }}
                  >
                    {name}
                  </button>
                );
              })}
              {d.days.length < 7 && (
                <button type="button" className="min-h-9 px-2 text-xs font-bold" style={{ color: "var(--color-brand)" }} onClick={() => setDraft({ ...d, days: EVERY_DAY })}>
                  Every day
                </button>
              )}
            </div>
          </div>

          <div className="text-sm">
            <label className="mb-1 block font-semibold" htmlFor="report-email">
              Email it to
            </label>
            {d.emails.length > 0 && (
              <ul className="mb-2 flex flex-wrap gap-1.5">
                {d.emails.map((e) => (
                  <li key={e} className="flex items-center rounded-lg pl-2.5 text-xs font-semibold" style={{ background: "var(--color-brand-soft)" }}>
                    <span className="break-all py-1">{e}</span>
                    <button
                      type="button"
                      aria-label={`Remove ${e}`}
                      className="grid h-9 w-9 shrink-0 place-items-center text-base font-bold"
                      style={{ color: "var(--color-bad)" }}
                      onClick={() => setDraft({ ...d, emails: d.emails.filter((x) => x !== e) })}
                    >
                      ×
                    </button>
                  </li>
                ))}
              </ul>
            )}
            <div className="flex flex-wrap gap-2">
              <input
                id="report-email"
                className="field min-w-0 flex-1"
                type="email"
                inputMode="email"
                autoComplete="off"
                autoCapitalize="none"
                maxLength={254}
                placeholder={d.emails.length >= MAX_EMAILS ? "5 addresses is the most" : "name@example.com"}
                disabled={d.emails.length >= MAX_EMAILS}
                value={d.entry}
                onChange={(e) => setDraft({ ...d, entry: e.target.value })}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === ",") {
                    e.preventDefault();
                    addEntry();
                  }
                }}
              />
              <button type="button" className="btn border" style={{ borderColor: "var(--color-line)" }} disabled={!d.entry.trim()} onClick={addEntry}>
                Add
              </button>
            </div>
            <span className="mt-1 block text-xs" style={{ color: "var(--color-ink-3)" }}>
              Up to {MAX_EMAILS} people, for example yourself, a partner or the accountant. Each gets their own email. They see your sales figures,
              so add only people who should.
            </span>
          </div>

          <label className="flex items-start gap-3">
            <input
              type="checkbox"
              className="mt-1 h-5 w-5"
              checked={d.phoneAlert}
              disabled={!phoneAlertAvailable && !d.phoneAlert}
              onChange={(e) => setDraft({ ...d, phoneAlert: e.target.checked })}
            />
            <span>
              <span className="block text-sm font-semibold">Also send a phone alert</span>
              <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
                {phoneAlertAvailable
                  ? "A short line with the bills and the total, on every phone that has alerts turned on in the owner app."
                  : "Needs the Owner mobile app module. Ask for it in Settings → Plan and modules."}
              </span>
            </span>
          </label>

          <div className="flex flex-wrap gap-2">
            <button className="btn btn-primary" disabled={pending} onClick={save}>
              {d.id ? "Save changes" : "Save schedule"}
            </button>
            <button
              className="btn border"
              style={{ borderColor: "var(--color-line)" }}
              disabled={pending}
              onClick={() => {
                setFormNote(null);
                setDraft(null);
              }}
            >
              Cancel
            </button>
          </div>
          <Msg m={formNote} />
        </section>
      )}
    </>
  );
}
