# noUSD — specification v1

Status: **ready for implementation**, 2026-11-25. Source of truth for the contracts. Rationale and the
history of each decision live in [`vision.md`](vision.md) (decision log) and
[`nousd-model.ru.html`](nousd-model.ru.html) (diagrams, Russian). Where this file and those differ,
this file wins.

Keywords MUST / SHOULD / MAY are used in the RFC 2119 sense.

---

## 1. What noUSD is

noUSD is an ERC-20 stablecoin backed by one shared vault of stable/stable liquidity on Uniswap v4.

- **Unit.** 1 noUSD = 1 unit of the stable basket of its chain, not 1 USD. All admitted stables are
  counted at par with each other (1 USDC = 1 USDT = 1 DAI …), normalized to 18 decimals.
- **Mint.** Anyone deposits one admitted stable; the vault swaps part of it inside a registered pool
  and adds liquidity in one transaction; the minter receives noUSD equal to the value actually added
  at par. No idle "waiting for deploy" state. If the swap or the add is impossible, the call reverts.
- **Burn.** A holder burns noUSD and receives, in kind, a pro-rata share of every position and of the
  vault's idle balances, plus their accrued fees. Burn can be delayed by a parameter but never blocked.
- **Yield.** Pool fees are distributed through an accumulator inside the token (variant **L**): the
  counter moves only on `sync()`, every transfer checkpoints both sides. Holders take accrued fees with
  `claim()`, paid in stables, without burning.
- **No operator.** No address can move funds. Every maintenance call (`sync`, `compound`, `recenter`,
  `executeBurns`, `reclassify`) is permissionless; the contracts check the conditions. A keeper only
  makes sure the calls happen.
- **Immutable.** No proxies. Every tunable is a parameter with a hard cap in code. A bug fix is a new
  deployment; holders migrate by burn → mint.
- **Per chain.** Each chain has its own independent deployment (registry, vault, token) and its own
  basket. No bridging of noUSD in v1. noUSD on chain A is not fungible with noUSD on chain B.

### Non-goals for v1

- PSM hook / hard 1:1 floor (stage 2; the floor is held by burn).
- A second "active" vault with an operator and narrow ranges.
- Cross-chain noUSD.
- Creating Uniswap pools. The vault only uses **existing** hookless v4 pools.
- First-deposit (inflation) protection: not needed, see §11.

---

## 2. Contracts

| Contract | Role | Owner |
|---|---|---|
| `NoUSD` | ERC-20 with the fee accumulator and accrual modes. Only the vault can mint, burn, move the counter and consume accrued. | none (vault address immutable) |
| `NoUSDVault` | Owns every v4 position (it is the `owner` in `modifyLiquidity`), implements `IUnlockCallback`. Mint, burn (instant and delayed), claim, sync, compound, recenter. | none — reads parameters from the registry |
| `NoUSDRegistry` | Admitted tokens, registered pools and their status, parameters with caps, oracle address, treasury, governance delays. | Safe 2-of-3 |

Deployment order: registry → vault (registry, PoolManager, token address precomputed) → token (vault).
The token's `vault` and the vault's `token` / `registry` / `poolManager` are `immutable`.

External dependency: the **unisafe price guard** (`IPriceOracle`, implementation `ChainlinkPriceOracle`
from the `uniswap-smart-wallet` repo), used only through its interface, by address (§7). Its ownership
stays with its current owner; the registry can switch the address (loosening → timelock).

Size: EIP-170 (24 576 B) applies. Keep the vault's heavy math in internal libraries; measure with
`forge build --sizes` and keep ≥ 1 KB headroom.

---

## 3. Units and decimals

- Every admitted token has `decimals ≤ 18`; the registry stores `scale = 10**(18 − decimals)`.
- `norm(token, amount) = amount × scale`. noUSD has 18 decimals.
- "Value at par" of a set of token amounts = Σ `norm`. No price is ever applied to value.
- Rounding: **always against the caller** (mint rounds down, burn/claim payouts round down, amounts
  owed to the vault round up). Use `FullMath.mulDiv` / `mulDivRoundingUp`.

