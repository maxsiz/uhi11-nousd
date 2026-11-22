# noUSD — current vision (model v3)

> Status: **working notes, not a spec.** This captures where the design stands on 2026-11-22
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
3. **Settle fees before entry:** poke the positions (or read `StateView`) so fees earned so far are
   credited to existing holders through the accumulator — the new minter gets none of them.
4. **Swap** the needed part of the deposit in pool **A** — whichever is cheapest for the minter.
5. **Add liquidity** in pool **B** — whichever is best for holders. Flash accounting nets A and B.
6. **Mint noUSD for the value actually added**, to `to`, subject to `minOut`. The minter pays the
   swap: 10 USDC → ≈ 9.9993 noUSD at a 0.01 % pool.

If the swap or the add is impossible → **revert**. There is no idle balance and no "waiting for
deploy" state, so every noUSD in existence is working capital from its first block. This is what
makes a plain balance-weighted accumulator exact (see the simulation).

## Burn

* Share `s = x / (supply + unclaimed)`, computed before burning.
* Remove share `s` of liquidity from every position; all tokens go to `recipient`.
* Fees accrued up to that moment stay with the holder and are taken with `claim()`.
* No swap, no token choice, no oracle, cannot be paused.

## Fees

* Physically, fees are collected into the position bodies on every mint/burn and keep earning.
* Accounting: an accumulator "noUSD owed per 1 noUSD" (Synthetix `rewardPerToken` pattern, living
  inside the token). Every `mint`, `burn` and `transfer` checkpoints the address.
* `claim()` mints noUSD for the accrued amount — the backing is already inside the positions.
* v4 facts this relies on: `Position.State = {liquidity, feeGrowthInside0/1LastX128}`;
  `modifyLiquidity` returns `callerDelta = principal + feesAccrued`, so a zero-liquidity poke
  collects fees.

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
