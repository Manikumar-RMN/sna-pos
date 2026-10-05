"use client";

import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ReceiptView, type ReceiptData } from "@/app/(app)/pos/receipt-view";
import type { BillFormat } from "@/lib/bill-format";
import { saveBillLayout } from "../actions";

/** The logo is stored inside the database, so it is kept small. */
const LOGO_MAX_SIDE = 240;
const LOGO_MAX_CHARS = 140_000;
/** A PNG this small is kept as it is (sharp edges, see-through background). */
const LOGO_SMALL_PNG = 60_000;

const TOO_DETAILED = "This picture is too detailed to print as a logo. Use a simpler picture.";
const CANNOT_OPEN = "This picture could not be opened. Choose a PNG or JPEG picture.";

function loadPicture(file: File): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error(CANNOT_OPEN));
    };
    img.src = url;
  });
}

function drawPicture(img: HTMLImageElement, w: number, h: number, kind: "image/png" | "image/jpeg"): string | null {
  try {
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    if (kind === "image/jpeg") {
      // JPEG has no see-through parts: they would print black without this.
      ctx.fillStyle = "#fff";
      ctx.fillRect(0, 0, w, h);
    }
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(img, 0, 0, w, h);
    const url = kind === "image/jpeg" ? canvas.toDataURL(kind, 0.85) : canvas.toDataURL(kind);
    return url.startsWith(`data:${kind};base64,`) ? url : null;
  } catch {
    return null;
  }
}

/**
 * Shrinks the chosen picture to a logo the database accepts: at most 240 pixels
 * wide (and tall), as a PNG when that is small, otherwise a JPEG, and never more
 * than 140,000 characters. Throws an Error with a message for the owner.
 */
async function makeLogo(file: File): Promise<string> {
  // Some tablets do not say what kind of file it is; the name is used then.
  const kind = file.type || (/\.png$/i.test(file.name) ? "image/png" : /\.jpe?g$/i.test(file.name) ? "image/jpeg" : "");
  if (kind !== "image/png" && kind !== "image/jpeg") throw new Error("Choose a PNG or JPEG picture.");
  const img = await loadPicture(file);
  const fullW = img.naturalWidth;
  const fullH = img.naturalHeight;
  if (!(fullW > 0 && fullH > 0)) throw new Error(CANNOT_OPEN);

  let scale = Math.min(1, LOGO_MAX_SIDE / fullW, LOGO_MAX_SIDE / fullH);
  for (let attempt = 0; attempt < 6; attempt++) {
    const w = Math.max(1, Math.round(fullW * scale));
    const h = Math.max(1, Math.round(fullH * scale));
    const png = drawPicture(img, w, h, "image/png");
    if (png && png.length <= LOGO_SMALL_PNG) return png;
    const jpeg = drawPicture(img, w, h, "image/jpeg");
    const fits = [png, jpeg].filter((u): u is string => !!u && u.length <= LOGO_MAX_CHARS).sort((a, b) => a.length - b.length);
    if (fits.length > 0) return fits[0];
    if (!png && !jpeg) throw new Error(CANNOT_OPEN);
    scale *= 0.7;
  }
  throw new Error(TOO_DETAILED);
}

const FORMAT_KEYS: (keyof BillFormat)[] = [
  "paper",
  "text",
  "kot_text",
  "logo",
  "legal_name",
  "branch",
  "address",
  "phone",
  "cashier",
  "guest",
  "rate",
  "upi_qr",
  "powered_by",
];

type OnOffKey = "logo" | "legal_name" | "branch" | "address" | "phone" | "cashier" | "guest" | "rate" | "upi_qr" | "powered_by";

