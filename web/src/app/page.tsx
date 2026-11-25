"use client";

import Link from "next/link";
import { useState } from "react";
import { LiveDot, PairChips, Skeleton, TokenChip } from "@/components/ui";
import { UnlockCycle } from "@/components/UnlockCycle";
import { FAQ } from "@/lib/data/mock";
import { duration, fmt } from "@/lib/format";
import { basketByToken } from "@/lib/preview";
import { useApp, useMountedAt, useNow } from "@/lib/state";

const HOW_ICONS: string[][] = [
  ["M19 7V5a2 2 0 0 0-2-2H5a2 2 0 0 0 0 4h14a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2", "M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"],
  ["m12 2 9 5-9 5-9-5 9-5z", "m3 12 9 5 9-5", "m3 17 9 5 9-5"],
  ["M12 2v20", "M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"],
  ["M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4", "m16 17 5-5-5-5", "M21 12H9"],
];

const HOW_STEPS: [string, string, string, boolean][] = [
  ["01 · MINT", "Deposit a stable", "USDC, USDT, DAI or USDe. You get noUSD for the value it adds.", false],
  ["02 · SAME TX", "Works as Uniswap v4 liquidity", "A small part may be swapped to pair it (≈ 0.01–0.03 %). Leftover comes back.", false],
  ["03 · HOLD", "Fees accrue to holders", "Earnings grow at every sync — hourly on L2, daily on Ethereum.", true],
  ["04 · EXIT OR KEEP", "Claim or Redeem", "Claim earnings and keep holding — or redeem for the basket, to any address.", false],
];

const SAFE: [string, string][] = [
  ["No operator can move funds", "Liquidity only moves on mint, redeem, claim and the public sync."],
  ["Immutable contracts, caps in code", "No upgrades. Every parameter has a hard limit governance can't exceed."],
  ["Loosening waits 48 h", "Queued on-chain and visible, so holders can leave first."],
  ["Redeem and claim can't be paused", "There is no switch for exits — not even for the multisig."],
  ["The price guard only gates minting", "It opens minting when prices are fresh. It never blocks exits."],
];

function StackedBar({ parts, height }: { parts: { sym: string; pct: number; color: string }[]; height: number }) {
  return (
    <div className="flex gap-[2px] overflow-hidden" style={{ height, borderRadius: height / 2 }}>
      {parts.map((p) => (
        <span key={p.sym} style={{ width: `${p.pct}%`, background: p.color, boxShadow: "inset 0 0 0 1px rgba(255,255,255,.35)" }} />
      ))}
    </div>
  );
}

