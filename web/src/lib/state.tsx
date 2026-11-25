"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { CHAINS, DEMO_ACTIVITY } from "./data/mock";
import type { ActivityItem, ChainKey, LiveChain, PendingRedeem } from "./data/types";

// App-wide UI state: the chain being viewed, Advanced, toasts, the prototype-state overrides, and the
// demo account's balances. Per-form stages (pending, success, error) live in their pages.

export type DemoWallet = "none" | "eoa" | "contract" | "wrong";
export type DemoMint = "normal" | "offpeg" | "paused" | "slippage" | "expired";
export type Destination = "wallet" | "custom";

const H = 36e5;

interface PerChain<T> {
  eth: T;
  uni: T;
}

export interface AppState {
  chainKey: ChainKey;
  chain: LiveChain;
  setChain: (k: ChainKey) => void;
  loading: boolean;
  flashLoading: (ms?: number) => void;
  advanced: boolean;
  toggleAdvanced: () => void;
  toast: string | null;
  showToast: (msg: string) => void;
  // prototype-state overrides (demo dock)
  demoWallet: DemoWallet;
  setDemoWallet: (w: DemoWallet) => void;
  demoMint: DemoMint;
  setDemoMint: (m: DemoMint) => void;
  redeemDelay: boolean;
  setRedeemDelay: (on: boolean) => void;
  usdtRefuses: boolean;
  setUsdtRefuses: (on: boolean) => void;
  // the connected account
  held: number;
  unclaimed: number;
  optedIn: boolean;
  optIn: () => void;
  addHeld: (delta: number) => void;
  addUnclaimed: (delta: number) => void;
  activity: ActivityItem[];
  addActivity: (a: ActivityItem) => void;
  pending: PendingRedeem[];
  setPending: (f: (p: PendingRedeem[]) => PendingRedeem[]) => void;
  // shared form settings
  slippage: string; // "0.1" (%)
  setSlippage: (s: string) => void;
  deadline: string; // minutes
  setDeadline: (s: string) => void;
  dest: Destination;
  setDest: (d: Destination) => void;
  custom: string;
  setCustom: (s: string) => void;
}

const Ctx = createContext<AppState | null>(null);

function perChain<T>(f: (k: "eth" | "uni") => T): PerChain<T> {
  return { eth: f("eth"), uni: f("uni") };
}

export function AppStateProvider({ children }: { children: ReactNode }) {
  const [chainKey, setChainKey] = useState<ChainKey>("eth");
  const [loading, setLoading] = useState(false);
  const [advanced, setAdvanced] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [demoWallet, setDemoWallet] = useState<DemoWallet>("eoa");
  const [demoMint, setDemoMint] = useState<DemoMint>("normal");
  const [redeemDelay, setRedeemDelayRaw] = useState(false);
  const [usdtRefuses, setUsdtRefuses] = useState(false);
  const [held, setHeld] = useState(() => perChain((k) => CHAINS[k].held ?? 0));
  const [unc, setUnc] = useState(() => perChain((k) => CHAINS[k].unc ?? 0));
  const [optedIn, setOptedIn] = useState(false);
  const [activity, setActivity] = useState(() => perChain((k) => DEMO_ACTIVITY[k] ?? []));
  const [pending, setPendingRaw] = useState<PendingRedeem[]>([]);
  const [slippage, setSlippage] = useState("0.1");
  const [deadline, setDeadline] = useState("20");
  const [dest, setDest] = useState<Destination>("wallet");
  const [custom, setCustom] = useState("");
  const toastTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const loadTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  useEffect(() => {
    return () => {
      clearTimeout(toastTimer.current);
      clearTimeout(loadTimer.current);
    };
  }, []);

  const showToast = useCallback((msg: string) => {
    clearTimeout(toastTimer.current);
    setToast(msg);
    toastTimer.current = setTimeout(() => setToast(null), 2400);
  }, []);

  const flashLoading = useCallback((ms = 800) => {
    setLoading(true);
    clearTimeout(loadTimer.current);
    loadTimer.current = setTimeout(() => setLoading(false), ms);
  }, []);

  const setChain = useCallback(
    (k: ChainKey) => {
      if (!CHAINS[k].live) return;
      setChainKey(k);
      flashLoading(800);
      showToast(`Now viewing noUSD on ${CHAINS[k].name}`);
    },
    [flashLoading, showToast],
  );

  const ck = chainKey === "uni" ? "uni" : "eth";

  const value = useMemo<AppState>(
    () => ({
      chainKey,
      chain: CHAINS[chainKey] as LiveChain,
      setChain,
      loading,
      flashLoading,
      advanced,
      toggleAdvanced: () => setAdvanced((a) => !a),
      toast,
      showToast,
      demoWallet,
      setDemoWallet: (w) => {
        setDemoWallet(w);
        if (w === "contract") setOptedIn(false);
      },
      demoMint,
      setDemoMint,
      redeemDelay,
      setRedeemDelay: (on) => {
        setRedeemDelayRaw(on);
        if (on) {
          setPendingRaw((p) =>
            p.length
              ? p
              : [
                  { id: 1, amt: 250, readyAt: Date.now() + 6 * H + 12 * 6e4, to: "0xB729…93B2" },
                  { id: 2, amt: 120, readyAt: Date.now() - 1, to: "0x3E1a…77F0" },
                ],
          );
        }
      },
      usdtRefuses,
      setUsdtRefuses,
      held: held[ck],
      unclaimed: unc[ck],
      optedIn,
      optIn: () => setOptedIn(true),
      addHeld: (d) => setHeld((h) => ({ ...h, [ck]: h[ck] + d })),
      addUnclaimed: (d) => setUnc((u) => ({ ...u, [ck]: Math.max(0, u[ck] + d) })),
      activity: activity[ck],
      addActivity: (a) => setActivity((x) => ({ ...x, [ck]: [a, ...x[ck]] })),
      pending,
      setPending: setPendingRaw,
      slippage,
      setSlippage,
      deadline,
      setDeadline,
      dest,
      setDest,
      custom,
      setCustom,
    }),
    [chainKey, setChain, loading, flashLoading, advanced, toast, showToast, demoWallet, demoMint, redeemDelay, usdtRefuses, held, unc, ck, optedIn, activity, pending, slippage, deadline, dest, custom],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useApp(): AppState {
  const v = useContext(Ctx);
  if (!v) throw new Error("useApp outside AppStateProvider");
  return v;
}

/** A clock that ticks every second, for countdowns and "last sync" times. */
export function useNow(): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const i = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(i);
  }, []);
  return now;
}

/** Time of page load, the anchor for demo countdowns. */
export function useMountedAt(): number {
  const [t0] = useState(() => Date.now());
  return t0;
}
