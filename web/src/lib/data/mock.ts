import type { ActivityItem, ChainKey, ChainView } from "./types";

// Demo data from the design handoff (noUSD App.dc.html). Formatting examples only: every number here
// is replaced by on-chain reads once the contracts are deployed.

const H = 36e5;

/** The demo account the mock connector signs in as. */
export const DEMO_ACCOUNT = "0xB7294cD1e0A5F3b6c8E9d2A47f1C05e3D8a693B2" as const;

/** The owner Safe shown on Governance. */
export const DEMO_SAFE = "0x2F8d61B0c9E4a3D2f5B7e8A1c0D9b6E4f3A27aC1";

/** The swap router shown under Advanced on Mint. */
export const DEMO_ROUTER = "0x7a3C61B0e2D9f4a8C5b1E0d3F6a29c7B4e815D02";

export const CHAINS: Record<ChainKey, ChainView> = {
  eth: {
    key: "eth",
    chainId: 1,
    name: "Ethereum",
    live: true,
    glyph: "linear-gradient(135deg,#A9B6FF,#627EEA)",
    sync: "daily",
    periodMs: 24 * H,
    lastSyncAgoMs: 2 * H + 14 * 6e4,
    supply: 84210.55,
    backing: 84236.1,
    unclaimed: 241.18,
    treasury: 0,
    apr7: 6.2,
    apr30: 5.8,
    cap: 100000,
    token: "0x4c9E2a71B0d3F5c8E6a9D1b4C7f0E3a2D5b868B3",
    mintable: ["USDC", "USDT", "DAI", "USDe"],
    closed: [],
    poolOf: { USDC: 0, USDe: 0, DAI: 1, USDT: 1 },
    pools: [
      {
        pair: ["USDe", "USDC"],
        fee: "0.0025 %",
        status: "Active",
        tvl: "$861k",
        apr: 10.8,
        share: 9.8,
        cap: 30,
        pos: 48920,
        inRange: true,
        bp: "+0.4 bp",
        tick: "4",
        range: "0.9990 – 1.0010",
        ticks: "−10 → +10",
        guard: "Vouched",
        compound: "6 h ago",
        id: "0x7f3a90d2b4e1c8a7f6d5e3b2a19c0d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4ac21e",
        comp: { USDe: 24470, USDC: 24450 },
      },
      {
        pair: ["DAI", "USDT"],
        fee: "0.0068 %",
        status: "Active",
        tvl: "$596k",
        apr: 1.5,
        share: 5.9,
        cap: 30,
        pos: 35004,
        inRange: true,
        bp: "−1.2 bp",
        tick: "−12",
        range: "0.9980 – 1.0015",
        ticks: "−20 → +15",
        guard: "Vouched",
        compound: "6 h ago",
        id: "0x19be5c7a2d0f84e3b1c6a9d7e2f05b48c3a1d6e9f7b2c40a8e5d3f1b6c9a04d7",
        comp: { DAI: 17502, USDT: 17502 },
      },
      {
        pair: ["USDS", "RLUSD"],
        fee: "0.0005 %",
        status: "Withdraw only",
        tvl: "$1.4M",
        apr: 0,
        share: 0,
        cap: 30,
        pos: 0,
        inRange: false,
        bp: "+0.1 bp",
        tick: "1",
        range: "no position",
        ticks: "—",
        guard: "No fresh price",
        compound: "—",
        id: "0xa4c2e81f6b3d90c7a5e2f4b1d8c6a3e0f9b7d5c2a1e8f6b4d3c0a9e7f5b29e10",
        comp: {},
      },
    ],
    idle: [
      ["USDC", 212.4],
      ["USDe", 99.71],
    ],
    basket: [
      ["USDe", 0.2905],
      ["USDC", 0.2906],
      ["DAI", 0.2088],
      ["USDT", 0.2087],
    ],
    held: 3412.8,
    unc: 9.76,
    since: "Sep 14, 2026",
    bal: { USDC: 25000, USDT: 4120.5, DAI: 8300, USDe: 1250 },
  },
  uni: {
    key: "uni",
    chainId: 130,
    name: "Unichain",
    live: true,
    glyph: "linear-gradient(135deg,#FF4FD8,#FF8A3D)",
    sync: "hourly",
    periodMs: H,
    lastSyncAgoMs: 22 * 6e4,
    supply: 12480.2,
    backing: 12483.95,
    unclaimed: 18.4,
    treasury: 0,
    apr7: 4.1,
    apr30: 3.9,
    cap: 50000,
    token: "0x91aF3c7D2e0B5a8F4d6C1e9b7A3f0D2c5E8b0C3e",
    mintable: ["USDC", "USDT"],
    closed: ["USDT"],
    poolOf: { USDC: 0, USDT: 0 },
    pools: [
      {
        pair: ["USDC", "USDT"],
        fee: "0.0010 %",
        status: "Active",
        tvl: "$1.2M",
        apr: 4.6,
        share: 1.0,
        cap: 30,
        pos: 12412,
        inRange: true,
        bp: "+0.2 bp",
        tick: "2",
        range: "0.9992 – 1.0008",
        ticks: "−8 → +8",
        guard: "No fresh price (USDT)",
        compound: "22 m ago",
        id: "0x3b8d1f0e7c2a5d9b4e6f8a1c3d5e7f9b0a2c4e6d8f1a3b5c7e9d0f2a4c6e8b1d",
        comp: { USDC: 6210, USDT: 6202 },
      },
    ],
    idle: [["USDC", 71.95]],
    basket: [
      ["USDC", 0.5003],
      ["USDT", 0.4998],
    ],
    held: 500,
    unc: 0.84,
    since: "Oct 2, 2026",
    bal: { USDC: 3200, USDT: 900 },
  },
  arb: { key: "arb", chainId: 42161, name: "Arbitrum", live: false, glyph: "linear-gradient(135deg,#28A0F0,#1B4ADD)" },
  base: { key: "base", chainId: 8453, name: "Base", live: false, glyph: "linear-gradient(135deg,#3C7BFF,#0052FF)" },
};

