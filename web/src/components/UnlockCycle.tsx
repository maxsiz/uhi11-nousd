"use client";

import { useEffect, useRef, useState } from "react";

// One mint and one redeem, step by step, as NoUSDPositionManager runs them inside a single
// PoolManager.unlock (spec §9; _mintInUnlock and Settlement.payout). The ledger is the manager's
// currency delta in the PoolManager after each step: + the PoolManager owes the manager, − the reverse.
// Numbers follow the design's 10,000 USDC example; they are illustrative, not live.

type Step = {
  title: string;
  code: string;
  body: string;
  /** Outside the unlock frame (before or after it). */
  outside?: "before" | "after";
  /** A real ERC-20 transfer happens in this step. */
  transfer?: string;
  ledger: string[];
  idle: string;
  transfers: number;
};

type Flow = { key: "mint" | "redeem"; label: string; cols: string[]; idleLabel: string; result: string; steps: Step[] };

const MINT: Flow = {
  key: "mint",
  label: "Mint",
  cols: ["USDC", "USDe"],
  idleLabel: "Idle USDe · ERC-6909 claims",
  result: "All deltas closed → unlock returns → mint 9,994.10 noUSD",
  steps: [
    {
      title: "Deposit straight into the PoolManager",
      code: "sync(USDC) · transferFrom → PoolManager · settle()",
      body: "10,000 USDC go from your wallet to the PoolManager, not to our contract. The manager now holds a credit.",
      transfer: "in",
      ledger: ["+10,000.00", "0"],
      idle: "212.40",
      transfers: 1,
    },
    {
      title: "Pair it with idle first",
      code: "idle USDe 212.40 · ERC-6909 claims",
      body: "Leftovers of earlier mints already sit in the PoolManager as ERC-6909 claims. They count as the other side — nothing moves.",
      ledger: ["+10,000.00", "0"],
      idle: "212.40 → pairing",
      transfers: 1,
    },
    {
      title: "Swap only what is missing",
      code: "swap(USDe/USDC) · never past par ± depeg",
      body: "4,500.29 USDC become USDe in a v4 pool. Any pool works — the singleton lets the swap and the add hit different pools in one unlock. Only deltas change.",
      ledger: ["+5,499.71", "+4,499.39"],
      idle: "212.40 → pairing",
      transfers: 1,
    },
    {
      title: "Add liquidity to the shared position",
      code: "modifyLiquidity(+L)",
      body: "The pair goes into the protocol's one position. The USDe side is short by exactly the idle it used.",
      ledger: ["0.00", "−207.70"],
      idle: "212.40 → pairing",
      transfers: 1,
    },
    {
      title: "Close every delta",
      code: "burn claims 212.40 · take(USDe 4.70 → you)",
      body: "Idle claims cover the gap, the change goes back to your wallet. Every delta is zero.",
      transfer: "out",
      ledger: ["0", "0"],
      idle: "0.00",
      transfers: 2,
    },
    {
      title: "Check, or undo everything",
      code: "oracle.check(pools) · share ≤ cap",
      body: "The unisafe price guard checks the pegs and the pool share cap is enforced. If anything fails, the whole unlock reverts as if nothing happened.",
      ledger: ["0", "0"],
      idle: "0.00",
      transfers: 2,
    },
    {
      title: "Mint noUSD for the value added",
      code: "noUSD.mint(you, 9,994.10)",
      body: "You get noUSD for what your deposit added to the basket — and start earning the pool fees.",
      outside: "after",
      ledger: ["0", "0"],
      idle: "0.00",
      transfers: 2,
    },
  ],
};

