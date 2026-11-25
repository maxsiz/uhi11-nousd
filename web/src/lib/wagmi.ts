import { createConfig, http } from "wagmi";
import { injected, mock } from "wagmi/connectors";
import { arbitrum, base, mainnet, unichain } from "viem/chains";
import { DEMO_ACCOUNT } from "./data/mock";

/**
 * Demo mode renders the design's data and simulates transactions. It is on until the contracts are
 * deployed and their addresses wired; set NEXT_PUBLIC_DEMO=0 to run against a real wallet.
 */
export const IS_DEMO = process.env.NEXT_PUBLIC_DEMO !== "0";

// Demo: wagmi's mock connector signs in as the design's account (same pattern as stablelp-ui's visual
// harness); it never signs anything. Real mode: injected wallets only, like unisafe v1.
const connectors = IS_DEMO
  ? [mock({ accounts: [DEMO_ACCOUNT], features: { defaultConnected: true, reconnect: true } })]
  : [injected()];

export const wagmiConfig = createConfig({
  chains: [mainnet, unichain, arbitrum, base],
  connectors,
  // Same-origin proxy (src/app/api/rpc): provider keys stay on the server, never in the bundle.
  transports: {
    [mainnet.id]: http(`/api/rpc/${mainnet.id}`),
    [unichain.id]: http(`/api/rpc/${unichain.id}`),
    [arbitrum.id]: http(`/api/rpc/${arbitrum.id}`),
    [base.id]: http(`/api/rpc/${base.id}`),
  },
  ssr: true,
  // Collapse cross-hook reads into one Multicall3 call (stablelp-ui: avoids RPC 429s).
  batch: { multicall: { batchSize: 4_096, wait: 24 } },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
