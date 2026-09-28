import type { Metadata, Viewport } from "next";
import { Figtree, Sora } from "next/font/google";
import "./globals.css";

const figtree = Figtree({ subsets: ["latin"], variable: "--font-figtree", display: "swap" });
const sora = Sora({ subsets: ["latin"], weight: ["600", "700", "800"], variable: "--font-sora", display: "swap" });

export const metadata: Metadata = {
  title: "SNA POS",
  description: "Point of sale for restaurants and cafés. A product of SNA.AI.",
  manifest: "/manifest.webmanifest",
  icons: { icon: "/icon-192.png", apple: "/apple-touch-icon.png" },
  appleWebApp: { capable: true, title: "SNA POS", statusBarStyle: "default" },
};

export const viewport: Viewport = { themeColor: "#1E4D2B" };

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${figtree.variable} ${sora.variable}`}>
      <body>{children}</body>
    </html>
  );
}