---

## 4. Registry

### 4.1 Tokens

```solidity
struct TokenConfig {
    bool admitted;        // may appear in a registered pool
    bool mintable;        // may be deposited in mint()
    uint8 decimals;       // cached at admission, ≤ 18
}
mapping(Currency => TokenConfig) public tokens;
```

Native ETH is never admitted. Fee-on-transfer and rebasing tokens MUST NOT be admitted (governance
responsibility; the vault does not defend against them).

### 4.2 Pools

```solidity
enum PoolStatus { None, Active, WithdrawOnly }
struct PoolConfig {
    PoolKey key;          // hooks MUST be address(0); both currencies admitted
    int24 tickLower;      // preset range (wide, ±1–2 %), multiple of tickSpacing
    int24 tickUpper;
    uint16 maxShareBps;   // our liquidity / pool liquidity cap, ≤ MAX_POOL_SHARE_BPS
    uint16 weight;        // tie-break weight in pool selection
    PoolStatus status;
}
PoolId[] public poolIds;  // length ≤ MAX_POOLS
```

- One position per registered pool. `salt = bytes32(0)`; the position is keyed by the vault, the pool
  and the preset range (after a recenter the range changes, see §9.6).
- `MAX_POOLS = 8` (code constant). In practice the number of pools ≤ number of admitted stables.
- **Active**: used by mint selection, sync, compound, recenter, burn, claim.
- **WithdrawOnly**: excluded from mint selection; burn/claim/sync/compound still touch it. Setting a
  pool to WithdrawOnly is immediate (tightening). Setting a pool Active, adding a pool, or changing its
  range preset / share cap upward is loosening (timelock).
- `retirePool(poolId)` (governance, immediate): removes all liquidity of that position to the vault's
  idle balances and marks the pool WithdrawOnly. Idle balances are paid out pro-rata by burn/claim and
  reused by mint/compound.
- Removing a pool from `poolIds` is allowed only when its position liquidity is 0 and it holds no
  accounted-but-uncollected fees.

### 4.3 Parameters

All in one struct, read by the vault each call (one `SLOAD` group). Caps are `constant` in code.

| Parameter | Cap in code | Launch value | Notes |
|---|---|---|---|
| `burnDelay` | 7 days | 0 | §9.3 |
| `mintFeeBps` | 50 | 0 | fee stays in the vault, distributed to holders on next `sync` |
| `protocolFeeBps` | 1 000 (10 %) | 0 | share of collected fees, to treasury accrual |
| `depegBps` | 1 … 200 | 50 | max |spot − par| for mint/recenter |
| `recenterAfter` | 1 h … 7 days | 6 h | continuous out-of-range time |
| `recenterCooldown` | ≥ 1 h | 24 h | per position |
| `maxPoolShareBps` (default for new pools) | 5 000 | 3 000 | |
| `compoundThreshold` | — | chain-specific, e.g. 5e18 on L2, 500e18 on Ethereum | per position, value at par |
| `selectionWindow` | 1 … 30 days | 7 days | fee-yield window for pool selection |
| `oracle` | — | unisafe `ChainlinkPriceOracle` address of the chain | `IPriceOracle` |
| `treasury` | — | Safe | receives protocol-fee accrual |

Staleness, sequencer uptime and the spot-vs-reference tolerance are **owned by the oracle** (its
per-feed heartbeat, sequencer feed, `maxSpotDeviationBps`); the vault does not duplicate them.

### 4.4 Governance and delays

- Owner: Safe 2-of-3 (`Ownable2Step`).
- **Tightening is immediate**: lower `depegBps`, raise `burnDelay`*, raise `mintFeeBps`*, pool →
  WithdrawOnly, `retirePool`, token `mintable = false`, raise `recenterAfter`/`recenterCooldown`,
  lower share caps, raise `compoundThreshold`.
  *Raising `burnDelay` or `mintFeeBps` hurts holders and is therefore **loosening for them**: these two
  go through the timelock in both directions.
