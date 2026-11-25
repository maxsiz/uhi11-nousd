import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import "./globals.css";
import { DemoBanner, DemoDock, Footer, Toast } from "@/components/Chrome";
import { Header } from "@/components/Header";
import { Providers } from "./providers";

// Space Grotesk (display), Hanken Grotesk (UI), JetBrains Mono (data). Variable latin files kept in the
// repo, not fetched from Google at build time: with Turbopack an undelivered woff2 fails the build
// (stablelp-ui lost six days of builds to one Google 404).
const display = localFont({ src: "./fonts/space-grotesk-latin.woff2", weight: "400 700", display: "swap", variable: "--font-display" });
const sans = localFont({ src: "./fonts/hanken-grotesk-latin.woff2", weight: "100 900", display: "swap", variable: "--font-sans" });
const mono = localFont({ src: "./fonts/jetbrains-mono-latin.woff2", weight: "100 800", display: "swap", variable: "--font-mono" });

export const metadata: Metadata = {
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL || "https://nousd.envelop.is"),
  title: { default: "noUSD — one stablecoin, backed by Uniswap v4 stable liquidity", template: "%s — noUSD" },
  description:
    "Deposit any allowed stable, get noUSD and earn the pool fees. Redeem for the basket any time, to any address. In the Envelop family.",
};

export const viewport: Viewport = { themeColor: "#0A0C10", width: "device-width", initialScale: 1, viewportFit: "cover" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${display.variable} ${sans.variable} ${mono.variable}`}>
      <body className="flex min-h-screen flex-col bg-bg font-sans text-[14px] text-tx antialiased">
        <Providers>
          <DemoBanner />
          <Header />
          <main className="mx-auto w-full max-w-content flex-1 px-4 pb-28 md:px-7 md:pb-20">{children}</main>
          <Footer />
          <Toast />
          <DemoDock />
        </Providers>
      </body>
    </html>
  );
}