export default function Landing() {
  const app = useApp();
  const c = app.chain;
  const now = useNow();
  const t0 = useMountedAt();
  const [faq, setFaq] = useState(0);

  const sinceSync = (c.lastSyncAgoMs + (now - t0)) % c.periodMs;
  const basket = basketByToken(c);
  const colors: Record<string, string> = { USDC: "#2775CA", USDT: "#26A17B", DAI: "#F5AC37", USDe: "#111111", USDS: "#F4B731", RLUSD: "#0B1F3A" };
  const bar = basket.map((b) => ({ sym: b.sym, pct: b.pct, color: colors[b.sym] }));
  const active = c.pools.filter((p) => p.status === "Active").length;
  const idleSum = c.idle.reduce((a, b) => a + b[1], 0);

  const strip: { label: string; value: string; accent?: boolean }[] = [
    { label: "noUSD supply", value: fmt(c.supply) },
    { label: "Backing at par", value: fmt(c.backing) },
    { label: "Holder APR · 7d", value: `${c.apr7.toFixed(1)} %`, accent: true },
    { label: "Pools", value: `${active} active · ${c.pools.length - active} exit-only` },
    { label: "Last sync", value: `${duration(sinceSync)} ago` },
  ];

  return (
    <>
      <section className="grid grid-cols-[minmax(0,1fr)] items-center gap-10 pb-10 pt-12 md:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)] md:gap-12 md:pt-[72px]">
        <div className="flex flex-col gap-[22px]">
          <span className="flex items-center gap-2 self-start whitespace-nowrap rounded-[20px] border border-accent-line bg-accent-soft px-[11px] py-[5px] text-[12px] font-semibold text-accent">
            <LiveDot />
            <span>Live on {c.name} · in the Envelop family</span>
          </span>
          <h1 className="m-0 text-balance font-display text-[36px] font-bold leading-[1.06] tracking-[-.025em] md:text-[50px]">
            One stablecoin, backed by Uniswap v4 stable liquidity. Earn the fees.
          </h1>
          <p className="m-0 max-w-[520px] text-pretty text-[17px] leading-[1.55] text-tx2">
            Deposit any allowed stable. Redeem for the basket any time, to any address.
          </p>
          <div className="flex flex-wrap gap-[10px]">
            <Link href="/app" className="btn-primary px-5 py-[13px] text-[15px] hover:text-ink hover:no-underline">
              Open the app
            </Link>
            <a href="#how" className="btn-secondary px-5 py-[13px] text-[15px] hover:no-underline">
              How it works
            </a>
          </div>
        </div>
        <div className="relative">
          <div className="absolute inset-[10%_15%] bg-[radial-gradient(circle,rgba(52,227,172,.12),transparent_70%)] blur-[30px]" />
          <div className="relative flex flex-col gap-4 rounded-[20px] border border-line bg-[linear-gradient(180deg,#101319,#0C0F14)] p-6">
            <div className="flex items-baseline justify-between gap-3">
              <span className="text-[12px] font-semibold uppercase tracking-[.08em] text-tx2">1 noUSD is one unit of the basket</span>
              <span className="num text-[11.5px] text-tx2">{c.name}</span>
            </div>
            <StackedBar parts={bar} height={10} />
            <div className="flex flex-col gap-[2px]">
              {basket.map((b) => (
                <div key={b.sym} className="flex items-center gap-[10px] border-b border-line py-2">
                  <TokenChip sym={b.sym} />
                  <span className="flex-1 font-semibold">{b.sym}</span>
                  <span className="num text-[13.5px]">{b.perNoUSD.toFixed(4)}</span>
                  <span className="num w-14 text-right text-[12px] text-tx2">{b.pct.toFixed(1)} %</span>
                </div>
              ))}
            </div>
            <div className="text-[12.5px] leading-normal text-tx2">
              Stables count 1 : 1 with each other. If one depegs, noUSD reflects it honestly — it is not a promise of $1.
            </div>
          </div>
        </div>
      </section>

      <section className="grid grid-cols-2 rounded-card border border-line bg-s1 md:grid-cols-5">
        {strip.map((st, i) => (
          <div key={st.label} className={`flex min-w-0 flex-col gap-[6px] px-[18px] py-4 ${i ? "md:border-l md:border-line" : ""}`}>
            <span className="label whitespace-nowrap">{st.label}</span>
            {app.loading ? (
              <Skeleton className="h-5 w-[70%]" />
            ) : (
              <span className={`num text-[16px] font-medium ${st.accent ? "text-accent" : "text-tx"}`}>{st.value}</span>
            )}
          </div>
        ))}
      </section>

      <UnlockCycle />

      <section id="how" className="flex scroll-mt-20 flex-col gap-[18px] pt-[72px]">
        <div className="flex flex-col gap-[6px]">
          <span className="eyebrow">HOW IT WORKS</span>
          <h2 className="h2 m-0">From one stable to a share of the whole pool</h2>
        </div>
        <div className="rounded-[18px] border border-line bg-[linear-gradient(180deg,#101319,#0C0F14)] px-6 pb-[26px] pt-7">
          <div className="relative hidden h-[84px] md:block">
            <svg viewBox="0 0 1000 84" preserveAspectRatio="none" className="absolute inset-0 h-full w-full overflow-visible" fill="none" aria-hidden="true">
              <path d="M165 32 Q250 12 335 32" stroke="rgba(52,227,172,.30)" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />
              <polygon points="333,27 343,33 333,37" fill="#34E3AC" />
              <path d="M415 32 Q500 12 585 32" stroke="rgba(52,227,172,.30)" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />
              <polygon points="583,27 593,33 583,37" fill="#34E3AC" />
              <path d="M665 32 Q750 12 835 32" stroke="rgba(52,227,172,.30)" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />
              <polygon points="833,27 843,33 833,37" fill="#34E3AC" />
              <path d="M860 58 Q750 104 642 60" stroke="#34E3AC" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />
              <polygon points="636,52 648,57 641,66" fill="#34E3AC" />
            </svg>
            <div className="absolute inset-0 grid grid-cols-4">
              {HOW_ICONS.map((d, i) => (
                <div key={i} className="flex justify-center pt-3">
                  <span className="flex h-[42px] w-[42px] items-center justify-center rounded-[12px] border border-accent-line bg-accent-soft text-accent">
                    <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                      {d.map((p) => (
                        <path key={p} d={p} />
                      ))}
                    </svg>
                  </span>
                </div>
              ))}
            </div>
          </div>
          <div className="grid grid-cols-[minmax(0,1fr)] gap-[22px] text-center sm:grid-cols-2 md:grid-cols-4">
            {HOW_STEPS.map(([tag, title, body, on]) => (
              <div key={tag} className="flex flex-col items-center gap-[7px]">
                <span className={`num text-[11px] ${on ? "text-accent" : "text-tx2"}`}>{tag}</span>
                <span className="font-display text-[16px] font-semibold">{title}</span>
                <span className="text-pretty text-[13px] leading-normal text-tx2">{body}</span>
              </div>
            ))}
          </div>
        </div>
        <div className="flex items-center gap-[10px] text-[13px] text-tx2">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#34E3AC" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M21 12a9 9 0 1 1-3-6.7L21 8" />
            <path d="M21 3v5h-5" />
          </svg>
          Claim takes only what you earned. Your noUSD stays in your wallet and keeps earning.
        </div>
      </section>

      <section className="flex flex-col gap-[18px] pt-[72px]">
        <div className="flex items-end justify-between gap-5">
          <div className="flex flex-col gap-[6px]">
            <span className="eyebrow">THE BASKET</span>
            <h2 className="h2 m-0">What backs noUSD on {c.name}</h2>
          </div>
          <Link href="/reserves" className="whitespace-nowrap text-[14px] font-semibold">
            Full reserves →
          </Link>
        </div>
        <div className="flex flex-col gap-5 rounded-[18px] border border-line bg-s1 p-[22px]">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <span className="font-display text-[30px] font-semibold tabular-nums tracking-[-.02em]">${fmt(c.backing)}</span>
            <span className="text-[13px] text-tx2">
              backing at par · <span className="num text-accent">{((c.backing / c.supply) * 100).toFixed(2)} %</span> of supply
            </span>
          </div>
          <StackedBar parts={bar} height={14} />
          <div className="grid grid-cols-[minmax(0,1fr)] gap-7 md:grid-cols-2">
            <div className="flex flex-col">
              <span className="label pb-2">By token</span>
              {basket.map((b) => (
                <div key={b.sym} className="flex items-center gap-[10px] border-t border-line py-[10px]">
                  <TokenChip sym={b.sym} />
                  <span className="flex-1 font-semibold">{b.sym}</span>
                  <span className="num text-[13px]">${fmt(b.value)}</span>
                  <span className="num w-[52px] text-right text-[12px] text-tx2">{b.pct.toFixed(1)} %</span>
                </div>
              ))}
            </div>
            <div className="flex flex-col">
              <span className="label pb-2">By pool</span>
              {c.pools
                .filter((p) => p.pos > 0)
                .map((p) => (
                  <div key={p.id} className="flex items-center gap-[10px] border-t border-line py-[10px]">
                    <PairChips pair={p.pair} />
                    <span className="flex-1 pl-2 font-semibold">
                      {p.pair.join(" / ")} <span className="num text-[11.5px] font-normal text-tx2">{p.fee}</span>
                    </span>
                    <span className="num text-[13px]">${fmt(p.pos)}</span>
                    <span className="num w-[52px] text-right text-[12px] text-tx2">{((p.pos / c.backing) * 100).toFixed(1)} %</span>
                  </div>
                ))}
              <div className="flex items-center gap-[10px] border-t border-line py-[10px]">
                <PairChips pair={c.idle.map((i) => i[0])} />
                <span className="flex-1 pl-2 font-semibold">
                  Idle <span className="num text-[11.5px] font-normal text-tx2">PoolManager</span>
                </span>
                <span className="num text-[13px]">${fmt(idleSum)}</span>
                <span className="num w-[52px] text-right text-[12px] text-tx2">{((idleSum / c.backing) * 100).toFixed(1)} %</span>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="flex flex-col gap-[18px] pt-[72px]">
        <div className="flex flex-col gap-[6px]">
          <span className="eyebrow">WHY IT IS SAFE</span>
          <h2 className="h2 m-0">Rules in code, not promises</h2>
        </div>
        <div className="grid grid-cols-[minmax(0,1fr)] gap-[14px] sm:grid-cols-2 md:grid-cols-5">
          {SAFE.map(([title, body], i) => (
            <div key={title} className="card flex flex-col gap-[10px] p-[18px]">
              <span className="num text-[11px] text-accent">{String(i + 1).padStart(2, "0")}</span>
              <span className="font-display text-[15px] font-semibold leading-[1.3]">{title}</span>
              <span className="text-[13px] leading-normal text-tx2">{body}</span>
            </div>
          ))}
        </div>
      </section>

      <section className="grid grid-cols-[minmax(0,1fr)] gap-10 pt-[72px] md:grid-cols-[minmax(0,1fr)_minmax(0,2fr)]">
        <div className="flex flex-col gap-[6px]">
          <span className="eyebrow">FAQ</span>
          <h2 className="h2 m-0">Plain answers</h2>
        </div>
        <div className="flex flex-col gap-2">
          {FAQ.map(([q, a], i) => {
            const open = faq === i;
            return (
              <div key={q} className={`rounded-[14px] border bg-s1 ${open ? "border-accent-line" : "border-line"}`}>
                <button
                  type="button"
                  aria-expanded={open}
                  onClick={() => setFaq(open ? -1 : i)}
                  className="flex w-full items-center justify-between gap-4 px-[18px] py-4 text-left text-[15px] font-semibold text-tx"
                >
                  {q}
                  <span className="num text-[16px] text-accent">{open ? "−" : "+"}</span>
                </button>
                {open && <div className="text-pretty px-[18px] pb-4 text-[14px] leading-[1.6] text-tx2">{a}</div>}
              </div>
            );
          })}
        </div>
      </section>
    </>
  );
}
