"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { WarnIcon } from "@/components/ui";
import { shortAddr } from "@/lib/format";
import { useApp } from "@/lib/state";
import { useWallet } from "@/lib/wallet";

const TABS: [string, string][] = [
  ["Portfolio", "/app"],
  ["Mint", "/app/mint"],
  ["Redeem", "/app/redeem"],
  ["Earnings", "/app/earn"],
];

export default function AppLayout({ children }: { children: ReactNode }) {
  const pathname = usePathname() ?? "/app";
  const app = useApp();
  const wallet = useWallet();
  const c = app.chain;

  return (
    <>
      <div className="mt-[26px] hidden items-center gap-1 border-b border-line md:flex">
        {TABS.map(([label, href]) => {
          const on = pathname === href;
          return (
            <Link
              key={href}
              href={href}
              aria-current={on ? "page" : undefined}
              className={`-mb-px border-b-2 px-[14px] py-3 text-[14.5px] font-semibold hover:no-underline ${on ? "border-accent text-tx hover:text-tx" : "border-transparent text-tx2 hover:text-tx"}`}
            >
              {label}
            </Link>
          );
        })}
        <div className="ml-auto flex items-center gap-[14px]">
          <span className="whitespace-nowrap text-[12.5px] text-tx2">
            noUSD on <b className="text-tx">{c.name}</b> · <span className="num">{app.advanced ? c.token : shortAddr(c.token)}</span>
          </span>
          <button
            type="button"
            aria-pressed={app.advanced}
            onClick={app.toggleAdvanced}
            className="flex items-center gap-2 whitespace-nowrap text-[13px] font-semibold text-tx2"
          >
            Advanced
            <span className={`relative h-[18px] w-[30px] rounded-[10px] border border-line2 ${app.advanced ? "bg-accent-soft" : "bg-s2"}`}>
              <span
                className={`absolute top-[2px] h-3 w-3 rounded-full transition-[left] ${app.advanced ? "left-[14px] bg-accent" : "left-[2px] bg-tx2"}`}
              />
            </span>
          </button>
        </div>
      </div>
      <div className="mt-4 text-[12px] text-tx2 md:hidden">
        noUSD on <b className="text-tx">{c.name}</b> · <span className="num">{shortAddr(c.token)}</span>
      </div>

      {wallet.kind === "wrong" && (
        <div role="alert" className="mt-[18px] flex flex-wrap items-center gap-3 rounded-[14px] border border-warn-line bg-warn-soft px-4 py-3">
          <WarnIcon />
          <span className="min-w-0 flex-1 text-[13.5px]">
            <b>Your wallet is on another network.</b>{" "}
            <span className="text-tx2">
              You&apos;re viewing noUSD on {c.name} — switch your wallet to {c.name} to mint, redeem or claim.
            </span>
          </span>
          <button type="button" onClick={wallet.switchToViewed} className="btn-warn rounded-[10px] px-[13px] py-2 text-[13px]">
            Switch to {c.name}
          </button>
        </div>
      )}

      {wallet.connected ? (
        children
      ) : (
        <div className="mx-auto mt-10 flex max-w-[520px] flex-col items-center gap-[14px] rounded-[20px] border border-line bg-s1 p-[34px] text-center">
          <span className="flex h-[46px] w-[46px] items-center justify-center rounded-[13px] border border-accent-line bg-accent-soft">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#34E3AC" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <path d="M19 7V5a2 2 0 0 0-2-2H5a2 2 0 0 0 0 4h14a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2" />
              <path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4" />
            </svg>
          </span>
          <span className="font-display text-[20px] font-semibold">Connect a wallet</span>
          <span className="text-[14px] leading-normal text-tx2">
            To mint, redeem and claim noUSD on {c.name}. Reserves and governance are public — no wallet needed.
          </span>
          <div className="flex flex-wrap justify-center gap-[10px]">
            <button type="button" onClick={wallet.connect} className="btn-primary px-[18px] py-3 text-[14px]">
              Connect wallet
            </button>
            <Link href="/reserves" className="btn-secondary px-[18px] py-3 text-[14px] hover:no-underline">
              View reserves
            </Link>
          </div>
        </div>
      )}

      {/* Phone: a bottom tab bar holds Portfolio / Mint / Redeem / Earnings. */}
      <nav className="fixed inset-x-0 bottom-0 z-40 grid grid-cols-4 border-t border-line bg-[rgba(10,12,16,.92)] px-2 pb-[calc(14px+env(safe-area-inset-bottom,0px))] pt-[10px] backdrop-blur-[14px] md:hidden">
        {TABS.map(([label, href]) => {
          const on = pathname === href;
          return (
            <Link
              key={href}
              href={href}
              aria-current={on ? "page" : undefined}
              className={`flex min-h-[44px] items-center justify-center text-[12px] font-semibold hover:no-underline ${on ? "text-accent" : "text-tx2 hover:text-tx"}`}
            >
              {label}
            </Link>
          );
        })}
      </nav>
    </>
  );
}
