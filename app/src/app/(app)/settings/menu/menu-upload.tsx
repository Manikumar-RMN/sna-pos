"use client";

import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { importMenu, type MenuImportResult } from "../../menu/actions";
import { MENU_COLUMNS, readMenuFile, rowsFromTable, toCsv, type MenuSheetRow } from "@/lib/menu-file";

type Cat = { id: string; name: string; parent_id?: string | null };
type Item = {
  name: string;
  price: number;
  category_id: string;
  tax_group_id: string;
  is_veg: boolean | null;
  hsn_code?: string | null;
  kitchen_station?: string | null;
  name_local?: string | null;
  is_charge?: boolean;
};

function download(fileName: string, text: string) {
  const url = URL.createObjectURL(new Blob([text], { type: "text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

/**
 * Settings → Menu: fill the whole menu in Excel and upload it.
 * Step 1 download the sheet, step 2 upload it: SNA POS checks every row and shows what it will
 * do; step 3 save. Nothing is saved while any row has a problem, and nothing is ever deleted.
 */
export function MenuUpload({
  taxGroups,
  categories,
  products,
  showHsn,
  showStations,
}: {
  taxGroups: { id: string; name: string }[];
  categories: Cat[];
  products: Item[];
  showHsn: boolean;
  showStations: boolean;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [fileName, setFileName] = useState<string | null>(null);
  const [rows, setRows] = useState<MenuSheetRow[] | null>(null);
  const [check, setCheck] = useState<MenuImportResult | null>(null);
  const [done, setDone] = useState<MenuImportResult | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const input = useRef<HTMLInputElement>(null);

  const tax1 = taxGroups[0]?.name ?? "";
  const tax2 = taxGroups[1]?.name ?? tax1;

  function template() {
    const head = [...MENU_COLUMNS];
    const ex: string[][] = [
      ["Beverages", "Hot drinks", "Masala tea", "20", tax1, "Y", "", "", "மசாலா டீ"],
      ["Beverages", "Cold drinks", "Rose milk", "40", tax1, "Y", "", "", ""],
      ["Tiffin", "", "Ghee roast dosa", "90", tax2, "Y", "", "", ""],
      ["Biryani", "Non-veg", "Chicken biryani", "220", tax2, "N", "", "", ""],
    ];
    download("sna-pos-menu-template.csv", toCsv([head, ...ex]));
  }

  function current() {
    const byId = new Map(categories.map((c) => [c.id, c]));
    const taxName = new Map(taxGroups.map((t) => [t.id, t.name]));
    const out: string[][] = [[...MENU_COLUMNS]];
    for (const p of products) {
      if (p.is_charge) continue;
      const c = byId.get(p.category_id);
      const parent = c?.parent_id ? byId.get(c.parent_id) : undefined;
      out.push([
        parent ? parent.name : (c?.name ?? ""),
        parent ? (c?.name ?? "") : "",
        p.name,
        String(p.price),
        taxName.get(p.tax_group_id) ?? "",
        p.is_veg === null ? "" : p.is_veg ? "Y" : "N",
        p.hsn_code ?? "",
        p.kitchen_station ?? "",
        p.name_local ?? "",
      ]);
    }
    download("sna-pos-menu.csv", toCsv(out));
  }

  function reset() {
    setFileName(null);
    setRows(null);
    setCheck(null);
    setProblem(null);
    if (input.current) input.current.value = "";
  }

  async function chosen(file: File | undefined) {
    reset();
    setDone(null);
    if (!file) return;
    setFileName(file.name);
    if (file.size > 5 * 1024 * 1024) return setProblem("The file is larger than 5 MB. A menu sheet is usually much smaller: check it is the right file.");
    let table: string[][];
    try {
      table = await readMenuFile(file);
    } catch (e) {
      return setProblem(e instanceof Error ? e.message : "The file could not be read.");
    }
    const { rows: found, missing } = rowsFromTable(table);
    if (missing.length > 0) return setProblem(`The first row must have the column titles. Missing: ${missing.join(", ")}. Download the template to see them.`);
    if (found.length === 0) return setProblem("The file has no menu rows under the titles.");
    if (found.length > 2000) return setProblem("Up to 2,000 rows can be uploaded at once. Split the file.");
    setRows(found);
    start(async () => {
      try {
        setCheck(await importMenu(found, false));
      } catch {
        setProblem("The check could not reach SNA POS. Look at the internet connection and choose the file again.");
      }
    });
  }

  function save() {
    if (!rows) return;
    start(async () => {
      let res: MenuImportResult;
      try {
        res = await importMenu(rows, true);
      } catch {
        setProblem("Saving could not reach SNA POS. Nothing was saved. Look at the internet connection and press Save again.");
        return;
      }
      if (res.ok && res.applied) {
        setDone(res);
        reset();
        router.refresh();
      } else setCheck(res);
    });
  }

  const checked = check && check.ok ? check : null;
  const good = !!checked && checked.errors.length === 0 && checked.newItems + checked.updatedItems > 0;
  const nothingToDo = !!checked && checked.errors.length === 0 && checked.newItems + checked.updatedItems === 0;

  return (
    <section className="card mb-5 p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h3 className="text-base font-bold">Upload the menu from Excel</h3>
          <p className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Type the whole menu in a sheet and upload it once, instead of adding dishes one by one.
          </p>
        </div>
        <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} aria-expanded={open} onClick={() => setOpen((v) => !v)}>
          {open ? "Close" : "Upload menu"}
        </button>
      </div>

      {done && done.ok && (
        <p className="mt-3 rounded-lg px-3 py-2 text-sm font-semibold" role="status" style={{ background: "var(--color-ok-soft)", color: "var(--color-ok)" }}>
          Menu saved: {done.newItems} new {done.newItems === 1 ? "dish" : "dishes"}, {done.updatedItems} changed
          {done.newCategories > 0 ? `, ${done.newCategories} new ${done.newCategories === 1 ? "category" : "categories"}` : ""}. They are on the billing screen now.
        </p>
      )}

      {open && (
        <div className="mt-4 space-y-4 text-sm">
          <ol className="list-decimal space-y-1.5 pl-5" style={{ color: "var(--color-ink-2)" }}>
            <li>
              Download the template and open it in Excel (or Google Sheets). Keep the first row as it is. One dish per row.
            </li>
            <li>
              <b>Category</b>, <b>Item name</b> and <b>Price</b> are needed. <b>Sub-category</b> is optional (for example Beverages → Hot drinks).{" "}
              <b>Tax group</b> must be one of: {taxGroups.map((t) => t.name).join(", ") || "none set up yet"}.
              {" "}Veg is Y or N.{showHsn ? " HSN code is optional." : ""}
              {showStations ? " Kitchen station sends the dish to that station's tickets." : ""}
            </li>
            <li>Save the file (Excel .xlsx or CSV) and upload it below. SNA POS checks every row and shows what it will do before anything is saved.</li>
          </ol>
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            A dish already on the menu (same name in the same category) gets the new price and details from the sheet. Dishes that are not in the sheet stay as
            they are; nothing is deleted.
          </p>
          <div className="flex flex-wrap gap-2">
            <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={template}>
              Download template
            </button>
            {products.some((p) => !p.is_charge) && (
              <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={current}>
                Download current menu
              </button>
            )}
            <label className="btn btn-primary cursor-pointer text-sm">
              Choose file to upload
              <input
                ref={input}
                type="file"
                accept=".xlsx,.csv,.txt,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                className="sr-only"
                onChange={(e) => chosen(e.target.files?.[0])}
              />
            </label>
          </div>

          {fileName && (
            <div className="rounded-xl border p-3" style={{ borderColor: "var(--color-line)" }}>
              <div className="font-semibold">{fileName}</div>
              {problem && (
                <p className="mt-2 rounded-lg px-3 py-2" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
                  {problem}
                </p>
              )}
              {pending && !problem && (
                <p className="mt-2" style={{ color: "var(--color-ink-3)" }}>
                  Checking {rows?.length ?? ""} rows…
                </p>
              )}
              {!pending && check && !check.ok && (
                <p className="mt-2 rounded-lg px-3 py-2" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
                  {check.error}
                </p>
              )}
              {!pending && checked && checked.errors.length > 0 && (
                <div className="mt-2">
                  <p className="font-semibold" role="alert" style={{ color: "var(--color-bad)" }}>
                    {checked.errors.length} {checked.errors.length === 1 ? "row needs" : "rows need"} fixing. Nothing has been saved. Correct the sheet and upload it again.
                  </p>
                  <div className="mt-2 max-h-72 overflow-y-auto rounded-lg border" style={{ borderColor: "var(--color-line)" }}>
                    <table className="w-full text-left text-xs">
                      <thead>
                        <tr style={{ color: "var(--color-ink-3)" }}>
                          <th className="px-3 py-1.5">Row</th>
                          <th className="px-3 py-1.5">Problem</th>
                        </tr>
                      </thead>
                      <tbody>
                        {checked.errors.map((e, i) => (
                          <tr key={i} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                            <td className="px-3 py-1.5 tabular-nums">{e.row > 0 ? e.row : "—"}</td>
                            <td className="px-3 py-1.5">{e.message}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}
              {!pending && good && checked && (
                <div className="mt-2">
                  <p>
                    All {rows?.length} rows are right. Saving will add <b>{checked.newItems}</b> new {checked.newItems === 1 ? "dish" : "dishes"}
                    {checked.newCategories > 0 ? (
                      <>
                        {" "}
                        and <b>{checked.newCategories}</b> new {checked.newCategories === 1 ? "category" : "categories"}
                      </>
                    ) : null}
                    , and change <b>{checked.updatedItems}</b> {checked.updatedItems === 1 ? "dish" : "dishes"} already on the menu.
                    {checked.unchangedItems > 0 ? ` ${checked.unchangedItems} are the same as now.` : ""}
                  </p>
                  <div className="mt-3 flex flex-wrap gap-2">
                    <button className="btn btn-primary text-sm" disabled={pending} onClick={save}>
                      Save to the menu
                    </button>
                    <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} disabled={pending} onClick={reset}>
                      Cancel
                    </button>
                  </div>
                </div>
              )}
              {!pending && nothingToDo && <p className="mt-2">Every dish in the file is already on the menu exactly like this. Nothing to save.</p>}
            </div>
          )}
        </div>
      )}
    </section>
  );
}
