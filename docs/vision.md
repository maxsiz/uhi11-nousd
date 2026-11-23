# noUSD — current vision (model v3)

> Status: **working notes, not a spec.** This captures where the design stands on 2026-11-23
> after several rounds of "find the contradiction, resolve it". Decisions carry the date they were
> taken; open questions are listed explicitly. The visual version (Russian, with diagrams) is
> [`nousd-model.ru.html`](nousd-model.ru.html).

## One paragraph

noUSD is a single ERC-20 that is also a shared vault of stablecoin liquidity on Uniswap v4.
Anyone deposits an allowed stablecoin; **in the same transaction** the vault swaps part of it and
adds liquidity to one of its stable/stable positions, then mints noUSD for the value actually
deposited. Burning noUSD returns the holder's pro-rata share of **every** position, in every token,
to any recipient they choose — no oracle, no swap, no permission. Trading fees stay inside the
positions and keep compounding; who owns them is tracked by a per-token fee accumulator, the same
idea as `feeGrowth` in v4 itself, so each holder earns only from the moment they entered.

## Architecture

```
               allowed stables, pool whitelist,
   multisig ─► limits, depeg thresholds (Registry)
                          │ read on every mint
                          ▼
   user ──mint──► noUSD Vault  (ERC-20 + owner of all positions)
   user ◄─burn──      │   fee accumulator ("fees per 1 noUSD"), claim()
                      ▼
          Uniswap v4 PoolManager (one unlock per mint / burn)
            ├─ USDC/USDT 0.01%   position
            ├─ USDC/USDT 0.05%   position
            └─ USDC/DAI  0.01%   position
   Stage 2 (maybe never): PSM hook 1:1
```

* **Vault = token.** One contract, one ERC-20, owns all positions. No second token, no rebase.
* **Registry.** Which stables are allowed, which pools are admissible, limits, depeg thresholds.
  Governed by a 2-of-3 multisig: tightening is immediate, loosening goes through a 48–72 h timelock.
  Neither the registry nor any pause can stop `burn`.
* **Positions.** Hookless v4 stable pools, wide preset ranges (±1–2 %), at most ~8 positions to bound
  gas. No operator.

## Mint — one transaction, one `unlock` (decided 2026-11-21)

1. **Checks:** stable is allowed, oracle price above its depeg threshold, caps not exceeded,
   spot within θ of the oracle in every pool touched, `deadline`.
2. **Pick the position** (hybrid selection, below).
3. **Settle fees before entry:** `sync()` — read fee growth of every position and move the
   accumulator, so fees earned so far go to existing holders and the new minter gets none of them.
4. **Swap** the needed part of the deposit in pool **A** — whichever is cheapest for the minter.
5. **Add liquidity** in pool **B** — whichever is best for holders. Flash accounting nets A and B.
6. **Mint noUSD for the value actually added**, to `to`, subject to `minOut`. The minter pays the
   swap: 10 USDC → ≈ 9.9993 noUSD at a 0.01 % pool.

If the swap or the add is impossible → **revert**. There is no idle balance and no "waiting for
deploy" state, so every noUSD in existence is working capital from its first block. This is what
makes a plain balance-weighted accumulator exact (see the simulation).

## Burn

