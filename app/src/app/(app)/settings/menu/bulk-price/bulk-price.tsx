"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ApprovalPrompt, cleanMessage, neededRight } from "../../../approval";
import { ConfirmButton } from "../../confirm-button";
import { money } from "@/lib/format";
import { applyBulkPrice, previewBulkPrice, undoBulkPrice } from "./actions";
import {
  buildScope,
  checkInput,
  descendantIds,
  describeChange,
  historyTitle,
  problemText,
  ROUNDINGS,
  summarize,
  type BulkMode,
  type HistoryRow,
  type Preview,
} from "./bulk-price-logic";

type Category = { id: string; name: string; parent_id: string | null };
type Product = { id: string; name: string; category_id: string };

const ROUNDING_LABEL: Record<number, string> = { 1: "Nearest whole number", 0.5: "Nearest 0.50", 0.01: "Exact (to 0.01)" };

function newRef(): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : "";
}

export function BulkPrice({
  currency,
  showOutlets,
  categories,
  products,
  history,
  historyError,
}: {
  currency: string;
  showOutlets: boolean;
  categories: Category[];
  products: Product[];
  history: HistoryRow[];
  historyError: string | null;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [mode, setMode] = useState<BulkMode>("percent");
  const [valueText, setValueText] = useState("");
  const [rounding, setRounding] = useState<number>(1);
  const [scopeKind, setScopeKind] = useState<"all" | "categories" | "items">("categories");
  const [catIds, setCatIds] = useState<string[]>([]);
  const [prodIds, setProdIds] = useState<string[]>([]);
  const [search, setSearch] = useState("");
  const [includeBranch, setIncludeBranch] = useState(true);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [reason, setReason] = useState("");
  const [clientRef, setClientRef] = useState(() => newRef());
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const [needs, setNeeds] = useState<{ right: string; retry: () => void } | null>(null);

  const scope = useMemo(
    () =>
      buildScope({
        all: scopeKind === "all",
        categoryIds: scopeKind === "categories" ? catIds : [],
        productIds: scopeKind === "items" ? prodIds : [],
      }),
    [scopeKind, catIds, prodIds],
  );
  const input = checkInput({ mode, valueText, scope });
  const sum = preview ? summarize(preview) : null;
  const shownProducts = products.filter((p) => p.name.toLowerCase().includes(search.trim().toLowerCase())).slice(0, 60);

  function invalidate() {
    setPreview(null);
    setMessage(null);
  }
  function toggleCategory(id: string) {
    invalidate();
    const group = descendantIds(categories, id);
    setCatIds((cur) => (cur.includes(id) ? cur.filter((c) => !group.includes(c)) : [...new Set([...cur, ...group])]));
  }
  function toggleProduct(id: string) {
    invalidate();
    setProdIds((cur) => (cur.includes(id) ? cur.filter((p) => p !== id) : [...cur, id]));
  }
  /** Runs a server action; a "(menu.price_change)" refusal opens the manager PIN prompt and retries once. */
  function guarded(run: () => Promise<{ ok: boolean; error?: string }>, onOk: () => void) {
    start(async () => {
      const res = await run();
      if (res.ok) return onOk();
      const right = neededRight(res.error);
      if (right) {
        setNeeds({ right, retry: () => guarded(run, onOk) });
        setMessage({ ok: false, text: cleanMessage(res.error ?? "") });
        return;
      }
      setMessage({ ok: false, text: res.error ?? "Something went wrong." });
    });
  }

  function doPreview() {
    setMessage(null);
    if (!input.ok) return setMessage({ ok: false, text: input.error });
    guarded(
      async () => {
        const r = await previewBulkPrice({ mode, valueText, rounding, scope, includeBranch });
        if (r.ok) setPreview(r.preview);
        return r;
      },
      () => setMessage(null),
    );
  }
  function doApply() {
    if (!preview || !sum || !sum.canApply || !input.ok) return;
    guarded(
      () => applyBulkPrice({ mode, valueText, rounding, scope, includeBranch, reason, clientRef, expectLines: preview.total_lines }),
      () => {
        setMessage({ ok: true, text: `Done. ${preview.total_lines} prices changed. You can undo this below.` });
        setPreview(null);
        setReason("");
        setClientRef(newRef());
        router.refresh();
      },
    );
  }
  function doUndo(h: HistoryRow) {
    setMessage(null);
    guarded(
      () => undoBulkPrice(h.id, ""),
      () => {
        setMessage({ ok: true, text: "Undone. Prices that were edited since were left as they are." });
        router.refresh();
      },
    );
  }

  const roots = categories.filter((c) => !c.parent_id || !categories.some((x) => x.id === c.parent_id));
  function renderCat(c: Category, depth: number): React.ReactNode {
    const kids = categories.filter((x) => x.parent_id === c.id);
    return (
      <div key={c.id}>
        <label className="flex min-h-11 cursor-pointer items-center gap-3 text-sm font-semibold" style={{ paddingLeft: depth * 20 }}>
          <input type="checkbox" className="h-5 w-5" checked={catIds.includes(c.id)} onChange={() => toggleCategory(c.id)} />
          {c.name}
        </label>
        {kids.map((k) => renderCat(k, depth + 1))}
      </div>
    );
  }

  return (
    <div className="space-y-5">
      <section className="card p-5">
        <h3 className="text-base font-bold">1. What to change</h3>
        <div className="mt-3 grid gap-3 sm:grid-cols-3">
          <label className="flex flex-col gap-1.5 text-sm font-bold">
            Change by
            <select className="field" value={mode} onChange={(e) => { invalidate(); setMode(e.target.value as BulkMode); }}>
              <option value="percent">A percentage (%)</option>
              <option value="amount">An amount ({currency})</option>
            </select>
          </label>
          <label className="flex flex-col gap-1.5 text-sm font-bold">
            {mode === "percent" ? "Percent (use - to lower)" : "Amount (use - to lower)"}
            <input className="field" inputMode="decimal" placeholder={mode === "percent" ? "e.g. 10" : "e.g. 5"} value={valueText} onChange={(e) => { invalidate(); setValueText(e.target.value); }} />
          </label>
          <label className="flex flex-col gap-1.5 text-sm font-bold">
            Round new prices
            <select className="field" value={rounding} onChange={(e) => { invalidate(); setRounding(Number(e.target.value)); }}>
              {ROUNDINGS.map((r) => (
                <option key={r} value={r}>
                  {ROUNDING_LABEL[r]}
                </option>
              ))}
            </select>
          </label>
        </div>

        <div className="mt-4 flex flex-wrap gap-2" role="radiogroup" aria-label="Which dishes">
          {(
            [
              ["categories", "Whole categories"],
              ["items", "Pick dishes"],
              ["all", "Every dish"],
            ] as const
          ).map(([k, label]) => (
            <button
              key={k}
              type="button"
              role="radio"
              aria-checked={scopeKind === k}
              onClick={() => { invalidate(); setScopeKind(k); }}
              className="min-h-11 rounded-2xl border px-4 text-sm font-bold"
              style={scopeKind === k ? { background: "var(--color-brand)", color: "#fff", borderColor: "var(--color-brand)" } : { borderColor: "var(--color-line)", color: "var(--color-ink-2)" }}
            >
              {label}
            </button>
          ))}
        </div>

        {scopeKind === "categories" && (
          <div className="mt-3 rounded-2xl border p-3" style={{ borderColor: "var(--color-line)" }}>
            {roots.length === 0 ? <p className="text-sm">No categories yet.</p> : roots.map((c) => renderCat(c, 0))}
            <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
              Ticking a category includes its sub-categories.
            </p>
          </div>
        )}
        {scopeKind === "items" && (
          <div className="mt-3 rounded-2xl border p-3" style={{ borderColor: "var(--color-line)" }}>
            <input className="field mb-2" placeholder="Search dishes" value={search} onChange={(e) => setSearch(e.target.value)} />
            <div className="max-h-64 overflow-y-auto">
              {shownProducts.map((p) => (
                <label key={p.id} className="flex min-h-11 cursor-pointer items-center gap-3 text-sm font-semibold">
                  <input type="checkbox" className="h-5 w-5" checked={prodIds.includes(p.id)} onChange={() => toggleProduct(p.id)} />
                  {p.name}
                </label>
              ))}
              {shownProducts.length === 0 && <p className="text-sm">No dish matches.</p>}
            </div>
            <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
              {prodIds.length} picked.
            </p>
          </div>
        )}

        {showOutlets && (
          <label className="mt-4 flex min-h-11 cursor-pointer items-center gap-3 text-sm font-semibold">
            <input type="checkbox" className="h-5 w-5" checked={includeBranch} onChange={(e) => { invalidate(); setIncludeBranch(e.target.checked); }} />
            <span>
              Also change the special prices set for individual outlets
              <span className="block text-xs font-medium" style={{ color: "var(--color-ink-3)" }}>
                Outlets with no special price follow the main price. Outlet prices that are set are shown in the preview.
              </span>
            </span>
          </label>
        )}

        <button type="button" className="btn btn-primary mt-4" disabled={pending || !input.ok} onClick={doPreview}>
          {pending && !preview ? "Working…" : "Show the new prices"}
        </button>
        {!input.ok && valueText.trim() !== "" && (
          <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
            {input.error}
          </p>
        )}
      </section>

      {message && (
        <p
          className="rounded-2xl px-4 py-3 text-sm"
          role={message.ok ? "status" : "alert"}
          style={message.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad)" }}
        >
          {message.text}
        </p>
      )}

      {preview && sum && input.ok && (
        <section className="card p-5">
          <h3 className="text-base font-bold">2. Check the new prices</h3>
          <p className="mt-1 text-sm" style={{ color: "var(--color-ink-2)" }}>
            {describeChange(mode, input.value)}: {preview.total_lines === 0 ? "no price would change." : `${preview.total_lines} prices change (${sum.up} up, ${sum.down} down${preview.branch_lines > 0 ? `, ${preview.branch_lines} of them outlet prices` : ""}).`}
          </p>
          {sum.invalid > 0 && (
            <p className="mt-3 rounded-2xl px-4 py-3 text-sm font-semibold" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
              {problemText(sum)}
            </p>
          )}
          {preview.total_lines > 0 && (
            <>
              <div className="mt-3 max-h-96 overflow-auto rounded-2xl border" style={{ borderColor: "var(--color-line)" }}>
                <table className="w-full text-sm">
                  <thead>
                    <tr style={{ color: "var(--color-ink-3)" }}>
                      <th className="px-3 py-2 text-left text-xs font-semibold">Dish</th>
                      <th className="px-3 py-2 text-left text-xs font-semibold">Where</th>
                      <th className="px-3 py-2 text-right text-xs font-semibold">Now</th>
                      <th className="px-3 py-2 text-right text-xs font-semibold">New</th>
                    </tr>
                  </thead>
                  <tbody>
                    {preview.lines.map((l, i) => (
                      <tr key={`${l.product_id}-${l.branch_id ?? "base"}-${i}`} style={{ borderTop: "1px solid var(--color-line)", ...(l.problem ? { background: "var(--color-bad-soft)" } : {}) }}>
                        <td className="px-3 py-2">
                          <div className="font-medium">{l.name}</div>
                          <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                            {l.category}
                          </div>
                        </td>
                        <td className="px-3 py-2 text-xs">{l.scope === "base" ? "Main price" : l.branch ?? "Outlet"}</td>
                        <td className="px-3 py-2 text-right tabular-nums">{money(l.old_price, currency)}</td>
                        <td className="px-3 py-2 text-right font-bold tabular-nums" style={l.problem ? { color: "var(--color-bad)" } : undefined}>
                          {money(l.new_price, currency)}
                          {l.problem && <div className="text-xs font-semibold">{l.problem === "below_zero" ? "below zero" : "too high"}</div>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {sum.hiddenRows > 0 && (
                <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                  Showing the first {preview.lines.length}. {sum.hiddenRows} more change the same way.
                </p>
              )}

              <label className="mt-4 flex flex-col gap-1.5 text-sm font-bold">
                Why are you changing the prices? (required, kept in the audit log)
                <input className="field" maxLength={120} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Supplier costs went up" />
              </label>
              <div className="mt-4 flex flex-wrap items-center gap-3">
                <ConfirmButton
                  className="btn btn-pay"
                  style={{}}
                  question={`Change ${preview.total_lines} prices now?`}
                  yesLabel="Yes, change them"
                  noLabel="Not yet"
                  tone="plain"
                  disabled={pending || reason.trim().length < 3 || !sum.canApply}
                  onConfirm={doApply}
                >
                  Apply to {preview.total_lines} prices
                </ConfirmButton>
                <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                  Open bills keep their price. Undo is available afterwards.
                </span>
              </div>
            </>
          )}
        </section>
      )}

      <section className="card p-5">
        <h3 className="text-base font-bold">Earlier changes</h3>
        {historyError && (
          <p className="mt-2 text-sm" style={{ color: "var(--color-bad)" }}>
            {historyError}
          </p>
        )}
        {!historyError && history.length === 0 && (
          <p className="mt-2 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Nothing yet.
          </p>
        )}
        <ul className="mt-2 divide-y" style={{ borderColor: "var(--color-line)" }}>
          {history.map((h) => (
            <li key={h.id} className="flex flex-wrap items-center justify-between gap-3 py-3">
              <div className="min-w-0">
                <div className="text-sm font-bold">
                  {historyTitle(h)}
                  {h.status === "undone" && (
                    <span className="ml-2 rounded-full px-2 py-0.5 text-xs font-semibold" style={{ background: "var(--color-ground)", color: "var(--color-ink-3)" }}>
                      Undone
                    </span>
                  )}
                </div>
                <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                  {new Date(h.created_at).toLocaleString()} · {h.by ?? "—"} · {h.reason}
                  {h.status === "undone" && ` · undone by ${h.undone_by ?? "—"}: ${h.restored ?? 0} restored, ${h.skipped ?? 0} left as edited`}
                </div>
              </div>
              {h.status === "applied" && (
                <ConfirmButton
                  className="whitespace-nowrap rounded-lg border px-3 py-2 text-xs font-semibold"
                  style={{ borderColor: "var(--color-line)", color: "var(--color-ink-2)" }}
                  question="Put the old prices back?"
                  yesLabel="Yes, undo"
                  noLabel="Keep"
                  disabled={pending}
                  onConfirm={() => doUndo(h)}
                >
                  Undo
                </ConfirmButton>
              )}
            </li>
          ))}
        </ul>
      </section>

      {needs && (
        <ApprovalPrompt
          permission={needs.right}
          onCancel={() => setNeeds(null)}
          onApproved={() => {
            const retry = needs.retry;
            setNeeds(null);
            setMessage(null);
            retry();
          }}
        />
      )}
    </div>
  );
}
