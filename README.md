# noUSD

**A stablecoin that is itself a share of Uniswap v4 stable liquidity.** Deposit any allowed stable, get
noUSD, and the pool fees go to the people holding it. Redeem any time for your slice of every position, in
kind, to any address.

- Live app (demo mode until the contracts are deployed): **https://nousd.envelop.is**
- Demo video: _link added on submission_
- Uniswap Hook Incubator, cohort UHI11

## Why it is a Uniswap v4 project

noUSD does not ship a hook. The exception was cleared with the organisers. Instead it is built on the
three things v4's PoolManager added. The pools it uses stay hookless, so noUSD adds depth to the stable
pools that already exist instead of splitting liquidity into a new hooked pool.

| v4 feature | What noUSD does with it |
|---|---|
| **Flash accounting** | A whole mint is one `unlock`. The deposit is settled straight into the PoolManager, swapped as a delta, added as liquidity, and every delta is closed before `unlock` returns. The user sees two token transfers: the deposit and the change. A redeem is one `unlock` too. |
| **Singleton** | The swap that pairs a deposit and the add can hit **different pools** in the same `unlock`, and no token leaves the PoolManager in between. A redeem removes a share of every position across all pools in one call. |
| **ERC-6909 claims** | Leftovers ("idle") stay inside the PoolManager as the manager's ERC-6909 claims. They pair the next mint without a swap and are paid out on redeem without any extra custody. |

The landing page has an animated walkthrough of both cycles with the manager's deltas step by step.

### One mint, inside `unlock`

1. `sync(token)` → `transferFrom(minter → PoolManager)` → `settle()`. The manager now holds a credit.
2. The pair currency is taken from idle (ERC-6909 claims) first.
3. Only the missing part is swapped, in the best registered pool, never past par ± `depegBps`. A two-pass
   approach handles narrow ranges. The swap exists only as a delta.
4. `modifyLiquidity(+L)` on the protocol's single shared position.
5. Every currency is resolved: change goes to the minter with `take`, the rest becomes idle claims
   (ERC-6909 `mint`/`burn`).
6. The unisafe price guard checks the pegs (Chainlink-referenced spot check), and the pool share cap is
   enforced. If anything fails, the whole `unlock` reverts.

After `unlock` the manager mints noUSD worth the value the deposit **added**. Liquidity is credited
rounded down, minus any holders' idle it consumed.

### One redeem, inside `unlock`

Burn noUSD → remove `num/den` of each position (fees collected on the way stay in the deltas) → add
`num/den` of each idle balance → check `minOut` → `take` every token straight to the chosen recipient. If
a token refuses that recipient (for example a frozen USDT address), v4's `WrappedError` is turned into
`PayoutFailed`, nothing is spent, and the holder picks another address. Redeem and claim can never be
paused.

## What else is in it

- **Fees to holders without staking.** An in-token accumulator moves only on `sync()`, and every transfer
  checkpoints both sides. Holders `claim()` in stables and keep their noUSD. Smart-contract holders are
  opted out until they opt in, so pools and vaults holding noUSD don't silently collect earnings.
- **No operator.** No address can move funds. `sync`, `compound`, `applyRange`, `executeBurns` and
  `burnStray` are permissionless and check their own conditions.
- **Immutable, bounded governance.** No proxies. Every tunable is a registry parameter with a hard cap in
  code. Loosening a rule waits 48 h, tightening applies at once.
- **A modern token.** EIP-2612 permit (including `bytes` signatures), EIP-3009 transfer/receive with
  authorization using USDC-style random nonces (x402-compatible), ERC-7598, ERC-1271, and EIP-7702-aware
  signature checks.

## Where the code is

