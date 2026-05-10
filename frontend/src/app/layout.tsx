import type { Metadata } from "next";
import { Providers } from "./providers";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import "./globals.css";

export const metadata: Metadata = {
  title: "Carry Vault",
  description: "Self-paying USDC loan against HYPE",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="bg-zinc-950 text-zinc-100 min-h-screen">
        <Providers>
          <header className="border-b border-zinc-800 px-6 py-4 flex items-center justify-between">
            <div className="flex items-center gap-8">
              <h1 className="text-lg font-semibold">Carry Vault</h1>
              <nav className="flex gap-6 text-sm text-zinc-400">
                <a href="/" className="hover:text-zinc-100">Stats</a>
                <a href="/dashboard" className="hover:text-zinc-100">Dashboard</a>
                <a href="/deposit" className="hover:text-zinc-100">Deposit</a>
                <a href="/withdraw" className="hover:text-zinc-100">Withdraw</a>
              </nav>
            </div>
            <ConnectButton showBalance={false} />
          </header>
          <main className="max-w-5xl mx-auto px-6 py-8">{children}</main>
        </Providers>
      </body>
    </html>
  );
}