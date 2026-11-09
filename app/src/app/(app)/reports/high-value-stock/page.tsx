import { WatchReport } from "../stock-watch/watch";

export default function Page({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; days?: string; cutoff?: string }> }) {
  return <WatchReport kind="high_value" searchParams={searchParams} />;
}