| Piece | File |
|---|---|
| Unlock entry and callback (mint / payout / compound / applyRange / retire) | [`src/NoUSDPositionManager.sol` → `unlockCallback`](src/NoUSDPositionManager.sol#L386), [`_unlock`](src/NoUSDPositionManager.sol#L744) |
| Mint inside the unlock: settle, pair with idle, two-pass swap, add, refund, checks | [`_mintInUnlock`](src/NoUSDPositionManager.sol#L579) |
| `modifyLiquidity`, delta resolution into ERC-6909 claims and `take`, pro-rata payout | [`src/lib/Settlement.sol`](src/lib/Settlement.sol) (`modify`, `resolve`, `payout`) |
| Swap of the missing part, bounded by the depeg price limit | [`src/lib/SwapStep.sol`](src/lib/SwapStep.sol) |
| Peg check through the deployed unisafe price guard | [`_pegOk`](src/NoUSDPositionManager.sol#L570), [`src/interfaces/IPriceOracle.sol`](src/interfaces/IPriceOracle.sol) |
| Fee accounting (`sync` → accumulator) | [`_sync`](src/NoUSDPositionManager.sol#L444), [`NoUSD.distribute`](src/NoUSD.sol#L295) |
| Token: accumulator, transfers, permit, EIP-3009 | [`src/NoUSD.sol`](src/NoUSD.sol) |
| Parameters, caps and timelock | [`src/NoUSDRegistry.sol`](src/NoUSDRegistry.sol) |
| Pool selection on mint, delayed-burn queue, position math | [`src/lib/PoolSelection.sol`](src/lib/PoolSelection.sol), [`BurnQueue.sol`](src/lib/BurnQueue.sol), [`PositionMath.sol`](src/lib/PositionMath.sol) |
| Web app (Next.js, wagmi) | [`web/`](web/), see [`web/README.md`](web/README.md) |

The specification is the source of truth: [`docs/spec.md`](docs/spec.md). The rationale and decision log
are in [`docs/vision.md`](docs/vision.md).

## Partner integrations

**Uniswap v4** is the only partner integration. noUSD talks to the v4 `PoolManager` directly: `unlock`
and `unlockCallback`, `sync`/`settle`/`take`, `swap`, `modifyLiquidity`, ERC-6909 `mint`/`burn`, and
`StateLibrary`/`TransientStateLibrary` reads. See the table above for where each one is.

No other partner integrations.

## How to verify

```bash
git submodule update --init --recursive
forge fmt --check && forge build --sizes && forge test -vvv
```

- **138 tests**: unit and fuzz tests for the token, registry and manager; signature tests (permit,
  EIP-3009, ERC-1271, EIP-7702); a deployment test; a token invariant suite (balances sum to supply,
  unclaimed covers pending; 64 runs × 64 calls); a solvency check after every manager scenario (the body
  covers liabilities at the credit price); and gas tests.
- **Ethereum mainnet fork tests** (`test/fork/`) run the launch set (USDe/USDC and DAI/USDT, real USDT,
  the deployed unisafe oracle). They need `ENVELOP_MAINNET` (an RPC URL) in `.env` and skip without it.
- **Contract sizes** are under EIP-170: manager 22,430 B, registry 14,859 B, token 9,812 B.
- **Gas** (`forge test --match-path 'test/gas/*' -vv`):

  | Call | Gas |
  |---|---|
  | mint (settle, pair, swap, add, refund, checks) | 597k |
  | redeem across 3 positions | 507k |
  | claim across 3 positions | 484k |
  | sync, 3 positions | 186k |
  | noUSD transfer, no sync since last touch | 41.2k (plain ERC-20: 39.5k) |

- **Web app**: `cd web && npm ci && npm run lint && npm run typecheck && npm run test:run && npm run build`.
  CI runs both the contracts and the web app on every push.

## Deployments

Not deployed yet. The launch configuration for Ethereum (pools, tokens and the oracle address) is in
[`script/config/1.json`](script/config/1.json) and [`docs/spec.md` §12](docs/spec.md). The deploy script
is [`script/Deploy.s.sol`](script/Deploy.s.sol). Until contracts are live, the web app runs in demo mode
with simulated data.

## Credits

All contracts were written for this hackathon, starting 2026-11-22. They build on:
- [Uniswap v4-core](https://github.com/Uniswap/v4-core): `PoolManager` interfaces and libraries
  (`StateLibrary`, `TransientStateLibrary`, `TickMath`, `SqrtPriceMath`, `FullMath`), and `PoolSwapTest`
  in the test fixture;
- [Uniswap v4-periphery](https://github.com/Uniswap/v4-periphery): `LiquidityAmounts`;
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts): `EIP712`, `Nonces`,
  `SafeERC20`, `Ownable2Step`, `ReentrancyGuardTransient`, `SignatureChecker`, error interfaces;
- `IPriceOracle`: the interface of the already deployed unisafe price guard (Envelop), copied so the
  manager can call it. No unisafe code is included.

The web app's RPC proxy policy is adapted from the authors' own unisafe front end (Envelop).
