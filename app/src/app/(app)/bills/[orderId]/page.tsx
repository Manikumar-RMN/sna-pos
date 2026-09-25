import { BillScreen } from "../bill-screen";

export default async function BillPage({
  params,
  searchParams,
}: {
  params: Promise<{ orderId: string }>;
  searchParams: Promise<{ pay?: string }>;
}) {
  const { orderId } = await params;
  const { pay } = await searchParams;
  return <BillScreen orderId={orderId} from="bills" splitPay={pay === "split"} />;
}
