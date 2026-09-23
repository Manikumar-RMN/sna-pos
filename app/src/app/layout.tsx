import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "SNA POS",
  description: "Point of sale for small restaurants. A product of SNA.AI.",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
