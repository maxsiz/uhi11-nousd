# noUSD — current vision (model v3)

> Status: **working notes, not a spec.** The contracts are specified in [`spec.md`](spec.md)
> (v1.1, 2026-11-25); where this file and the spec differ, the spec wins. This file keeps the
> rationale and the decision log. Decisions carry the date they were taken. The visual version
> (Russian, with diagrams) is [`nousd-model.ru.html`](nousd-model.ru.html).

## One paragraph

noUSD is an ERC-20 backed by a shared pool of stablecoin liquidity on Uniswap v4, held by one
contract, `NoUSDPositionManager`. Anyone deposits an allowed stablecoin; **in the same transaction**
the manager pairs it with its idle balance of the other stable and/or swaps part of it, adds
liquidity to one of its stable/stable positions, then mints noUSD for the value the minter
contributed. Burning noUSD returns the holder's pro-rata share of **every** position, in every token,
to any recipient they choose — no oracle, no swap, no permission. Who owns the trading fees is
tracked by a per-token fee accumulator, the same idea as `feeGrowth` in v4 itself, so each holder
earns only from the moment they entered; holders take them with `claim()` in stables.

## Architecture

```
               allowed stables, pool whitelist,
   multisig ─► limits, depeg thresholds (Registry)
                          │ read on every mint
                          ▼
   user ──mint──► NoUSDPositionManager  (owner of all positions, idle, burn queue)
   user ◄─burn──      │  mints / burns / distributes
                      ├──► NoUSD (ERC-20, fee accumulator "fees per 1 noUSD", accrued)
                      ▼
          Uniswap v4 PoolManager (one unlock per mint / burn)
            ├─ USDe/USDC   position
            ├─ DAI/USDT    position
            └─ USDS/RLUSD  position (WithdrawOnly at launch)
   Stage 2 (maybe never): PSM hook 1:1
```

* **Manager + token.** The manager owns all positions; noUSD is a separate ERC-20 that only the
  manager can mint, burn and move the counter of (decided 2026-11-23). No rebase.
* **Registry.** Which stables are allowed, which pools are admissible, limits, depeg thresholds.
  Governed by a 2-of-3 multisig: tightening is immediate, loosening goes through a 48 h timelock.
  Neither the registry nor any pause can stop `burn`.
* **Positions.** Existing hookless v4 stable pools, fixed preset ranges around par (±1–2 %), at most 8
  positions to bound gas. No operator, no automatic recenter.

## Mint — one transaction, one `unlock` (decided 2026-11-21)

1. **Checks:** stable is allowed, oracle price above its depeg threshold, caps not exceeded,
   spot within θ of the oracle in every pool touched, `deadline`.
2. **Pick the position** (hybrid selection, below).
3. **Settle fees before entry:** `sync()` — read fee growth of every position and move the
   accumulator, so fees earned so far go to existing holders and the new minter gets none of them.
4. **Pair with idle** (decided 2026-11-25): if the manager holds idle tokens of the other currency
   (left from a retired pool or from `compound()`), they go into the add as the counterpart of the
   deposit; the minter is credited only for their own tokens.
5. **Swap** the rest of the needed part in pool **A** — whichever is cheapest for the minter.
6. **Add liquidity** in pool **B** — whichever is best for holders. Flash accounting nets A and B.
7. **Mint noUSD for the value the minter added**, to `to`, subject to `minOut` and `deadline`. The
   minter pays the swap: 10 USDC → ≈ 9.9993 noUSD at a 0.01 % pool (less with idle pairing).

If the swap or the add is impossible → **revert**. A deposit never waits in idle for deployment, so
every noUSD minted is working capital from its first block. This is what makes a plain
balance-weighted accumulator exact (see the simulation). Idle that the manager itself creates
(retire, compound leftovers) belongs to all holders pro-rata and is redeployed by mints.

## Burn

