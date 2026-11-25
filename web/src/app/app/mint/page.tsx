"use client";

import Link from "next/link";
import { useState } from "react";
import { CheckBadge, Chevron, Cta, Diamond, LiveDot, NoticeCard, PairChips, TokenChip } from "@/components/ui";
import { DEMO_ROUTER } from "@/lib/data/mock";
import type { Sym } from "@/lib/data/types";
import { mintNotice, type MintNoticeKey } from "@/lib/errors";
import { cleanAmountInput, fmt, parseAmount } from "@/lib/format";
import { mintBlock, mintPreview } from "@/lib/preview";
import { useApp } from "@/lib/state";
import { PERMIT } from "@/lib/tokens";
import { sendTx } from "@/lib/tx";
import { useWallet } from "@/lib/wallet";

type Stage = "idle" | "pending" | "success" | "error";

const SLIPS = ["0.05", "0.1", "0.5"];

export default function Mint() {
  const app = useApp();
  const wallet = useWallet();
  const c = app.chain;
  const [tokenPick, setTokenPick] = useState<Sym>("USDC");
  const [amountTxt, setAmountTxt] = useState("10,000");
  const [stage, setStage] = useState<Stage>("idle");
  const [err, setErr] = useState<"slippage" | "expired" | null>(null);
  const [approved, setApproved] = useState<Partial<Record<Sym, boolean>>>({});
  const [settings, setSettings] = useState(false);
  const [tokOpen, setTokOpen] = useState(false);
  const [done, setDone] = useState<{ recv: number; amt: number; token: Sym; refund: number; pair: Sym } | null>(null);

  const token = c.mintable.includes(tokenPick) ? tokenPick : c.mintable[0];
  const amount = parseAmount(amountTxt);
  const slip = parseAmount(app.slippage);
  const p = mintPreview(c, token, amount, slip);
  const block = mintBlock(c, token, p.supplyAfter, { paused: app.demoMint === "paused", usdtOffPar: app.demoMint === "offpeg" });
  const wrong = wallet.kind === "wrong";
  const balance = c.bal[token] ?? 0;
  const permit = !!PERMIT[token];
  const needApprove = !permit && !approved[token];

  let noticeKey: MintNoticeKey | null = null;
  if (stage === "error" && err) noticeKey = err;
  else if (block) noticeKey = block;
  const notice = noticeKey
    ? mintNotice(noticeKey, { token, chain: c.name, deadlineMin: app.deadline, mintableLeft: Math.max(0, c.cap - c.supply) })
    : null;

  const doMint = async () => {
    setStage("pending");
    setErr(null);
    setSettings(false);
    setTokOpen(false);
    try {
      await sendTx(c.name);
    } catch (e) {
      setStage("idle");
      app.showToast((e as Error).message);
      return;
    }
    if (app.demoMint === "slippage" || app.demoMint === "expired") {
      setErr(app.demoMint);
      setStage("error");
      return;
    }
    setDone({ recv: p.receive, amt: amount, token, refund: p.refund, pair: p.pair });
    setStage("success");
    app.addHeld(p.receive);
    app.addActivity({ type: "Mint", detail: `${fmt(amount)} ${token} in ${p.pool.pair.join(" / ")}`, amt: `+${fmt(p.receive)}`, time: "Just now", tx: "0x9a1f…4c02" });
    app.showToast("Mint confirmed · noUSD added to wallet");
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
  } else if (block) {
    cta = { closed: `Minting with ${token} is closed`, paused: "Minting paused", offpeg: `${token} is off par`, cap: "Over the supply cap" }[block];
    disabled = true;
  } else if (amount <= 0) {
    cta = "Enter an amount";
    disabled = true;
  } else if (amount > balance) {
    cta = `Not enough ${token}`;
    disabled = true;
  } else if (needApprove) {
    cta = `Approve ${token}`;
    act = async () => {
      setStage("pending");
      try {
        await sendTx(c.name, 900);
      } catch (e) {
        setStage("idle");
        app.showToast((e as Error).message);
        return;
      }
      setStage("idle");
      setApproved((a) => ({ ...a, [token]: true }));
      app.showToast(`${token} approved`);
    };
  } else {
    cta = stage === "error" ? "Try again" : permit ? "Mint · one-click permit" : "Mint noUSD";
    act = () => void doMint();
  }

  const capNow = (c.supply / c.cap) * 100;
  const capAfter = Math.min(100, (p.supplyAfter / c.cap) * 100);
  const overCap = p.supplyAfter > c.cap;
  const guardShut = block === "closed" || block === "offpeg" || block === "paused";
  const guardTxt =
    block === "closed" ? `No fresh price for ${token} — mint closed` : block === "offpeg" ? `${token} off par — mint closed` : block === "paused" ? "Mint paused by governance" : `Mint open for ${token}`;
  const showSteps = !permit && !block && !wrong;
  const permitNote = permit && !block && !wrong && amount > 0 ? `${token} supports permit — approve and mint in one signature.` : "";

  return (
    <section className="mt-6 grid grid-cols-[minmax(0,1fr)] items-start gap-5 md:grid-cols-[minmax(0,520px)_minmax(0,1fr)]">
      <div className="relative flex flex-col gap-4 rounded-[20px] border border-line bg-s1 p-4 md:p-[22px]">
        <div className="flex items-start justify-between gap-3">
          <div className="flex flex-col gap-1">
            <h2 className="m-0 font-display text-[21px] font-semibold tracking-[-.01em]">Mint noUSD</h2>
            <span className="text-[13.5px] text-tx2">Deposit one stable, get noUSD for what it adds.</span>
          </div>
          <button
            type="button"
            aria-label="Mint settings"
            aria-expanded={settings}
            onClick={() => {
              setSettings((s) => !s);
              setTokOpen(false);
            }}
            className="num flex min-h-[36px] items-center gap-[6px] rounded-[10px] border border-line2 bg-s2 px-[10px] py-[7px] text-[12px] text-tx2"
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
              <path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6" />
            </svg>
            {app.slippage} %
          </button>
        </div>

        {settings && (
          <div className="popover absolute right-4 top-[66px] z-20 flex w-[290px] flex-col gap-[14px] bg-s2 p-4 md:right-[22px]">
            <div className="flex flex-col gap-2">
              <span className="text-[12.5px] font-semibold">Slippage — sets your minimum received</span>
              <div className="flex gap-[6px]">
                {SLIPS.map((v) => (
                  <button
                    key={v}
                    type="button"
                    aria-pressed={app.slippage === v}
                    onClick={() => app.setSlippage(v)}
                    className={`num flex-1 whitespace-nowrap rounded-[9px] border py-[7px] text-[12.5px] ${app.slippage === v ? "border-accent-line bg-accent-soft text-accent" : "border-line2 bg-s1 text-tx2"}`}
                  >
                    {v} %
                  </button>
                ))}
              </div>
            </div>
            <div className="flex items-center justify-between gap-[10px]">
              <label htmlFor="deadline" className="text-[12.5px] font-semibold">
                Deadline
              </label>
              <span className="flex items-center gap-[6px] rounded-[9px] border border-line2 bg-s1 px-[9px] py-[5px]">
                <input
                  id="deadline"
                  value={app.deadline}
                  onChange={(e) => app.setDeadline(e.target.value.replace(/\D/g, "").slice(0, 3))}
                  inputMode="numeric"
                  className="num w-[34px] bg-transparent text-right text-[13px] text-tx outline-none"
                />
                <span className="text-[12px] text-tx2">min</span>
              </span>
            </div>
            <span className="text-[12px] leading-[1.45] text-tx2">If the price moves past your minimum, nothing is spent and the mint is cancelled.</span>
          </div>
        )}

        {stage === "success" && done ? (
          <div className="flex flex-col items-center gap-3 pb-[6px] pt-[18px] text-center">
            <CheckBadge />
            <span className="font-display text-[20px] font-semibold">Minted {fmt(done.recv)} noUSD</span>
            <span className="text-[13.5px] text-tx2">
              {fmt(done.amt)} {done.token} deposited · {fmt(done.refund)} {done.pair} refunded to your wallet
            </span>
            <a href="#" onClick={(e) => { e.preventDefault(); app.showToast("Opens the explorer"); }} className="num text-[12.5px]">
              View transaction 0x9a1f…4c02 ↗
            </a>
            <div className="flex items-center gap-2 rounded-[12px] border border-line bg-s2 px-[14px] py-[10px] text-[13px]">
              <LiveDot /> noUSD added to wallet · earning from the next sync
            </div>
            <div className="mt-[6px] flex gap-[10px]">
              <button type="button" onClick={() => setStage("idle")} className="btn-secondary px-4 py-[10px]">
                Mint again
              </button>
              <Link href="/app" className="btn-primary px-4 py-[10px] hover:text-ink hover:no-underline">
                Go to portfolio
              </Link>
            </div>
          </div>
        ) : (
          <>
            <div className={`relative flex flex-col gap-[10px] rounded-[14px] border bg-s2 px-4 py-[14px] ${amount > balance ? "border-warn-line" : "border-line2"}`}>
              <div className="flex justify-between gap-[10px] whitespace-nowrap text-[12.5px] text-tx2">
                <span>You deposit</span>
                <span>
                  Balance <span className="num text-tx">{fmt(balance)} {token}</span>
                </span>
              </div>
              <div className="flex items-center gap-[10px]">
                <input
                  value={amountTxt}
                  onChange={(e) => {
                    setAmountTxt(cleanAmountInput(e.target.value));
                    if (stage === "error") setStage("idle");
                  }}
                  inputMode="decimal"
                  aria-label="Amount to deposit"
                  placeholder="0.00"
                  className="num min-w-0 flex-1 bg-transparent text-[26px] text-tx outline-none"
                />
                <button type="button" onClick={() => setAmountTxt(fmt(balance))} className="btn-max">
                  MAX
                </button>
                <button
                  type="button"
                  aria-haspopup="listbox"
                  aria-expanded={tokOpen}
                  onClick={() => {
                    setTokOpen((o) => !o);
                    setSettings(false);
                  }}
                  className="flex items-center gap-2 rounded-[20px] border border-line2 bg-s3 py-[5px] pl-[5px] pr-[10px] text-[14px] font-semibold text-tx"
                >
                  <TokenChip sym={token} size={24} />
                  {token}
                  <Chevron size={13} />
                </button>
              </div>
              {tokOpen && (
                <div role="listbox" className="popover absolute right-0 top-full z-20 mt-[6px] w-[300px] max-w-[calc(100vw-32px)] bg-s2 p-[6px]">
                  <div className="px-[10px] py-2 text-[11.5px] text-tx2">Mintable on {c.name}</div>
                  {c.mintable.map((k) => {
                    const tag = c.closed.includes(k) ? "Closed" : app.demoMint === "offpeg" && k === "USDT" ? "Off par" : "";
                    return (
                      <button
                        key={k}
                        type="button"
                        role="option"
                        aria-selected={k === token}
                        onClick={() => {
                          setTokenPick(k);
                          setTokOpen(false);
                          setStage("idle");
                          setErr(null);
                        }}
                        className={`flex w-full items-center gap-[10px] rounded-[10px] px-[10px] py-[9px] text-left text-tx hover:bg-s3 ${k === token ? "bg-s3" : ""}`}
                      >
                        <TokenChip sym={k} size={24} />
                        <span className="flex-1 text-[14px] font-semibold">
                          {k}
                          {tag && <span className="ml-2 rounded-[20px] border border-warn-line px-[7px] py-px text-[11px] font-semibold text-warn">{tag}</span>}
                        </span>
                        <span className="num text-[12.5px] text-tx2">{fmt(c.bal[k] ?? 0)}</span>
                      </button>
                    );
                  })}
                </div>
              )}
            </div>

            {notice && <NoticeCard notice={notice} />}

            {showSteps && (
              <div className="flex gap-2 text-[12.5px]">
                <span className={`flex flex-1 items-center gap-2 rounded-[11px] border bg-s2 px-[11px] py-[9px] ${approved[token] ? "border-accent-line text-accent" : "border-line2 text-tx"}`}>
                  <span className="num">1</span>
                  {approved[token] ? "Approved" : `Approve ${token}`}
                </span>
                <span className="flex flex-1 items-center gap-2 rounded-[11px] border border-line bg-s2 px-[11px] py-[9px] text-tx2">
                  <span className="num">2</span>Mint noUSD
                </span>
              </div>
            )}
            <Cta label={cta} onClick={act} disabled={disabled} />
            {permitNote && <span className="-mt-[6px] text-center text-[12px] text-tx2">{permitNote}</span>}
          </>
        )}
      </div>

      <div className="flex flex-col gap-1 rounded-[20px] border border-line bg-s1 p-4 md:p-[22px]">
        <span className="label pb-2 text-[12px] tracking-[.08em]">Preview · updates live</span>
        <div className="row py-3">
          <span className="text-[13.5px] text-tx2">Goes to pool</span>
          <span className="flex items-center gap-2">
            <PairChips pair={p.pool.pair} size={20} />
            <span className="pl-[6px] font-semibold">{p.pool.pair.join(" / ")}</span>
            <span className="num rounded-[8px] border border-line2 px-[7px] py-[2px] text-[12px] text-tx2">{p.pool.fee}</span>
          </span>
        </div>
        <div className="row py-3">
          <span className="text-[13.5px] text-tx2">Pairing</span>
          <span
            className={`num flex min-w-0 items-center gap-[7px] truncate rounded-[9px] border px-[9px] py-1 text-[13px] ${p.swap > 0 ? "border-warn-line text-warn" : "border-accent-line text-accent"}`}
          >
            <span>{p.swap > 0 ? "⇄" : "✓"}</span>
            <span className="truncate">{p.swap > 0 ? `≈ ${fmt(p.swap)} ${token} swapped in ${p.pool.pair.join(" / ")}` : "Paired with idle — no swap"}</span>
          </span>
        </div>
        <div className="row py-3">
          <span className="text-[13.5px] text-tx2">Swap cost</span>
          <span className="num text-[13px]">{p.swap > 0 ? `≈ 0.02 % · $${fmt(p.swapCost)}` : "none"}</span>
        </div>
        <div className="row items-baseline py-[14px]">
          <span className="text-[14px] font-semibold">You receive</span>
          <span className="font-display text-[24px] font-semibold tabular-nums tracking-[-.02em]">
            ≈ {fmt(p.receive)} <span className="text-[14px] text-accent">noUSD</span>
          </span>
        </div>
        <div className="row py-[10px]">
          <span className="text-[13.5px] text-tx2">Refund (leftover)</span>
          <span className="num text-[13px]">
            ≈ {fmt(p.refund)} {p.pair}
          </span>
        </div>
        <div className="row py-[10px]">
          <span className="text-[13.5px] text-tx2">Minimum received ({app.slippage} %)</span>
          <span className="num text-[13px]">{fmt(p.minReceived)} noUSD</span>
        </div>
        <div className="row py-3">
          <span className="text-[13.5px] text-tx2">Price guard</span>
          <span className={`flex items-center gap-2 text-[13px] font-semibold ${guardShut ? "text-warn" : "text-accent"}`}>
            {guardShut ? <Diamond /> : <LiveDot />}
            {guardTxt}
          </span>
        </div>
        <div className="flex flex-col gap-2 border-t border-line pb-[2px] pt-3">
          <div className="flex justify-between whitespace-nowrap text-[13.5px]">
            <span className="text-tx2">Supply cap</span>
            <span className="num text-[12.5px]">
              {fmt(c.supply, 0)} / {fmt(c.cap, 0)}
            </span>
          </div>
          <div className="relative h-2 overflow-hidden rounded-[5px] bg-s3">
            <span className="absolute inset-y-0 left-0" style={{ width: `${capAfter}%`, background: overCap ? "#FFC76B" : "rgba(52,227,172,.35)" }} />
            <span className="absolute inset-y-0 left-0 bg-accent" style={{ width: `${capNow}%` }} />
          </div>
          <div className="flex justify-between whitespace-nowrap text-[12px] text-tx2">
            <span>
              Now <span className="num">{capNow.toFixed(1)} %</span>
            </span>
            <span>
              After this mint <span className={`num ${overCap ? "text-warn" : "text-tx"}`}>{overCap ? "over cap" : `${((p.supplyAfter / c.cap) * 100).toFixed(1)} %`}</span>
            </span>
          </div>
        </div>
        {app.advanced && (
          <div className="num mt-3 grid grid-cols-[auto_1fr] gap-x-[14px] gap-y-[6px] rounded-[12px] bg-s2 px-[14px] py-3 text-[11.5px] text-tx2">
            <span>Pool ID</span>
            <span className="break-all text-tx">{p.pool.id}</span>
            <span>Range</span>
            <span className="text-tx">{p.pool.ticks}</span>
            <span>Router</span>
            <span className="break-all text-tx">{DEMO_ROUTER}</span>
          </div>
        )}
      </div>
    </section>
  );
}