- **Loosening goes through an in-contract queue**: `queue(bytes32 changeHash, bytes data)` stores
  `eta = now + 48 h`; `execute(data)` after `eta`; `cancel(changeHash)`. `TIMELOCK = 48 hours` is a code
  constant. Every change emits an event with old and new values.
- Changing `oracle` or `treasury`, adding a pool/token, raising `protocolFeeBps` are loosening.
- There is **no pause of burn or claim**. There is `pauseMint()` (immediate) / `unpauseMint()` (timelock).

---

## 5. NoUSD token

### 5.1 Storage

```solidity
// slot A per holder
struct Account {
    uint128 balance;
    uint120 checkpoint;   // accPerShare at last touch, truncated (see 5.2)
    uint8   flags;        // bit0 = excluded, bit1 = classified, bit2 = optedIn
}
mapping(address => Account) internal _accounts;
mapping(address => uint256) public accrued;      // slot B, value at par (18 dec)
mapping(address => mapping(address => uint256)) public allowance;

uint256 public totalSupply;
uint256 public excludedSupply;   // Σ balance of excluded accounts
uint256 public accPerShare;      // value per 1e18 noUSD, scaled by ACC_SCALE = 1e18 (see 5.2)
uint256 public totalUnclaimed;   // Σ accrued + not-yet-checkpointed earnings, value at par
address public immutable vault;
```

- ERC-20 + EIP-2612 `permit`. Written by hand on top of OZ 5.x interfaces (do **not** subclass OZ
  `ERC20`: its `_balances` cannot hold the packed layout). Run an ERC-20 property suite against it.
- `balance` is `uint128`: supply above 3.4e20 noUSD is impossible by construction; `_mint` MUST revert
  if it would overflow.

### 5.2 Accumulator

