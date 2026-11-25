"use client";

import Link from "next/link";
import { Diamond, HollowDot, Skeleton, StatTile } from "@/components/ui";
import type { ActivityType } from "@/lib/data/types";
import { fmt } from "@/lib/format";
import { useApp } from "@/lib/state";
import { useWallet } from "@/lib/wallet";

const PILL: Record<ActivityType, string> = {
  Mint: "text-accent border-accent-line",
  Claim: "text-accent border-accent-line",
  Redeem: "text-tx border-line2",
  Transfer: "text-tx2 border-line2",
};

export default function Portfolio() {
  const app = useApp();
  const wallet = useWallet();
  const c = app.chain;
  const contract = wallet.kind === "contract";
  const earningOn = !contract || app.optedIn;
  const unc = earningOn ? app.unclaimed : 0;

  return (
    <section className="mt-6 flex flex-col gap-5">
      <div className="relative overflow-hidden rounded-[20px] border border-line bg-[linear-gradient(160deg,#121722,#0D1015_60%)] p-[18px] md:p-[26px]">
        <div className="pointer-events-none absolute -left-[120px] -top-[220px] h-[420px] w-[420px] bg-[radial-gradient(circle,rgba(52,227,172,.12),transparent_65%)]" />
        <div className="relative grid grid-cols-[minmax(0,1fr)] items-end gap-[22px] md:grid-cols-[minmax(0,1.3fr)_repeat(4,minmax(0,1fr))]">
          <div className="flex flex-col gap-[6px]">
            <span className="label text-[12px] tracking-[.08em]">noUSD balance · {c.name}</span>
            {app.loading ? (
              <Skeleton className="h-11 w-4/5 rounded-[8px]" />
            ) : (
              <span className="font-display text-[36px] font-semibold tabular-nums tracking-[-.02em] md:text-[42px]">{fmt(app.held)}</span>
            )}
            <span className="text-[13px] text-tx2">
              ≈ <span className="num">{fmt((app.held * c.backing) / c.supply)}</span> backing at par
            </span>
          </div>
          <div className="grid grid-cols-2 gap-2 md:contents">
            <StatTile label="Unclaimed earnings" value={app.loading ? "…" : fmt(unc)} color="#34E3AC" />
            <StatTile
              label="Earning"
              value={earningOn ? "On" : contract ? "Off · contract" : "Off"}
              color={earningOn ? "#34E3AC" : "#FFC76B"}
              dot={
                earningOn ? (
                  <span className="h-2 w-2 rounded-full bg-accent shadow-[0_0_7px_#34E3AC]" />
                ) : (
                  <HollowDot color="#FFC76B" />
                )
              }
            />
            <StatTile label="Pending redeems" value={String(app.redeemDelay ? app.pending.length : 0)} />
            <StatTile label="Holder APR · 7d" value={`${c.apr7.toFixed(1)} %`} color="#34E3AC" />
          </div>
        </div>
        <div className="relative mt-[22px] grid grid-cols-3 gap-2 md:flex md:gap-[10px]">
          <Link href="/app/mint" className="btn-primary px-[18px] py-[11px] text-[14px] hover:text-ink hover:no-underline">
            Mint
          </Link>
          <Link href="/app/redeem" className="btn-secondary px-[18px] py-[11px] text-[14px] hover:no-underline">
            Redeem
          </Link>
          <Link href="/app/earn" className="btn-secondary whitespace-nowrap px-[18px] py-[11px] text-[14px] hover:no-underline">
            Claim<span className="hidden md:inline">&nbsp;{fmt(unc)}</span>
          </Link>
        </div>
      </div>

      {contract && (
        <div className="flex flex-wrap items-center gap-3 rounded-[14px] border border-warn-line bg-warn-soft px-4 py-3 text-[13.5px]">
          <Diamond />
          <span className="flex-1">{app.optedIn ? "Earning is on for this contract wallet." : "This address is a contract and does not earn yet."}</span>
          <Link href="/app/earn" className="rounded-[10px] border border-warn-line px-3 py-[7px] text-[13px] font-semibold text-warn hover:text-warn hover:no-underline">
            Open Earnings
          </Link>
        </div>
      )}

      <div className="rounded-[18px] border border-line bg-s1 px-4 pb-3 pt-2 md:px-[22px]">
        <div className="flex items-center justify-between pb-[10px] pt-[14px]">
          <span className="font-display text-[17px] font-semibold">Activity</span>
          <span className="text-[12.5px] text-tx2">{c.name} only</span>
        </div>
        {app.activity.length === 0 && (
          <div className="py-[30px] text-center text-[14px] text-tx2">No activity on {c.name} yet. Mint to get started.</div>
        )}
        {app.activity.map((a, i) => (
          <div
            key={`${a.tx}-${i}`}
            className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-[14px] gap-y-1 border-t border-line py-3 md:grid-cols-[110px_minmax(0,1fr)_170px_150px_120px]"
          >
            <span className={`justify-self-start rounded-[20px] border px-[10px] py-[3px] text-[12px] font-semibold ${PILL[a.type]}`}>{a.type}</span>
            <span className="order-3 col-span-2 text-[13.5px] text-tx2 md:order-none md:col-span-1">{a.detail}</span>
            <span className={`num text-right text-[13.5px] ${a.amt.startsWith("+") ? "text-accent" : "text-tx"}`}>{a.amt}</span>
            <span className="num hidden text-right text-[12px] text-tx2 md:block">{a.time}</span>
            <a
              href="#"
              onClick={(e) => {
                e.preventDefault();
                app.showToast("Opens the explorer");
              }}
              className="num hidden text-right text-[12px] md:block"
            >
              {a.tx} ↗
            </a>
          </div>
        ))}
      </div>
    </section>
  );
}