* Share `s = x / (supply + unclaimed)`, computed before burning.
* `sync()` first, then remove share `s` of liquidity from every position (this collects all their
  fees; the vault re-adds what is not the burner's — `compound()`); all tokens go to `recipient`.
* Fees accrued up to that moment stay with the holder and are taken with `claim()`.
* No swap, no token choice, no oracle, cannot be paused.

## Fees (accounting decided 2026-11-23)

noUSD is a **separate ERC-20 contract**; the vault is its only minter/burner and the only caller of
`distribute()`.

**State in the token**

| Where | Field | Written by |
|---|---|---|
| global | `accPerShare` — fees in noUSD earned by 1 noUSD since launch (only grows) | `sync()` via `distribute(F)` |
| global | `totalUnclaimed` — credited to holders, not yet minted | `distribute` (+), `claim` (−) |
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
| 24:00 | keeper `sync()` | `F = 60·min(p_USDC,1) + 40·min(p_USDT,1) = $100`; `Δcounter = F / (supply − excluded) = 100/1M` | counter 100, unclaimed $100, no tokens moved |
| 24:05 | Carol burns 100k | Carol accrued `200k × 100/1M = $20`; `s = 100k / (1M + 100)`; compound → body $1 000 100; Carol takes `s × 1 000 100 = $100 000` | supply 900 000; `900 000 + 100 = 900 100` = body ✓ |
| 24:10 | Bob `claim()` | `400k × 100/1M = $40` → mint 40 noUSD | supply 900 040, unclaimed 60; `900 040 + 60 = 900 100` ✓ |

Result: Alice $40, Bob $40, Carol $20 = $100 earned. The exact split by capital × time is
50/40/10: L misallocates only between the two sides of a transfer, at most
`amount × unsynced yield per noUSD` (here $10).
Invariant at every step: `supply + totalUnclaimed = value of the position bodies`.

**`sync()` vs `compound()`** — two different operations:

| | `sync()` — accounting | `compound()` — reinvest |
|---|---|---|
| does | reads `feeGrowthInside` vs `feeGrowthInsideLast` per position, values at `min(oracle,1)`, moves the counter; no tokens move | `modifyLiquidity` on the position: v4 pays out all its fees (`callerDelta = principal + feesAccrued`), the vault adds them back as liquidity |
| matters for | fairness (the buy-before-sync attack targets the counter) | yield only |
| mint | mandatory before entry, all positions | position B only (the add collects its fees) |
| burn | mandatory before computing the share | all positions (burn touches each) |
| quiet day | keeper at least daily; anyone may call | when uncollected fees exceed a threshold |
| gas, 8 positions (rough) | ~200–250k | ~0.7–1M |

Why daily is enough: buying noUSD on a DEX, calling `sync()` and selling pays only when the
unsynced yield per noUSD exceeds the round-trip cost — ~1.75 days without sync in a 0.01 % pool,
~9 days in a 0.05 % pool (at 5 % APR).

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
| burn | `x / supply` of value | `x / (supply + unclaimed)`, accrued stays |
| transfer | plain ERC-20, ~34.5k | +2.4–12.4k |
| per-address state | balance | balance, checkpoint, accrued |
| paying out yield | not needed — it is in the price | `claim` in noUSD or burn with accrued in stables — open |
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

Taken from v2 regardless of the choice: `_mintFee` (lines 89–107) as the protocol-share pattern —
mint the treasury 1/6 of `√k` growth lazily, here on `sync()`; `MINIMUM_LIQUIDITY = 1000` locked at
`address(0)` (lines 120–121) against share inflation; burn by actual balances, not cached reserves.

**Open fork:** if "≈ $1" is mandatory, L stays. If an appreciating noUSD is acceptable, the v2 model
removes accrued slots, `claim`, the keeper and the transfer error — but it is then a yield share like
sDAI, and a stable on top of it would be a second token.

## Pool selection — hybrid (decided 2026-11-21)

v4 has several pools with the same pair and different fee tiers and depth. On-chain we choose like this:

| Layer | Who | What |
|---|---|---|
| Admission | Registry | hookless pools, allowed stables and fee tiers, price inside the preset range |
| Limits | Registry | our share ≤ 30 % of pool liquidity, max weight in the basket, minimum pool liquidity |
| Signal | Contract | inside the limits: yield per unit of liquidity from `feeGrowthGlobal` over 7 days × `L/(L+x)` (dilution by our own deposit) |

The vault snapshots `feeGrowthGlobal` with timestamps on each poke. The signal can be pumped with
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
| 2026-11-23 | Compared with Uniswap v2 LP tokens (share of reserves, price grows, no accounting needed). Open: is "noUSD ≈ $1" mandatory, or is a v2-style appreciating share acceptable? |

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

1. **Par arbitrage inside the depeg threshold.** If USDT trades at $0.999, minting with USDT and
   burning into a basket that holds USDC is a free swap at par, draining good stables from all
   positions. Options: mint at `min(oracle, 1)`, or a mint/burn fee. Both are now possible since
   strict 1:1 is gone.
2. **Accrual to addresses that will never claim** (DEX pools, bridges, other contracts). Needs an
   exclusion list with redistribution — governance surface.
3. **Position out of range with no operator.** Proposal: a permissionless call that moves such a
   position into a preset around the current price, oracle-checked (modelled on an existing
   `moveLiquidity` design).
4. **Protocol share** of fees: 0, or X % minted as noUSD to a treasury on each collection.
5. **First deposit:** dead shares at deployment (ERC-4626 inflation lesson), rounding against the user
   everywhere (Bunni lesson).
6. **Valuation:** token amounts priced by oracle, not spot (Gamma lesson), each stable at `min(oracle, 1)`.

## Prior art (short)

Closest: Origin OUSD (stable basket in strategies, oracle-bounded mint/redeem), Arrakis Modular v4
module, Bunni v2 (lesson: rounding in withdraw, Sept 2025), Gamma Hypervisors (lesson: spot price at
share issuance, Jan 2024). No production system found that does exactly this. Details and sources
are in the HTML page.
