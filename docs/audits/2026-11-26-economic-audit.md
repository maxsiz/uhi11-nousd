# noUSD audit — economic attacks, Uniswap v4, uncontrolled emission (2026-11-26)

## Scope and method

Internal multi-agent review of `uhi11-nousd` at commit `7e3bff9` (branch `main`), covering `src/` (`src/NoUSD.sol`, `src/NoUSDPositionManager.sol`, `src/NoUSDRegistry.sol`, `src/lib/*`) and the launch parameters in `script/config/1.json`. Eight finders, each working through one attack lens, produced candidate findings, which were then deduplicated. Each finding was checked by a Foundry PoC on the local PoolManager fixture (`ManagerFixture`) and by two independent skeptics, one economic and one code/spec. A completeness critic then reviewed the whole set. `src/` was not modified during the audit.

## Summary table

| ID | Finding | Severity after review | Verification | Category | Status |
|---|---|---|---|---|---|
| H-01 | `accPerShare` (uint120) overflows when eligible supply is about 1 wei. After that `_sync` breaks permanently, and with it burn, claim and mint | **High** | Confirmed by PoC | emission | Fixed in `bbc2292` |
| M-01 | `_sync` values fee growth at par with no peg check: `donate()` of a depegged token creates claims that are paid out in healthy stables | **Medium** | Confirmed by skeptic's E2E PoC | uniswap | Open (owner decision) |
| M-02 | Par arbitrage: the real depeg bound is ≈ `depegBps` + `maxSpotDeviationBps` (about 100 bps), not 50 | **Medium** | Confirmed by PoC | economic | Open (owner decision) |
| M-03 | A free flash loan of noUSD before `sync()` captures B/(E+B) of accrued fees | **Medium** | Confirmed by PoC | economic | Open (owner decision) |
| M-04 | The minter gets the mint fee back through `carry`, so the `mintFeeBps` lever does not work | **Medium** | Confirmed by PoC | economic | Fixed in `b41e7eb` |
| L-01 | Liquidity is added at a price skewed by up to `depegBps`: about 6.3 bps of every add goes to a backrunner | Low (up to Medium as `supplyCap` grows) | Confirmed by PoC | uniswap | Open (owner decision) |
| L-02 | Fees from the mint's own swap are accounted on the post-add liquidity: phantom accruals appear | Low | Confirmed by PoC | emission | Fixed in `8eaded9` |
| L-03 | `maxShareBps` bypass via flash JIT liquidity | Low | Confirmed by PoC | uniswap | Open (owner decision) |
| L-04 | A matured burn request bypasses a `burnDelay` raised later | Low | Confirmed by PoC (with corrections) | economic | Fixed in `b0aceb5` |
| L-05 | `executeBurns` stalls on junk requests, `queueHead` is pinned | Low | Confirmed by PoC | other | Open (owner decision) |
| L-06 | Sandwich of a victim's mint: the internal swap is bounded only by a minOut computed at par | Low | Confirmed by PoC (one skeptic: not an issue) | uniswap | Open (owner decision) |
| L-07 | Mint credits the requested `amount`, not what arrived in `settle()` (if USDT enables its fee) | Low (conditional) | Confirmed by PoC (one skeptic: by design) | emission | Fixed in `5f04f2b` |

M-02, M-04 and L-04 lead to one systemic conclusion. Spec §11 relies on two levers against par arbitrage, `mintFeeBps` and `burnDelay`. M-04 disables the first and L-04 partly bypasses the second. As a result governance has no working response to M-02.


## Fix status (2026-11-27)

