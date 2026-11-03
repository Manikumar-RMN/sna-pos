import Link from "next/link";
import { redirect } from "next/navigation";
import type { ReactNode } from "react";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import type { RegCard } from "@/lib/fo";
import { PrintButton } from "../../../../print-button";

/** The registration card the guest signs at check-in. */
export default async function RegCardPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) redirect("/front-office");
  const user = await requireUser();
  if (!has(user, "front_office") || !(can(user, "fo.view") || can(user, "fo.manage"))) redirect("/front-office");
  const { data } = await (await createClient()).rpc("fo_reg_card", { p_stay: id });
  const r = data as unknown as RegCard | null;
  if (!r) redirect(`/front-office/stay/${id}`);
  const c = user.currency_code;
  const p = r.property, s = r.stay, g = r.guest;
  const Row = ({ k, v }: { k: string; v: ReactNode }) => (
    <div className="flex gap-2 border-b py-1" style={{ borderColor: "#ccc" }}><span className="w-40 shrink-0 text-xs font-bold uppercase" style={{ color: "#555" }}>{k}</span><span className="min-h-[1.1em]">{v || ""}</span></div>
  );
  return (
    <div className="mx-auto max-w-3xl">
      <div className="no-print mb-3 flex items-center justify-between gap-3">
        <Link href={`/front-office/stay/${id}`} className="text-sm underline">← Folio</Link>
        <div className="w-48"><PrintButton label="Print registration card" /></div>
      </div>
      <div className="report-root card p-6 text-[13px] leading-snug" style={{ background: "#fff", color: "#111" }}>
        <div className="text-center">
          <div className="text-lg font-extrabold">{p.legal_name ?? p.name}</div>
          {p.address && <div className="whitespace-pre-line">{p.address}</div>}
          <div>{[p.phone, p.email].filter(Boolean).join(" · ")}</div>
          <div className="mt-2 text-base font-extrabold tracking-wide">GUEST REGISTRATION CARD</div>
        </div>
        <div className="mt-4 grid gap-x-6 sm:grid-cols-2">
          <div>
            <Row k="Guest" v={<b>{g.full_name}{g.vip ? " (VIP)" : ""}</b>} />
            <Row k="Phone" v={g.phone} />
            <Row k="Email" v={g.email} />
            <Row k="Address" v={[g.address, g.city, g.country].filter(Boolean).join(", ")} />
            <Row k="ID type" v={g.id_type} />
            <Row k="ID number" v={g.id_number} />
            <Row k="Company" v={g.company ? `${g.company}${g.company_gstin ? ` · GSTIN ${g.company_gstin}` : ""}` : ""} />
          </div>
          <div>
            <Row k="Stay no." v={`#${s.stay_no}`} />
            <Row k="Room" v={[s.room_number, s.room_type].filter(Boolean).join(" · ")} />
            <Row k="Arrival" v={`${s.arrival} (check-in from ${p.check_in_time})`} />
            <Row k="Departure" v={`${s.departure} (check-out by ${p.check_out_time})`} />
            <Row k="Nights" v={s.nights} />
            <Row k="Guests" v={`${s.adults} adult${s.adults === 1 ? "" : "s"}${s.children ? `, ${s.children} child${s.children === 1 ? "" : "ren"}` : ""}`} />
            <Row k="Rate" v={`${money(s.nightly_rate, c)} per night plus tax${s.rate_plan ? ` · ${s.rate_plan}` : ""}${s.meal_plan ? ` (${s.meal_plan})` : ""}`} />
            <Row k="Advance paid" v={r.advance_paid > 0 ? money(r.advance_paid, c) : ""} />
          </div>
        </div>
        {(g.preferences || s.notes) && <p className="mt-3"><b>Notes:</b> {[g.preferences, s.notes].filter(Boolean).join(" · ")}</p>}
        <p className="mt-6 text-[11px]">I agree to settle my account on departure and accept the hotel&apos;s rules. The hotel is not responsible for valuables left in the room.</p>
        <div className="mt-10 flex justify-between text-xs"><span className="border-t pt-1" style={{ borderColor: "#111", minWidth: "40%" }}>Guest signature</span><span className="border-t pt-1 text-right" style={{ borderColor: "#111", minWidth: "40%" }}>Front desk</span></div>
      </div>
    </div>
  );
}
