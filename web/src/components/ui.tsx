import type { ReactNode } from "react";
import type { Sym } from "@/lib/data/types";
import type { Notice } from "@/lib/errors";
import { TOKEN_STYLE } from "@/lib/tokens";

// Primitives of the noUSD visual system. Status is shape + label, never color alone (handoff
// "Status language"): live = filled pulsing circle, attention = diamond, idle/queued = hollow circle,
// refused = ⊗.

/** Live / in range / vouched. */
export function LiveDot() {
  return (
    <span
      aria-hidden="true"
      className="inline-block h-2 w-2 flex-none animate-nu-pulse rounded-full bg-accent shadow-[0_0_7px_#34E3AC]"
    />
  );
}

/** Attention: closed, off par, wrong network, contract wallet. */
export function Diamond() {
  return <span aria-hidden="true" className="inline-block h-2 w-2 flex-none rotate-45 bg-warn" />;
}

/** Idle / no position / queued. */
export function HollowDot({ color = "#9AA4B2", fill = "transparent", size = 8 }: { color?: string; fill?: string; size?: number }) {
  return (
    <span
      aria-hidden="true"
      className="inline-block flex-none rounded-full"
      style={{ width: size, height: size, border: `1.5px solid ${color}`, background: fill }}
    />
  );
}

/** Round token glyph. `overlap` draws the ring used where chips stack. */
export function TokenChip({ sym, size = 22, overlap = false }: { sym: Sym; size?: number; overlap?: boolean }) {
  const t = TOKEN_STYLE[sym];
  return (
    <span
      title={sym}
      className="inline-flex flex-none items-center justify-center rounded-full font-bold"
      style={{
        width: size,
        height: size,
        background: t.bg,
        color: t.fg,
        fontSize: Math.round(size / 2),
        ...(overlap
          ? { border: "2px solid #0D1015", marginRight: -Math.round(size / 3) }
          : { boxShadow: "0 0 0 1px rgba(255,255,255,.12)" }),
      }}
    >
      {t.glyph}
    </span>
  );
}

export function PairChips({ pair, size = 22 }: { pair: readonly Sym[]; size?: number }) {
  return (
    <span className="flex">
      {pair.map((s) => (
        <TokenChip key={s} sym={s} size={size} overlap />
      ))}
    </span>
  );
}

/** The noUSD glyph used in the redeem amount box. */
export function NoUSDChip() {
  return (
    <span className="inline-flex h-6 w-6 items-center justify-center rounded-full border-[1.5px] border-accent bg-bg font-display text-[10px] font-bold text-accent">
      no
    </span>
  );
}

export function Skeleton({ className = "" }: { className?: string }) {
  return <span aria-hidden="true" className={`block rounded-[6px] bg-s3 ${className}`} />;
}

/** The mark: unisafe's concentric rings split into arcs — the basket of positions. */
export function Mark({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 28 28" fill="none" aria-hidden="true">
      <circle cx="14" cy="14" r="12" stroke="#34E3AC" strokeWidth="2" strokeDasharray="14.6 4.25" strokeLinecap="round" transform="rotate(-78 14 14)" />
      <circle cx="14" cy="14" r="7.5" stroke="#34E3AC" strokeOpacity=".55" strokeWidth="2" strokeDasharray="11.9 3.8" strokeLinecap="round" transform="rotate(30 14 14)" />
      <circle cx="14" cy="14" r="2.4" fill="#34E3AC" />
    </svg>
  );
}

/** Wordmark option A (default): "no" in tx, "USD" in accent. Option B swaps the colors. */
export function Wordmark({ size = 20, variant = "A" }: { size?: number; variant?: "A" | "B" }) {
  return (
    <span className="font-display font-bold tracking-[-.02em]" style={{ fontSize: size }}>
      <span className={variant === "A" ? "text-tx" : "text-accent"}>no</span>
      <span className={variant === "A" ? "text-accent" : "text-tx"}>USD</span>
    </span>
  );
}

export function WarnIcon({ color = "#FFC76B", size = 18 }: { color?: string; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="mt-px flex-none" aria-hidden="true">
      <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
      <path d="M12 9v4" />
      <path d="M12 17h.01" />
    </svg>
  );
}

export function CheckBadge() {
  return (
    <span className="flex h-[52px] w-[52px] items-center justify-center rounded-full border border-accent-line bg-accent-soft">
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#34E3AC" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M20 6 9 17l-5-5" />
      </svg>
    </span>
  );
}

export function Chevron({ color = "#9AA4B2", size = 14 }: { color?: string; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" aria-hidden="true">
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

/** Inline notice for blocked or failed actions: warn (state) or danger (refusal / failure). */
export function NoticeCard({ notice, children }: { notice: Notice; children?: ReactNode }) {
  const danger = notice.tone === "danger";
  return (
    <div
      role={danger ? "alert" : "status"}
      className={`flex gap-3 rounded-[14px] border px-[14px] py-[13px] ${danger ? "border-danger-line bg-danger-soft" : "border-warn-line bg-warn-soft"}`}
    >
      <WarnIcon color={danger ? "#FF7A7A" : "#FFC76B"} />
      <div className="flex flex-col gap-1">
        <span className={`text-[13.5px] font-bold ${danger ? "text-danger" : "text-warn"}`}>{notice.title}</span>
        <span className="text-[13px] leading-normal text-tx2">{notice.body}</span>
        {children}
      </div>
    </div>
  );
}

/** Full-width action button; disabled renders the s3/tx2 state from the handoff. */
export function Cta({ label, onClick, disabled }: { label: string; onClick: () => void; disabled?: boolean }) {
  return (
    <button type="button" onClick={onClick} disabled={disabled} className="btn-primary w-full p-[14px] text-[15px]">
      {label}
    </button>
  );
}

/** A small stat tile (label + mono value), used in hero panels. */
export function StatTile({ label, value, color, dot }: { label: string; value: string; color?: string; dot?: ReactNode }) {
  return (
    <div className="flex flex-col gap-[6px] rounded-[14px] border border-line bg-white/[.025] px-[14px] py-[13px]">
      <span className="label">{label}</span>
      <span className="num flex items-center gap-[7px] text-[15px]" style={{ color }}>
        {dot}
        {value}
      </span>
    </div>
  );
}