* `sync()` first. `D = supply + unclaimed + treasury accrual + carry`, computed before burning.
* The burner's accrued `a` is paid in the same call: fraction `f = (x + a) / D` of liquidity of every
  position and of idle (removing liquidity collects all the position's fees into idle; what is not the
  burner's stays and is re-added later by `compound()`); all tokens go to `to`.
* `minOut` (value at par) and `deadline` protect against sandwiching (decided 2026-11-25).
* No swap, no token choice, no oracle, cannot be paused. A token refusing to pay `to` reverts with
  `PayoutFailed(token, to)` — pick another recipient.

## Fees (accounting decided 2026-11-23)

noUSD is a **separate ERC-20 contract**; the manager is its only minter/burner and the only caller of
`distribute()`.

**State in the token**

| Where | Field | Written by |
|---|---|---|
| global | `accPerShare` — fees in noUSD earned by 1 noUSD since launch (only grows) | `sync()` via `distribute(F)` |
| global | `totalUnclaimed` — credited to holders, not yet paid out | `distribute` (+), `claim` / `burn` (−) |
| global | `excludedSupply` — balance of excluded addresses (DEX pools, bridges) | transfers touching them |
| per address, slot 1 | `balance (uint128) \| checkpoint (uint120) \| excluded flag` | every transfer, like any ERC-20 balance |
| per address, slot 2 | `accrued` — earned, not claimed | only when `accPerShare` moved since the last touch |

**`transfer(from, to, x)`**: read `accPerShare`; for `from` and `to`:
`accrued += balance × (accPerShare − checkpoint)`, `checkpoint = accPerShare`; then move `x`.
No external calls — a plain ERC-20 from the outside.

**Variant L (chosen):** the counter moves only on `sync()`, never on transfer. Variant E (every
transfer reads fee growth from PoolManager, ~23k gas per position, ~235k per transfer with 8
positions) is exact but rejected: 3–7× transfer gas, dependency on PoolManager, breaks integrations
with a fixed gas stipend.

**Walk-through** ($100/day of fees, supply 1M, Alice 600k, Bob 400k; counter in $ per 1M noUSD):

| Time | Event | Math | State after |
|---|---|---|---|
| 00:00 | sync | — | counter 0, unclaimed 0 |
| 12:00 | Alice → Carol 200k ($50 already in pools, counter doesn't see it) | Alice: `600k × (0−0) = 0`, cp 0; Carol: `0`, cp 0 | Alice 400k, Bob 400k, Carol 200k |
| 24:00 | keeper `sync()` | `F = 60 USDC + 40 USDT = $100` at par; `Δcounter = F / (supply − excluded) = 100/1M` | counter 100, unclaimed $100, no tokens moved |
| 24:05 | Carol burns 100k | Carol accrued `a = 200k × 100/1M = $20`; `f = (100k + 20) / (1M + 100)`; body $1 000 100 → Carol takes `f × 1 000 100 = $100 020` in kind (her $20 included) | supply 900 000, unclaimed 80; `900 000 + 80 = 900 080` = body ✓ |
| 24:10 | Bob `claim()` | `400k × 100/1M = $40`, paid in stables: `40 / 900 080` of every position | supply 900 000, unclaimed 40 (Alice's); `900 000 + 40 = 900 040` = body ✓ |

Result: Alice $40, Bob $40, Carol $20 = $100 earned. The exact split by capital × time is
50/40/10: L misallocates only between the two sides of a transfer, at most
`amount × unsynced yield per noUSD` (here $10).
Invariant at every step: `supply + totalUnclaimed (+ treasury accrual + carry) = value of the body` at par.

**`sync()` vs `compound()`** — two different operations:

| | `sync()` — accounting | `compound()` — reinvest |
|---|---|---|
| does | reads `feeGrowthInside` vs the manager's own `fgAccounted` per position, values at par, moves the counter; no tokens move | `modifyLiquidity` on the position: v4 pays out all its fees (`callerDelta = principal + feesAccrued`), the manager adds them back as liquidity (spot must be at par) |
| matters for | fairness (the buy-before-sync attack targets the counter) | yield only |
| mint | mandatory before entry, all positions | position B only (the add collects its fees) |
| burn | mandatory before computing the share | all positions (burn touches each) |
| quiet day | keeper hourly on L2 (~$0.015/call), daily on Ethereum; anyone may call | when uncollected fees exceed a threshold |
| gas, 8 positions (rough) | ~200–250k | ~0.7–1M |

**Chains** (final 2026-11-25). Ethereum is the initial deployment; each L2 gets its own deployment
with its own pair set from existing hookless pools. One codebase, per-chain parameters: keeper
interval (1 h on L2, 24 h on Ethereum), `compound()` threshold; the sequencer-uptime check lives in the
unisafe oracle.

Why daily is enough: buying noUSD on a DEX, calling `sync()` and selling pays only when the
unsynced yield per noUSD exceeds the round-trip cost — ~1.75 days without sync in a 0.01 % pool,
~9 days in a 0.05 % pool (at 5 % APR). With hourly sync on L2 the attack needs ~40× more unsynced
yield than can accumulate between calls.

**Transfer gas (L, estimates from opcode prices, to be replaced by `forge snapshot`):** ~37k vs ~34.5k
for a plain ERC-20 when no sync happened since the last touch; ~47k on the first transfer after a
sync (both `accrued` slots written); +5k when an excluded address is involved. `claim()` leaves
1 wei in `accrued` so the slot never goes back to zero (avoids the 22k fresh write).

* v4 facts this relies on: `Position.State = {liquidity, feeGrowthInside0/1LastX128}`;
  `modifyLiquidity` returns `callerDelta = principal + feesAccrued`.

## Comparison with Uniswap v2 LP tokens

A v2 LP token is also an ERC-20, yet needs no accumulator: it is a **share of reserves**, not a dollar
claim (`UniswapV2Pair.sol`). Swap fees stay in the reserves (line 180), so every share appreciates in
the same block; mint is at the current share price (line 123,
`min(amount0 × supply / reserve0, amount1 × supply / reserve1)`); burn returns `liquidity × balance / supply`
(line 144); transfer is a plain ERC-20. Fairness comes from the price, not from bookkeeping.

Same example in v2 terms: share price 1.00000 → 1.00005 at 12:00 → 1.00010 at 24:00. Alice's 200k
shares sent at 12:00 are worth $200 010 — her morning $10 travel inside the tokens (and are paid for
if Carol bought them). Result: Alice $50, Bob $40, Carol $10 — exact.

| | Share, v2-style (price grows) | noUSD, L (≈ $1) |
|---|---|---|
| token price | grows: 1.0001 after a day, ~1.05 after a year at 5 % | ≈ $1 |
| where fees sit | v2: in reserves at once. On v4: next to the position, must be included in the share price at mint/burn | next to the position, accounted on `sync()` |
| mint | at share price | at deposited value, `sync()` first |
| burn | `x / supply` of value | `(x + accrued) / (supply + unclaimed)`, accrued paid in the same call |
| transfer | plain ERC-20, ~34.5k | +2.4–12.4k |
| per-address state | balance | balance, checkpoint, accrued |
| paying out yield | not needed — it is in the price | `claim()` pays accrued in stables, pro-rata from all positions (decided 2026-11-24) |
| compounding | automatic | only via `claim` |
| fairness | exact, through price | error between the two sides of a transfer |
| buy-before-sync attack | none if mint/burn price includes uncollected fees | exists, unprofitable with daily `sync()` |
| keeper | not needed | daily `sync()` |
| contract holders (DEX, bridges) | yield grows in price, nothing lost | unclaimable accruals → exclusion list |
| integrations | needs a share-price oracle (like wstETH, sDAI) | stable ≈ $1 |
| product | yield-bearing share, not a stable | stable + yield |

Why we differ: (1) the requirement "noUSD ≈ $1" — the v2 way is exactly the "mint at P = NAV/supply"
option rejected on 2026-11-20; (2) since v3, fees live next to concentrated positions until collected,
and Uniswap itself tracks them with the same pattern we use: `feeGrowthInside` is the global counter,
`feeGrowthInsideLast` the checkpoint, `tokensOwed` the accrued slot. Variant L moves v3/v4 fee
accounting from positions to token holders.

Taken from v2: `_mintFee` (lines 89–107) as the protocol-share pattern — the treasury share is
taken lazily, here on `sync()`; burn by actual balances, not cached reserves. **Not** taken:
`MINIMUM_LIQUIDITY` (lines 120–121) — noUSD is minted at par, not at a share price, so the
inflation attack it defends against does not apply (decided 2026-11-24).

**Resolved 2026-11-24:** 1 noUSD = 1 stable of the basket (not 1 USD), so L stays. Before that: if "≈ $1" is mandatory, L stays. If an appreciating noUSD is acceptable, the v2 model
removes accrued slots, `claim`, the keeper and the transfer error — but it is then a yield share like
sDAI, and a stable on top of it would be a second token.

## Pool selection — hybrid (decided 2026-11-21)

v4 has several pools with the same pair and different fee tiers and depth. On-chain we choose like this:

| Layer | Who | What |
|---|---|---|
| Admission | Registry | hookless pools, allowed stables and fee tiers, price inside the preset range |
| Limits | Registry | our share ≤ 30 % of pool liquidity, max weight in the basket, minimum pool liquidity |
| Signal | Contract | inside the limits: yield per unit of liquidity from `feeGrowthGlobal` over the selection window (7 days) × `L/(L+x)` (dilution by our own deposit) |

The manager keeps two `feeGrowthGlobal` points per pool and rotates them on `sync()` once per
window, so the measured window is 7–14 days (decided 2026-11-25). The signal can be pumped with
`donate()` or wash swaps (`Pool.sol` adds donations to `feeGrowthGlobal`); that costs the attacker
real money, and the share limit plus the 7-day window cap how much of our capital they can steer.
Limit values are a starting proposal, to be fitted on real pool data.

## How the price holds

* **Ceiling:** above $1, anyone deposits a stable and sells noUSD. Supply grows.
* **Floor:** below the basket share, anyone buys noUSD, burns it and takes the basket. Supply shrinks.
  The floor is the basket, not $1: if one collateral stable depegs, noUSD honestly loses that much;
  minting with the bad stable stops, burning keeps working.
* So a PSM hook with a hard $1 floor is moved to stage 2 and is probably unnecessary.

## Decision log

| Date | Decision |
|---|---|
| 2026-11-18 | Model A (a manager per owner + PSM hook) archived: the holder had no access to collateral, so the floor depended on minters wanting to leave. |
| 2026-11-20 | Model v3: one shared vault, burn = share of all positions, anyone can mint. Recorded the contradiction "strict 1:1 mint vs. share of a fee-growing pot". |
| 2026-11-21 | Contradiction resolved: mint for value actually deposited (not strictly 1:1), fee accumulator + `claim()`, burn by `x / (supply + unclaimed)`. |
| 2026-11-21 | Mint in one transaction: swap in pool A, add in pool B, revert if impossible. No idle balance. |
| 2026-11-21 | Pool selection: hybrid (registry admission + limits, on-chain yield signal). |
| 2026-11-23 | noUSD is a separate ERC-20. Fee accounting variant L: transfers checkpoint both sides, only `sync()` moves the counter (on mint, burn, and a keeper at least daily). `compound()` is a separate, threshold-driven operation. Variant E (exact, transfer reads the pools) rejected on gas. |
| 2026-11-23 | Main chain is an L2; Ethereum mainnet is secondary. Keeper `sync()` hourly on L2, daily on Ethereum; per-chain `compound()` threshold; sequencer-uptime check on L2. *(Chains superseded 2026-11-25.)* |
| 2026-11-23 | Compared with Uniswap v2 LP tokens (share of reserves, price grows, no accounting needed). Open: is "noUSD ≈ $1" mandatory, or is a v2-style appreciating share acceptable? |
| 2026-11-24 | 1 noUSD = 1 stable at par, not 1 USD; oracle only as a depeg breaker. `claim()` pays in stables. Protocol fee parameter up to 10 %, 0 at launch. Recenter path required (design open). |
| 2026-11-24 | Not upgradeable, all parameters capped in code. Burn delay parameter (0 at launch). Blast-style accrual (contracts opt in, 7702 EOAs accrue). Recenter accepted *(removed 2026-11-25)*. No first-deposit protection (attack does not apply). Chains: Unichain, Arbitrum *(superseded 2026-11-25)*. |
| 2026-11-24 | Governance confirmed (2-of-3 multisig, 48 h timelock for loosening). Proposed numbers, launch set (Arbitrum main, Unichain demo until a USDT0 oracle) and keeper calls. |
| 2026-11-25 | Chains: Ethereum + L2s, each with its own pair set from existing hookless v4 pools only (no pool creation); registry marks pools Active / WithdrawOnly. Ethereum launch set: USDe/USDC, DAI/USDT active, USDS/RLUSD registered but inactive (0.17 % APR). Oracle: reuse the deployed unisafe `ChainlinkPriceOracle` as a spot-manipulation guard (no per-token adapters); depeg = Uniswap spot vs par. Positions ≤ number of stables. Spec v1 written: `docs/spec.md`. |
| 2026-11-25 | Spec review → v1.1. `NoUSDVault` renamed `NoUSDPositionManager`. **Recenter removed**: for stable pools "out of range" already means spot is further from par than `depegBps`, so its condition could never hold; positions stay at the registry preset, a new preset (timelock) is applied by permissionless `applyRange`. Mint pairs the deposit with idle of the other currency before swapping (idle from retire/compound is redeployed). `minOut` + `deadline` on burn/claim, `deadline` on mint. A token refusing a payout reverts with `PayoutFailed(token, to)` — retry with another recipient. Pool-selection window rotates per `selectionWindow`. `supplyCap` for a guarded launch. |

## Why the accumulator — simulation

[`simulation/sim2.py`](simulation/sim2.py) (Monte-Carlo, 2000 runs per scenario, seed 20261120):
10 users, $100k cap, 30 days, a pool earning $500/day with $2M of other in-range liquidity.
Share of fees going to the wrong party:

| Scenario | A: fees in body, burn `x/supply` | B: daily snapshot | C: accumulator by balance | C2: accumulator on deployed only |
|---|---|---|---|---|
| no attacker, deploy daily | 22 % | 1.1 % | 1.6 % | 0 |
| flash mint+burn | **86 %** to attacker | 0 | 0 | 0 |
| enter before snapshot | **84 %** | **51 %** | 0 | 0 |
| sit in idle between deploys | **94–99 %** | 0 | **58 %** | 0 |

C2 is the reference. Minting in one transaction removes the idle state, which makes C equal to C2 —
that is why it was chosen. Full results: [`simulation/sim2.json`](simulation/sim2.json).

## Open questions

Decided 2026-11-24:
- 1 noUSD = 1 stable at par (oracle is only a depeg breaker); `claim()` pays in stables pro-rata.
- Protocol fee: `protocolFeeBps`, capped at 10 % in code, 0 at launch, taken on `sync()` into a
  treasury accrual.
- **Contracts are not upgradeable.** Every parameter is provisioned now with a hard cap in code
  (`protocolFeeBps`, `mintFeeBps`, burn delay, `supplyCap`); a bug fix is a new deployment and
  holders migrate via burn → mint. Burn can never be blocked, only delayed within its cap.
- **Burn delay** is a parameter, 0 at launch. With T > 0: `requestBurn(x)` escrows noUSD (it stops
  accruing), anyone executes after T, and the share is computed at execution — otherwise a request
  is a free option against a depeg. `claim()` is never delayed.
- **Accrual, Blast-style:** EOAs accrue by default, contracts are excluded unless they opt in
  themselves; no governed list. An EIP-7702-delegated EOA (code `0xef0100…`) counts as an EOA.
  A public `reclassify(addr)` excludes an address that later got real code; what it already
  accrued stays claimable.
- **Recenter** *(removed 2026-11-25)*: was a permissionless `recenter(pos)` — out of range for N hours,
  both stables at peg, new range around the current price. Its two conditions contradict each other
  for stable pools; replaced by governance presets + `applyRange` (see the decision log).
- **No first-deposit protection:** the inflation attack does not apply — noUSD is minted for value
  added, not at a share price, and nobody can donate into the manager's positions (a pool `donate`
  arrives through `sync()` as fees). Rounding against the user stays a code rule.
- **Chains** *(superseded 2026-11-25)*: Ethereum first, then L2s with their own pair sets.

Governance (confirmed 2026-11-24): 2-of-3 multisig sets parameters within the code caps;
tightening is immediate, loosening goes through a 48 h timelock.

## Proposal 2026-11-24: numbers, launch set, keeper (historical)

Approved numbers and the final launch set are in [`spec.md`](spec.md) §4.3 and §12. Recenter rows
and per-token oracle adapters below were dropped on 2026-11-25.

| Parameter | Cap in code | Launch | Why |
|---|---|---|---|
| burn delay | 7 days | 0 | Ethena cooldown / Lido worst case; longer = DEX discount |
| `mintFeeBps` | 50 bps | 0 | equals the depeg threshold, so it can absorb par arbitrage inside it |
| `protocolFeeBps` | 10 % | 0 | decided |
| depeg breaker (stop mint with that stable) | 1–200 bps | 50 bps | stable feeds step 0.1–0.3 % |
| oracle max age | per feed | heartbeat + 20 % | Arbitrum USDC/USDT feeds: 255 s heartbeat; SVR and Unichain: 24 h |
| sequencer grace | ≤ 24 h | 1 h | Chainlink practice |
| spot vs oracle on mint | ≤ 200 bps | Arbitrum 45, Unichain 185 bps | values already tuned for our LP managers |
| recenter: out of range for | 1 h – 7 d | 6 h | |
| recenter: cooldown per position | ≥ 1 h | 24 h | |
| share of one pool | ≤ 50 % | 30 % | decided 2026-11-21 |
| positions | 8 | — | gas of sync and burn |
| `compound()` threshold | per chain | $5 on L2, $500 on Ethereum | gas ≤ 1 % of what is reinvested |

**Launch set (data.v2 + GeckoTerminal, 2026-11-24).** Hookless v4 stable/stable pools above $100k TVL:
- Arbitrum USDC/USDT0, fee 0.0008 % (+0.0002 % Uniswap protocol fee): TVL $543k, 7d volume ~$80M,
  APR 5.3 %. At a 30 % share our cap is ~$230k, and our entry lowers the pool APR to ~3.7 %.
- Unichain USDC/USDT0, fee 0.01 %: TVL $151k, 7d volume ~$0.4M, APR 1.3 %.

Unichain has no Chainlink USDT/USD feed (only USDC/USD), so a USDT0 depeg is invisible there.
Proposal: the oracle is a per-token adapter in the registry, pluggable later without redeploying;
a token without an adapter cannot be minted with, burn still works. Check Pyth / RedStone for USDT0
on Unichain; until then Unichain is a demo deployment and Arbitrum is the main one.

**Keeper.** No privileges — every call is permissionless and the contract checks the conditions.
Our service is primary; Gelato or Chainlink Automation is the backup where available.

| Call | When | If the keeper is gone |
|---|---|---|
| `sync()` | hourly on L2, daily on Ethereum; once per selection window also records `feeGrowthGlobal` points for pool selection | transfer error grows; mint and burn still sync |
| `compound(pos)` | uncollected fees above threshold | fees idle but not lost; burn compounds |
| `executeBurns(n)` | only if burn delay > 0 | holders execute their own requests |
| `applyRange(pos)` | after a timelocked preset change, both stables at peg | position stays on the old range |
| `reclassify(addr)` | an address that accrued now has real (non-7702) code | accrual stuck, not lost |

It also alerts (no transactions): breaker on or stale feed, sequencer down, position out of range,
pool share above cap, noUSD on DEX more than 0.3 % from 1, burn queue growing, keeper low on gas.

Resolved 2026-11-25: numbers and the Ethereum launch set are in the spec; Unichain stays without
mint until a USDT/USD feed exists in the unisafe oracle (no-opinion → mint closed, burn works).

## Prior art (short)

Closest: Origin OUSD (stable basket in strategies, oracle-bounded mint/redeem), Arrakis Modular v4
module, Bunni v2 (lesson: rounding in withdraw, Sept 2025), Gamma Hypervisors (lesson: spot price at
share issuance, Jan 2024). No production system found that does exactly this. Details and sources
are in the HTML page.
