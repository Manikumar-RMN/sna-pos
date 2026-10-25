import { redirect } from "next/navigation";
import { rangeQuery } from "@/lib/reports-pack";

/** The old "More reports" page. Each report now has its own page; old links land on the Reports hub. */
export default async function MoreReportsRedirect({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  redirect(`/reports${rangeQuery(await searchParams)}`);
}
