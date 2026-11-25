"use client";

import { useAccount, useBytecode, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { DEMO_ACCOUNT } from "./data/mock";
import { useApp } from "./state";
import { IS_DEMO } from "./wagmi";

export type WalletKind = "none" | "eoa" | "contract" | "wrong";

export interface Wallet {
  kind: WalletKind;
  connected: boolean;
  address: string;
  connect: () => void;
  disconnect: () => void;
  switchToViewed: () => void;
}

/** An EIP-7702 delegated EOA carries a 23-byte designator 0xef0100…; it still earns like a wallet. */
function isRealContract(code: string | undefined): boolean {
  if (!code || code === "0x") return false;
  return !(code.length === 2 + 46 && code.toLowerCase().startsWith("0xef0100"));
}

/**
 * The connected account as the UI sees it: disconnected, a wallet, a contract (does not earn until it
 * opts in) or on another chain than the noUSD being viewed. In demo mode the kind comes from the
 * prototype-states dock instead of the wallet.
 */
export function useWallet(): Wallet {
  const app = useApp();
  const account = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const code = useBytecode({ address: account.address, query: { enabled: !IS_DEMO && !!account.address } });

  if (IS_DEMO) {
    const kind = app.demoWallet;
    return {
      kind,
      connected: kind !== "none",
      address: DEMO_ACCOUNT,
      connect: () => {
        app.setDemoWallet("eoa");
        app.showToast("Wallet connected");
      },
      disconnect: () => {
        app.setDemoWallet("none");
        app.showToast("Disconnected");
      },
      switchToViewed: () => {
        app.setDemoWallet("eoa");
        app.showToast(`Wallet switched to ${app.chain.name}`);
      },
    };
  }

  let kind: WalletKind = "none";
  if (account.isConnected) {
    if (account.chainId !== app.chain.chainId) kind = "wrong";
    else kind = isRealContract(code.data) ? "contract" : "eoa";
  }
  return {
    kind,
    connected: account.isConnected,
    address: account.address ?? "",
    connect: () => connectors[0] && connect({ connector: connectors[0] }),
    disconnect: () => disconnect(),
    switchToViewed: () => switchChain({ chainId: app.chain.chainId as 1 }),
  };
}
