# CLAUDE.md — uhi11-nousd

noUSD: an ERC-20 stablecoin backed by one shared pool of stable/stable liquidity, held by `NoUSDPositionManager`, on hookless
Uniswap v4 pools. Hackathon project UHI11, personal GitHub remote `maxsiz/uhi11-nousd` (use `gh`,
not `glab`). Lives in the `ev2` workspace next to the unisafe repos but does not depend on their code.

## Read first

- `docs/spec.md` — **the source of truth for the contracts.** Implement exactly this; if something in it
  is wrong or impossible, write down why and ask the owner before deviating.
- `docs/vision.md` — rationale and decision log. Do not reopen decided items without a new fact.
- `docs/nousd-model.ru.html` — the same with diagrams (Russian).

## Hard rules

- Contracts are **immutable** (no proxies). Every tunable is a registry parameter with a hard cap in code.
- Nobody can move funds: maintenance calls are permissionless and condition-checked. No operator role.
- Burn and claim can never be paused or blocked (burn may only be delayed within its cap).
- The only external contract dependency is the deployed unisafe price guard, through
  `IPriceOracle` (copied interface from `uniswap-smart-wallet/src/interfaces/IPriceOracle.sol`). Do not
  add `uniswap-smart-wallet` as a submodule.
- Check contract size (`forge build --sizes`, EIP-170) before and after each change.
- No infrastructure details (hosts, keys, servers) in this public repo.

## Commands (once the Foundry project exists)

```bash
git submodule update --init --recursive
forge fmt --check && forge build --sizes && forge test -vvv
```

Fork tests are env-gated (`ETH_RPC`, `ARB_RPC`, `BASE_RPC`, `UNICHAIN_RPC`) and skip without RPC.
