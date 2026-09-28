"use client";

import { useEffect, useState, useTransition } from "react";
import { useActionState } from "react";
import { useRouter } from "next/navigation";
import {
  saveOptionGroup,
  removeOptionGroup,
  type OptionInput,
  createCategory,
  renameCategory,
  deleteCategory,
  createProduct,
  updateProduct,
  toggleAvailability,
  deleteProduct,
  type MenuState,
} from "./actions";

type Category = { id: string; name: string; display_order: number };
type Product = {
  id: string;
  name: string;
  price: number;
  category_id: string;
  tax_group_id: string;
  is_veg: boolean | null;
  is_available: boolean;
  kitchen_station?: string | null;
};
type TaxGroup = { id: string; name: string };
export type OptionGroupView = {
  id: string;
  name: string;
  required: boolean;
  max: number;
  options: { id: string; name: string; price: number }[];
};

const initial: MenuState = { error: null };

function money(currency: string, amount: number) {
  try {
    return new Intl.NumberFormat("en-IN", {
      style: "currency",
      currency: currency || "INR",
      minimumFractionDigits: 2,
    }).format(amount);
  } catch {
    return `${amount.toFixed(2)}`;
  }
}

export function MenuManager({
  canManage,
  currency,
  categories,
  products,
  taxGroups,
  optionGroups,
  productGroups,
  showStations = true,
}: {
  canManage: boolean;
  currency: string;
  categories: Category[];
  products: Product[];
  taxGroups: TaxGroup[];
  optionGroups: OptionGroupView[];
  productGroups: Record<string, string[]>;
  /** Professional: kitchen station per item. */
  showStations?: boolean;
}) {
  const [editing, setEditing] = useState<Product | null>(null);
  const [addingIn, setAddingIn] = useState<string | null>(null); // category id

  const byCategory = (catId: string) => products.filter((p) => p.category_id === catId);
  const uncategorised = products.filter((p) => !categories.some((c) => c.id === p.category_id));
  const groupNames = (productId: string) =>
    (productGroups[productId] ?? [])
      .map((g) => optionGroups.find((x) => x.id === g)?.name)
      .filter(Boolean)
      .join(", ");

  if (!canManage) {
    return (
      <div className="card p-5">
        <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
          You can see the menu but not change it. Editing the menu needs the
          &ldquo;Manage menu&rdquo; permission — ask an owner or manager.
        </p>
        <div className="mt-4 space-y-4">
          {categories.map((c) => (
            <div key={c.id}>
              <div className="mb-1 text-sm font-semibold">{c.name}</div>
              <div className="text-sm" style={{ color: "var(--color-ink-3)" }}>
                {byCategory(c.id).length === 0
                  ? "No items"
                  : byCategory(c.id).map((p) => `${p.name} — ${money(currency, p.price)}`).join(" · ")}
              </div>
            </div>
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className={showStations ? "space-y-5" : "space-y-5 hide-stations"}>
      {categories.length === 0 && (
        <div className="card p-5">
          <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
            Start by adding a category — for example <b>Tiffin</b>, <b>Chettinad</b>, or <b>Drinks</b>.
            Then add items inside it.
          </p>
        </div>
      )}

      {categories.map((cat) => (
        <div key={cat.id} className="card overflow-hidden">
          <div
            className="flex items-center justify-between gap-3 px-4 py-3"
            style={{ borderBottom: "1px solid var(--color-line)" }}
          >
            <CategoryHeader cat={cat} itemCount={byCategory(cat.id).length} />
            <button
              className="btn"
              style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)", minHeight: 40, padding: "0 12px" }}
              onClick={() => setAddingIn(cat.id)}
            >
              + Add item
            </button>
          </div>

          <div>
            {byCategory(cat.id).length === 0 ? (
              <p className="px-4 py-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
                No items yet. Tap &ldquo;Add item&rdquo;.
              </p>
            ) : (
              byCategory(cat.id).map((p) => (
                <ProductRow
                  key={p.id}
                  product={p}
                  currency={currency}
                  optionNames={groupNames(p.id)}
                  onEdit={() => setEditing(p)}
                />
              ))
            )}
          </div>
        </div>
      ))}

      {uncategorised.length > 0 && (
        <div className="card overflow-hidden">
          <div className="px-4 py-3 text-sm font-semibold" style={{ borderBottom: "1px solid var(--color-line)" }}>
            Other items
          </div>
          {uncategorised.map((p) => (
            <ProductRow key={p.id} product={p} currency={currency} optionNames={groupNames(p.id)} onEdit={() => setEditing(p)} />
          ))}
        </div>
      )}

      <AddCategoryCard />

      <OptionGroupsCard groups={optionGroups} currency={currency} />

      {addingIn && (
        <ProductModal
          title="Add item"
          categories={categories}
          taxGroups={taxGroups}
          defaultCategory={addingIn}
          optionGroups={optionGroups}
          selectedGroups={[]}
          action={createProduct}
          onClose={() => setAddingIn(null)}
        />
      )}

      {editing && (
        <ProductModal
          title="Edit item"
          categories={categories}
          taxGroups={taxGroups}
          product={editing}
          optionGroups={optionGroups}
          selectedGroups={productGroups[editing.id] ?? []}
          action={updateProduct}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function CategoryHeader({ cat, itemCount }: { cat: Category; itemCount: number }) {
  const [renaming, setRenaming] = useState(false);
  const [renameState, renameAction, renaming2] = useActionState(renameCategory, initial);
  const [delState, delAction, deleting] = useActionState(deleteCategory, initial);

  if (renaming) {
    return (
      <form action={renameAction} className="flex items-center gap-2" onSubmit={() => setRenaming(false)}>
        <input type="hidden" name="id" value={cat.id} />
        <input name="name" defaultValue={cat.name} className="field" style={{ minHeight: 40 }} autoFocus />
        <button type="submit" className="btn btn-primary" style={{ minHeight: 40, padding: "0 12px" }} disabled={renaming2}>
          Save
        </button>
        <button type="button" className="btn" style={{ minHeight: 40, padding: "0 10px" }} onClick={() => setRenaming(false)}>
          Cancel
        </button>
      </form>
    );
  }

  return (
    <div className="flex items-center gap-2">
      <span className="text-sm font-bold">{cat.name}</span>
      <span className="text-xs tabular-nums" style={{ color: "var(--color-ink-3)" }}>
        {itemCount} item{itemCount === 1 ? "" : "s"}
      </span>
      <button className="text-xs underline" style={{ color: "var(--color-ink-3)" }} onClick={() => setRenaming(true)}>
        rename
      </button>
      {itemCount === 0 && (
        <form action={delAction} className="inline">
          <input type="hidden" name="id" value={cat.id} />
          <button type="submit" className="text-xs underline" style={{ color: "var(--color-bad)" }} disabled={deleting}>
            delete
          </button>
        </form>
      )}
      {(renameState.error || delState.error) && (
        <span className="text-xs" style={{ color: "var(--color-bad)" }}>
          {renameState.error || delState.error}
        </span>
      )}
    </div>
  );
}

function ProductRow({
  product,
  currency,
  optionNames,
  onEdit,
}: {
  product: Product;
  currency: string;
  optionNames: string;
  onEdit: () => void;
}) {
  const [availState, availAction, toggling] = useActionState(toggleAvailability, initial);
  const [delState, delAction, deleting] = useActionState(deleteProduct, initial);

  return (
    <div
      className="flex items-center gap-3 px-4 py-3"
      style={{ borderBottom: "1px solid var(--color-line)" }}
    >
      {product.is_veg !== null && (
        <span
          aria-hidden
          style={{
            width: 12,
            height: 12,
            borderRadius: 3,
            border: `1.5px solid ${product.is_veg ? "var(--color-ok)" : "var(--color-bad)"}`,
            display: "inline-grid",
            placeItems: "center",
            flex: "none",
          }}
        >
          <span
            style={{
              width: 6,
              height: 6,
              borderRadius: "50%",
              background: product.is_veg ? "var(--color-ok)" : "var(--color-bad)",
            }}
          />
        </span>
      )}
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm font-medium">
          {product.name}
          {!product.is_available && (
            <span className="ml-2 rounded px-1.5 py-0.5 text-[11px]" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
              Sold out
            </span>
          )}
        </div>
        {optionNames && (
          <div className="truncate text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            Options: {optionNames}
          </div>
        )}
      </div>
      <div className="tabular-nums text-sm font-semibold">{money(currency, product.price)}</div>

      <form action={availAction}>
        <input type="hidden" name="id" value={product.id} />
        <input type="hidden" name="available" value={product.is_available ? "false" : "true"} />
        <button
          type="submit"
          className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
          style={{ borderColor: "var(--color-line)", color: "var(--color-ink-2)" }}
          disabled={toggling}
          title={product.is_available ? "Mark sold out" : "Mark available"}
        >
          {product.is_available ? "In stock" : "Sold out"}
        </button>
      </form>

      <button
        className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
        style={{ borderColor: "var(--color-line)" }}
        onClick={onEdit}
      >
        Edit
      </button>

      <form action={delAction}>
        <input type="hidden" name="id" value={product.id} />
        <button
          type="submit"
          className="rounded-lg px-2 py-1.5 text-xs font-semibold"
          style={{ color: "var(--color-bad)" }}
          disabled={deleting}
        >
          Delete
        </button>
      </form>

      {(availState.error || delState.error) && (
        <span className="text-xs" style={{ color: "var(--color-bad)" }}>
          {availState.error || delState.error}
        </span>
      )}
    </div>
  );
}

function AddCategoryCard() {
  const [state, action, pending] = useActionState(createCategory, initial);
  return (
    <form action={action} className="card flex items-center gap-2 p-4">
      <input
        name="name"
        placeholder="New category (e.g. Tiffin)"
        className="field"
        style={{ maxWidth: 280 }}
      />
      <button type="submit" className="btn btn-primary" style={{ minHeight: 44, padding: "0 16px" }} disabled={pending}>
        {pending ? "Adding…" : "Add category"}
      </button>
      {state.error && (
        <span className="text-sm" style={{ color: "var(--color-bad)" }}>
          {state.error}
        </span>
      )}
    </form>
  );
}

function ProductModal({
  title,
  categories,
  taxGroups,
  product,
  defaultCategory,
  optionGroups,
  selectedGroups,
  action,
  onClose,
}: {
  title: string;
  categories: Category[];
  taxGroups: TaxGroup[];
  product?: Product;
  defaultCategory?: string;
  optionGroups: OptionGroupView[];
  selectedGroups: string[];
  action: (prev: MenuState, fd: FormData) => Promise<MenuState>;
  onClose: () => void;
}) {
  const [state, formAction, pending] = useActionState(action, initial);

  // Close on success.
  useEffect(() => {
    if (state.ok) onClose();
  }, [state, onClose]);

  const vegDefault = product?.is_veg === true ? "on" : product?.is_veg === false ? "off" : "";

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        background: "rgba(10,8,20,.55)",
        display: "grid",
        placeItems: "center",
        padding: 16,
        zIndex: 50,
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <form
        action={formAction}
        className="card"
        style={{ width: "100%", maxWidth: 460, padding: 18, background: "var(--color-surface)" }}
      >
        <h3 className="mb-4 text-lg font-bold">{title}</h3>
        {product && <input type="hidden" name="id" value={product.id} />}

        <label className="mb-1.5 block text-sm font-semibold">Item name</label>
        <input name="name" defaultValue={product?.name ?? ""} className="field mb-4" placeholder="Masala Dosa" autoFocus required />

        <div className="mb-4 grid grid-cols-2 gap-3">
          <div>
            <label className="mb-1.5 block text-sm font-semibold">Category</label>
            <select name="category_id" defaultValue={product?.category_id ?? defaultCategory ?? ""} className="field" required>
              {categories.map((c) => (
                <option key={c.id} value={c.id}>{c.name}</option>
              ))}
            </select>
          </div>
          <div>
            <label className="mb-1.5 block text-sm font-semibold">Price</label>
            <input name="price" defaultValue={product ? String(product.price) : ""} className="field" inputMode="decimal" placeholder="80" required />
          </div>
        </div>

        <div className="mb-4 grid grid-cols-2 gap-3">
          <div>
            <label className="mb-1.5 block text-sm font-semibold">Tax group</label>
            <select name="tax_group_id" defaultValue={product?.tax_group_id ?? (taxGroups[0]?.id ?? "")} className="field" required>
              {taxGroups.map((t) => (
                <option key={t.id} value={t.id}>{t.name}</option>
              ))}
            </select>
          </div>
          <div>
            <label className="mb-1.5 block text-sm font-semibold">Veg / Non-veg</label>
            <select name="is_veg" defaultValue={vegDefault} className="field">
              <option value="">Not set</option>
              <option value="on">Veg</option>
              <option value="off">Non-veg</option>
            </select>
          </div>
        </div>

        <div className="station-field mb-4">
          <label className="mb-1.5 block text-sm font-semibold">Kitchen station</label>
          <input
            name="kitchen_station"
            defaultValue={product?.kitchen_station ?? ""}
            className="field"
            list="station-list"
            maxLength={30}
            placeholder="Kitchen"
          />
          <datalist id="station-list">
            <option value="Kitchen" />
            <option value="Bar" />
            <option value="Tandoor" />
            <option value="Chinese" />
            <option value="Desserts" />
            <option value="Beverages" />
          </datalist>
          <p className="mt-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            Where this item is made. Each station gets its own kitchen ticket and printer. Empty means Kitchen.
          </p>
        </div>

        <input type="hidden" name="options_present" value="1" />
        {optionGroups.length > 0 && (
          <fieldset className="mb-4">
            <legend className="mb-1.5 text-sm font-semibold">Options for this item</legend>
            <div className="flex flex-wrap gap-x-4 gap-y-2">
              {optionGroups.map((g) => (
                <label key={g.id} className="flex items-center gap-2 text-sm">
                  <input type="checkbox" name="option_group" value={g.id} defaultChecked={selectedGroups.includes(g.id)} className="h-4 w-4" />
                  {g.name}
                </label>
              ))}
            </div>
          </fieldset>
        )}

        {state.error && (
          <p className="mb-3 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
            {state.error}
          </p>
        )}

        <div className="flex gap-2">
          <button type="button" className="btn" style={{ flex: "none", padding: "0 16px" }} onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className="btn btn-primary" style={{ flex: 1 }} disabled={pending}>
            {pending ? "Saving…" : "Save item"}
          </button>
        </div>
      </form>
    </div>
  );
}

/* ---------- options & add-ons ---------- */

function OptionGroupsCard({ groups, currency }: { groups: OptionGroupView[]; currency: string }) {
  const [editing, setEditing] = useState<OptionGroupView | "new" | null>(null);
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);

  return (
    <div className="card overflow-hidden">
      <div className="flex items-center justify-between gap-3 px-4 py-3" style={{ borderBottom: "1px solid var(--color-line)" }}>
        <div>
          <div className="text-sm font-bold">Options &amp; add-ons</div>
          <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Sizes, half/full, spice level, extra toppings. Make a group once, then tick it on each item.
          </div>
        </div>
        <button
          className="btn shrink-0"
          style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)", minHeight: 40, padding: "0 12px" }}
          onClick={() => setEditing("new")}
        >
          + New group
        </button>
      </div>
      {groups.length === 0 ? (
        <p className="px-4 py-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
          No option groups yet. Example: <b>Size</b> (required, choose 1): Half, Full +80.
        </p>
      ) : (
        groups.map((g) => (
          <div key={g.id} className="flex items-center gap-3 px-4 py-3" style={{ borderBottom: "1px solid var(--color-line)" }}>
            <div className="min-w-0 flex-1">
              <div className="text-sm font-medium">
                {g.name}{" "}
                <span className="text-xs font-normal" style={{ color: "var(--color-ink-3)" }}>
                  {g.required ? (g.max === 1 ? "required · choose 1" : `required · up to ${g.max}`) : g.max === 1 ? "optional · choose 1" : `optional · up to ${g.max}`}
                </span>
              </div>
              <div className="truncate text-xs" style={{ color: "var(--color-ink-2)" }}>
                {g.options.map((o) => (o.price ? `${o.name} ${o.price > 0 ? "+" : "−"}${money(currency, Math.abs(o.price))}` : o.name)).join(" · ")}
              </div>
            </div>
            <button className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setEditing(g)}>
              Edit
            </button>
            <button
              className="rounded-lg px-2 py-1.5 text-xs font-semibold"
              style={{ color: "var(--color-bad)" }}
              disabled={pending}
              onClick={() =>
                start(async () => {
                  setError(null);
                  const r = await removeOptionGroup(g.id);
                  if (r.error) setError(r.error);
                  else router.refresh();
                })
              }
            >
              Remove
            </button>
          </div>
        ))
      )}
      {error && (
        <p className="px-4 py-2 text-sm" style={{ color: "var(--color-bad)" }}>
          {error}
        </p>
      )}
      {editing && <OptionGroupModal group={editing === "new" ? null : editing} onClose={() => setEditing(null)} />}
    </div>
  );
}

function OptionGroupModal({ group, onClose }: { group: OptionGroupView | null; onClose: () => void }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [name, setName] = useState(group?.name ?? "");
  const [required, setRequired] = useState(group?.required ?? true);
  const [max, setMax] = useState(String(group?.max ?? 1));
  const [rows, setRows] = useState<{ id: string | null; name: string; price: string }[]>(
    group?.options.map((o) => ({ id: o.id, name: o.name, price: String(o.price) })) ?? [
      { id: null, name: "", price: "0" },
      { id: null, name: "", price: "0" },
    ],
  );
  const [error, setError] = useState<string | null>(null);
  const update = (i: number, patch: Partial<(typeof rows)[number]>) => setRows(rows.map((r, j) => (j === i ? { ...r, ...patch } : r)));

  function save() {
    setError(null);
    const options: OptionInput[] = rows.map((r) => ({ id: r.id, name: r.name, price: Number(r.price.replace(/\u2212/g, "-").trim() || 0) }));
    start(async () => {
      const r = await saveOptionGroup(group?.id ?? null, name, required, Number(max), options);
      if (r.error) return setError(r.error);
      router.refresh();
      onClose();
    });
  }

  return (
    <div
      style={{ position: "fixed", inset: 0, background: "rgba(10,8,20,.55)", display: "grid", placeItems: "center", padding: 16, zIndex: 50 }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="card" style={{ width: "100%", maxWidth: 480, padding: 18, background: "var(--color-surface)" }} role="dialog" aria-label="Option group">
        <h3 className="mb-4 text-lg font-bold">{group ? "Edit option group" : "New option group"}</h3>
        <label className="mb-1.5 block text-sm font-semibold">Group name</label>
        <input className="field mb-3" value={name} onChange={(e) => setName(e.target.value)} placeholder="Size, Spice level, Add-ons" autoFocus />

        <div className="mb-3 grid grid-cols-2 gap-3">
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" className="h-4 w-4" checked={required} onChange={(e) => setRequired(e.target.checked)} />
            Customer must choose
          </label>
          <label className="flex items-center gap-2 text-sm">
            Up to
            <input className="field h-9 w-16 text-center" inputMode="numeric" value={max} onChange={(e) => setMax(e.target.value)} aria-label="Most choices allowed" />
            choice{max === "1" ? "" : "s"}
          </label>
        </div>

        <div className="mb-1 grid grid-cols-[1fr_110px_28px] gap-2 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
          <span>Option</span>
          <span>Extra price</span>
          <span />
        </div>
        <div className="max-h-[40vh] space-y-2 overflow-y-auto">
          {rows.map((r, i) => (
            <div key={i} className="grid grid-cols-[1fr_110px_28px] items-center gap-2">
              <input className="field h-10 text-sm" value={r.name} onChange={(e) => update(i, { name: e.target.value })} placeholder={i === 0 ? "Half" : "Full"} aria-label="Option name" />
              <input className="field h-10 text-right text-sm" inputMode="decimal" value={r.price} onChange={(e) => update(i, { price: e.target.value })} aria-label="Extra price" />
              <button className="text-sm font-semibold" style={{ color: "var(--color-bad)" }} onClick={() => setRows(rows.filter((_, j) => j !== i))} aria-label="Remove option">
                ✕
              </button>
            </div>
          ))}
        </div>
        <button className="mt-2 text-xs font-semibold" style={{ color: "var(--color-brand)" }} onClick={() => setRows([...rows, { id: null, name: "", price: "0" }])} disabled={rows.length >= 20}>
          + Add option
        </button>
        <p className="mt-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
          Extra price is added to the item&rsquo;s price (use 0 for no change, or a minus for cheaper, e.g. Half -40).
        </p>

        {error && (
          <p className="mt-3 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
            {error}
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button type="button" className="btn" style={{ flex: "none", padding: "0 16px" }} onClick={onClose}>
            Cancel
          </button>
          <button type="button" className="btn btn-primary" style={{ flex: 1 }} disabled={pending} onClick={save}>
            {pending ? "Saving…" : "Save group"}
          </button>
        </div>
      </div>
    </div>
  );
}