export const CHAIN_ORDER: ChainKey[] = ["eth", "uni", "arb", "base"];

export const DEMO_ACTIVITY: Partial<Record<ChainKey, ActivityItem[]>> = {
  eth: [
    { type: "Mint", detail: "10,000.00 USDC in USDe / USDC", amt: "+9,994.10", time: "Nov 21 · 14:02", tx: "0x9a1f…4c02" },
    { type: "Claim", detail: "Earnings to my wallet · 4 tokens", amt: "12.40", time: "Nov 18 · 09:41", tx: "0x51c8…e07a" },
    { type: "Transfer", detail: "Sent to 0x3E1a…77F0", amt: "−2,000.00", time: "Nov 10 · 18:22", tx: "0xd4e2…19bb" },
    { type: "Redeem", detail: "Basket to 0xB729…93B2", amt: "−4,581.30", time: "Oct 29 · 11:05", tx: "0x0c7d…a3f1" },
  ],
  uni: [{ type: "Mint", detail: "500.30 USDC in USDC / USDT", amt: "+500.00", time: "Oct 2 · 16:40", tx: "0x2b90…7e1c" }],
};

export const FAQ: [string, string][] = [
  [
    "Is 1 noUSD = $1?",
    "No. 1 noUSD is one unit of the stable basket — all allowed stables count 1 : 1 with each other. Redeeming gives you your share of every position in kind. If one stable depegs, noUSD honestly reflects it instead of hiding it.",
  ],
  [
    "Where do earnings come from?",
    "From trading fees in the Uniswap v4 stable pools the basket provides liquidity to. When the protocol syncs (hourly on L2, daily on Ethereum), new fees are added to every holder's accrued earnings.",
  ],
  [
    "Why do I get several tokens on redeem?",
    "Because noUSD is backed by liquidity positions that each hold two stables, plus small idle balances. Redeem returns a pro-rata slice of all of them — e.g. 1,000 noUSD → 290.5 USDe + 290.6 USDC + 208.8 DAI + 208.7 USDT.",
  ],
  [
    "Can my smart wallet earn?",
    "Regular wallets earn automatically. Smart-contract wallets (Safes, vaults, pools) don't earn until they opt in, so contracts holding noUSD never collect earnings by accident. Use \"Turn on earning\" in the app.",
  ],
  [
    "What does \"per chain\" mean?",
    "Each network has its own independent noUSD with its own basket. noUSD on Ethereum is not the same token as noUSD on Unichain, and there is no bridge between them.",
  ],
  [
    "What are the fees?",
    "Mint and protocol fees are 0 % today, capped in code at 0.5 % and 10 %. Minting may swap a small part to pair your deposit, which costs about 0.01–0.03 %. Redeem and claim have no protocol fee.",
  ],
];
