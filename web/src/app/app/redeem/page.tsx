"use client";

import { useState } from "react";
import { DestinationPicker, useDestination } from "@/components/Destination";
import { CheckBadge, Cta, NoUSDChip, TokenChip } from "@/components/ui";
import { cleanAmountInput, duration, fmt, parseAmount, shortAddr } from "@/lib/format";
import { redeemPreview } from "@/lib/preview";
import { useApp, useNow } from "@/lib/state";
import { sendTx } from "@/lib/tx";
import { useWallet } from "@/lib/wallet";

type Stage = "idle" | "pending" | "success" | "refused";

const SLIPS = ["0.05", "0.1", "0.5"];
const H = 36e5;

export default function Redeem() {
  const app = useApp();
  const wallet = useWallet();
  const now = useNow();
  const c = app.chain;
  const d = useDestination(wallet.address);
  const [amountTxt, setAmountTxt] = useState("1,000");
  const [stage, setStage] = useState<Stage>("idle");
  const [doneTxt, setDoneTxt] = useState("");

  const contract = wallet.kind === "contract";
  const unc = !contract || app.optedIn ? app.unclaimed : 0;
  const x = parseAmount(amountTxt);
  const r = redeemPreview(c, x, app.held, unc);
  const wrong = wallet.kind === "wrong";

  const doRedeem = async () => {
    setStage("pending");
    try {
      await sendTx(c.name);
    } catch (e) {
      setStage("idle");
      app.showToast((e as Error).message);
      return;
    }
    // PayoutFailed: the token refuses this recipient, so the whole redeem reverts and nothing is spent.
    if (app.usdtRefuses && app.dest === "wallet") {
      setStage("refused");
      return;
    }
    if (app.redeemDelay) {
      app.addHeld(-x);
      app.setPending((p) => [{ id: Date.now(), amt: x, readyAt: Date.now() + 24 * H, to: d.shortTo }, ...p]);
      setStage("idle");
      app.showToast("Redeem requested · ready in 24 h");
      return;
    }
    app.addHeld(-x);
    app.addUnclaimed(-r.included);
    setDoneTxt(`${fmt(x)} noUSD redeemed for ${c.basket.length} tokens + ${fmt(r.included)} earnings, sent to ${d.shortTo}.`);
    setStage("success");
    app.addActivity({ type: "Redeem", detail: `Basket to ${d.shortTo}`, amt: `−${fmt(x)}`, time: "Just now", tx: "0x3d07…be91" });
    app.showToast(`Redeem confirmed → ${d.shortTo}`);
  };

  let cta = "";
  let act: () => void = () => undefined;
  let disabled = false;
  if (wrong) {
    cta = `Switch to ${c.name}`;
    act = wallet.switchToViewed;
  } else if (stage === "pending") {
    cta = "Confirm in wallet…";
    disabled = true;
  } else if (x <= 0) {
    cta = "Enter an amount";
    disabled = true;
  } else if (x > app.held + 1e-9) {
    cta = "Not enough noUSD";
    disabled = true;
  } else if (!d.valid) {
    cta = "Enter a valid address";
    disabled = true;
  } else if (app.redeemDelay) {
    cta = "Request redeem · ready in 24 h";
    act = () => void doRedeem();
  } else {
    cta = app.dest === "wallet" ? "Redeem to my wallet" : `Redeem to ${d.shortTo}`;
    act = () => void doRedeem();
  }

  return (
    <section className="mt-6 grid grid-cols-[minmax(0,1fr)] items-start gap-5 md:grid-cols-[minmax(0,560px)_minmax(0,1fr)]">
      <div className="flex flex-col gap-4 rounded-[20px] border border-line bg-s1 p-4 md:p-[22px]">
        <div className="flex flex-col gap-1">
          <h2 className="m-0 font-display text-[21px] font-semibold">Redeem for the basket</h2>
          <span className="text-[13.5px] text-tx2">Burn noUSD and get your share of every position, in kind — sent to any address.</span>
        </div>

        {stage === "success" ? (
          <div className="flex flex-col items-center gap-[10px] pb-1 pt-4 text-center">
            <CheckBadge />
            <span className="font-display text-[20px] font-semibold">Basket sent</span>
            <span className="text-[13.5px] text-tx2">{doneTxt}</span>
            <a href="#" onClick={(e) => { e.preventDefault(); app.showToast("Opens the explorer"); }} className="num text-[12.5px]">
              View transaction 0x3d07…be91 ↗
            </a>
            <button type="button" onClick={() => setStage("idle")} className="btn-secondary mt-[6px] px-4 py-[10px]">
              Done
            </button>
          </div>
        ) : (
          <>
            <div className="flex flex-col gap-[10px] rounded-[14px] border border-line2 bg-s2 px-4 py-[14px]">
              <div className="flex justify-between gap-[10px] whitespace-nowrap text-[12.5px] text-tx2">
                <span>You redeem</span>
                <span>
                  Balance <span className="num text-tx">{fmt(app.held)} noUSD</span>
                </span>
              </div>
              <div className="flex items-center gap-[10px]">
                <input
                  value={amountTxt}
                  onChange={(e) => setAmountTxt(cleanAmountInput(e.target.value))}
                  inputMode="decimal"
                  aria-label="noUSD to redeem"
                  placeholder="0.00"
                  className="num min-w-0 flex-1 bg-transparent text-[26px] text-tx outline-none"
                />
                <button type="button" onClick={() => setAmountTxt(fmt(app.held))} className="btn-max">
                  MAX
                </button>
                <span className="flex items-center gap-2 rounded-[20px] border border-line2 bg-s3 py-[5px] pl-[5px] pr-3 font-semibold">
                  <NoUSDChip />
                  noUSD
                </span>
              </div>
            </div>

            <div className="flex flex-col gap-[10px]">
              <span className="label text-[12px] tracking-[.08em]">Send the basket to</span>
              <DestinationPicker walletAddress={wallet.address} />
            </div>

            {stage === "refused" && (
              <div role="alert" className="flex gap-3 rounded-[14px] border border-danger-line bg-danger-soft px-[14px] py-[13px]">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#FF7A7A" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="mt-px flex-none" aria-hidden="true">
                  <circle cx="12" cy="12" r="10" />
                  <path d="m15 9-6 6M9 9l6 6" />
                </svg>
                <div className="flex flex-1 flex-col gap-2">
                  <span className="text-[13.5px] font-bold text-danger">USDT refused to send to {shortAddr(wallet.address)}</span>
                  <span className="text-[13px] leading-normal text-tx2">
                    The address is frozen by USDT, so the whole redeem was cancelled — nothing left your wallet. Redeem to another address.
                  </span>
                  <button
                    type="button"
                    onClick={() => {
                      app.setDest("custom");
                      setStage("idle");
                    }}
                    className="btn-secondary self-start rounded-[10px] px-3 py-2 text-[13px]"
                  >
                    Use a custom address
                  </button>
                </div>
              </div>
            )}

            {app.redeemDelay && (
              <div className="flex gap-[10px] rounded-[14px] border border-warn-line bg-warn-soft px-[14px] py-3 text-[13px] leading-normal">
                <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#FFC76B" strokeWidth="2" strokeLinecap="round" className="mt-px flex-none" aria-hidden="true">
                  <circle cx="12" cy="12" r="10" />
                  <path d="M12 6v6l4 2" />
                </svg>
                <span>
                  <b className="text-warn">Redeem delay is 24 h on {c.name}.</b>{" "}
                  <span className="text-tx2">Your noUSD is held until then and stops earning; the payout is computed when it executes.</span>
                </span>
              </div>
            )}

            <div className="flex items-center justify-between gap-2 text-[13px]">
              <span className="text-tx2">Minimum received</span>
              <span className="flex gap-[6px]">
                {SLIPS.map((v) => (
                  <button
                    key={v}
                    type="button"
                    aria-pressed={app.slippage === v}
                    onClick={() => app.setSlippage(v)}
                    className={`num whitespace-nowrap rounded-[8px] border px-[9px] py-1 text-[12px] ${app.slippage === v ? "border-accent-line bg-accent-soft text-accent" : "border-line2 bg-s1 text-tx2"}`}
                  >
                    −{v} %
                  </button>
                ))}
              </span>
            </div>
            <Cta label={cta} onClick={act} disabled={disabled} />
          </>
        )}
      </div>

      <div className="flex flex-col gap-5">
        <div className="flex flex-col rounded-[20px] border border-line bg-s1 p-4 md:p-[22px]">
          <div className="flex items-baseline justify-between pb-[10px]">
            <span className="label text-[12px] tracking-[.08em]">You get · {c.basket.length} tokens</span>
            <span className="text-[12px] text-tx2">value at par</span>
          </div>
          {r.rows.map((row) => (
            <div key={row.sym} className="flex items-center gap-[10px] border-t border-line py-[11px]">
              <TokenChip sym={row.sym} size={24} />
              <span className="min-w-0 flex-1 font-semibold">{row.sym}</span>
              <span className="num flex-none text-[14px]">{fmt(row.amount)}</span>
              <span className="num w-24 text-right text-[12.5px] text-tx2">${fmt(row.amount)}</span>
            </div>
          ))}
          <div className="row py-[11px] text-[13.5px]">
            <span className="text-tx2">Includes your unclaimed earnings</span>
            <span className="num text-accent">+ {fmt(r.included)}</span>
          </div>
          <div className="flex items-baseline justify-between border-t border-line2 pt-[13px]">
            <span className="font-semibold">Total at par</span>
            <span className="font-display text-[22px] font-semibold tabular-nums">${fmt(r.total)}</span>
          </div>
          <span className="mt-[10px] text-[12px] leading-normal text-tx2">
            Amounts are a pro-rata slice of every position and idle balance. Minimum received: <span className="num">−{app.slippage} %</span> per token.
          </span>
        </div>

        {app.redeemDelay && (
          <div className="rounded-[20px] border border-line bg-s1 px-4 pb-3 pt-2 md:px-[22px]">
            <div className="flex items-center justify-between pb-2 pt-[14px]">
              <span className="font-display text-[16px] font-semibold">Pending redeems</span>
              <span className="num text-[12px] text-tx2">{app.pending.length} open</span>
            </div>
            {app.pending.length === 0 && <div className="py-[18px] text-[13.5px] text-tx2">No pending requests.</div>}
            {app.pending.map((p) => {
              const left = p.readyAt - now;
              const ready = left <= 0;
              return (
                <div key={p.id} className="grid grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-[14px] border-t border-line py-3">
                  <div className="flex flex-col gap-[3px]">
                    <span className="num text-[14px]">{fmt(p.amt)} noUSD</span>
                    <span className="text-[12px] text-tx2">
                      to <span className="num">{p.to}</span>
                    </span>
                  </div>
                  <span
                    className={`flex items-center gap-[7px] rounded-[20px] border px-[10px] py-[3px] text-[12.5px] ${ready ? "border-accent-line text-accent" : "border-warn-line text-warn"}`}
                  >
                    <span className="h-[7px] w-[7px] rounded-full border-[1.5px]" style={{ borderColor: ready ? "#34E3AC" : "#FFC76B", background: ready ? "#34E3AC" : "transparent" }} />
                    <span className="num">{ready ? "ready" : `ready in ${duration(left)}`}</span>
                  </span>
                  <button
                    type="button"
                    onClick={() => {
                      app.setPending((q) => q.filter((y) => y.id !== p.id));
                      if (ready) {
                        app.showToast(`Redeem executed → ${p.to}`);
                      } else {
                        app.addHeld(p.amt);
                        app.showToast("Request cancelled · noUSD returned");
                      }
                    }}
                    className={`min-h-[36px] rounded-[9px] border border-line2 px-[11px] py-[6px] text-[12.5px] font-semibold ${ready ? "text-accent" : "text-tx"}`}
                  >
                    {ready ? "Execute" : "Cancel"}
                  </button>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </section>
  );
}