| ID | Status | Change |
|---|---|---|
| H-01 | Fixed `bbc2292` | `distribute` never reverts: value over eligible supply below `MIN_ELIGIBLE` (1 noUSD) goes to `treasuryAccrued`, and the uint120 bound is a non-reverting backstop (spec §5.2). |
| M-04 | Fixed `b41e7eb` | The mint fee is distributed (`carry + fee`, protocol cut included) before `token.mint`, so the minter's new balance earns none of it (spec §9.1 step 8). |
| L-02 | Fixed `8eaded9` | `_add` books the old liquidity's fee growth into `carry` and moves the counters before adding (spec §9.1 c). |
| L-07 | Fixed `5f04f2b` | The deposit is the amount `settle()` returns (spec §9.1 step 5). |
| L-04 | Fixed `b0aceb5` | `requestBurn` reverts `UseBurn` while `burnDelay == 0` (spec §9.3). |
| M-01, M-02, M-03, L-01, L-03, L-05, L-06 | Open | Each fix changes economic behaviour the spec defines (peg check in `sync`, reference to $1 in the mint band, time-weighted accrual, add gate, share-cap reference, queue keeper rules, swap price check). They wait for the owner's decision. |

Every fixed finding has a regression test in `test/AuditRegressions.t.sol` that fails on the audited commit and passes after the fix. One side observation from the M-04 test: a 100k mint right after a 1k one leaves the body about $0.23 short of the credit-price measure with any fee; that is the L-01 effect (add at a price skewed within the band).

---

## H-01. `accPerShare` overflow at tiny eligible supply: `_sync` stops working permanently

**Impact.** The whole backing is frozen permanently. No holder can `burn`, `claim`, `executeBurn(s)` or `mint`. That is up to `supplyCap` (100k on Ethereum) per chain. It violates the hard rule that burn and claim cannot be blocked. The contracts are immutable and `retirePool` also calls `_sync`, so there is no recovery.

**Mechanics.** `NoUSD.distribute` (`src/NoUSD.sol:295-314`) computes `delta = value*1e18/eligible` and reverts with `AccumulatorOverflow` if `accPerShare+delta > 2^120-1` (≈1.329e36). Only `eligible == 0` is handled separately. `_sync` is called first on every state-changing path (`src/NoUSDPositionManager.sol:171, 208, 223, 256, 275, 302, 333`). On revert the `fg*Accounted` counters roll back, so every later sync fails again.

**Attack.**
- Variant A, at launch. There is no seed mint, and contracts are excluded by default.
  1. Contract C mints 100k first; eligible = 0.
  2. C transfers 1 wei to an EOA; eligible = 1 wei.
  3. About $1.33 of value reaches the position: under an hour of fees, or a `donate()`. This gives `delta ≥ 1.33e36`, and the next sync reverts.
- Variant B, pinning at the bound. The attacker alternates `donate()`/`sync()` in small steps, then raises eligible to 1e18 for fine tuning, and leaves `accPerShare = uint120.max − h` with `h ≈ 1`. From outside the contract looks normal, and victims mint up to the cap. The remaining headroom is `h*E/1e18` dollars, so the first trading session breaks sync permanently. Rounding delta down to 0 requires `eligible > value*1e18`, which is unreachable with supply ≤ cap.
- Cost: from a few dollars to about $270 in donations, plus gas. The attacker withdraws their own funds before springing the trap.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed.
```
[PASS] test_bricksSync() (gas: 1721262)
[PASS] test_pinAccumulatorPermanent() (gas: 67369563)
  acc: 1329227995784915872903807060280344574
  headroom: 1
```
After 50k noUSD is transferred to an EOA and normal trading happens, `sync` and `burn` revert with `AccumulatorOverflow`.

**Skeptics (both High).**
- The attack works only in the launch window, while honest EOAs hold less than 1 noUSD eligible. Later the attacker has to bring in about `$1.33·E`.
- The donate/sync sequence can be run atomically from a contract, with the steps computed off-chain.
- The pinned state is visible on-chain (`accPerShare ≈ 2^120`), but users will not notice it.
- Spec §5.2 calls the bound "unreachable". That is an assumption, not an accepted risk.

