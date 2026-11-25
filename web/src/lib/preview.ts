import type { LiveChain, PoolView, Sym } from "./data/types";

// Preview math for the demo data. On-chain it is replaced by eth_call simulations: mint() returns the
// noUSD out; redeem and claim pay num/den of every position and idle (spec §9.2, §9.5).

export interface MintPreview {
  token: Sym;
  pool: PoolView;
  pair: Sym; // the pool's other token
  swap: number; // deposit token swapped in the pool (0 when idle covers the pair side)
  swapCost: number; // value lost to the swap fee
  receive: number;
  refund: number; // leftover of the pair token, refunded
  minReceived: number;
  supplyAfter: number;
}

/** Ratios measured on the demo pools: 0.059 % of a deposit is swap cost + refund, 0.047 % refund. */
export function mintPreview(c: LiveChain, token: Sym, amount: number, slippagePct: number): MintPreview {
  const pool = c.pools[c.poolOf[token] ?? 0];
  const pair = pool.pair.find((x) => x !== token) ?? pool.pair[1];
  const idlePair = c.idle.find((i) => i[0] === pair)?.[1] ?? 0;
  const swap = Math.max(0, amount * 0.46 - idlePair);
  const receive = amount * (1 - 0.00059);
  return {
    token,
    pool,
    pair,
    swap,
    swapCost: swap * 0.0002,
    receive,
    refund: amount * 0.00047,
    minReceived: receive * (1 - slippagePct / 100),
    supplyAfter: c.supply + receive,
  };
}

export type MintBlock = "closed" | "paused" | "offpeg" | "cap";

/** Why minting with `token` is blocked right now, if it is (handoff Mint "States"). */
export function mintBlock(
  c: LiveChain,
  token: Sym,
  supplyAfter: number,
  demo: { paused: boolean; usdtOffPar: boolean },
): MintBlock | null {
  if (c.closed.includes(token)) return "closed";
  if (demo.paused) return "paused";
  if (demo.usdtOffPar && token === "USDT") return "offpeg";
  if (supplyAfter > c.cap) return "cap";
  return null;
}

export interface BasketRow {
  sym: Sym;
  amount: number;
}

/** Redeeming `x` noUSD: one row per token of the basket, plus the share of unclaimed earnings paid too. */
export function redeemPreview(c: LiveChain, x: number, held: number, unclaimed: number) {
  const included = held > 0 ? (Math.min(x, held) / held) * unclaimed : 0;
  const rows: BasketRow[] = c.basket.map(([sym, r]) => ({ sym, amount: x * r }));
  const total = x * c.basket.reduce((a, b) => a + b[1], 0) + included;
  return { rows, included, total };
}

/** Claiming `unclaimed`: its split across the basket tokens. */
export function claimSplit(c: LiveChain, unclaimed: number): BasketRow[] {
  const sum = c.basket.reduce((a, b) => a + b[1], 0);
  return c.basket.map(([sym, r]) => ({ sym, amount: (unclaimed * r) / sum }));
}

/** Backing by token (positions + idle) and its share of total backing. */
export function basketByToken(c: LiveChain) {
  const tot: Partial<Record<Sym, number>> = {};
  for (const p of c.pools) {
    for (const [k, v] of Object.entries(p.comp) as [Sym, number][]) tot[k] = (tot[k] ?? 0) + v;
  }
  for (const [k, v] of c.idle) tot[k] = (tot[k] ?? 0) + v;
  const per = Object.fromEntries(c.basket) as Partial<Record<Sym, number>>;
  return (Object.entries(tot) as [Sym, number][]).map(([sym, value]) => ({
    sym,
    value,
    pct: (value / c.backing) * 100,
    perNoUSD: per[sym] ?? 0,
  }));
}
