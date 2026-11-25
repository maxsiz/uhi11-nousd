import type { Sym } from "./data/types";

// Fallback token glyphs (handoff "Token chips"). Real logos replace these in production.
export const TOKEN_STYLE: Record<Sym, { bg: string; fg: string; glyph: string }> = {
  USDC: { bg: "#2775CA", fg: "#fff", glyph: "$" },
  USDT: { bg: "#26A17B", fg: "#fff", glyph: "₮" },
  DAI: { bg: "#F5AC37", fg: "#2A1C00", glyph: "◈" },
  USDe: { bg: "#111111", fg: "#fff", glyph: "e" },
  USDS: { bg: "#F4B731", fg: "#2A1C00", glyph: "S" },
  RLUSD: { bg: "#0B1F3A", fg: "#fff", glyph: "R" },
};

/** Tokens whose contract supports EIP-2612 permit: approve and mint in one signature. */
export const PERMIT: Partial<Record<Sym, boolean>> = { USDC: true, DAI: true, USDe: true, USDT: false };
