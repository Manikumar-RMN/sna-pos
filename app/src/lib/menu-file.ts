/**
 * Reading and writing the menu sheet (Settings → Menu → Upload menu).
 * Works in the browser with no extra library: CSV is parsed by hand, and an Excel
 * .xlsx file (a zip of XML files) is opened with the browser's own unzip and XML reader.
 */

export type MenuSheetRow = {
  row: number;
  category: string;
  sub_category: string;
  name: string;
  price: string;
  tax_group: string;
  veg: string;
  hsn: string;
  station: string;
  local_name: string;
};

/** Column titles in the template, in order. */
export const MENU_COLUMNS = [
  "Category",
  "Sub-category",
  "Item name",
  "Price",
  "Tax group",
  "Veg (Y/N)",
  "HSN code",
  "Kitchen station",
  "Name in second language",
] as const;

type Key = Exclude<keyof MenuSheetRow, "row">;

/** Which column is which, by title. Several spellings are accepted. */
const TITLES: Record<Key, string[]> = {
  category: ["category", "main category", "group"],
  sub_category: ["sub-category", "sub category", "subcategory", "sub group", "subgroup"],
  name: ["item name", "item", "name", "dish", "dish name", "product", "product name"],
  price: ["price", "rate", "selling price", "mrp"],
  tax_group: ["tax group", "tax", "gst", "tax name"],
  veg: ["veg (y/n)", "veg", "veg/non-veg", "veg / non veg", "type"],
  hsn: ["hsn code", "hsn", "hsn/sac", "sac", "hsn / sac"],
  station: ["kitchen station", "station", "kitchen"],
  local_name: ["name in second language", "second language", "local name", "tamil name", "other language"],
};

const norm = (s: string) => s.replace(/\s+/g, " ").trim().toLowerCase();

/** Turns a table (first row = titles) into menu rows. Says which needed columns are missing. */
export function rowsFromTable(table: string[][]): { rows: MenuSheetRow[]; missing: string[] } {
  // The title row is the first row that names a Category column (a title line above it is allowed).
  let head = table.findIndex((r) => r.some((c) => TITLES.category.includes(norm(c))));
  if (head < 0) head = 0;
  const titles = (table[head] ?? []).map(norm);
  const col: Partial<Record<Key, number>> = {};
  (Object.keys(TITLES) as Key[]).forEach((k) => {
    const i = titles.findIndex((t) => TITLES[k].includes(t));
    if (i >= 0) col[k] = i;
  });
  const missing = (["category", "name", "price"] as Key[]).filter((k) => col[k] === undefined).map((k) => (k === "name" ? "Item name" : k === "price" ? "Price" : "Category"));
  const get = (r: string[], k: Key) => (col[k] === undefined ? "" : String(r[col[k]!] ?? "").trim());
  const rows: MenuSheetRow[] = [];
  for (let i = head + 1; i < table.length; i++) {
    const r = table[i];
    const row: MenuSheetRow = {
      row: i + 1,
      category: get(r, "category"),
      sub_category: get(r, "sub_category"),
      name: get(r, "name"),
      price: get(r, "price"),
      tax_group: get(r, "tax_group"),
      veg: get(r, "veg"),
      hsn: get(r, "hsn"),
      station: get(r, "station"),
      local_name: get(r, "local_name"),
    };
    if (row.category || row.sub_category || row.name || row.price) rows.push(row);
  }
  return { rows, missing };
}

/** CSV as written by Excel, Google Sheets or LibreOffice: commas or semicolons, quotes, line breaks in quotes. */
export function parseCsv(text: string): string[][] {
  const src = text.replace(/^﻿/, "");
  // The separator: whichever of comma, semicolon or tab is most common in the first lines.
  const head = src.split(/\r?\n/, 10).join("\n");
  const counts = { ",": head.split(",").length, ";": head.split(";").length, "\t": head.split("\t").length };
  const sep = (Object.keys(counts) as (keyof typeof counts)[]).reduce((a, b) => (counts[b] > counts[a] ? b : a), ",");
  // Each record is put at the index of the file line it starts on, so row numbers in messages
  // match what Excel shows even when a cell holds a line break.
  const out: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  let line = 0;
  let startLine = 0;
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (quoted) {
      if (ch === '"') {
        if (src[i + 1] === '"') {
          cell += '"';
          i++;
        } else quoted = false;
      } else {
        if (ch === "\n") line++;
        cell += ch;
      }
    } else if (ch === '"') quoted = true;
    else if (ch === sep) {
      row.push(cell);
      cell = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && src[i + 1] === "\n") i++;
      row.push(cell);
      out[startLine] = row;
      row = [];
      cell = "";
      line++;
      startLine = line;
    } else cell += ch;
  }
  if (cell !== "" || row.length > 0) {
    row.push(cell);
    out[startLine] = row;
  }
  return Array.from(out, (r) => r ?? []);
}

