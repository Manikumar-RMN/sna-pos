import Page from "../../purchases/rules/page";

// Same screen as purchases/rules, shown inside Setup (menu on the left, no back link).
export default function SetupPage() {
  return Page({ searchParams: Promise.resolve({ from: "embedded" }) });
}
