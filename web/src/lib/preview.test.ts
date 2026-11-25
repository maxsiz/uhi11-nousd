import { describe, expect, it } from "vitest";
import { CHAINS } from "./data/mock";
import type { LiveChain } from "./data/types";
import { mintNotice } from "./errors";
import { duration, fmt, isRecipient, parseAmount, shortAddr } from "./format";
import { basketByToken, claimSplit, mintBlock, mintPreview, redeemPreview } from "./preview";

const eth = CHAINS.eth as LiveChain;
const uni = CHAINS.uni as LiveChain;
const noDemo = { paused: false, usdtOffPar: false };

describe("format", () => {
  it("formats amounts, addresses and durations like the design", () => {
    expect(fmt(9994.1)).toBe("9,994.10");
    expect(parseAmount("10,000.5")).toBe(10000.5);
    expect(parseAmount("abc")).toBe(0);
    expect(shortAddr("0xB7294cD1e0A5F3b6c8E9d2A47f1C05e3D8a693B2")).toBe("0xB729…93B2");
    expect(duration(21 * 36e5 + 46 * 6e4)).toBe("21 h 46 m");
    expect(duration(4 * 6e4 + 7e3)).toBe("4 m 07 s");
  });

  it("accepts a hex address or an ENS name as recipient", () => {
    expect(isRecipient("0x1f9C4e2Ab03D1f9C4e2Ab03D1f9C4e2Ab03Db03D")).toBe(true);
    expect(isRecipient("alice.eth")).toBe(true);
    expect(isRecipient("0x1234")).toBe(false);
  });
});

describe("mint preview", () => {
  it("reproduces the design's 10,000 USDC example", () => {
    const p = mintPreview(eth, "USDC", 10_000, 0.1);
    expect(p.pool.pair).toEqual(["USDe", "USDC"]);
    expect(p.pair).toBe("USDe");
    expect(fmt(p.receive)).toBe("9,994.10");
    expect(fmt(p.minReceived)).toBe("9,984.11");
    expect(fmt(p.refund)).toBe("4.70");
  });

  it("pairs with idle first: no swap when idle covers the pair side", () => {
    expect(mintPreview(eth, "USDe", 100, 0.1).swap).toBe(0); // 212.40 USDC idle covers 46
    expect(mintPreview(eth, "USDe", 10_000, 0.1).swap).toBeCloseTo(4600 - 212.4);
  });

  it("blocks mint for the right reason", () => {
    expect(mintBlock(uni, "USDT", 0, noDemo)).toBe("closed");
    expect(mintBlock(eth, "USDC", 0, { paused: true, usdtOffPar: false })).toBe("paused");
    expect(mintBlock(eth, "USDT", 0, { paused: false, usdtOffPar: true })).toBe("offpeg");
    expect(mintBlock(eth, "USDC", 100_001, noDemo)).toBe("cap");
    expect(mintBlock(eth, "USDC", eth.supply + 10, noDemo)).toBeNull();
  });

  it("states how much can still be minted under the cap", () => {
    const n = mintNotice("cap", { token: "USDC", chain: "Ethereum", deadlineMin: "20", mintableLeft: eth.cap - eth.supply });
    expect(n.body).toContain("15,789.45 noUSD can be minted on Ethereum");
  });
});

describe("redeem and claim", () => {
  it("pays a slice of every basket token plus the matching earnings", () => {
    const r = redeemPreview(eth, 1000, 3412.8, 9.76);
    expect(r.rows.map((x) => fmt(x.amount))).toEqual(["290.50", "290.60", "208.80", "208.70"]);
    expect(fmt(r.included)).toBe("2.86");
  });

  it("splits earnings across the basket and keeps the total", () => {
    const rows = claimSplit(eth, 9.76);
    expect(rows.reduce((a, b) => a + b.amount, 0)).toBeCloseTo(9.76);
  });

  it("adds positions and idle into backing by token", () => {
    const usdc = basketByToken(eth).find((b) => b.sym === "USDC");
    expect(usdc?.value).toBeCloseTo(24450 + 212.4);
  });
});
