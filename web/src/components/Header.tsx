"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { CHAIN_ORDER, CHAINS } from "@/lib/data/mock";
import { shortAddr } from "@/lib/format";
import { useApp } from "@/lib/state";
import { useWallet } from "@/lib/wallet";
import { Chevron, Diamond, LiveDot, Mark, Wordmark } from "./ui";

const NAV: { label: string; href: string | null; match: (p: string) => boolean }[] = [
  { label: "App", href: "/app", match: (p) => p.startsWith("/app") },
  { label: "Reserves", href: "/reserves", match: (p) => p === "/reserves" },
  { label: "Governance", href: "/governance", match: (p) => p === "/governance" },
  { label: "Docs", href: null, match: () => false },
];

/** Closes a popover on a click outside `ref` or on Escape. */
function useDismiss(open: boolean, close: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) close();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open, close]);
  return ref;
}

export function Header() {
  const pathname = usePathname() ?? "/";
  const app = useApp();
  const wallet = useWallet();
  const [netOpen, setNetOpen] = useState(false);
  const [walletOpen, setWalletOpen] = useState(false);
  const netRef = useDismiss(netOpen, () => setNetOpen(false));
  const walletRef = useDismiss(walletOpen, () => setWalletOpen(false));
  const c = app.chain;
  const wrong = wallet.kind === "wrong";

  return (
    <header className="sticky top-0 z-50 h-16 border-b border-line bg-[rgba(10,12,16,.78)] backdrop-blur-[14px]">
      <div className="mx-auto flex h-full max-w-content items-center gap-3 px-4 md:gap-[18px] md:px-7">
        <Link href="/" aria-label="noUSD home" className="flex items-center gap-[10px] text-tx hover:text-tx hover:no-underline">
          <Mark size={24} />
          <Wordmark size={18} />
        </Link>
        <span className="num hidden flex-none whitespace-nowrap rounded-[20px] border border-line2 px-2 py-[3px] text-[11px] text-tx2 md:inline">
          v1.0.0
        </span>
        <nav className="ml-[6px] hidden gap-[2px] md:flex">
          {NAV.map((n) =>
            n.href ? (
              <Link
                key={n.label}
                href={n.href}
                className={`whitespace-nowrap rounded-[10px] px-[13px] py-2 text-[14px] font-semibold hover:no-underline ${n.match(pathname) ? "bg-s2 text-tx hover:text-tx" : "text-tx2 hover:text-tx"}`}
              >
                {n.label}
              </Link>
            ) : (
              <button
                key={n.label}
                type="button"
                onClick={() => app.showToast("Docs open in a new tab")}
                className="whitespace-nowrap rounded-[10px] px-[13px] py-2 text-[14px] font-semibold text-tx2 hover:text-tx"
              >
                {n.label}
              </button>
            ),
          )}
        </nav>

        <div className="ml-auto flex items-center gap-2 md:gap-[10px]">
          <div ref={netRef} className="relative">
            <button
              type="button"
              aria-haspopup="listbox"
              aria-expanded={netOpen}
              onClick={() => {
                setNetOpen((o) => !o);
                setWalletOpen(false);
              }}
              className="flex min-h-[40px] flex-none items-center gap-2 whitespace-nowrap rounded-[12px] border border-line2 bg-s2 px-[11px] py-2 text-[13.5px] font-semibold text-tx"
            >
              <span className="h-4 w-4 rounded-full" style={{ background: c.glyph }} />
              {c.name}
              <Chevron />
            </button>
            {netOpen && (
              <div role="listbox" className="popover absolute right-0 top-[46px] z-[60] w-[270px] bg-s1 p-2">
                <div className="px-[10px] pb-[6px] pt-2 text-[11.5px] leading-[1.45] text-tx2">
                  Each network has its own noUSD. They are separate tokens — there is no bridge.
                </div>
                {CHAIN_ORDER.map((k) => {
                  const x = CHAINS[k];
                  const viewing = k === app.chainKey;
                  return (
                    <button
                      key={k}
                      type="button"
                      role="option"
                      aria-selected={viewing}
                      disabled={!x.live}
                      onClick={() => {
                        app.setChain(k);
                        setNetOpen(false);
                      }}
                      className={`flex w-full items-center gap-[10px] rounded-[11px] p-[10px] text-left text-[14px] font-semibold ${viewing ? "bg-s3" : ""} ${x.live ? "cursor-pointer text-tx" : "cursor-not-allowed text-tx2"}`}
                    >
                      <span className="h-[18px] w-[18px] rounded-full" style={{ background: x.glyph, opacity: x.live ? 1 : 0.45 }} />
                      <span className="flex-1">{x.name}</span>
                      <span
                        className={`rounded-[20px] border px-2 py-[2px] text-[11px] font-semibold ${x.live ? "border-accent-line text-accent" : "border-line2 text-tx2"}`}
                      >
                        {!x.live ? "Soon" : viewing ? "Viewing" : "Live"}
                      </span>
                    </button>
                  );
                })}
              </div>
            )}
          </div>

          {!wallet.connected ? (
            <button type="button" onClick={wallet.connect} className="btn-primary min-h-[40px] flex-none whitespace-nowrap px-[15px] py-[9px] text-[13.5px]">
              Connect wallet
            </button>
          ) : (
            <div ref={walletRef} className="relative">
              <button
                type="button"
                aria-haspopup="menu"
                aria-expanded={walletOpen}
                onClick={() => {
                  setWalletOpen((o) => !o);
                  setNetOpen(false);
                }}
                className={`flex min-h-[40px] flex-none items-center gap-[6px] whitespace-nowrap rounded-[11px] border bg-s2 px-[9px] py-[7px] text-tx sm:gap-2 sm:rounded-[12px] sm:px-3 sm:py-2 ${wrong ? "border-warn-line" : "border-line2"}`}
              >
                {wrong ? <Diamond /> : <LiveDot />}
                <span className="num hidden text-[13px] sm:inline">{shortAddr(wallet.address)}</span>
                {/* Phone header (handoff M1): a shorter address keeps mark, network and wallet on one line. */}
                <span className="num text-[12px] sm:hidden">{`${wallet.address.slice(0, 4)}…${wallet.address.slice(-4)}`}</span>
                {wallet.kind === "contract" && (
                  <span className="rounded-[20px] border border-warn-line px-[7px] py-px text-[11px] font-semibold text-warn">Contract</span>
                )}
                {wrong && <span className="hidden text-[11px] font-semibold text-warn sm:inline">Wrong network</span>}
              </button>
              {walletOpen && (
                <div role="menu" className="popover absolute right-0 top-[46px] z-[60] w-[260px] bg-s1 p-2">
                  <div className="num break-all p-[10px] text-[11.5px] text-tx2">{wallet.address}</div>
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      void navigator.clipboard?.writeText(wallet.address).catch(() => undefined);
                      setWalletOpen(false);
                      app.showToast("Address copied");
                    }}
                    className="w-full rounded-[10px] p-[10px] text-left text-[13.5px] text-tx hover:bg-s3"
                  >
                    Copy address
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      setWalletOpen(false);
                      wallet.disconnect();
                    }}
                    className="w-full rounded-[10px] p-[10px] text-left text-[13.5px] text-danger hover:bg-s3"
                  >
                    Disconnect
                  </button>
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </header>
  );
}