const REDEEM: Flow = {
  key: "redeem",
  label: "Redeem",
  cols: ["USDe", "USDC", "DAI", "USDT"],
  idleLabel: "Idle USDC · ERC-6909 claims",
  result: "All deltas closed → unlock returns → 4 tokens at your address",
  steps: [
    {
      title: "Burn noUSD",
      code: "noUSD.burn(1,000) · 1.19 % of supply",
      body: "Your unclaimed earnings ride along. Redeem can't be paused — not even by the owner.",
      outside: "before",
      ledger: ["0", "0", "0", "0"],
      idle: "212.40",
      transfers: 0,
    },
    {
      title: "Take your slice of every position",
      code: "modifyLiquidity(−L · 1.19 %) × each pool",
      body: "The same share leaves every pool in one unlock. Fees collected on the way stay in the deltas.",
      ledger: ["+289.32", "+288.08", "+208.80", "+208.70"],
      idle: "212.40",
      transfers: 0,
    },
    {
      title: "Add your slice of idle",
      code: "burn claims · USDC 2.52 · USDe 1.18",
      body: "Idle claims inside the PoolManager are part of the backing, so you get your share of them too.",
      ledger: ["+290.50", "+290.60", "+208.80", "+208.70"],
      idle: "209.88",
      transfers: 0,
    },
    {
      title: "Pay out, or revert",
      code: "≥ minOut · take(token → any address) × 4",
      body: "Each token goes from the PoolManager straight to the address you chose. If one token refuses the recipient, the whole redeem reverts and nothing is spent.",
      transfer: "out",
      ledger: ["0", "0", "0", "0"],
      idle: "209.88",
      transfers: 4,
    },
  ],
};

const FLOWS = [MINT, REDEEM];
const STEP_MS = 2600;
const HOLD_MS = 4200;

const PILLARS = [
  ["Flash accounting", "Deposit, swap, add and refund net out in one unlock — only the deltas move."],
  ["Singleton", "Swap in one pool and add in another without a token ever leaving the PoolManager."],
  ["ERC-6909 claims", "Idle balances stay inside the PoolManager as claims: no transfers, no extra custody."],
] as const;

