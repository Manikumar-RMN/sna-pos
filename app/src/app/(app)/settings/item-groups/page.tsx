import Page from "../../stock/lists/page";

// Same screen as stock/lists, shown inside Setup (menu on the left, no back link).
export default function SetupPage() {
  return Page({ searchParams: Promise.resolve({ from: "embedded" }) });
}