**Fix.**
- `src/NoUSD.sol:295-314`: when `eligible < MIN_ELIGIBLE` (e.g. 1e18), treat it like `eligible == 0`, i.e. route the value to `treasuryAccrued`/`carry`. Route any excess above the uint120 bound to carry/treasury too instead of reverting, or widen `accPerShare` to uint256.
- `script/Deploy.s.sol`: create a non-withdrawable eligible seed (1 noUSD to a dead address marked eligible).
- `src/NoUSDPositionManager.sol:444-480`: wrap `distribute` in try/catch so that burn and claim keep working even if sync fails.

**Status:** Fixed in `bbc2292`; regression test `test_H01_*` in `test/AuditRegressions.t.sol`.

---

## M-01. `_sync` values fees at par with no peg check: `donate()` of a depegged token creates claims on the healthy backing

**Impact.** Value flows from excluded holders (DEX pools, lending, Safe, the escrow of delayed burns) and small eligible holders to the attacker. Mint protections (`_atPar`, oracle, `mintPaused`, `mintable`, `supplyCap`) are bypassed. `totalSupply` does not grow; `totalUnclaimed` does. Ceiling: `D0·(1−p)·(1−w)`, where w is the share of the body in the depegged pool.

**Attack.** An administered token T trades at p < 1, its pool is still registered, mint is closed.
1. The attacker holds a dominant share of eligible supply: their own, through a small eligible float, or through flash noUSD (see M-03).
2. A swap moves the pool into the manager's range, where the manager holds almost all active L (m ≈ 1).
3. Call `PoolManager.donate(key, X of T)`.
4. Call `manager.sync()`. The fee `mX` is valued at $1 and distributed over eligible only.
5. Swap back.
6. Call `claim()` and receive `mX/(D0+mX)` of the body, mostly in USDC/USDT/DAI.

Retiring the pool needs a Safe transaction, while the attack is atomic. Sync still accounts a pool in WithdrawOnly status.

**PoC.** The PoC agent did not finish its test: its session was interrupted and no file was created. A skeptic ran an E2E test instead. PoC: local Foundry test (fixture-based); converted into a regression test when fixed. Parameters: p = 0.5, D0 ≈ 200k, the attacker is the only eligible holder (1 unit), m = 1.
```
[PASS] test_e2e_m1_X100k()            net  16712
[PASS] test_e2e_m1_X1M()              net  41774
[PASS] test_e2e_m1_eligibleOthers20k() net -49997
[PASS] test_e2e_outsideLP_X100k()     net -46623
```
The round-trip swap costs about $0.75. Without the conditions s ≈ 1 and m ≈ 1 the attack loses money (last two lines).

**Skeptics (both lowered High → Medium).**
- The economics in the original finding are overstated by about 2x: it ignores that the manager's position in the depegged pool has already turned into T. At D0 = 100k, p = 0.5, X = 100k the profit is about $8.3k, not $25k. At p = 0.9 the ceiling is about $5k.
- The attack needs a real depeg, external LPs leaving the range, and a dominant eligible share.
- The mechanism is real. Spec §9.4 ("no oracle") and §11 ("donate distributed normally") do not consider a depeg.

**Fix.** In `src/NoUSDPositionManager.sol:444-480` (`_sync`), add a per-pool peg/oracle check that does not revert. If the check fails, do not advance `fg*Accounted` (fees stay in the body as surplus), or value them at `min(1, oracle price)`. Also cap the value a single sync can distribute per pool.

**Status:** Open — the fix changes economic behaviour beyond the spec and waits for the owner's decision.

---

## M-02. Par arbitrage: the real depeg bound is about 100 bps, not `depegBps` = 50

**Impact.** Holders take in the weak stable at par and give out strong stables pro-rata. Backing by "the basket" gradually becomes backing by "the worst token in the basket". At a $100k cap, losses range from hundreds of dollars to about $1.4k per depeg episode, growing linearly with `supplyCap`. At launch `mintFeeBps = 0` and `burnDelay = 0`, so the loop is free apart from gas.

