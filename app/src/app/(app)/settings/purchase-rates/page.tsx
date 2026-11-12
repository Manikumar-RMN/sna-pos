import Page from "../../purchases/rates/page";

// Same screen as purchases/rates, shown inside Setup (menu on the left, no back link).
export default function SetupPage() {
  return Page({ searchParams: Promise.resolve({ from: "embedded" }) });
}
