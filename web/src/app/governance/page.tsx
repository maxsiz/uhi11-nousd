"use client";

import { DEMO_SAFE } from "@/lib/data/mock";
import type { QueueItem, QueueStatus } from "@/lib/data/types";
import { duration, fmt, shortAddr } from "@/lib/format";
import { useApp, useMountedAt, useNow } from "@/lib/state";

const H = 36e5;

const STATUS: Record<QueueStatus, { label: string; ink: string; line: string; fill: string }> = {
  queued: { label: "Queued", ink: "#FFC76B", line: "rgba(255,199,107,.35)", fill: "transparent" },
  executable: { label: "Executable", ink: "#34E3AC", line: "rgba(52,227,172,.30)", fill: "#34E3AC" },
  executed: { label: "Executed", ink: "#9AA4B2", line: "rgba(255,255,255,.11)", fill: "#9AA4B2" },
  cancelled: { label: "Cancelled", ink: "#9AA4B2", line: "rgba(255,255,255,.11)", fill: "transparent" },
};

export default function Governance() {
  const app = useApp();
  const now = useNow();
  const t0 = useMountedAt();
  const c = app.chain;

  const params: [string, string, string, boolean][] = [
    ["Redeem delay", app.redeemDelay ? "24 h" : "0", "≤ 7 days", app.redeemDelay],
    ["Mint fee", "0 %", "≤ 0.5 %", false],
    ["Protocol fee", "0 %", "≤ 10 %", false],
    ["Depeg threshold", "0.5 %", "0.01 – 2 %", false],
    ["Pool share cap", "30 %", "≤ 50 %", false],
    ["Supply cap", `${fmt(c.cap, 0)} noUSD`, "owner-set · raises wait 48 h", false],
    ["Mint paused", app.demoMint === "paused" ? "Yes" : "No", "redeem & claim: never", app.demoMint === "paused"],
  ];

  const queue: QueueItem[] = [
    { title: "Raise supply cap", from: fmt(c.cap, 0), to: fmt(c.cap * 2.5, 0), loosens: true, status: "queued", when: `executes in ${duration(t0 + 31 * H - now)}` },
    { title: "Raise pool share cap", from: "30 %", to: "35 %", loosens: true, status: "executable", when: "delay passed · Nov 24" },
    { title: "Lower depeg threshold", from: "0.6 %", to: "0.5 %", loosens: false, status: "executed", when: "applied Nov 12" },
    { title: "Allow mint in USDS / RLUSD", from: "off", to: "on", loosens: true, status: "cancelled", when: "cancelled Nov 3" },
  ];

  return (
    <section className="flex flex-col gap-5 pt-[34px]">
      <div className="flex flex-col gap-[6px]">
        <h1 className="m-0 font-display text-[30px] font-semibold tracking-[-.02em]">Governance on {c.name}</h1>
        <span className="max-w-[680px] text-[14px] leading-[1.55] text-tx2">
          Changes that loosen rules wait 48 h so holders can leave first; tightening applies at once. Every value is bounded by a hard cap written in the contract.
        </span>
      </div>

      <div className="grid grid-cols-[minmax(0,1fr)] items-start gap-5 md:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]">
        <div className="rounded-[18px] border border-line bg-s1 px-5 pb-[10px] pt-[6px]">
          <div className="grid grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)_minmax(0,1.2fr)] gap-3 pb-[10px] pt-[14px] text-[11.5px] font-semibold uppercase tracking-[.06em] text-tx2">
            <span>Parameter</span>
            <span>Current</span>
            <span>Hard cap in code</span>
          </div>
          {params.map(([name, cur, cap, attention]) => (
            <div key={name} className="grid grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)_minmax(0,1.2fr)] items-center gap-3 border-t border-line py-3">
              <span className="text-[14px] font-semibold">{name}</span>
              <span className={`num text-[13.5px] ${attention ? "text-warn" : "text-tx"}`}>{cur}</span>
              <span className="num flex items-center gap-2 text-[13px] text-tx2">
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" className="flex-none" aria-label="hard cap">
                  <rect x="4" y="11" width="16" height="10" rx="2" />
                  <path d="M8 11V7a4 4 0 0 1 8 0v4" />
                </svg>
                {cap}
              </span>
            </div>
          ))}
        </div>
        <div className="flex flex-col gap-[14px]">
          <div className="flex flex-col gap-[10px] rounded-[18px] border border-line bg-s1 px-5 py-[18px]">
            <span className="label text-[12px] tracking-[.08em]">Owner</span>
            <span className="flex flex-wrap items-center gap-[10px]">
              <span className="font-display text-[17px] font-semibold">Safe · 2-of-3</span>
              <span className="num break-all text-[12.5px] text-tx2">{app.advanced ? DEMO_SAFE : shortAddr(DEMO_SAFE)}</span>
            </span>
            <span className="text-[13px] leading-normal text-tx2">
              Can only change the parameters on the left, within their caps. Cannot move funds, pause redeem or claim, or upgrade contracts.
            </span>
          </div>
          <div className="flex flex-col gap-2 rounded-[18px] border border-line bg-s1 px-5 py-[18px]">
            <span className="label text-[12px] tracking-[.08em]">Timelock</span>
            <span className="flex justify-between text-[13.5px]">
              <span className="text-tx2">Delay for loosening</span>
              <span className="num">48 h</span>
            </span>
            <span className="flex justify-between text-[13.5px]">
              <span className="text-tx2">Delay for tightening</span>
              <span className="num">none</span>
            </span>
          </div>
        </div>
      </div>

      <div className="overflow-x-auto rounded-[18px] border border-line bg-s1 px-5 pb-[10px] pt-[6px]">
        <div className="flex items-center justify-between gap-3 pb-[10px] pt-[14px]">
          <span className="font-display text-[17px] font-semibold">Timelock queue</span>
          <span className="text-[12.5px] text-tx2">Read-only · executed by the owner after the delay</span>
        </div>
        {queue.map((q) => {
          const s = STATUS[q.status];
          return (
            <div key={q.title} className="grid min-w-[760px] grid-cols-[minmax(0,1.4fr)_minmax(0,1.2fr)_150px_minmax(0,1fr)_130px] items-center gap-[14px] border-t border-line py-[13px]">
              <span className="text-[14px] font-semibold">{q.title}</span>
              <span className="num text-[13px]">
                <span className="text-tx2">{q.from}</span> → <span>{q.to}</span>
              </span>
              <span
                className={`justify-self-start rounded-[20px] border px-[9px] py-[3px] text-[12px] font-semibold ${q.loosens ? "border-warn-line text-warn" : "border-accent-line text-accent"}`}
              >
                {q.loosens ? "Loosens · 48 h" : "Tightens · at once"}
              </span>
              <span className="num text-[12.5px] text-tx2">{q.when}</span>
              <span className="flex items-center gap-[7px] justify-self-end rounded-[20px] border px-[10px] py-[3px] text-[12px] font-semibold" style={{ color: s.ink, borderColor: s.line }}>
                <span className="h-[7px] w-[7px] rounded-full border-[1.5px]" style={{ borderColor: s.ink, background: s.fill }} />
                {s.label}
              </span>
            </div>
          );
        })}
      </div>
    </section>
  );
}