- `accPerShare` grows only in `distribute(uint256 value)` (onlyVault, called by `sync`):
  `eligible = totalSupply − excludedSupply`; if `eligible == 0` the value goes to `treasury` accrual;
  else `accPerShare += value × ACC_SCALE / eligible` (round down; the remainder stays in the vault as
  dust and is counted in the next distribution via `sync`'s carry).
- `checkpoint` is stored as `uint120`. `accPerShare` MUST fit: with ACC_SCALE = 1e18, 2^120 ≈ 1.3e36
  allows 1.3e18 value units per 1e18 noUSD — unreachable. Revert in `distribute` if exceeded.
- **Settle** an account (`_settle(a)`), used on every balance change and on `claim`:
  ```
  if (!excluded(a)) accrued[a] += balance(a) × (accPerShare − checkpoint(a)) / ACC_SCALE
  checkpoint(a) = accPerShare
  ```
  Skip the `accrued` write when the delta is 0. Never write `accrued` from non-zero to exactly 0:
  `consumeAccrued` leaves 1 wei (gas: avoids a 20k re-init).
- `totalUnclaimed += value` in `distribute`; `totalUnclaimed −= paid` in `consumeAccrued`.
- **Transfer**: `_settle(from); _settle(to);` then move balances; maintain `excludedSupply` if exactly
  one side is excluded. Self-transfer settles once.

### 5.3 Accrual modes (Blast-style)

- An address is classified lazily, the first time it receives noUSD (`classified` flag unset):
  - `code.length == 0` → EOA → accrues.
  - code is an EIP-7702 delegation designator (`code.length == 23` and starts with `0xef0100`) →
    treated as EOA → accrues.
  - otherwise (a contract) → **excluded** unless it has opted in.
- `configureAccrual(bool on)`: called by the address itself; a contract opts in (`on = true`) or out.
  An EOA MAY opt out. Settles before switching; moves its balance in/out of `excludedSupply`.
- `reclassify(address a)` (anyone): if `a` is not opted in and now has real code (non-7702), mark it
  excluded (settle first; what it accrued stays claimable). If `a` is excluded, not opted in, and now has
  no code or a 7702 designator, mark it accruing. No-op otherwise.
- Contracts under construction (`code.length == 0` in constructor) are classified as EOA; `reclassify`
  fixes it later. The vault itself is excluded (it holds the burn-queue escrow).

### 5.4 Vault-only functions

```solidity
function mint(address to, uint256 amount) external;            // settle(to) first
function burnFrom(address from, uint256 amount) external;      // settle(from) first; vault-held escrow or holder
function distribute(uint256 value) external;                   // moves the counter
function consumeAccrued(address a, address treasuryOrSelf) external returns (uint256 amount);
function accrueTreasury(uint256 value) external;               // protocol fee share
```

`consumeAccrued` settles `a`, takes `accrued[a] − 1`, decreases `totalUnclaimed`, returns the amount.
The treasury's accrual is a plain counter `treasuryAccrued` consumed the same way.

### 5.5 Views

`pendingAccrued(a)` = `accrued[a] + balance × (accPerShare − checkpoint)` (0 term if excluded).
`isExcluded(a)`, `eligibleSupply()`.

---

## 6. Vault state

```solidity
struct Position {
    int24 tickLower; int24 tickUpper;   // current range of this pool's position
    uint256 fg0Accounted;               // feeGrowthInside0X128 already turned into accPerShare
    uint256 fg1Accounted;
    uint64 outOfRangeSince;             // 0 = in range at last observation
    uint64 lastRecenter;
}
mapping(PoolId => Position) public positions;

struct Obs { uint64 t; uint256 fg0; uint256 fg1; }   // feeGrowthGlobal points for selection
mapping(PoolId => Obs[2]) public obs;                 // [older, newer], rotated daily by sync

mapping(Currency => uint256) public idle;            // vault-held tokens counted in the body
uint256 public carry;                                // undistributed value (dust, mint fees)

struct BurnRequest { address owner; address to; uint128 amount; uint64 readyAt; }
BurnRequest[] public burnQueue; uint256 public queueHead;
```

**Body** = all position liquidity + `idle` + uncollected fees. Invariant (at par, up to rounding and
in-range composition drift):

```
value(body) ≈ totalSupply + totalUnclaimed + treasuryAccrued + carry
```

No function values the body with a price. Mint values what it actually added; burn and claim pay a
**fraction** of every position and of idle; sync values fee amounts at par.

---

## 7. Oracle and peg checks

The unisafe guard `IPriceOracle.check(PoolKey key, bool zeroForOne, uint256 amountIn, uint256 amountOut)`
with `amountIn = 0` judges the pool's spot (`slot0`) against the ratio of the two Chainlink USD feeds
(`usd0 / usd1` — the dollar cancels, so it is a relative stable/stable reference). It:
- reverts `SpotPriceOutOfBounds` if spot deviates more than its `maxSpotDeviationBps`;
- returns `true` if it had fresh references and the spot is in bounds;
- returns `false` (no opinion) when a feed is missing/stale/pinned or the L2 sequencer is down / in grace.

The vault defines:

```
_spotVouched(key)  := oracle.check(key, false, 0, 0) == true   // reverts propagate
_atPar(key)        := |spotPrice(key) − 1| ≤ depegBps            // price of currency1 per currency0, normalized
_pegOk(key)        := _spotVouched(key) && _atPar(key)
```

- **Mint** requires `_pegOk` on the pool it swaps in and the pool it adds to, checked **after** the swap
  and the add, inside the unlock callback (so the final state is judged).
- **Recenter** requires `_pegOk` before acting.
- **Burn, claim, sync, compound never call the oracle.** They are in-kind or count real amounts.
- Why the external reference is needed although value is at par: a v4 spot can be moved inside one
  transaction (flash loan) almost for free; hookless v4 pools keep no TWAP. Chainlink only proves the
  spot is not manipulated; the depeg decision itself is the Uniswap spot vs par.
- Unichain-like case (no feed for a token): `check` returns `false` → mint through that pool is closed;
  burn/claim work. Fail-closed, no special code.

---

## 8. Pool selection on mint (hybrid)

Input: deposit token `t`. Candidates: `Active` pools that contain `t`, whose position is in range, whose
`ourLiquidity / poolLiquidity < maxShareBps`, and where `t.mintable`.

Score per candidate (on-chain, from `obs`):
```
feeYield = Δ(feeGrowthGlobal0 + feeGrowthGlobal1 normalized) over [obs.older.t, now] per unit liquidity
score    = feeYield × L_pool / (L_pool + L_ours + L_new) × weight
```
Pick the max score; ties → lower index. If no candidate: revert `NoPoolForToken`.

- **Add pool** = the chosen pool. **Swap pool** = the registered `Active` pool with the same pair and the
  lowest fee (may be the add pool itself). With disjoint pairs (the Ethereum launch set) they coincide.
- Daily `obs` rotation happens in `sync` (§9.4). Until a pool has two observations its `feeYield` is 0
  and it is chosen only if it is the sole candidate.

---

## 9. Vault functions

### 9.1 `mint(Currency token, uint256 amount, uint256 minOut, address to) returns (uint256 out)`

1. Checks: not `mintPaused`; `tokens[token].mintable`; `amount > 0`.
2. `_sync()` (§9.4) — accrual is up to date before the supply changes.
3. Pull `amount` from `msg.sender` (`transferFrom`, SafeERC20).
4. Select pools (§8).
5. `poolManager.unlock(data)` → in the callback:
   a. compute the swap amount so that `amount − s` of `t` and the swap output fit the position's ratio
      at the current price (`LiquidityAmounts` + one-step correction; leftover allowed);
   b. `swap` in the swap pool (exact input `s`, `sqrtPriceLimit` = depeg bound);
   c. `modifyLiquidity` on the add pool, `liquidityDelta > 0`, `salt = 0`. Its `callerDelta` also
      contains this position's **fees** (v4 credits fees on any modify): those fee amounts go to `idle`
      (they were already accounted by `_sync` step 2 — see §9.4 bookkeeping);
   d. `_pegOk` on both pools;
   e. settle / take with `CurrencySettler` patterns; check `msg.sender == poolManager`.
6. `added = Σ norm(amounts actually added as liquidity)`; leftovers of the deposit are refunded to
   `msg.sender`.
7. `fee = added × mintFeeBps / 10 000`; `out = added − fee`; `carry += fee`.
8. `require(out ≥ minOut)`; `token.mint(to, out)`.

Reverts if the swap or the add is impossible (out of range, breaker, share cap, slippage).

### 9.2 `burn(uint256 x, address to)` — instant path (`burnDelay == 0`)

1. `_sync()`.
2. `_collectAll()`: for each position with liquidity, `modifyLiquidity(0)` — v4 pays its fees; add them
   to `idle`. (One unlock for all positions.)
3. `D = totalSupply + totalUnclaimed + treasuryAccrued + carry`; `s = x / D` (WAD, round down).
4. Accrued of the holder: `a = token.consumeAccrued(msg.sender)` (paid in the same call). Total fraction
   `f = (x + a) / D`.
5. `token.burnFrom(msg.sender, x)`.
6. In one unlock: for each position remove `floor(L × f)`; take the tokens to `to`; also send
   `floor(idle[c] × f)` of every currency.
7. Re-add the remaining collected fees (`compound` of what is in `idle`) is **not** done here (gas); the
   keeper's `compound` does it.

If `burnDelay > 0`, `burn` reverts `UseRequestBurn`.

Gas target (Ethereum launch, 3 positions): ≤ 450k. One failing token transfer reverts the whole burn;
the user chooses `to`.

### 9.3 Delayed burn (`burnDelay > 0`)

- `requestBurn(uint256 x, address to) returns (uint256 id)`: settles and pays out the holder's accrued
  first (as `claim` does), then transfers `x` noUSD to the vault (excluded → stops accruing), pushes
  `{owner, to, x, readyAt = now + burnDelay}`.
- `executeBurns(uint256 n)` (anyone): processes up to `n` matured requests FIFO from `queueHead`, each
  exactly as §9.2 steps 1–6 with `a = 0` and burning from the vault's escrow. **The fraction is computed
  at execution**, never at request.
- `executeBurn(uint256 id)` (anyone): a single matured request, out of order.
- `cancelBurn(uint256 id)` (owner of the request, before execution): returns the noUSD; no accrual for
  the time in queue.
- Lowering `burnDelay` applies to new requests; existing ones keep `readyAt`.

### 9.4 `sync()` (anyone)

For every registered position with liquidity:
```
(fgi0, fgi1) = StateLibrary.getFeeGrowthInside(pm, id, tickLower, tickUpper)
d0 = L × (fgi0 − fg0Accounted) / 2^128 ;  d1 = likewise    // unchecked subtraction, as v4 does
fg0Accounted = fgi0 ; fg1Accounted = fgi1
F += norm(c0, d0) + norm(c1, d1)
```
- `L` is the vault's position liquidity (`getPositionInfo`). `fgXAccounted` is the vault's own record,
  **not** v4's `feeGrowthInsideLast` (which only moves on modify). After any `modifyLiquidity` the vault
  does not reset `fgXAccounted`: fees credited by v4 at that moment are the same fees `sync` counted.
- `F += carry; carry = 0`.
- `cut = F × protocolFeeBps / 10 000` → `token.accrueTreasury(cut)`; `token.distribute(F − cut)`.
- Update `outOfRangeSince` for each position from the current tick.
- If `now ≥ obs.newer.t + 1 day`: rotate `obs` with current `feeGrowthGlobal0/1` of each pool.
- No token transfers, no oracle, no swaps. Gas target: ≤ 60k + 40k per position.

`sync` runs inside mint, burn, claim, requestBurn, executeBurns, and by the keeper (hourly on L2,
daily on Ethereum).

### 9.5 `claim(address to) returns (uint256 paid)`

1. `_sync()`; `_collectAll()`.
2. `a = token.consumeAccrued(msg.sender)`; `f = a / D` (D as §9.2).
3. Pay `floor(L × f)` of every position and `floor(idle × f)` of every currency to `to`, in kind.
4. `claimTreasury(address to)` — same for `treasuryAccrued`, callable only by `treasury`.

Never delayed. Accrued does not compound.

### 9.6 `compound(PoolId id)` (anyone)

- Requires the position's uncollected fees (from §9.4 math, at par) + its pair's `idle` ≥
  `compoundThreshold`.
- One unlock: `modifyLiquidity(0)` to collect, then add as much of `idle[c0], idle[c1]` as fits the
  current ratio. No swap. Leftover stays in `idle`.

### 9.7 `recenter(PoolId id)` (anyone)

Conditions: pool `Active`; position out of range continuously for ≥ `recenterAfter`
(`outOfRangeSince != 0 && now − outOfRangeSince ≥ recenterAfter`, and out of range now);
`now − lastRecenter ≥ recenterCooldown`; `_pegOk(key)`.
Action (one unlock): remove all liquidity → `idle`; new range = registry preset width centered on the
current tick, rounded to `tickSpacing`; add as much as fits; **no swap**; leftover stays in `idle`.
`fgXAccounted` is re-initialized from `getFeeGrowthInside` of the new range **after** a `_sync()` done
first. Under depeg (`_atPar` false) recenter is impossible; governance retires the pool instead.

### 9.8 `reclassify(address a)` — forwards to the token (§5.3).

---

## 10. Events and errors (minimum)

Events: `Minted(minter, to, token, amountIn, added, fee, out, addPool, swapPool)`,
`Burned(owner, to, x, accruedPaid, fractionWad)`, `BurnRequested(id, owner, to, x, readyAt)`,
`BurnExecuted(id, fractionWad)`, `BurnCancelled(id)`, `Claimed(holder, to, value, fractionWad)`,
`Synced(value, cut, accPerShare)`, `Compounded(poolId, added0, added1)`,
`Recentered(poolId, oldLower, oldUpper, newLower, newUpper)`, `AccrualModeChanged(account, excluded)`,
registry `ChangeQueued/Executed/Cancelled`, `PoolStatusChanged`, `ParamChanged`.

Errors: `MintPaused`, `TokenNotMintable`, `NoPoolForToken`, `PegCheckFailed(poolId)`,
`OracleNoOpinion(poolId)`, `Slippage`, `UseRequestBurn`, `NotMatured`, `NotRecenterable`,
`BelowCompoundThreshold`, `CapExceeded`, `TimelockNotReady`, `NotPoolManager`.

---

## 11. Security notes

- **Inflation attack** does not apply: noUSD is minted for value added at par, not at a share price, and
  nobody can add to the vault's positions (a pool `donate` reaches the vault through `sync` as fees and
  is distributed normally).