export function BillLayout({
  initialFormat,
  initialLogo,
  sample,
  isIndia,
  hasUpiId,
  severalOutlets,
}: {
  initialFormat: BillFormat;
  /** The logo belongs to the restaurant: every outlet prints the same one. */
  initialLogo: string | null;
  /** A made-up paid bill under the restaurant's real name and details. */
  sample: ReceiptData;
  isIndia: boolean;
  /** A UPI ID is set in Payment methods, so the QR can print. */
  hasUpiId: boolean;
  severalOutlets: boolean;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [fmt, setFmt] = useState(initialFormat);
  const [logo, setLogo] = useState(initialLogo);
  // What is saved now, to know whether anything on this page has changed.
  const [saved, setSaved] = useState({ fmt: initialFormat, logo: initialLogo });
  const [show, setShow] = useState<"paid" | "unpaid">("paid");
  const [reading, setReading] = useState(false);
  const [logoError, setLogoError] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  const logoChanged = logo !== saved.logo;
  const dirty = logoChanged || FORMAT_KEYS.some((k) => fmt[k] !== saved.fmt[k]);

  function change(patch: Partial<BillFormat>) {
    setFmt((f) => ({ ...f, ...patch }));
    setMsg(null);
  }

  async function chooseLogo(file: File | undefined) {
    if (!file) return;
    setLogoError(null);
    setMsg(null);
    setReading(true);
    try {
      setLogo(await makeLogo(file));
    } catch (e) {
      setLogoError(e instanceof Error && e.message ? e.message : CANNOT_OPEN);
    } finally {
      setReading(false);
    }
  }

  function save() {
    setMsg(null);
    const sent = { fmt, logo };
    start(async () => {
      const r = await saveBillLayout(sent.fmt, sent.logo !== saved.logo ? (sent.logo ?? "") : undefined);
      if (!r.ok) return setMsg({ ok: false, text: r.error });
      setSaved(sent);
      setMsg({ ok: true, text: r.message ?? "Saved." });
      router.refresh();
    });
  }

  const preview: ReceiptData = {
    ...sample,
    ...(show === "unpaid" ? { state: "unpaid" as const, payments: [], balance: sample.grandTotal } : {}),
    format: fmt,
    logo,
  };

  const rows: { key: OnOffKey; label: string; hint?: string }[] = [
    { key: "logo", label: "Logo", hint: logo ? undefined : "Add a logo above first." },
    { key: "legal_name", label: "Registered business name", hint: "Printed under the name customers see, when the two are different." },
    { key: "branch", label: "Outlet name" },
    { key: "address", label: "Address" },
    { key: "phone", label: "Phone number" },
    { key: "cashier", label: "Cashier name" },
    { key: "guest", label: "Guest name and phone", hint: "And the delivery address, when one was taken." },
    { key: "rate", label: "Rate column", hint: "The price of one, beside the quantity." },
    ...(isIndia
      ? [
          {
            key: "upi_qr" as const,
            label: "UPI scan-to-pay QR on unpaid bills",
            hint: hasUpiId ? "The customer scans it to pay the exact amount." : "Needs your UPI ID. Add it in Settings → Payment methods.",
          },
        ]
      : []),
    { key: "powered_by", label: "“Billed on SNA POS” line" },
  ];

  return (
    <div className="flex flex-col gap-4 lg:flex-row lg:items-start">
      <div className="min-w-0 flex-1 space-y-4">
        <section className="card p-5">
          <h2 className="text-base font-bold">Logo</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Printed at the top of the bill. A simple black-and-white picture prints best. It is made small automatically.
            {severalOutlets ? " The logo is used by every outlet; the layout choices below are for this outlet only." : ""}
          </p>
          <div className="mt-4 flex flex-wrap items-center gap-3">
            {logo && (
              <span className="grid h-20 min-w-20 place-items-center rounded-2xl border px-3" style={{ borderColor: "var(--color-line)", background: "#fff" }}>
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={logo} alt="Your logo" style={{ maxHeight: 64, maxWidth: 200 }} />
              </span>
            )}
            <input
              ref={fileInput}
              type="file"
              accept="image/png,image/jpeg"
              hidden
              onChange={(e) => {
                const file = e.target.files?.[0];
                // Cleared so the same file can be chosen again.
                e.target.value = "";
                void chooseLogo(file);
              }}
            />
            <button type="button" className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} disabled={reading || pending} onClick={() => fileInput.current?.click()}>
              {reading ? "Reading…" : logo ? "Change picture" : "Choose a picture"}
            </button>
            {logo && (
              <button
                type="button"
                className="min-h-12 rounded-lg px-2 text-sm font-semibold"
                style={{ color: "var(--color-bad)" }}
                disabled={reading || pending}
                onClick={() => {
                  setLogo(null);
                  setLogoError(null);
                  setMsg(null);
                }}
              >
                Remove
              </button>
            )}
            {!logo && saved.logo && (
              <button type="button" className="min-h-12 rounded-lg px-2 text-sm font-semibold" style={{ color: "var(--color-brand)" }} onClick={() => setLogo(saved.logo)}>
                Put it back
              </button>
            )}
          </div>
          <p className="mt-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            PNG or JPEG.{logoChanged ? (logo ? " New logo: tap Save changes to keep it." : " Logo removed: tap Save changes to confirm.") : ""}
          </p>
          {logoError && (
            <p className="mt-2 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
              {logoError}
            </p>
          )}
        </section>

        <section className="card space-y-4 p-5">
          <h2 className="text-base font-bold">Paper and text size</h2>
          <Choice
            label="Paper roll"
            value={fmt.paper}
            onChange={(paper) => change({ paper })}
            options={[
              { value: "80", label: "80 mm" },
              { value: "58", label: "58 mm" },
            ]}
          />
          <Choice
            label="Text on the bill"
            value={fmt.text}
            onChange={(text) => change({ text })}
            options={[
              { value: "small", label: "Small" },
              { value: "normal", label: "Normal" },
              { value: "large", label: "Large" },
            ]}
          />
          <Choice
            label="Text on the kitchen ticket"
            hint="Changes the kitchen ticket only, so the preview stays the same."
            value={fmt.kot_text}
            onChange={(kot_text) => change({ kot_text })}
            options={[
              { value: "normal", label: "Normal" },
              { value: "large", label: "Large" },
            ]}
          />
        </section>

        <section className="card p-5">
          <h2 className="text-base font-bold">What is printed</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Untick a line to leave it off the bill. Tax numbers and totals are always printed.
          </p>
          <div className="mt-3 grid gap-x-6 sm:grid-cols-2 lg:grid-cols-1 xl:grid-cols-2">
            {rows.map((r) => (
              <label key={r.key} className="flex min-h-12 items-start gap-3 py-2 text-sm">
                <input
                  type="checkbox"
                  className="mt-0.5 h-5 w-5 shrink-0"
                  checked={fmt[r.key]}
                  onChange={(e) => {
                    change({ [r.key]: e.target.checked });
                    // The QR is only on unpaid bills: show one, so the change can be seen.
                    if (r.key === "upi_qr") setShow("unpaid");
                  }}
                />
                <span>
                  {r.label}
                  {r.hint && (
                    <span className="block text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                      {r.hint}
                    </span>
                  )}
                </span>
              </label>
            ))}
          </div>
        </section>

        <div>
          <button type="button" className="btn btn-primary" disabled={pending || reading || !dirty} onClick={save}>
            {pending ? "Saving…" : "Save changes"}
          </button>
          {dirty && !pending && (
            <span className="ml-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
              The preview shows your changes. They are not saved yet.
            </span>
          )}
          {msg && (
            <p
              className="mt-3 rounded-lg px-3 py-2 text-sm"
              role={msg.ok ? "status" : "alert"}
              style={{ background: msg.ok ? "var(--color-ok-soft)" : "var(--color-bad-soft)", color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}
            >
              {msg.text}
            </p>
          )}
        </div>
      </div>

      <aside className="rounded-[22px] border p-3 lg:sticky lg:top-3 lg:w-[336px] lg:shrink-0" style={{ borderColor: "var(--color-line)", background: "var(--color-surface-2)" }}>
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-base font-bold">Preview</h2>
          <div role="group" aria-label="Which bill to preview" className="flex overflow-hidden rounded-lg border" style={{ borderColor: "var(--color-line)" }}>
            {(["paid", "unpaid"] as const).map((s) => (
              <button
                key={s}
                type="button"
                aria-pressed={show === s}
                onClick={() => setShow(s)}
                className="min-h-9 px-3 text-xs font-semibold"
                style={{ background: show === s ? "var(--color-brand)" : "var(--color-surface)", color: show === s ? "#fff" : "var(--color-ink-2)" }}
              >
                {s === "paid" ? "Paid bill" : "Unpaid bill"}
              </button>
            ))}
          </div>
        </div>
        {/*
          The real bill, so what you see is what prints. Its own buttons (back,
          Print) are hidden and nothing in it can be tapped.
        */}
        <style>{`.bill-preview .no-print { display: none !important; }`}</style>
        <div className="overflow-x-auto">
          <div className="bill-preview pointer-events-none mx-auto w-fit select-none">
            <ReceiptView data={preview} showNextBill={false} />
          </div>
        </div>
        <p className="mt-3 text-center text-[11px]" style={{ color: "var(--color-ink-3)" }}>
          A sample bill with made-up dishes, under your own name, address and tax details.
        </p>
      </aside>
    </div>
  );
}

/** A small set of either/or buttons, e.g. 80 mm / 58 mm. */
function Choice<T extends string>({
  label,
  hint,
  value,
  options,
  onChange,
}: {
  label: string;
  hint?: string;
  value: T;
  options: { value: T; label: string }[];
  onChange: (v: T) => void;
}) {
  return (
    <div>
      <div className="mb-1 text-xs font-semibold">{label}</div>
      <div role="group" aria-label={label} className="flex w-fit overflow-hidden rounded-lg border" style={{ borderColor: "var(--color-line)" }}>
        {options.map((o) => (
          <button
            key={o.value}
            type="button"
            aria-pressed={value === o.value}
            onClick={() => onChange(o.value)}
            className="min-h-11 px-4 text-sm font-semibold"
            style={{ background: value === o.value ? "var(--color-brand)" : "transparent", color: value === o.value ? "#fff" : "var(--color-ink-2)" }}
          >
            {o.label}
          </button>
        ))}
      </div>
      {hint && (
        <div className="mt-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
          {hint}
        </div>
      )}
    </div>
  );
}
