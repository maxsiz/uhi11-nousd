import type { Sym } from "./data/types";
import { fmt } from "./format";

// Contract errors as people read them (handoff "Error mapping"). Raw revert strings never reach the UI.

export interface Notice {
  title: string;
  body: string;
  tone: "warn" | "danger";
}

export type MintNoticeKey = "closed" | "paused" | "offpeg" | "cap" | "slippage" | "expired";

export function mintNotice(
  key: MintNoticeKey,
  ctx: { token: Sym; chain: string; deadlineMin: string; mintableLeft: number },
): Notice {
  switch (key) {
    case "closed": // OracleNoOpinion
      return {
        tone: "warn",
        title: `Minting with ${ctx.token} is closed on ${ctx.chain}`,
        body: `The price guard has no fresh price for ${ctx.token} here, so it can't vouch for a fair mint. Redeem and claim work.`,
      };
    case "paused": // MintPaused
      return {
        tone: "warn",
        title: "Minting is paused by governance",
        body: "Redeem and claim can never be paused — they work as usual.",
      };
    case "offpeg": // PegCheckFailed
      return {
        tone: "warn",
        title: `${ctx.token} is 0.6 % off par; minting with it is paused until it returns`,
        body: "Other stables can still mint. Redeem and claim are unaffected.",
      };
    case "cap": // SupplyCapExceeded
      return {
        tone: "warn",
        title: "This mint would pass the supply cap",
        body: `Up to ${fmt(ctx.mintableLeft)} noUSD can be minted on ${ctx.chain} right now. Lower the amount.`,
      };
    case "slippage": // Slippage
      return {
        tone: "danger",
        title: "Price moved; you would get less than your minimum.",
        body: "Nothing was spent. Try again, or allow more slippage in settings.",
      };
    case "expired": // Expired
      return {
        tone: "danger",
        title: "Took too long; try again.",
        body: `The transaction passed its ${ctx.deadlineMin}-minute deadline. Nothing was spent.`,
      };
  }
}