- **Buy-before-sync**: profitable only after ~1.75 days without `sync` in a 0.01 % DEX pool for
  noUSD; hourly sync on L2 / daily on Ethereum keeps it unprofitable. Mint and burn always sync.
- **Par arbitrage inside `depegBps`**: bounded by `depegBps`; levers are `mintFeeBps` and `burnDelay`.
- **Transfer error of L**: between `sync`s the sender keeps the yield of the transferred amount;
  bounded by one sync interval of yield.
- **Reentrancy**: all external entry points `nonReentrant` (transient-storage guard). Token callbacks:
  admitted tokens are plain ERC-20s; the vault still follows checks-effects-interactions.
- **Recenter drain** (lesson from unisafe VolatileLPManager H-VOL-1): recenter never swaps and takes no
  caller input.
- **Oracle owner** is outside noUSD governance; the registry can replace the oracle address via the
  timelock.
- **Rounding** always against the caller; `uint128` balance overflow reverts.

---

## 12. Launch configuration

Only existing hookless v4 pools; tokens without a pool are not admitted; the registry decides which
pools are Active. Data as of 2026-11-24 (Uniswap data.v2, Chainlink directory).

### Ethereum (1) — initial deployment

| Pair | fee (pips) | tickSpacing | poolId | TVL | apr7d | Launch status |
|---|---|---|---|---|---|---|
| USDe / USDC | 25 | 1 | `0x56fc29b86900aa0afa6e20b020429bffba1105cfb45070492c67529b46eb48c1` | $861k | 10.8 % | Active |
| DAI / USDT | 68 | 1 | `0xf6e8088529094bc485561fa2a03e3d19c9a60f5d99a997e8fe16ab4ca2db277a` | $596k | 1.5 % | Active |
| USDS / RLUSD | 5 | 1 | `0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f` | $50M | 0.17 % | registered, WithdrawOnly (low yield) |

