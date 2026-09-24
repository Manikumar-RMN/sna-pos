import { BillScreen } from "../../../bills/bill-screen";

export default async function ReceiptPage({ params }: { params: Promise<{ orderId: string }> }) {
  const { orderId } = await params;
  return <BillScreen orderId={orderId} from="pos" />;
}