**Mechanics.** `_pegOk` (`src/NoUSDPositionManager.sol:562-573`) checks `|slot0 − par| ≤ 50` and `oracle.check(key,false,0,0)`, i.e. spot within 50 bps of Chainlink. Both checks read slot0, which the attacker moves in the same transaction. Credit is computed as `_liquidityValue` at par (`:543-547, :639`). `burn` (`:201-214`) is instant and has no peg check.

**Attack.** USDe is at 0.9905 (−95 bps), Chainlink agrees, mint is closed.
1. A flash buy of USDe moves the pool to par−46.
2. `mint(USDe)`: about 0.9987·A noUSD for USDe bought at 0.9905·A.
3. Swap back to −95.
4. `burn` in the same transaction: a pro-rata basket, about half of it from the DAI/USDT pool.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed. (Body about $200k, pool fee 1 bp, oracle is a replica of ChainlinkPriceOracle.)
```
[PASS] test_F3_pushedDepeg95_mintAtParBurnBasket()  eve PnL +58.14 $; bob loss 156.17 $
[PASS] test_F3_pushedDepeg95_150k()                 eve PnL +247.33 $; bob loss 345.36 $
[PASS] test_F3_genuineDiscount45_mintAtParBurnBasket() eve PnL +74.08 $; bob loss 76.63 $
```
Verified that a plain mint at −95 reverts. After the push everything goes through.

**Skeptics (Low / Medium).**
- The part up to 50 bps is accepted in spec §11. What is new is the extra 50–100 bps from the oracle tolerance and feed lag. The spec's claim that the bound equals `depegBps` is wrong.
- `MAX_MINT_FEE_BPS = 50` cannot close the gap.
- The sub-claim "idle pairing credits the whole A at par" was not tested.
- At the −50 edge of the range an off-by-one revert from the SwapStep limit is possible; it does not block the attack.

**Fix.**
- `src/NoUSDPositionManager.sol:568-573` (`_pegOk`): check that the Chainlink reference price itself lies within the mint band around par, or credit the deposit at `min(1, usd_t/usd_u)`. Introduce a separate narrow mint band (about 10 ticks).
- `src/NoUSDRegistry.sol:79`: `MAX_MINT_FEE_BPS ≥ depegBps + maxSpotDeviationBps`.
- Do not launch with the combination `mintFeeBps = 0` and `burnDelay = 0`.
- Fix `docs/spec.md:571`.

**Status:** Open — the fix changes economic behaviour beyond the spec and waits for the owner's decision.

---

## M-03. A free flash loan of noUSD before `sync()` captures accrued fees

**Impact.** On every sync, honest eligible holders lose B/(E+B) of the fees accrued since the previous sync. If most noUSD sits in excluded contracts, the attacker's share approaches 100%. The body is not affected, only the yield. At launch this is about $3–13 per day; at $10M supply about $1.4k·B/(E+B) per day. The bound in spec §11 ("buy-before-sync" costs a DEX round trip) does not hold. This is exactly the reason §5.6 rejected ERC-3156.

**Attack.**
1. Inside `PoolManager.unlock`, call `take(noUSD, C, B)` from v4 pool reserves or ERC-6909. Morpho/Balancer work the same way.
2. Contract C is eligible (`configureAccrual(true)`) or is an EOA.
3. Call `manager.sync()`. It does not call `unlock` and so runs inside someone else's callback.
4. Return B via `transfer`. C's accrual is checkpointed at the transfer.
5. Call `claim()`.

Cost: gas only, about 200–300k.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed.
```
[PASS] test_F4_flashBorrowedNoUSD_capturesHalfOfPendingFees() (gas: 3870774)
  borrowed 98995181351219999523104
  distributed this sync 10884354513439506052
  attacker accrued 5414829632314126126
  alice accrued (sole honest holder) 5469524881125379925
```
The attacker, with no capital, got 49.7% of the distribution; `claim` paid out 5.4148 in stables.

