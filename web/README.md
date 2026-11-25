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

Not wired yet: ENS resolution for custom recipients (any `*.eth` is accepted as typed).

## RPC

wagmi talks to the same-origin proxy `/api/rpc/<chainId>` (`src/app/api/rpc`). The proxy reads the
upstream URL from a server-only variable (`MAINNET_RPC_URL`, `UNICHAIN_RPC_URL`, `ARBITRUM_RPC_URL`,
`BASE_RPC_URL`, each with an optional `<VAR>_FALLBACK` used on 429), refuses broadcasting and debug
methods, caps body and batch size and rate-limits per client (`src/lib/server/rpc.ts`).

## Production

`.github/workflows/deploy-prod.yml` builds a standalone bundle on push to `main` (paths `web/**`) and
ships it over SSH. Host details live only in the `production` environment's secrets; RPC URLs live only
on the host.
