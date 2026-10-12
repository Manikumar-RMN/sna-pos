import type { Metadata } from "next";
import { HelpView } from "@/components/help-view";
import { CONSOLE_GUIDE } from "@/lib/help/console-guide";

export const metadata: Metadata = { title: "Help · SNA console" };

/** The SNA Console Staff Guide inside the console. The console layout already checks the SNA staff sign-in. */
export default function ConsoleHelpPage() {
  return (
    <HelpView
      guide={CONSOLE_GUIDE}
      title="Console help"
      intro="How to create clients, keep licences, record sales, and take a client live. Search for a word or pick a topic."
    />
  );
}
