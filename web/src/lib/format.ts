// Number, address and time formatting shared by every screen. Amounts are always rendered in mono
// with tabular numerals (see `.num`), so these helpers only produce strings.

/** Fixed-decimals en-US number: 9994.1 → "9,994.10". */
export function fmt(n: number, digits = 2): string {
  return Number(n || 0).toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

/** Parses a user-typed amount ("10,000.5") into a number; anything unparsable is 0. */
export function parseAmount(v: string): number {
  return parseFloat(String(v || "").replace(/,/g, "")) || 0;
}

/** Keeps only digits, dots and commas while the user types an amount. */
export function cleanAmountInput(v: string): string {
  return v.replace(/[^\d.,]/g, "");
}

/** 0x4c9E2a71…68B3 → "0x4c9E…68B3"; short strings pass through. */
export function shortAddr(a: string): string {
  return a && a.length > 14 ? `${a.slice(0, 6)}…${a.slice(-4)}` : a;
}

/** Duration for countdowns: "21 h 46 m" above an hour, else "4 m 07 s". */
export function duration(ms: number): string {
  const t = Math.max(0, ms);
  const h = Math.floor(t / 36e5);
  const m = Math.floor((t % 36e5) / 6e4);
  const s = Math.floor((t % 6e4) / 1e3);
  return h > 0 ? `${h} h ${String(m).padStart(2, "0")} m` : `${m} m ${String(s).padStart(2, "0")} s`;
}

/** A recipient the UI accepts: a 20-byte hex address or an ENS name (resolved before sending). */
export function isRecipient(a: string): boolean {
  const v = (a || "").trim();
  return /^0x[0-9a-fA-F]{40}$/.test(v) || /^[a-z0-9-]+\.eth$/i.test(v);
}