/** A CSV file Excel opens correctly, Tamil and other scripts included (UTF-8 with a BOM). */
export function toCsv(table: (string | number)[][]): string {
  const esc = (v: string | number) => {
    const s = String(v ?? "");
    return /[",\n\r]/.test(s) || /^\s|\s$/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return "﻿" + table.map((r) => r.map(esc).join(",")).join("\r\n") + "\r\n";
}

// ---------------------------------------------------------------- Excel (.xlsx)

async function inflate(data: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([data as BlobPart]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** The files inside a zip, read from its central directory. */
async function unzip(buf: ArrayBuffer, wanted: (name: string) => boolean): Promise<Map<string, string>> {
  const view = new DataView(buf);
  const bytes = new Uint8Array(buf);
  let eocd = -1;
  for (let i = buf.byteLength - 22; i >= Math.max(0, buf.byteLength - 66000); i--) {
    if (view.getUint32(i, true) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error("This is not an Excel file.");
  const count = view.getUint16(eocd + 10, true);
  let p = view.getUint32(eocd + 16, true);
  const out = new Map<string, string>();
  const dec = new TextDecoder("utf-8");
  for (let n = 0; n < count; n++) {
    if (view.getUint32(p, true) !== 0x02014b50) break;
    const method = view.getUint16(p + 10, true);
    const size = view.getUint32(p + 20, true);
    const nameLen = view.getUint16(p + 28, true);
    const extraLen = view.getUint16(p + 30, true);
    const commentLen = view.getUint16(p + 32, true);
    const local = view.getUint32(p + 42, true);
    const name = dec.decode(bytes.subarray(p + 46, p + 46 + nameLen));
    p += 46 + nameLen + extraLen + commentLen;
    if (!wanted(name)) continue;
    const lNameLen = view.getUint16(local + 26, true);
    const lExtraLen = view.getUint16(local + 28, true);
    const start = local + 30 + lNameLen + lExtraLen;
    const raw = bytes.subarray(start, start + size);
    const data = method === 0 ? raw : method === 8 ? await inflate(raw) : null;
    if (!data) throw new Error("This Excel file is packed in a way SNA POS cannot read. Save it as CSV and upload that.");
    out.set(name, dec.decode(data));
  }
  return out;
}

/** Column letters of a cell reference ("C12" → 2). */
function colIndex(ref: string): number {
  const letters = ref.replace(/[0-9]/g, "");
  let n = 0;
  for (const ch of letters) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
}

/** The first sheet of an .xlsx file as a table of text. */
export async function readXlsx(file: File): Promise<string[][]> {
  if (typeof DecompressionStream === "undefined") throw new Error("This browser cannot open Excel files. Save the sheet as CSV and upload that.");
  const files = await unzip(await file.arrayBuffer(), (n) => /^xl\/(workbook\.xml|_rels\/workbook\.xml\.rels|sharedStrings\.xml|worksheets\/sheet\d+\.xml)$/.test(n));
  const xml = (s: string) => new DOMParser().parseFromString(s, "application/xml");

  // Shared texts.
  const shared: string[] = [];
  const ss = files.get("xl/sharedStrings.xml");
  if (ss) for (const si of Array.from(xml(ss).getElementsByTagNameNS("*", "si"))) shared.push(Array.from(si.getElementsByTagNameNS("*", "t")).map((t) => t.textContent ?? "").join(""));

  // The first sheet in the workbook's own order.
  let sheetPath = "xl/worksheets/sheet1.xml";
  const wb = files.get("xl/workbook.xml");
  const rels = files.get("xl/_rels/workbook.xml.rels");
  if (wb && rels) {
    const first = xml(wb).getElementsByTagNameNS("*", "sheet")[0];
    const rid = first?.getAttribute("r:id") ?? first?.getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id");
    const rel = Array.from(xml(rels).getElementsByTagNameNS("*", "Relationship")).find((r) => r.getAttribute("Id") === rid);
    const target = rel?.getAttribute("Target");
    if (target) sheetPath = target.startsWith("/") ? target.slice(1) : `xl/${target.replace(/^\.\//, "")}`;
  }
  const sheet = files.get(sheetPath) ?? files.get("xl/worksheets/sheet1.xml");
  if (!sheet) throw new Error("The Excel file has no sheet SNA POS can read.");

  const table: string[][] = [];
  for (const row of Array.from(xml(sheet).getElementsByTagNameNS("*", "row"))) {
    const r = Number(row.getAttribute("r") ?? table.length + 1) - 1;
    const cells: string[] = [];
    for (const c of Array.from(row.getElementsByTagNameNS("*", "c"))) {
      const ref = c.getAttribute("r");
      const i = ref ? colIndex(ref) : cells.length;
      const type = c.getAttribute("t");
      const v = c.getElementsByTagNameNS("*", "v")[0]?.textContent ?? "";
      let text = "";
      if (type === "s") text = shared[Number(v)] ?? "";
      else if (type === "inlineStr") text = Array.from(c.getElementsByTagNameNS("*", "t")).map((t) => t.textContent ?? "").join("");
      else if (type === "b") text = v === "1" ? "TRUE" : "FALSE";
      else text = v;
      // Excel keeps 120.5 as "120.5" and 0.1+0.2 style noise as many digits; round plain numbers to 6 places.
      if (!type && /^-?\d+\.\d{7,}$/.test(text)) text = String(Math.round(Number(text) * 1e6) / 1e6);
      cells[i] = text;
    }
    table[r] = Array.from(cells, (x) => x ?? "");
  }
  return Array.from(table, (x) => x ?? []);
}

/** Reads an uploaded menu file: .xlsx, .csv or .txt. */
export async function readMenuFile(file: File): Promise<string[][]> {
  const name = file.name.toLowerCase();
  if (name.endsWith(".xls")) throw new Error("Old Excel (.xls) files cannot be read. In Excel choose File → Save As → Excel Workbook (.xlsx) or CSV, and upload that.");
  if (name.endsWith(".xlsx")) return readXlsx(file);
  return parseCsv(await file.text());
}
