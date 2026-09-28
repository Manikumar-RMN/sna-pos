import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { RestaurantPanel, type SnaRestaurant } from "./restaurant-panel";

export default async function SnaRestaurantPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const [{ data, error }, { data: me }] = await Promise.all([supabase.rpc("sna_restaurant", { p_id: id }), supabase.rpc("sna_me")]);
  if (error?.message?.includes("not found")) notFound();
  if (error || !data) return <div className="card p-5 text-sm">{error?.message ?? "Could not load."}</div>;
  return (
    <div>
      <Link href="/sna" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← All restaurants
      </Link>
      <RestaurantPanel r={data as unknown as SnaRestaurant} role={(me as { role?: string } | null)?.role ?? "support"} />
    </div>
  );
}
