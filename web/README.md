# noUSD web app

Next.js front end for noUSD, built from the Claude Design handoff (landing, Portfolio, Mint, Redeem,
Earnings, Reserves, Governance; desktop and 390 px phone).

```bash
nvm use            # Node 24
npm ci
npm run dev        # http://localhost:3000
npm run lint && npm run typecheck && npm run test:run && npm run build
```

## Demo mode

The contracts are not deployed yet, so the app runs in demo mode by default
(`NEXT_PUBLIC_DEMO` unset or anything but `0`):

- the wallet is wagmi's `mock` connector with a fixed demo address;
- every number comes from `src/lib/data/mock.ts` (the design's own data), previews from `src/lib/preview.ts`;
- transactions are simulated (`src/lib/tx.ts`), and the **Prototype states** dock switches wallet kind,
  mint outcome, redeem delay and a frozen-USDT recipient.

With `NEXT_PUBLIC_DEMO=0` the app uses the injected wallet; sending refuses with
"not deployed" until addresses are wired.

## Moving to on-chain data

| Screen data | Source once deployed |
|---|---|
| balance, unclaimed, opted-in | `NoUSD.balanceOf`, `NoUSDPositionManager` account view |
| supply, cap, backing, pools, idle | `NoUSD.totalSupply`, `Registry` params, manager book + `StateView` |
| mint / redeem preview | `eth_call` simulation of `mint` / `redeem` with `minOut` |
| price guard | deployed unisafe `IPriceOracle.check` |
| governance queue | `Registry` timelock events |

Not wired yet: ENS resolution for custom recipients (any `*.eth` is accepted as typed) and a same-origin
RPC proxy (public transports are used).
