import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { UpgradeNote } from "../../upgrade-note";
import { GuestSearch } from "./guest-search";

export default async function GuestsPage() {
  const user = await requireUser();
  if (!has(user, "front_office")) return <div className="mx-auto max-w-md"><UpgradeNote feature="Front office and housekeeping" /></div>;
  if (!(can(user, "fo.view") || can(user, "fo.manage"))) return <div className="card mx-auto max-w-md p-5 text-sm">Your role does not include guest profiles.</div>;
  return (
    <div className="mx-auto max-w-3xl">
      <div className="mb-3 flex items-center justify-between gap-3">
        <h1 className="text-xl font-extrabold">Guests</h1>
        <Link href="/front-office" className="text-sm underline">Back to front office</Link>
      </div>
      <GuestSearch canManage={can(user, "fo.manage")} />
    </div>
  );
}
