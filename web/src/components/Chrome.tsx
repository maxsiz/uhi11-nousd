"use client";

import { shortAddr } from "@/lib/format";
import { useApp, type DemoMint, type DemoWallet } from "@/lib/state";
import { IS_DEMO } from "@/lib/wagmi";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { LiveDot } from "./ui";

export function Footer() {
  const app = useApp();
  return (
    <footer className="border-t border-line">
      <div className="mx-auto flex max-w-content flex-col justify-between gap-3 px-4 py-[22px] text-[13px] text-tx2 sm:flex-row sm:items-center md:px-7">
        <span className="flex items-center gap-[14px]">
          <span className="font-display font-bold text-tx">noUSD</span>— powered by Envelop
        </span>
        <span className="num flex flex-wrap gap-[18px] text-[12px]">
          <span>
            noUSD {app.chain.name} {app.advanced ? app.chain.token : shortAddr(app.chain.token)}
          </span>
          <a href="https://github.com/maxsiz/uhi11-nousd" target="_blank" rel="noreferrer">
            GitHub
          </a>
        </span>
      </div>
    </footer>
  );
}

/** Bottom-center toast: s2 with an accent-line border, rises in, gone after 2.4 s. */
export function Toast() {
  const { toast } = useApp();
  if (!toast) return null;
  return (
    <div
      key={toast}
      role="status"
      className="fixed bottom-[calc(28px+env(safe-area-inset-bottom,0px))] left-1/2 z-[90] flex -translate-x-1/2 animate-nu-rise items-center gap-[9px] whitespace-nowrap rounded-[12px] border border-accent-line bg-s2 px-4 py-[11px] text-[13.5px] text-tx shadow-pop"
    >
      <LiveDot />
      {toast}
    </div>
  );
}

/**
 * The prototype's "Prototype states" dock: forces wallet types, mint outcomes, the redeem delay and a
 * refused payout. Demo mode only; it disappears once the app runs against deployed contracts.
 */
export function DemoDock() {
  const app = useApp();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  if (!IS_DEMO) return null;

  const opt = (label: string, on: boolean, pick: () => void) => (
    <button
      key={label}
      type="button"
      aria-pressed={on}
      onClick={pick}
      className={`whitespace-nowrap rounded-[8px] border px-2 py-1 text-[11.5px] font-semibold ${on ? "border-accent-line bg-accent-soft text-accent" : "border-line2 bg-s2 text-tx2"}`}
    >
      {label}
    </button>
  );
  const wallet = (w: DemoWallet, label: string) => opt(label, app.demoWallet === w, () => app.setDemoWallet(w));
  // Like the prototype, a forced outcome also opens the screen that shows it.
  const mint = (m: DemoMint, label: string) =>
    opt(label, app.demoMint === m, () => {
      app.setDemoMint(m);
      if (m !== "normal") router.push("/app/mint");
    });

  const groups: [string, React.ReactNode[]][] = [
    ["Wallet", [wallet("none", "Disconnected"), wallet("eoa", "Wallet"), wallet("contract", "Contract"), wallet("wrong", "Wrong network")]],
    ["Mint outcome", [mint("normal", "Normal"), mint("offpeg", "USDT off par"), mint("paused", "Paused"), mint("slippage", "Slippage"), mint("expired", "Expired")]],
    ["Redeem delay", [opt("0 (launch)", !app.redeemDelay, () => app.setRedeemDelay(false)), opt("24 h", app.redeemDelay, () => {
      app.setRedeemDelay(true);
      router.push("/app/redeem");
    })]],
    ["USDT refuses my wallet", [opt("Off", !app.usdtRefuses, () => app.setUsdtRefuses(false)), opt("On", app.usdtRefuses, () => {
      app.setUsdtRefuses(true);
      app.setDest("wallet");
      router.push("/app/redeem");
    })]],
    ["Network data", [opt("Show loading", app.loading, () => app.flashLoading(1800))]],
  ];

  return (
    <div
      className="fixed bottom-[96px] left-4 z-[70] hidden rounded-card border border-line2 bg-[rgba(16,19,25,.96)] shadow-pop backdrop-blur-[10px] md:bottom-4 md:block"
      style={{ width: open ? 300 : 200 }}
    >
      <button
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        className="flex w-full items-center justify-between px-[14px] py-[11px] text-[12px] font-bold tracking-[.08em] text-tx"
      >
        PROTOTYPE STATES<span className="num text-tx2">{open ? "−" : "+"}</span>
      </button>
      {open && (
        <div className="flex flex-col gap-[11px] px-[14px] pb-[14px]">
          {groups.map(([label, opts]) => (
            <div key={label} className="flex flex-col gap-[5px]">
              <span className="text-[11px] font-semibold text-tx2">{label}</span>
              <div className="flex flex-wrap gap-1">{opts}</div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