Tokens: USDe `0x4c9EDD5852cd905f086C759E8383e09bff1E68B3`, USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`,
DAI `0x6B175474E89094C44Da98b954EedeAC495271d0F`, USDT `0xdAC17F958D2ee523a2206206994597C13D831ec7`,
USDS `0xdC035D45d973E3EC169d2276DDab16f1e407384F`, RLUSD `0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD`.
Oracle: `0xa5A1fF40a1F89F26Db124DC56ad6fD8aBb378f29` (feeds set for all except RLUSD; RLUSD/USD feed
`0x26C46B7aD0012cA71F2298ada567dC9Af14E7f2A` must be added by the oracle owner before USDS/RLUSD goes
Active). Note: USDT is not standard ERC-20 (no return value) — use SafeERC20 everywhere.

### L2s — own pair set per chain, from existing pools only

| Chain | Candidates (hookless v4) | Oracle | Notes |
|---|---|---|---|
| Arbitrum (42161) | USDC/USDT0 fee 8 ($543k, 5.3 %); DAI/USDT0 fee 100 ($22k) | `0x4F59E6454462C9d3851D4B4126DC200FE6209e2D` | feeds for USDC/USDT/DAI wired; heartbeat 255 s |
| Base (8453) | none of the launch pairs; survey before deploy | `0x0A55A8e0Ee3d58e8D7d82803d70092903c593a96` | |
| Unichain (130) | USDC/USDT0 fee 100 ($151k, 1.3 %) | `0xfE56c2A6cA650F88D8F5bE6b4F18667C91d259b7` | no USDT/USD feed → mint closed (oracle no opinion) |

Each L2 deployment's pool list is fixed at deploy time from a fresh survey; the spec does not
depend on it.

---

## 13. Stack and repository

- Foundry, solc 0.8.26, `evm_version = "cancun"`, optimizer on, `via_ir = false` unless size forces it,
  `ffi = false`. Same pins as `uniswap-smart-wallet` (v4-core, v4-periphery `LiquidityAmounts` only,
  OZ 5.x).
- `IPriceOracle` copied as an interface file (MIT) with a header pointing to its origin; no submodule
  dependency on `uniswap-smart-wallet`.
- Layout: `src/NoUSD.sol`, `src/NoUSDVault.sol`, `src/NoUSDRegistry.sol`, `src/lib/*`,
  `src/interfaces/*`, `test/`, `script/Deploy.s.sol` + `script/config/<chainId>.json`.
- CI (GitHub Actions): `forge fmt --check` → `forge build --sizes` → `forge test -vvv`; fork tests
  env-gated (`ETH_RPC`, `ARB_RPC`, …) and skipped without RPC.

## 14. Tests (acceptance)

Unit / fuzz:
- Accumulator: worked example of the vision (Alice 600k, Bob 400k, transfer 200k to Carol at 12:00,
  sync F = $100 at 24:00, Carol burns, Bob claims) reproduces 40 / 40 / 20.
- Transfer settles both sides; self-transfer; excluded ↔ accruing transfers keep `excludedSupply`.
- Accrual modes: EOA, contract, 7702 designator, opt-in/out, `reclassify` both directions.
- `consumeAccrued` leaves 1 wei; `uint128` overflow reverts.
- Registry: caps enforced; tightening immediate; loosening only after 48 h; cancel.
- Delayed burn: fraction at execution; cancel; FIFO and out-of-order; no accrual in queue.
- Recenter: all conditions, cooldown, no swap, refused under depeg / no oracle opinion.

Invariants (handler-based):
- Σ balances = `totalSupply`; Σ excluded balances = `excludedSupply`.
- `totalUnclaimed` = Σ pendingAccrued over holders (± rounding).
- value(body) ≥ totalSupply + totalUnclaimed + treasuryAccrued + carry − ε (no value created).
- No sequence of calls by a non-owner reduces another holder's withdrawable share except through fees
  and price movement inside range.

Fork (Ethereum, env-gated): mint with each launch token, burn, claim, sync, compound against the real
pools and the real unisafe oracle; oracle no-opinion path with a mocked stale feed; gas snapshot for
transfer (target ≤ 37k warm / ≤ 47k first after sync), sync, mint, burn.

## 15. Open items that do not block implementation

- Final L2 pool lists (deploy-time survey).
- RLUSD feed in the unisafe oracle (owner action) before USDS/RLUSD goes Active.
- Transfer of the oracle's ownership to the Safe — later, owner's decision.
- Keeper service and alerts (spec of the off-chain part is separate).