export function UnlockCycle() {
  const [flowKey, setFlowKey] = useState<Flow["key"]>("mint");
  const [step, setStep] = useState(0);
  const [playing, setPlaying] = useState(true);
  const [hold, setHold] = useState(false);
  const [visible, setVisible] = useState(false);
  const ref = useRef<HTMLElement>(null);
  const flow = flowKey === "mint" ? MINT : REDEEM;
  const s = flow.steps[step];
  const last = step === flow.steps.length - 1;

  // Play only while on screen and the tab is visible; reduced motion starts paused.
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let first = true;
    const io = new IntersectionObserver(
      ([e]) => {
        if (first && window.matchMedia("(prefers-reduced-motion: reduce)").matches) setPlaying(false);
        first = false;
        setVisible(e.isIntersecting && !document.hidden);
      },
      { threshold: 0.35 },
    );
    io.observe(el);
    const onVis = () => {
      if (document.hidden) setVisible(false);
    };
    document.addEventListener("visibilitychange", onVis);
    return () => {
      io.disconnect();
      document.removeEventListener("visibilitychange", onVis);
    };
  }, []);

  useEffect(() => {
    if (!playing || hold || !visible) return;
    const t = setTimeout(
      () => {
        if (!last) return setStep(step + 1);
        // After a mint, show the redeem; after a redeem, start over.
        setFlowKey(flowKey === "mint" ? "redeem" : "mint");
        setStep(0);
      },
      last ? HOLD_MS : STEP_MS,
    );
    return () => clearTimeout(t);
  }, [playing, hold, visible, step, last, flowKey]);

  const pick = (k: Flow["key"]) => {
    setFlowKey(k);
    setStep(0);
  };

  const inside = flow.steps.map((x, i) => ({ x, i })).filter(({ x }) => !x.outside);
  const before = flow.steps.map((x, i) => ({ x, i })).filter(({ x }) => x.outside === "before");
  const after = flow.steps.map((x, i) => ({ x, i })).filter(({ x }) => x.outside === "after");

  const row = ({ x, i }: { x: Step; i: number }) => {
    const state = i === step ? "now" : i < step ? "done" : "next";
    return (
      <li key={`${flow.key}-${i}`}>
        <button
          type="button"
          aria-current={state === "now" ? "step" : undefined}
          onClick={() => {
            setStep(i);
            setPlaying(false);
          }}
          className={`group flex w-full items-start gap-3 rounded-[12px] border px-3 py-[10px] text-left transition-colors duration-300 motion-reduce:transition-none ${
            state === "now" ? "border-accent-line bg-accent-soft" : "border-transparent hover:bg-white/[.03]"
          }`}
        >
          <span
            className={`num mt-px flex h-[22px] w-[22px] flex-none items-center justify-center rounded-full border text-[11px] transition-colors duration-300 motion-reduce:transition-none ${
              state === "now"
                ? "border-accent bg-accent text-ink"
                : state === "done"
                  ? "border-accent-line text-accent"
                  : "border-line2 text-tx3"
            }`}
          >
            {state === "done" ? "✓" : i + 1}
          </span>
          <span className="flex min-w-0 flex-1 flex-col gap-1">
            <span className="flex flex-wrap items-center gap-2">
              <span className={`text-[14px] font-semibold ${state === "next" ? "text-tx2" : "text-tx"}`}>{x.title}</span>
              {x.transfer && (
                <span className="rounded-[20px] border border-warn-line px-[7px] py-px text-[10.5px] font-semibold uppercase tracking-[.06em] text-warn">
                  token transfer
                </span>
              )}
            </span>
            <span className={`num break-words text-[11.5px] ${state === "now" ? "text-accent" : "text-tx3"}`}>{x.code}</span>
            {state === "now" && <span className="text-[13px] leading-[1.5] text-tx2">{x.body}</span>}
          </span>
        </button>
      </li>
    );
  };

  return (
    <section
      ref={ref}
      id="unlock"
      aria-labelledby="unlock-title"
      className="flex scroll-mt-20 flex-col gap-[18px] pt-[56px]"
      onMouseEnter={() => setHold(true)}
      onMouseLeave={() => setHold(false)}
      onFocus={() => setHold(true)}
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setHold(false);
      }}
    >
      <div className="flex flex-col justify-between gap-4 md:flex-row md:items-end">
        <div className="flex max-w-[640px] flex-col gap-2">
          <span className="eyebrow">BUILT ON UNISWAP V4 · NO HOOK NEEDED</span>
          <h2 id="unlock-title" className="h2 m-0">
            Every mint and redeem is one <span className="num text-accent">unlock()</span>
          </h2>
          <span className="text-[14.5px] leading-[1.55] text-tx2">
            noUSD lives inside v4&apos;s PoolManager. Deposit, swap, add liquidity and change all net out in a single
            unlock with flash accounting — two token transfers touch your wallet, and if any check fails, everything
            reverts.
          </span>
        </div>
        <div className="flex flex-none items-center gap-2">
          <div role="tablist" aria-label="Flow" className="flex rounded-[12px] border border-line2 bg-s2 p-[3px]">
            {FLOWS.map((f) => (
              <button
                key={f.key}
                type="button"
                role="tab"
                aria-selected={flowKey === f.key}
                onClick={() => pick(f.key)}
                className={`min-h-[36px] rounded-[9px] px-[14px] text-[13px] font-semibold ${flowKey === f.key ? "bg-s3 text-tx" : "text-tx2 hover:text-tx"}`}
              >
                {f.label}
              </button>
            ))}
          </div>
          <button
            type="button"
            aria-pressed={playing}
            aria-label={playing ? "Pause the walkthrough" : "Play the walkthrough"}
            onClick={() => {
              if (!playing && last) setStep(0);
              setPlaying((p) => !p);
            }}
            className="flex h-[42px] w-[42px] items-center justify-center rounded-[12px] border border-line2 bg-s2 text-tx2 hover:text-tx"
          >
            {playing ? (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                <rect x="6" y="5" width="4" height="14" rx="1" />
                <rect x="14" y="5" width="4" height="14" rx="1" />
              </svg>
            ) : (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                <path d="M7 4.5v15a1 1 0 0 0 1.5.86l12-7.5a1 1 0 0 0 0-1.72l-12-7.5A1 1 0 0 0 7 4.5Z" />
              </svg>
            )}
          </button>
        </div>
      </div>

      <div className="grid grid-cols-[minmax(0,1fr)] gap-4 rounded-[20px] border border-line bg-s1 p-3 md:grid-cols-[minmax(0,1.45fr)_minmax(0,1fr)] md:gap-5 md:p-5">
        <div className="flex flex-col gap-2">
          {before.length > 0 && <ol className="flex flex-col">{before.map(row)}</ol>}
          <div className="relative rounded-[16px] border border-dashed border-accent-line p-2 pt-7">
            <span className="num absolute left-3 top-2 text-[11px] text-accent">
              poolManager.unlock( ) <span className="text-tx3">→ unlockCallback</span>
            </span>
            <ol className="flex flex-col">{inside.map(row)}</ol>
          </div>
          {after.length > 0 && <ol className="flex flex-col">{after.map(row)}</ol>}
        </div>

        <div className="flex flex-col gap-3 rounded-[16px] border border-line bg-s2 p-4" aria-live="off">
          <div className="flex items-baseline justify-between gap-2">
            <span className="label">Manager&apos;s deltas in the PoolManager</span>
            <span className="num text-[11px] text-tx3">
              step {step + 1}/{flow.steps.length}
            </span>
          </div>
          <div className="flex flex-col">
            {flow.cols.map((c, j) => {
              const v = s.ledger[j];
              const zero = v === "0" || v === "0.00";
              return (
                <div key={c} className="flex items-center justify-between border-t border-line py-[9px]">
                  <span className="text-[13.5px] font-semibold">{c}</span>
                  <span
                    className={`num text-[14px] transition-colors duration-300 motion-reduce:transition-none ${zero ? "text-tx3" : v.startsWith("−") ? "text-warn" : "text-accent"}`}
                  >
                    {zero ? "0" : v}
                  </span>
                </div>
              );
            })}
            <div className="flex items-center justify-between gap-3 border-t border-line py-[9px]">
              <span className="text-[12.5px] text-tx2">{flow.idleLabel}</span>
              <span className="num whitespace-nowrap text-[13px] text-tx">{s.idle}</span>
            </div>
          </div>
          <div className="flex items-center justify-between rounded-[12px] border border-line bg-s1 px-3 py-[10px]">
            <span className="text-[12.5px] text-tx2">Real token transfers</span>
            <span className="flex items-center gap-[6px]">
              {Array.from({ length: flowKey === "mint" ? 2 : 4 }, (_, k) => (
                <span
                  key={k}
                  className={`h-[10px] w-[10px] rounded-full border transition-colors duration-300 motion-reduce:transition-none ${k < s.transfers ? "border-warn bg-warn" : "border-line2"}`}
                />
              ))}
              <span className="num ml-1 text-[13px]">{s.transfers}</span>
            </span>
          </div>
          <div
            className={`rounded-[12px] border px-3 py-[10px] text-[12.5px] leading-[1.45] transition-colors duration-300 motion-reduce:transition-none ${last ? "border-accent-line bg-accent-soft text-accent" : "border-line text-tx3"}`}
          >
            {last ? flow.result : "Every delta must reach zero before unlock returns — or the transaction reverts."}
          </div>
          <span className="text-[11.5px] leading-[1.45] text-tx3">
            Example amounts. Uniswap pools stay hookless: noUSD adds depth to existing stable pools instead of
            fragmenting them.
          </span>
        </div>
      </div>

      <div className="grid grid-cols-[minmax(0,1fr)] gap-3 md:grid-cols-3">
        {PILLARS.map(([t, d]) => (
          <div key={t} className="flex flex-col gap-1 rounded-card border border-line bg-s1 px-4 py-[14px]">
            <span className="text-[14px] font-semibold text-tx">{t}</span>
            <span className="text-[13px] leading-[1.5] text-tx2">{d}</span>
          </div>
        ))}
      </div>
    </section>
  );
}
