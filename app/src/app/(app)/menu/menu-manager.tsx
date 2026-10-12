"use client";

import { startTransition, useEffect, useState, useTransition } from "react";
import { useActionState } from "react";
import Link from "next/link";
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
  addSize,
  updateSize,
  toggleAvailability,
  deleteProduct,
  type MenuState,
} from "./actions";
import { ConfirmButton } from "../settings/confirm-button";

type Category = { id: string; name: string; display_order: number; parent_id?: string | null };
type TreeCategory = Category & { depth: 0 | 1; label: string; childCount: number };

/** Main categories in their order, each followed by its sub-categories. */
function categoryTree(categories: Category[]): TreeCategory[] {
  const ids = new Set(categories.map((c) => c.id));
  const mains = categories.filter((c) => !c.parent_id || !ids.has(c.parent_id));
  const out: TreeCategory[] = [];
  for (const m of mains) {
    const kids = categories.filter((c) => c.parent_id === m.id);
    out.push({ ...m, depth: 0, label: m.name, childCount: kids.length });
    for (const k of kids) out.push({ ...k, depth: 1, label: `${m.name} › ${k.name}`, childCount: 0 });
  }
  return out;
}
type Product = {
  id: string;
  name: string;
  price: number;
  category_id: string;
  tax_group_id: string;
  is_veg: boolean | null;
  is_available: boolean;
  kitchen_station?: string | null;
  name_local?: string | null;
  /** India: optional HSN / SAC code for this dish (4 to 8 digits). */
  hsn_code?: string | null;
  /** The packing charge: a charge, not a dish. Its amount and on/off are set in Settings → Service charge, not here. */
  is_charge?: boolean;
  /** A size of another dish (its "parent"): Small, Large, Half, Full… */
  parent_id?: string | null;
  variant_name?: string | null;
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
  showHsn = false,
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
  /** India: an HSN / SAC code field on each dish. */
  showHsn?: boolean;
}) {
  const [editing, setEditing] = useState<Product | null>(null);
  const [addingIn, setAddingIn] = useState<string | null>(null); // category id
  const [sizingId, setSizingId] = useState<string | null>(null); // dish whose sizes are open

  // Sizes are listed under their dish, not as dishes of their own.
  const dishes = products.filter((p) => !p.parent_id);
  const sizesOf = (id: string) =>
    products.filter((p) => p.parent_id === id).sort((a, b) => a.price - b.price || (a.variant_name ?? "").localeCompare(b.variant_name ?? ""));
  const byCategory = (catId: string) => dishes.filter((p) => p.category_id === catId);
  const tree = categoryTree(categories);
  const mains = tree.filter((c) => c.depth === 0);
  const uncategorised = dishes.filter((p) => !categories.some((c) => c.id === p.category_id));
  const sizingDish = sizingId ? dishes.find((p) => p.id === sizingId) ?? null : null;
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
                  : byCategory(c.id)
                      .map((p) => {
                        const sz = sizesOf(p.id);
                        return sz.length
                          ? `${p.name} — ${sz.map((x) => `${x.variant_name} ${money(currency, x.price)}`).join(", ")}`
                          : `${p.name} — ${money(currency, p.price)}`;
                      })
                      .join(" · ")}
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

      {tree.map((cat) => (
        <div key={cat.id} className={cat.depth === 1 ? "card ml-5 overflow-hidden sm:ml-8" : "card overflow-hidden"} style={cat.depth === 1 ? { borderLeft: "4px solid var(--color-brand-soft)" } : undefined}>
          <div
            className="flex flex-wrap items-center justify-between gap-3 px-4 py-3"
            style={{ borderBottom: "1px solid var(--color-line)" }}
          >
            <CategoryHeader cat={cat} itemCount={byCategory(cat.id).length} mains={mains} />
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
                  sizes={sizesOf(p.id)}
                  onSizes={() => setSizingId(p.id)}
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
            <ProductRow key={p.id} product={p} currency={currency} optionNames={groupNames(p.id)} sizes={sizesOf(p.id)} onSizes={() => setSizingId(p.id)} onEdit={() => setEditing(p)} />
          ))}
        </div>
      )}

      <AddCategoryCard mains={mains} />

      <OptionGroupsCard groups={optionGroups} currency={currency} />

      {addingIn && (
        <ProductModal
          title="Add item"
          categories={tree}
          taxGroups={taxGroups}
          defaultCategory={addingIn}
          optionGroups={optionGroups}
          selectedGroups={[]}
          showHsn={showHsn}
          action={createProduct}
          onClose={() => setAddingIn(null)}
        />
      )}

      {sizingDish && <SizesModal dish={sizingDish} sizes={sizesOf(sizingDish.id)} currency={currency} onClose={() => setSizingId(null)} />}

      {editing && (
        <ProductModal
          title="Edit item"
          categories={tree}
          taxGroups={taxGroups}
          product={editing}
          optionGroups={optionGroups}
          selectedGroups={productGroups[editing.id] ?? []}
          showHsn={showHsn}
          action={updateProduct}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function CategoryHeader({ cat, itemCount, mains }: { cat: TreeCategory; itemCount: number; mains: TreeCategory[] }) {
  const [renaming, setRenaming] = useState(false);
  const [addingSub, setAddingSub] = useState(false);
  const [renameState, renameAction, renaming2] = useActionState(renameCategory, initial);
  const [delState, delAction, deleting] = useActionState(deleteCategory, initial);
  const [subState, subAction, addingSub2] = useActionState(createCategory, initial);
  // A category with sub-categories stays a main category; the others can be put inside one.
  const parents = mains.filter((m) => m.id !== cat.id);

  useEffect(() => {
    if (subState.ok) setAddingSub(false);
  }, [subState]);

  if (addingSub) {
    return (
      <form action={subAction} className="flex flex-wrap items-center gap-2">
        <input type="hidden" name="parent_id" value={cat.id} />
        <span className="text-sm font-bold">{cat.name} ›</span>
        <input name="name" placeholder="Sub-category, e.g. Hot drinks" className="field" style={{ minHeight: 40, maxWidth: 240 }} autoFocus required />
        <button type="submit" className="btn btn-primary" style={{ minHeight: 40, padding: "0 12px" }} disabled={addingSub2}>
          {addingSub2 ? "Adding…" : "Add"}
        </button>
        <button type="button" className="btn" style={{ minHeight: 40, padding: "0 10px" }} onClick={() => setAddingSub(false)}>
          Cancel
        </button>
        {subState.error && (
          <span className="text-xs" style={{ color: "var(--color-bad)" }}>
            {subState.error}
          </span>
        )}
      </form>
    );
  }

  if (renaming) {
    return (
      <form action={renameAction} className="flex flex-wrap items-center gap-2" onSubmit={() => setRenaming(false)}>
        <input type="hidden" name="id" value={cat.id} />
        <input name="name" defaultValue={cat.name} className="field" style={{ minHeight: 40, maxWidth: 240 }} autoFocus />
        {cat.childCount === 0 && parents.length > 0 && (
          <label className="flex items-center gap-1.5 text-xs font-semibold">
            Inside
            <select name="parent_id" defaultValue={cat.parent_id ?? ""} className="field" style={{ minHeight: 40, maxWidth: 200 }}>
              <option value="">— none (main category) —</option>
              {parents.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.name}
                </option>
              ))}
            </select>
          </label>
        )}
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
    <div className="flex min-w-0 flex-wrap items-center gap-2">
      <span className="text-sm font-bold">{cat.label}</span>
      <span className="text-xs tabular-nums" style={{ color: "var(--color-ink-3)" }}>
        {itemCount} item{itemCount === 1 ? "" : "s"}
        {cat.childCount > 0 ? ` · ${cat.childCount} sub-categor${cat.childCount === 1 ? "y" : "ies"}` : ""}
      </span>
      <button className="text-xs underline" style={{ color: "var(--color-ink-3)" }} onClick={() => setRenaming(true)}>
        {cat.depth === 0 && cat.childCount > 0 ? "rename" : "rename / move"}
      </button>
      {cat.depth === 0 && (
        <button className="text-xs font-semibold underline" style={{ color: "var(--color-brand)" }} onClick={() => setAddingSub(true)}>
          + sub-category
        </button>
      )}
      {itemCount === 0 && cat.childCount === 0 && (
        <ConfirmButton
          className="text-xs underline"
          question={`Delete the category ${cat.name}?`}
          yesLabel="Yes, delete"
          disabled={deleting}
          onConfirm={() => {
            const fd = new FormData();
            fd.set("id", cat.id);
            startTransition(() => delAction(fd));
          }}
        >
          delete
        </ConfirmButton>
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
  sizes,
  onSizes,
  onEdit,
}: {
  product: Product;
  currency: string;
  optionNames: string;
  sizes: Product[];
  onSizes: () => void;
  onEdit: () => void;
}) {
  const [availState, availAction, toggling] = useActionState(toggleAvailability, initial);
  const [delState, delAction, deleting] = useActionState(deleteProduct, initial);

  // The packing charge is not a dish. Deleting it, switching it off or changing its amount
  // here would stop bills getting it, so those are done in Settings → Service charge only.
  if (product.is_charge) {
    return (
      <div
        className="flex flex-wrap items-center justify-end gap-3 px-4 py-3"
        style={{ borderBottom: "1px solid var(--color-line)" }}
      >
        <div className="min-w-0 flex-1">
          <div className="truncate text-sm font-medium">{product.name}</div>
          <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            Added to takeaway and delivery bills. Its amount, and switching it on or off, are in Settings.
          </div>
        </div>
        <Link
          href="/settings/charges"
          className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
          style={{ borderColor: "var(--color-line)" }}
        >
          Settings → Service charge
        </Link>
      </div>
    );
  }

  return (
    <div
      className="flex flex-wrap items-center justify-end gap-3 px-4 py-3"
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
        {sizes.length > 0 && (
          <div className="truncate text-[11px]" style={{ color: "var(--color-ink-2)" }}>
            Sizes: {sizes.map((z) => `${z.variant_name} ${money(currency, z.price)}${z.is_available ? "" : " (sold out)"}`).join(" · ")}
          </div>
        )}
        {optionNames && (
          <div className="truncate text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            Options: {optionNames}
          </div>
        )}
      </div>
      <div className="tabular-nums text-sm font-semibold">
        {sizes.length > 0 ? `from ${money(currency, Math.min(...sizes.map((z) => z.price)))}` : money(currency, product.price)}
      </div>

      <button
        className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
        style={{ borderColor: "var(--color-line)", color: sizes.length ? "var(--color-brand)" : undefined }}
        onClick={onSizes}
        title="Sizes such as Small / Large or Half / Full, each with its own price"
      >
        {sizes.length ? `Sizes (${sizes.length})` : "Sizes"}
      </button>

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

      <ConfirmButton
        question={sizes.length ? `Delete ${product.name} and its ${sizes.length} sizes?` : `Delete ${product.name}?`}
        yesLabel="Yes, delete"
        disabled={deleting}
        onConfirm={() => {
          const fd = new FormData();
          fd.set("id", product.id);
          startTransition(() => delAction(fd));
        }}
      >
        Delete
      </ConfirmButton>

      {(availState.error || delState.error) && (
        <span className="text-xs" style={{ color: "var(--color-bad)" }}>
          {availState.error || delState.error}
        </span>
      )}
    </div>
  );
}

/** The sizes of one dish: each has its own name and price; add, rename, re-price, mark sold out or delete. */
function SizesModal({ dish, sizes, currency, onClose }: { dish: Product; sizes: Product[]; currency: string; onClose: () => void }) {
  const [name, setName] = useState("");
  const [price, setPrice] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const add = () =>
    start(async () => {
      const r = await addSize(dish.id, name, price);
      setError(r.error);
      if (!r.error) {
        setName("");
        setPrice("");
      }
    });

  return (
    <div
      style={{ position: "fixed", inset: 0, background: "rgba(10,8,20,.55)", display: "grid", placeItems: "center", padding: 16, zIndex: 50 }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="card" role="dialog" aria-modal="true" aria-label={`Sizes of ${dish.name}`} style={{ width: "100%", maxWidth: 520, padding: 18, background: "var(--color-surface)", maxHeight: "90vh", overflowY: "auto" }}>
        <h3 className="text-lg font-bold">Sizes of {dish.name}</h3>
        <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
          For dishes sold in more than one size — Small / Medium / Large, Half / Full, 250 g / 500 g, 30 ml / 60 ml.
          Each size has its own price. On the billing screen, tapping {dish.name} asks which size. Sizes share the dish&rsquo;s
          category, tax, veg mark, kitchen station and options. Once a dish has sizes, its own price is not used.
        </p>

        <div className="mt-4 space-y-2">
          {sizes.length === 0 && (
            <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
              No sizes yet. Add the first one below.
            </p>
          )}
          {sizes.map((z) => (
            <SizeRow key={`${z.id}-${z.variant_name}-${z.price}-${z.is_available}`} size={z} currency={currency} />
          ))}
        </div>

        <div className="mt-4 rounded-xl border p-3" style={{ borderColor: "var(--color-line)" }}>
          <div className="mb-2 text-sm font-semibold">Add a size</div>
          <div className="flex flex-wrap items-center gap-2">
            <input className="field" style={{ maxWidth: 200 }} placeholder="Size, e.g. Large" maxLength={30} value={name} onChange={(e) => setName(e.target.value)} aria-label="Size name" />
            <input className="field" style={{ maxWidth: 120 }} placeholder="Price" inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} aria-label="Price of this size" onKeyDown={(e) => e.key === "Enter" && add()} />
            <button className="btn btn-primary" style={{ minHeight: 40 }} disabled={pending} onClick={add}>
              {pending ? "Adding…" : "Add size"}
            </button>
          </div>
          {error && (
            <p className="mt-2 text-xs" role="alert" style={{ color: "var(--color-bad)" }}>
              {error}
            </p>
          )}
        </div>

        <div className="mt-4 flex justify-end">
          <button className="btn" onClick={onClose}>
            Done
          </button>
        </div>
      </div>
    </div>
  );
}

function SizeRow({ size, currency }: { size: Product; currency: string }) {
  const [name, setName] = useState(size.variant_name ?? "");
  const [price, setPrice] = useState(String(size.price));
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [availState, availAction, toggling] = useActionState(toggleAvailability, initial);
  const [delState, delAction, deleting] = useActionState(deleteProduct, initial);
  const changed = name.trim() !== (size.variant_name ?? "") || Number(price) !== size.price;

  return (
    <div className="flex flex-wrap items-center gap-2 rounded-xl border p-2" style={{ borderColor: "var(--color-line)" }}>
      <input className="field" style={{ maxWidth: 170 }} maxLength={30} value={name} onChange={(e) => setName(e.target.value)} aria-label="Size name" />
      <input className="field" style={{ maxWidth: 100 }} inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} aria-label={`Price (${money(currency, size.price)})`} />
      {changed && (
        <button
          className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
          style={{ borderColor: "var(--color-brand)", color: "var(--color-brand)" }}
          disabled={pending}
          onClick={() =>
            start(async () => {
              const r = await updateSize(size.id, name, price);
              setError(r.error);
            })
          }
        >
          {pending ? "Saving…" : "Save"}
        </button>
      )}
      <form action={availAction}>
        <input type="hidden" name="id" value={size.id} />
        <input type="hidden" name="available" value={size.is_available ? "false" : "true"} />
        <button type="submit" className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)", color: "var(--color-ink-2)" }} disabled={toggling}>
          {size.is_available ? "In stock" : "Sold out"}
        </button>
      </form>
      <ConfirmButton
        question={`Delete the size ${size.variant_name}?`}
        yesLabel="Yes, delete"
        disabled={deleting}
        onConfirm={() => {
          const fd = new FormData();
          fd.set("id", size.id);
          startTransition(() => delAction(fd));
        }}
      >
        Delete
      </ConfirmButton>
      {(error || availState.error || delState.error) && (
        <span className="w-full text-xs" style={{ color: "var(--color-bad)" }}>
          {error || availState.error || delState.error}
        </span>
      )}
    </div>
  );
}

