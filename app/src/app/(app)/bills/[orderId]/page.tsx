import { BillScreen } from "../bill-screen";

export default async function BillPage({ params }: { params: Promise<{ orderId: string }> }) {
  const { orderId } = await params;
  return <BillScreen orderId={orderId} from="bills" />;
}
