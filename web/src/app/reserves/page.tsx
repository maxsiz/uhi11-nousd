"use client";

import { Diamond, HollowDot, LiveDot, PairChips, Skeleton, TokenChip } from "@/components/ui";
import { duration, fmt } from "@/lib/format";
import { useApp, useMountedAt, useNow } from "@/lib/state";

const COLS = "grid-cols-[minmax(0,1.5fr)_minmax(0,.75fr)_minmax(0,.95fr)_minmax(0,.9fr)_minmax(0,1.35fr)_minmax(0,.9fr)_minmax(0,.65fr)_minmax(0,1.2fr)]";

export default function Reserves() {
  const app = useApp();
  const now = useNow();
  const t0 = useMountedAt();
  const c = app.chain;
  const sinceSync = c.lastSyncAgoMs + (now - t0);
  const lastSync = `${duration(sinceSync % c.periodMs)} ago`;
  const nextSync = `in ${duration(c.periodMs - (sinceSync % c.periodMs))}`;

  const totals: [string, string, boolean][] = [
    ["Supply", fmt(c.supply), false],
    ["Unclaimed earnings", fmt(c.unclaimed), false],
    ["Treasury accrual", fmt(c.treasury), false],
    ["Carry", `+${fmt(c.backing - c.supply)}`, false],
    ["Backing at par", fmt(c.backing), false],
    ["Backing / supply", (c.backing / c.supply).toFixed(4), true],
  ];

  const rows = c.pools.map((p) => {
    const off = app.demoMint === "offpeg" && p.pair.includes("USDT");
    const exitOnly = p.status !== "Active";
    const guardBad = p.guard !== "Vouched";
    return { p, off, exitOnly, guardBad };
  });

  return (
    <section className="flex flex-col gap-5 pt-[34px]">
      <div className="flex flex-col justify-between gap-3 sm:flex-row sm:items-end sm:gap-5">
        <div className="flex flex-col gap-[6px]">
          <h1 className="m-0 font-display text-[30px] font-semibold tracking-[-.02em]">Reserves on {c.name}</h1>
          <span className="text-[14px] text-tx2">Everything that backs noUSD, read on-chain. Values at par (1 stable = 1).</span>
        </div>
        <span className="flex flex-none items-center gap-2 whitespace-nowrap text-[12.5px] text-tx2">
          <LiveDot /> Last sync <span className="num text-tx">{lastSync}</span>
        </span>
      </div>

      <div className="grid grid-cols-2 gap-[10px] sm:grid-cols-3 md:grid-cols-6">
        {totals.map(([label, value, accent]) => (
          <div key={label} className={`flex min-w-0 flex-col gap-[7px] whitespace-nowrap rounded-card border bg-s1 px-4 py-[15px] ${accent ? "border-accent-line" : "border-line"}`}>
            <span className="label">{label}</span>
            {app.loading ? <Skeleton className="h-5 w-4/5" /> : <span className={`num text-[16px] ${accent ? "text-accent" : "text-tx"}`}>{value}</span>}
          </div>
        ))}
      </div>

      <div className="overflow-x-auto rounded-[18px] border border-line bg-s1 px-5 pb-[10px] pt-[6px]">
        <div className="flex items-center justify-between pb-[10px] pt-[14px]">
          <span className="font-display text-[17px] font-semibold">Pools</span>
          <button type="button" onClick={app.toggleAdvanced} className="text-[12.5px] text-tx2 hover:text-tx">
            {app.advanced ? "Hide technical fields" : "Show pool IDs & ticks"}
          </button>
        </div>
        <div className={`grid min-w-[1000px] ${COLS} gap-3 py-2 text-[11.5px] font-semibold uppercase tracking-[.06em] text-tx2`}>
          <span>Pool</span>
          <span>Fee</span>
          <span>Status</span>
          <span>Price vs par</span>
          <span>Our share vs cap</span>
          <span className="text-right">Position</span>
          <span className="text-right">Fee APR</span>
          <span>Range</span>
        </div>
        {rows.map(({ p, off, exitOnly }) => (
          <div key={p.id} className="min-w-[1000px] whitespace-nowrap border-t border-line py-[13px]">
            <div className={`grid ${COLS} items-center gap-3`}>
              <span className="flex items-center gap-2">
                <PairChips pair={p.pair} />
                <span className="pl-[6px] font-semibold">{p.pair.join(" / ")}</span>
              </span>
              <span className="num text-[12.5px]">{p.fee}</span>
              <span
                className={`justify-self-start rounded-[20px] border px-[9px] py-[3px] text-[12px] font-semibold ${exitOnly ? "border-warn-line text-warn" : "border-accent-line text-accent"}`}
              >
                {p.status}
              </span>
              <span className={`num flex items-center gap-[6px] text-[12.5px] ${off ? "text-warn" : "text-tx"}`}>
                {off ? "−60.0 bp" : p.bp}
                {off && <span className="rounded-[6px] border border-[rgba(255,199,107,.4)] px-[5px] py-px font-sans text-[11px] font-bold">OFF PAR</span>}
              </span>
              <span className="flex flex-col gap-[5px]">
                <span className="relative h-[7px] rounded-[4px] bg-s3">
                  <span className="absolute inset-y-0 left-0 rounded-[4px] bg-accent" style={{ width: `${(p.share / 50) * 100}%` }} />
                  <span className="absolute -bottom-[3px] -top-[3px] w-[2px] bg-tx" style={{ left: `${(p.cap / 50) * 100}%` }} />
                </span>
                <span className="num text-[11.5px] text-tx2">
                  {p.share.toFixed(1)} % of {p.cap} % cap
                </span>
              </span>
              <span className="num text-right text-[13px]">${fmt(p.pos, 0)}</span>
              <span className={`num text-right text-[13px] ${p.apr ? "text-accent" : "text-tx2"}`}>{p.apr ? `${p.apr.toFixed(1)} %` : "—"}</span>
              <span className="flex flex-col gap-1">
                <span className="flex items-center gap-[7px] text-[12.5px] font-semibold">
                  {p.inRange ? <LiveDot /> : <HollowDot />}
                  {p.inRange ? "In range" : "No position"}
                </span>
                <span className="num text-[11.5px] text-tx2">{p.range}</span>
              </span>
            </div>
            {app.advanced && (
              <div className="num mt-[10px] grid grid-cols-[auto_1fr_auto_1fr_auto_1fr] gap-x-[14px] gap-y-[6px] rounded-[11px] bg-s2 px-3 py-[10px] text-[11.5px] text-tx2">
                <span>Pool ID</span>
                <span className="col-span-5 break-all text-tx">{p.id}</span>
                <span>Ticks</span>
                <span className="text-tx">{p.ticks}</span>
                <span>Current tick</span>
                <span className="text-tx">{p.tick}</span>
                <span>Pool TVL</span>
                <span className="text-tx">{p.tvl}</span>
              </div>
            )}
          </div>
        ))}
      </div>

      <div className="grid grid-cols-[minmax(0,1fr)] gap-5 md:grid-cols-3">
        <div className="flex flex-col rounded-[18px] border border-line bg-s1 px-5 py-[18px]">
          <span className="font-display text-[16px] font-semibold">Idle balances</span>
          <span className="pb-[10px] pt-1 text-[12.5px] text-tx2">Held in the Uniswap PoolManager, counted in backing.</span>
          {c.idle.map(([sym, v]) => (
            <div key={sym} className="flex items-center gap-[10px] border-t border-line py-[10px]">
              <TokenChip sym={sym} />
              <span className="flex-1 font-semibold">{sym}</span>
              <span className="num text-[13px]">{fmt(v)}</span>
            </div>
          ))}
        </div>
        <div className="flex flex-col rounded-[18px] border border-line bg-s1 px-5 py-[18px]">
          <span className="font-display text-[16px] font-semibold">Price guard</span>
          <span className="pb-[10px] pt-1 text-[12.5px] text-tx2">Opens minting only when prices are fresh. Never blocks exits.</span>
          {rows.map(({ p, guardBad }) => (
            <div key={p.id} className="flex items-center gap-[10px] border-t border-line py-[10px]">
              <span className="flex-1 text-[13.5px] font-semibold">{p.pair.join(" / ")}</span>
              <span className={`flex items-center gap-[7px] text-[12.5px] font-semibold ${guardBad ? "text-warn" : "text-accent"}`}>
                {guardBad ? <Diamond /> : <LiveDot />}
                {guardBad ? p.guard : "Vouched · mint open"}
              </span>
            </div>
          ))}
        </div>
        <div className="flex flex-col rounded-[18px] border border-line bg-s1 px-5 py-[18px]">
          <span className="font-display text-[16px] font-semibold">Keeper</span>
          <span className="pb-[10px] pt-1 text-[12.5px] text-tx2">Anyone can call sync; a keeper does it {c.sync}.</span>
          <div className="flex justify-between border-t border-line py-[10px] text-[13.5px]">
            <span className="text-tx2">Last sync</span>
            <span className="num">{lastSync}</span>
          </div>
          <div className="flex justify-between border-t border-line py-[10px] text-[13.5px]">
            <span className="text-tx2">Next sync</span>
            <span className="num">{nextSync}</span>
          </div>
          {c.pools.map((p) => (
            <div key={p.id} className="flex justify-between gap-2 border-t border-line py-[10px] text-[13.5px]">
              <span className="text-tx2">Compound · {p.pair.join(" / ")}</span>
              <span className="num">{p.compound}</span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