**Skeptics (both Medium).** The attack needs noUSD liquidity in a fee-free source, which may not exist on day one. It is structural yield theft that grows with adoption.

**Fix.** Make a balance held for 0 seconds earn nothing. Options:
- `src/NoUSD.sol:295-314`: stream each sync's `F` into `accPerShare` linearly over the next interval;
- or checkpoint on `min(balance)` between syncs;
- or let `claim` pay only accruals fixed no later than the previous sync.

Partial measure: in `src/NoUSDPositionManager.sol:191-194`, forbid `sync` while the PoolManager is unlocked (`exttload`). Remove the swap-fee-based bound from the spec.

**Status:** Open — the fix changes economic behaviour beyond the spec and waits for the owner's decision.

---

## M-04. The mint fee returns to the minter through `carry`

**Impact.** The effective mint fee is `fee·E/(E+out)`, not `mintFeeBps`. If the eligible float is small, the fee is refunded in full. This is the only mint-side lever of spec §11 against M-02, and it does not work. At launch (`mintFeeBps = 0`) there are no direct losses. The problem is that governance's expected response to M-02 has no effect.

**Mechanics.** `mint` (`src/NoUSDPositionManager.sol:178-183`) does `carry += fee`, then `token.mint(to, out)`. Then `burn` (`:206-212`) calls `_sync`, which calls `distribute(carry…)` (`:474-478`) over eligible supply that already includes the fresh `out`. Then `consumeAccrued(msg.sender)` returns the minter's share. With `burnDelay > 0` the same result comes from the sequence mint → `sync()` → `requestBurn`.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed. (Mint 50k with an immediate burn; bob has about 20k eligible.)
```
[PASS] test_F11_mintFeeRefundsItselfToTheMinter() (gas: 3524110)
  fee charged at 50 bps (1e18)         249492261421220004144
  cost fee=0 (1e18)                    7712281827107209576
  cost fee=50, bob eligible (1e18)     79352655768679632972
  cost fee=50, bob excluded (1e18)     7688136090002305897
```
Effective fee: 14.3 bps instead of 50. If bob is excluded, it is 0.

**Skeptics (Low / Medium).** No extra noUSD is created. `burnDelay` remains the second lever, but see L-04. Skeptic's objection: the M-02 edge is about 50–100 bps, not 100–150 as the original finding stated.

**Fix.** `src/NoUSDPositionManager.sol:178-183`: call `token.distribute(carry + fee)` before `token.mint(to, out)`, so that the new balance is checkpointed after the distribution. Alternatively send the mint fee to the treasury or to a vesting bucket.

**Status:** Fixed in `b41e7eb`; regression test `test_M04_*` in `test/AuditRegressions.t.sol`.

---

## L-01. Add at a skewed price (mint, compound, applyRange): about 6.3 bps of every add goes to a backrunner

**Impact.** A position valued at par is convex in price and has its minimum at par. An add at |tick−par| = 50 with a ±100 range loses `ε²/4w` ≈ 6.25 bps once the price returns. Mint is credited at the skewed spot; the shortfall falls on holders.

