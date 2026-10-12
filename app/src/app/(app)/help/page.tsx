import type { Metadata } from "next";
import { requireUser } from "@/lib/auth";
import { HelpView } from "@/components/help-view";
import { POS_GUIDE } from "@/lib/help/pos-guide";

export const metadata: Metadata = { title: "Help" };

/** The User Help Guide inside SNA POS. Open to everyone signed in, also while the licence is read-only. */
export default async function HelpPage() {
  await requireUser();
  return (
    <HelpView
      guide={POS_GUIDE}
      title="Help"
      intro="How to bill, run the kitchen, close the day, and set up SNA POS. Search for a word or pick a topic."
    />
  );
}
