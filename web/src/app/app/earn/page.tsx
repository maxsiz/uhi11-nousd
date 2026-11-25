"use client";

import { useState } from "react";
import { DestinationPicker, useDestination } from "@/components/Destination";
import { Cta, TokenChip, WarnIcon } from "@/components/ui";
import { duration, fmt } from "@/lib/format";
import { claimSplit } from "@/lib/preview";
import { useApp, useMountedAt, useNow } from "@/lib/state";
import { sendTx } from "@/lib/tx";
import { useWallet } from "@/lib/wallet";

export default function Earnings() {
  const app = useApp();
  const wallet = useWallet();
  const now = useNow();
  const t0 = useMountedAt();
  const c = app.chain;
  const d = useDestination(wallet.address);
  const [pending, setPending] = useState(false);

  const contract = wallet.kind === "contract";
  const earningOn = !contract || app.optedIn;
  const unc = earningOn ? app.unclaimed : 0;
  const rows = claimSplit(c, unc);
  const sinceSync = c.lastSyncAgoMs + (now - t0);
  const nextSync = `in ${duration(c.periodMs - (sinceSync % c.periodMs))}`;
  const wrong = wallet.kind === "wrong";
  const toLabel = app.dest === "wallet" ? "my wallet" : d.shortTo;

  let cta = "";
  let act: () => void = () => undefined;
  let disabled = false;
  if (wrong) {
    cta = `Switch to ${c.name}`;
    act = wallet.switchToViewed;
  } else if (contract && !app.optedIn) {
    cta = "Turn on earning first";
    disabled = true;
  } else if (pending) {
    cta = "Confirm in wallet…";
    disabled = true;
  } else if (unc < 0.005) {
    cta = "Nothing to claim yet";
    disabled = true;
  } else if (!d.valid) {
    cta = "Enter a valid address";
    disabled = true;
  } else {
    cta = `Claim ${fmt(unc)} to ${toLabel}`;
    act = async () => {
      setPending(true);
      try {
        await sendTx(c.name, 1200);
      } catch (e) {
        setPending(false);
        app.showToast((e as Error).message);
        return;
      }
      setPending(false);
      app.addUnclaimed(-unc);
      app.addActivity({ type: "Claim", detail: `Earnings to ${toLabel}`, amt: fmt(unc), time: "Just now", tx: "0x51c8…e07a" });
      app.showToast(`Claimed ${fmt(unc)} in stables → ${toLabel}`);
    };
  }

  const stats: [string, string, string][] = [
    ["APR · 7d", `${c.apr7.toFixed(1)} %`, "#34E3AC"],
    ["APR · 30d", `${c.apr30.toFixed(1)} %`, "#34E3AC"],
    ["Earning since", earningOn ? (contract ? "today" : c.since) : "not earning", earningOn ? "#EAEEF4" : "#FFC76B"],
    ["Next sync", nextSync, "#EAEEF4"],
  ];

  return (
    <section className="mt-6 flex flex-col gap-5">
      {contract && !app.optedIn && (
        <div className="flex flex-col gap-4 rounded-[18px] border border-warn-line bg-warn-soft px-5 py-[18px] md:flex-row md:items-center">
          <span className="hidden h-10 w-10 flex-none items-center justify-center rounded-[12px] border border-warn-line bg-[rgba(255,199,107,.12)] md:flex">
            <WarnIcon />
          </span>
          <div className="flex flex-1 flex-col gap-1">
            <span className="text-[15px] font-bold text-warn">This address is a contract and does not earn yet</span>
            <span className="text-[13.5px] leading-normal text-tx2">
              Smart-contract wallets are opted out by default, so pools and vaults holding noUSD don&apos;t silently collect earnings. Turning it on is one transaction from this wallet.
            </span>
          </div>
          <button
            type="button"
            onClick={() => {
              app.optIn();
              app.showToast("Earning turned on for this contract");
            }}
            className="btn-warn flex-none px-4 py-[11px] text-[14px]"
          >
            Turn on earning
          </button>
        </div>
      )}

      <div className="grid grid-cols-[minmax(0,1fr)] items-start gap-5 md:grid-cols-2">
        <div className="relative flex flex-col gap-[18px] overflow-hidden rounded-[20px] border border-line bg-[linear-gradient(160deg,#121722,#0D1015_60%)] p-[18px] md:p-6">
          <div className="pointer-events-none absolute -left-[100px] -top-[180px] h-[360px] w-[360px] bg-[radial-gradient(circle,rgba(52,227,172,.12),transparent_65%)]" />
          <div className="relative flex flex-col gap-[6px]">
            <span className="label text-[12px] tracking-[.08em]">Unclaimed earnings</span>
            <span className={`font-display text-[36px] font-semibold tabular-nums tracking-[-.02em] md:text-[42px] ${unc > 0 ? "text-accent" : "text-tx"}`}>{fmt(unc)}</span>
            <span className="text-[13px] text-tx2">
              paid in stables · you keep your <span className="num">{fmt(app.held)}</span> noUSD
            </span>
          </div>
          <div className="relative grid grid-cols-2 gap-[10px]">
            {stats.map(([label, value, color]) => (
              <div key={label} className="flex flex-col gap-[5px] rounded-[13px] border border-line bg-white/[.025] px-[14px] py-3">
                <span className="label">{label}</span>
                <span className="num text-[15px]" style={{ color }}>
                  {value}
                </span>
              </div>
            ))}
          </div>
          <span className="relative text-[12.5px] leading-normal text-tx2">
            Earnings grow when the protocol syncs pool fees ({c.sync} on {c.name}). APR is trailing, not a promise.
          </span>
        </div>

        <div className="flex flex-col gap-[14px] rounded-[20px] border border-line bg-s1 p-4 md:p-[22px]">
          <div className="flex flex-col gap-1">
            <h2 className="m-0 font-display text-[21px] font-semibold">Claim</h2>
            <span className="text-[13.5px] text-tx2">Take what you earned, in stables. Your noUSD stays put.</span>
          </div>
          <div className="flex flex-col">
            {rows.map((r) => (
              <div key={r.sym} className="flex items-center gap-[10px] border-t border-line py-[10px]">
                <TokenChip sym={r.sym} />
                <span className="min-w-0 flex-1 font-semibold">{r.sym}</span>
                <span className="num flex-none text-[13.5px]">{fmt(r.amount)}</span>
              </div>
            ))}
          </div>
          <DestinationPicker walletAddress={wallet.address} compact />
          <Cta label={cta} onClick={act} disabled={disabled} />
        </div>
      </div>
    </section>
  );
}