**Attack.**
- Mint loop: push to par−42…−44, `mint` (the mint's own swap brings it to −50), swap to par, instant `burn`.
- `compound` checks only `_atPar` (`src/NoUSDPositionManager.sol:298-308`) and does not call the oracle.
- `applyRange` after a preset change.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed. (Fee 25 pips, valued at par, gas excluded.)
```
[PASS] test_F5_launchScale_skewedMintLoop_profitable()  bob delta -15.15 $ ; eve pnl +10.18 $
[PASS] test_F5_scaled_skewedMintLoop_profitable()       bob delta -614.49 $ ; eve pnl +488.87 $
[PASS] test_F5_applyRange_atSkew_profitable()           eve +139.39 $ ; holders -200.95 $
[PASS] test_F5_control_noSkew_isUnprofitable()          eve pnl -0.36 $
```

**Skeptics (both Low).**
- At launch, after gas, the result is about zero. Spec §11 accepts the effect as "second order", but with `depegBps = w/2` it is 6 bps.
- The PoC refuted the claim that the loop repeats freely: the deficit is shared pro-rata, profit drops from +$10.2 to +$2.4, and from the third loop on the attack loses money.
- `compound` was not tested: about $0.3 gain on $500 against about $10 in fees.

**Fix.** In `src/NoUSDPositionManager.sol:303` (compound), `:321` (applyRange) and `:613-616` (mint post-add), add a narrow gate for adds, 2–5 ticks, or `oracle.checkOp` with the position's range. Credit at `min(V(L,spot), V(L,par))` in `:639`. Or keep `mintFeeBps ≥ ε²/4w` (about 7 bps) or a non-zero `burnDelay` until `supplyCap` is raised.

**Status:** Open — the fix changes economic behaviour beyond the spec and waits for the owner's decision.

---

## L-02. Phantom fees from the mint's own swap

**Impact.** `totalUnclaimed` and `treasuryAccrued` grow beyond the fees actually received. This is uncontrolled emission of claims, though small: up to about 0.43× the mint's swap fee, from cents to ~$1.5 per 100k. It violates the spec §9.4 invariant and the §9.1 note. The attacker gains nothing.

**Mechanics.**
1. `mint` calls `_sync` (`:171`), which fixes `fgAccounted` at L_old.
2. The swap runs in the same pool (`:602-608`; at launch `swapId == addId`).
3. `_add` (`:724-730`) rebases `fgAccounted` only for `wasEmpty`.
4. The next `_sync` (`:444-471`) accrues `(L_old+L_add)·Δ`, although v4 paid only `L_old·Δ`.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed.
```
[PASS] test_F6_seed10k_mint200k()  received 0.0900 $; accrued 0.9890 $; unbacked 0.8990 $; shortfall 0.4076 $
[PASS] test_F6_seed200k_mint100k() received 0.8006 $; accrued 1.0002 $; unbacked 0.1996 $
```
The excess matches `L_add·Δ` to within 1 wei. The existing invariant tests do not see it: the price moving off par after the swap masks the difference.

**Skeptics (both Low).** The attacker pays the full swap fee. In practice this is a redistribution from excluded holders, plus a treasury cut taken from the phantom.

**Fix.** `src/NoUSDPositionManager.sol:724-730` (`_add`): for a non-empty position, read `getFeeGrowthInside` before the modify, credit `(fgi − fgAccounted)·L_old` to `carry`, and set `fgAccounted = fgi`. Alternatively run a per-position sync right after the swap at `:608`.

**Status:** Fixed in `8eaded9`; regression test `test_L02_*` in `test/AuditRegressions.t.sol`.

---

## L-03. `maxShareBps` bypass via flash JIT

**Impact.** The concentration limiter (30%, hard cap 50%) has no effect. No direct value extraction; the cost is gas only.

**Attack.** Both checks (`src/lib/PoolSelection.sol:79,97` and `src/NoUSDPositionManager.sol:617-619`) read the instantaneous `getLiquidity`. In one transaction the attacker adds a narrow JIT position, calls `mint`, and removes the JIT.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed.
```
[PASS] test_F7_shareCapBypassedWithFlashJit() (gas: 3099862)
  share before (bps) 2852
  share after JIT removal (bps) 5822
  cap (bps) 3000
```
An honest 2M mint reverts with `CapExceeded`. Through JIT the same mint goes through, at a net cost of about $53.

**Skeptics (both Low).**
- The argument "the pool becomes cheaper to move" is wrong: after the mint there is more active L in the pool, not less.
- The cap is soft to begin with: external LPs can leave at any time.
- The effect matters mainly for thin L2 pools.

**Fix.** In `src/NoUSDPositionManager.sol:617-619` and `src/lib/PoolSelection.sol:97`, use `min(L recorded at the last sync, current L)`, or add an absolute per-pool cap in the registry.

**Status:** Open — the fix changes economic behaviour beyond the spec and waits for the owner's decision.

---

## L-04. A matured burn request bypasses a `burnDelay` raised later

**Impact.** `readyAt` is fixed when the request is created (`src/lib/BurnQueue.sol:22`), and `_executeOne` (`src/NoUSDPositionManager.sol:502-513`) checks only the stored value. Requests created with `burnDelay = 0` mature immediately and remain an instant exit after the delay is raised to 7 days. Measured edge about 18 bps of N, up to ~$180 per episode at a $100k cap.

**Attack (as corrected by the PoC agent).**
1. At launch, `requestBurn(N, minOut = trigger)`, where trigger is about 1.5 bps above the par payout. The keeper skips such a request.
2. Governance raises `burnDelay`.
3. On a depeg within the band, the attacker mints N at par and immediately calls `executeBurn(parked)`.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed.
```
[PASS] test_parkedRequestIsInstantExitDespiteBurnDelay() (gas: 35464613)
  eve realised in stables ... 92055171623021450403
  bob loss  (1e18 USD)    73533007023903075535
```

**Skeptics (both Low).** Three parts of the original finding were refuted:
- the "cancel and re-request" variant: a new request gets the current `burnDelay`;
- `minOut = uint128.max`: such a request can never be executed;
- the 100–150 bps estimate: about 18 bps was measured.

In addition, once the trigger is reachable, anyone can execute the request and the option is lost. At launch the attack adds nothing, because `burn()` is already instant.

**Fix.** In `src/NoUSDPositionManager.sol:504`, use the effective `readyAt = max(stored, requestedAt + current burnDelay)`. Give requests an expiry, or a cooldown on cancel (`src/lib/BurnQueue.sol:33-40`). Reject `requestBurn` when `burnDelay == 0` (`src/NoUSDPositionManager.sol:245`).

**Status:** Fixed in `b0aceb5`; regression test `test_L04_*` in `test/AuditRegressions.t.sol`.

---

## L-05. `executeBurns` stalls on junk requests

**Impact.** The keeper's batch path degrades: with `n ≤ K` a call executes nothing, and every such call re-runs all the doomed payouts. No funds are lost: the permissionless `executeBurn(id)` works. Relevant only when `burnDelay > 0`.

**Attack.** Call `requestBurn(1 wei, minOut = uint128.max)` K times (about 142k gas each). `queueHead` advances only past executed requests (`src/lib/BurnQueue.sol:42-46`, `src/NoUSDPositionManager.sol:255-271`). The attacker recovers the escrow via `cancelBurn`.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed.
```
[PASS] test_F10_spamPinsQueueHeadAndStallsBatchKeeper() (gas: 26116641)
  executeBurns(K) gas, 0 executed   6278101
  keeper gas per junk visit         209270
```

**Skeptics (both Low).** The claim "it needs about 45M gas, more than a block" is wrong: failed requests count toward `n`, so the cost is bounded by the keeper's parameter. Spec §9.3 describes this behaviour, but the spec's test list (`:654-655`) promises that the queue does not block.

**Fix.** A separate scan cursor in addition to `queueHead`. A minimum request size (e.g. 1 noUSD) in `src/NoUSDPositionManager.sol:245`. A public cancel that refunds the owner for requests not executed for longer than X.

**Status:** Open — the fix changes economic behaviour beyond the spec and waits for the owner's decision.

---

## L-06. Sandwich of a victim's mint

**Impact.** The swap inside mint (`src/lib/SwapStep.sol:50-62`) is bounded only by the range `parTick ± depegBps`. The victim loses an amount within their own slippage. On top of that, about $39 of IL per $100k falls on holders, and minOut does not cover that part.

**Attack.** Front-run to par−40, the victim's mint (minOut 99.5% passes), back-run to par.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed. (Fee 1 bp.)
```
[PASS] test_F8_sandwichVictimMint() (gas: 2576626)
  victim loss vs baseline e18 105487960590312494630
  attacker PROFIT e18 67235311080570489053
  body - liabilities, attacked, back at par (e18) -35889098828770053839
```

**Skeptics (Low / none).** The victim's loss is bounded by their own minOut, which is valued at par; this is standard DEX risk. The second part (about 4 bps on holders) is a consequence of L-01.

**Fix.** Check the actual swap rate via `oracle.check(key, zeroForOne, paid, got)` in `src/NoUSDPositionManager.sol:602-608`, or give the caller their own price limit. In the UI, set a tight minOut and submit through a private mempool.

**Status:** Open — the fix changes economic behaviour beyond the spec and waits for the owner's decision.

---

## L-07. Mint credits `amount`, not the sum received by `settle()`

**Impact.** If Tether enables its transfer fee (≤20 bps, ≤50 USDT), every USDT mint is credited for the full amount, and the fee is taken from holders' idle USDT. Current damage is zero.

**Mechanics.** In `src/NoUSDPositionManager.sol:586-588` the return value of `settle()` is ignored. `:598` sets `m.tLeft = amount`. `Settlement.resolve` (`src/lib/Settlement.sol:66-76`) burns the missing part from ERC-6909 claims.

**PoC.** PoC: local Foundry test (fixture-based); converted into a regression test when fixed.
```
[PASS] test_feeOnTransfer_mintOverCredits_fromHoldersIdle() (gas: 6290789)
  liabilities - backing (18d): 94941073565644314405
  holders' idle B burned (6d) 94860941
```
Once idle runs out, mint reverts (`test_feeOnTransfer_noIdle_reverts`).

**Skeptics (none / Low).** Spec §4 explicitly leaves FoT tokens to governance, and the attacker has no profit. But USDT is listed as mintable in `script/config/1.json`, and its fee switch is in the token's code, though currently off.

**Fix.** In `src/NoUSDPositionManager.sol:588,598`, use the value returned by `poolManager.settle()` as the deposit, or revert when `settled != amount`.

**Status:** Fixed in `5f04f2b`; regression test `test_L07_*` in `test/AuditRegressions.t.sol`.

---

## Refuted / not an issue

No finding was refuted in full. Individual claims were rejected:
- **L-04:** the "cancel and re-request" variant does not work; a new request gets the current `burnDelay`. A request with `minOut = uint128.max` can never be executed. The 100–150 bps edge was not confirmed; about 18 bps was measured.
- **L-05:** "about 45M gas, more than a block" is wrong; the cost is bounded by `n`.
- **L-01:** "freely repeatable loop" is wrong; from the third loop on the attack loses money.
- **L-03:** "concentration makes the pool cheaper to move" is wrong; active L increases.
- **M-01:** the claimed damage of $25k per 100k at p = 0.5 is overstated; it is really about $8.3k, because the position in the depegged pool is already in token T.
- **M-02/M-04:** "100–150 bps per loop" is overstated; 50–100 bps is realistic, accounting for feed lag.
- **L-06:** in one skeptic's view this is not a protocol defect: the victim's loss is bounded by their minOut.
- **L-07:** in one skeptic's view the case is covered by design (spec §4, FoT is governance's responsibility).
- **M-02:** the sub-claim "idle pairing credits the whole deposit at par" was not tested by a PoC.

## Unverified critic leads

- The peg guard compares the pair's tokens only with each other, not with the dollar. If both tokens of an Active pair depeg at once (e.g. USDe/USDC in a systemic event), mint at par stays open. Holders of that pair could run the mint/burn loop and drain the healthy pairs through pro-rata burn. Not verified by a PoC. Related to M-02: the fix "reference price within the mint band to $1" would close this case too.
