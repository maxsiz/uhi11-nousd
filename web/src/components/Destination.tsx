"use client";

import { isRecipient, shortAddr } from "@/lib/format";
import { useApp } from "@/lib/state";

/** Where a redeem or claim pays out: my wallet, or any 0x… / ENS address. */
export function useDestination(walletAddress: string) {
  const app = useApp();
  const customOk = isRecipient(app.custom);
  const valid = app.dest === "wallet" || customOk;
  const shortTo = app.dest === "wallet" ? shortAddr(walletAddress) : shortAddr(app.custom.trim());
  const resolvedText =
    app.dest === "wallet"
      ? `${app.advanced ? walletAddress : shortAddr(walletAddress)} · my wallet`
      : app.custom
        ? customOk
          ? app.advanced
            ? app.custom
            : shortAddr(app.custom)
          : "Not a valid address yet"
        : "Enter an address above";
  return { dest: app.dest, valid, customOk, shortTo, resolvedText };
}

export function DestinationPicker({ walletAddress, compact = false }: { walletAddress: string; compact?: boolean }) {
  const app = useApp();
  const d = useDestination(walletAddress);
  const opts: { k: "wallet" | "custom"; label: string; sub: string }[] = [
    { k: "wallet", label: "My wallet", sub: app.advanced ? `${shortAddr(walletAddress)} (connected)` : shortAddr(walletAddress) },
    { k: "custom", label: "Custom address", sub: "any 0x… or ENS" },
  ];
  return (
    <div className="flex flex-col gap-[10px]">
      <div className="grid grid-cols-2 gap-[10px]">
        {opts.map((o) => {
          const on = app.dest === o.k;
          return (
            <button
              key={o.k}
              type="button"
              aria-pressed={on}
              onClick={() => app.setDest(o.k)}
              className={`flex min-h-[44px] min-w-0 flex-col gap-[5px] whitespace-nowrap rounded-[14px] border text-left text-tx ${compact ? "px-[13px] py-[11px]" : "px-[14px] py-[13px]"} ${on ? "border-accent-line bg-accent-soft" : "border-line2 bg-s2"}`}
            >
              <span className="flex items-center gap-2 text-[14px] font-semibold">
                <span
                  className="h-[14px] w-[14px] rounded-full border-2 shadow-[inset_0_0_0_2px_#101319]"
                  style={{ borderColor: on ? "#34E3AC" : "#9AA4B2", background: on ? "#34E3AC" : "transparent" }}
                />
                {o.label}
              </span>
              <span className="num truncate text-[12px] text-tx2">{o.sub}</span>
            </button>
          );
        })}
      </div>
      {app.dest === "custom" && (
        <input
          value={app.custom}
          onChange={(e) => app.setCustom(e.target.value)}
          aria-label="Recipient address"
          placeholder="0x… or name.eth"
          spellCheck={false}
          className={`num rounded-[12px] border bg-s2 px-[14px] py-3 text-[13px] text-tx outline-none ${app.custom && !d.customOk ? "border-warn-line" : "border-line2"}`}
        />
      )}
      <div className={`flex items-center gap-[10px] rounded-[12px] border px-[14px] py-[10px] text-[13px] ${d.valid ? "border-accent-line bg-accent-soft" : "border-line2 bg-s2"}`}>
        <span className="flex-none whitespace-nowrap text-tx2">Funds go to</span>
        <span className={`num min-w-0 break-all ${d.valid ? "text-accent" : "text-tx2"}`}>{d.resolvedText}</span>
      </div>
    </div>
  );
}
