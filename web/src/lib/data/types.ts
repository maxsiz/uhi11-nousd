// The read model every screen renders from. Today it is filled from `mock.ts` (contracts are not
// deployed yet); later from wagmi reads of NoUSD, NoUSDPositionManager and NoUSDRegistry — the
// handoff README's "Data sources" table says which call feeds which field.

export type Sym = "USDC" | "USDT" | "DAI" | "USDe" | "USDS" | "RLUSD";

export type ChainKey = "eth" | "uni" | "arb" | "base";

export type PoolStatus = "Active" | "Withdraw only";

export interface PoolView {
  pair: [Sym, Sym];
  fee: string; // display, e.g. "0.0025 %"
  status: PoolStatus;
  tvl: string; // pool TVL (all LPs), display
  apr: number; // trailing fee APR, %
  share: number; // our liquidity / pool liquidity, %
  cap: number; // share cap, %
  pos: number; // our position value at par
  inRange: boolean;
  bp: string; // price vs par, display
  tick: string;
  range: string; // price range, display
  ticks: string; // tick range relative to par, display
  guard: string; // "Vouched" or why not
  compound: string; // last compound, relative
  id: string; // pool id
  comp: Partial<Record<Sym, number>>; // position composition at par
}

/** One deployment of noUSD. Undeployed chains only carry name and glyph. */
export interface ChainView {
  key: ChainKey;
  chainId: number;
  name: string;
  live: boolean;
  glyph: string; // CSS background
  sync?: "daily" | "hourly";
  periodMs?: number; // keeper sync cadence
  lastSyncAgoMs?: number; // at page load
  supply?: number;
  backing?: number;
  unclaimed?: number;
  treasury?: number;
  apr7?: number;
  apr30?: number;
  cap?: number;
  token?: string; // noUSD address on this chain
  mintable?: Sym[];
  closed?: Sym[]; // price guard has no fresh price
  poolOf?: Partial<Record<Sym, number>>; // which pool a deposit of the token goes to
  pools?: PoolView[];
  idle?: [Sym, number][];
  basket?: [Sym, number][]; // tokens in one noUSD
  // the connected account (demo)
  held?: number;
  unc?: number;
  since?: string;
  bal?: Partial<Record<Sym, number>>;
}

export type LiveChain = Required<ChainView>;

export type ActivityType = "Mint" | "Redeem" | "Claim" | "Transfer";

export interface ActivityItem {
  type: ActivityType;
  detail: string;
  amt: string; // signed display
  time: string;
  tx: string;
}

export interface PendingRedeem {
  id: number;
  amt: number;
  readyAt: number; // ms epoch
  to: string; // short address
}

export interface GovParam {
  name: string;
  cur: string;
  cap: string;
  attention: boolean;
}

export type QueueStatus = "queued" | "executable" | "executed" | "cancelled";

export interface QueueItem {
  title: string;
  from: string;
  to: string;
  loosens: boolean;
  status: QueueStatus;
  when: string;
}