function AddCategoryCard({ mains }: { mains: TreeCategory[] }) {
  const [state, action, pending] = useActionState(createCategory, initial);
  return (
    <form action={action} className="card flex flex-wrap items-center gap-2 p-4">
      <input
        name="name"
        placeholder="New category (e.g. Tiffin)"
        className="field"
        style={{ maxWidth: 280 }}
      />
      {mains.length > 0 && (
        <label className="flex items-center gap-1.5 text-xs font-semibold">
          Inside
          <select name="parent_id" defaultValue="" className="field" style={{ maxWidth: 220 }} aria-label="Put the new category inside a main category (optional)">
            <option value="">— none (main category) —</option>
            {mains.map((m) => (
              <option key={m.id} value={m.id}>
                {m.name}
              </option>
            ))}
          </select>
        </label>
      )}
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
  showHsn,
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
  showHsn: boolean;
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

        <label className="mb-1.5 block text-sm font-semibold">
          Name in second language <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>(optional — shown under the English name)</span>
        </label>
        <input name="name_local" defaultValue={product?.name_local ?? ""} className="field mb-4" maxLength={120} placeholder="மசாலா தோசை" />

        <div className="mb-4 grid grid-cols-2 gap-3">
          <div>
            <label className="mb-1.5 block text-sm font-semibold">Category</label>
            <select name="category_id" defaultValue={product?.category_id ?? defaultCategory ?? ""} className="field" required>
              {categoryTree(categories).map((c) => (
                <option key={c.id} value={c.id}>{c.label}</option>
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

        {showHsn && (
          <div className="mb-4">
            <label className="mb-1.5 block text-sm font-semibold" htmlFor="hsn-code">
              HSN / SAC code <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>(optional)</span>
            </label>
            <input
              id="hsn-code"
              name="hsn_code"
              defaultValue={product?.hsn_code ?? ""}
              className="field"
              inputMode="numeric"
              maxLength={8}
              pattern="[0-9]{4,8}"
              title="4 to 8 digits"
              placeholder="996331"
            />
            <p className="mt-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
              4 to 8 digits, from your accountant. Leave empty if you do not have one for this item.
            </p>
          </div>
        )}

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
          <div key={g.id} className="flex flex-wrap items-center justify-end gap-3 px-4 py-3" style={{ borderBottom: "1px solid var(--color-line)" }}>
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
            <ConfirmButton
              question={`Remove ${g.name}?`}
              disabled={pending}
              onConfirm={() =>
                start(async () => {
                  setError(null);
                  const r = await removeOptionGroup(g.id);
                  if (r.error) setError(r.error);
                  else router.refresh();
                })
              }
            >
              Remove
            </ConfirmButton>
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
