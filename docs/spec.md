# noUSD — specification v1.1

Status: **ready for implementation**, 2026-11-25 (v1.1: spec review — see the change list at the end).
Source of truth for the contracts. Rationale and the history of each decision live in
[`vision.md`](vision.md) (decision log) and [`nousd-model.ru.html`](nousd-model.ru.html) (diagrams,
Russian). Where this file and those differ, this file wins.

Keywords MUST / SHOULD / MAY are used in the RFC 2119 sense.

---

## 1. What noUSD is

noUSD is an ERC-20 stablecoin backed by one shared pool of stable/stable liquidity on Uniswap v4,
held by a single contract, `NoUSDPositionManager` ("the manager").

- **Unit.** 1 noUSD = 1 unit of the stable basket of its chain, not 1 USD. All admitted stables are
  counted at par with each other (1 USDC = 1 USDT = 1 DAI …), normalized to 18 decimals.
- **Mint.** Anyone deposits one admitted stable; the manager pairs it with its idle balance of the other
  currency and/or swaps part of it inside a registered pool, adds liquidity in one transaction, and the
  minter receives noUSD equal to the value **the minter** contributed at par. No "waiting for deploy"
  state for deposits. If the swap or the add is impossible, the call reverts.
- **Burn.** A holder burns noUSD and receives, in kind, a pro-rata share of every position and of the
  manager's idle balances, plus their accrued fees. Burn can be delayed by a parameter but never blocked
  by the protocol. (A token that refuses to pay a particular recipient reverts the call with
  `PayoutFailed`; the holder picks another `to`.)
- **Yield.** Pool fees are distributed through an accumulator inside the token (variant **L**): the
  counter moves only on `sync()`, every transfer checkpoints both sides. Holders take accrued fees with
  `claim()`, paid in stables, without burning.
- **No operator.** No address can move funds. Every maintenance call (`sync`, `compound`, `applyRange`,
  `executeBurns`, `reclassify`, `burnStray`) is permissionless; the contracts check the conditions. A
  keeper only makes sure the calls happen.
- **Immutable.** No proxies. Every tunable is a parameter with a hard cap in code. A bug fix is a new
  deployment; holders migrate by burn → mint.
- **Per chain.** Each chain has its own independent deployment (registry, manager, token) and its own
  basket. No bridging of noUSD in v1. noUSD on chain A is not fungible with noUSD on chain B.

### Non-goals for v1

- PSM hook / hard 1:1 floor (stage 2; the floor is held by burn).
- A second "active" manager with an operator and narrow ranges.
- Cross-chain noUSD.
- Creating Uniswap pools. The manager only uses **existing** hookless v4 pools.
- Automatic recentering of positions (see §9.7: for stables "out of range" means depeg).
- First-deposit (inflation) protection: not needed, see §11.

---

## 2. Contracts

| Contract | Role | Owner |
|---|---|---|
| `NoUSD` | ERC-20 with the fee accumulator and accrual modes. Only the manager can mint, burn, move the counter and consume accrued. Name and symbol `noUSD`. | none (`manager` address immutable) |
| `NoUSDPositionManager` | Owns every v4 position (it is the `owner` in `modifyLiquidity`), implements `IUnlockCallback`. Mint, burn (instant and delayed), claim, sync, compound, applyRange, retire. | none — reads parameters from the registry |
| `NoUSDRegistry` | Admitted tokens, registered pools and their status, parameters with caps, oracle address, treasury, governance delays. | Safe 2-of-3 |

Not to be confused with Uniswap's v4-periphery `PositionManager` (ERC-721 positions), which noUSD does
not use: the manager talks to `PoolManager` directly.

Deployment order: registry → manager (registry, PoolManager, token address precomputed) → token
(manager) → `registry.setManager(manager)` (once). The token's `manager`, the manager's `token` /
`registry` / `poolManager` are `immutable`. The registry stores the manager address once, to call
`retire` (§4.2).

External dependency: the **unisafe price guard** (`IPriceOracle`, implementation `ChainlinkPriceOracle`
from the `uniswap-smart-wallet` repo), used only through its interface, by address (§7). Its ownership
stays with its current owner; the registry can switch the address (loosening → timelock).

Size: EIP-170 (24 576 B) applies. Keep the manager's heavy math in internal libraries; if it still does
not fit, move cold paths (delayed burn queue, applyRange) to **external libraries** linked at deploy, not
to a second stateful contract. Measure with `forge build --sizes` and keep ≥ 1 KB headroom.

---

## 3. Units and decimals

- Every admitted token has `decimals ≤ 18`; the registry stores `scale = 10**(18 − decimals)`.
- `norm(token, amount) = amount × scale`. noUSD has 18 decimals.
- "Value at par" of a set of token amounts = Σ `norm`. No price is ever applied to value.
- Rounding: **always against the caller** (mint rounds down, burn/claim payouts round down, amounts
  owed to the manager round up). Use `FullMath.mulDiv` / `mulDivRoundingUp`.

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
responsibility; the manager does not defend against them). At launch `mintable` is set for the tokens of
Active pools that have a feed in the oracle.

### 4.2 Pools

```solidity
enum PoolStatus { None, Active, WithdrawOnly }
struct PoolConfig {
    PoolKey key;          // hooks MUST be address(0); both currencies admitted
    int24 tickLower;      // range preset around par (wide, ±1–2 %), multiple of tickSpacing
    int24 tickUpper;
    uint16 maxShareBps;   // our liquidity / pool liquidity cap, ≤ MAX_POOL_SHARE_BPS
    uint16 weight;        // tie-break weight in pool selection
    PoolStatus status;
}
PoolId[] public poolIds;  // length ≤ MAX_POOLS
```

- One position per registered pool. `salt = bytes32(0)`; the position is keyed by the manager, the pool
  and its range. The range is the registry preset; it changes only through `applyRange` (§9.7) after a
  timelocked preset change.
- `MAX_POOLS = 8` (code constant). In practice the number of pools ≤ number of admitted stables.
- **Active**: used by mint selection, sync, compound, applyRange, burn, claim.
- **WithdrawOnly**: excluded from mint selection; burn/claim/sync/compound still touch it. Setting a
  pool to WithdrawOnly is immediate (tightening). Setting a pool Active, adding a pool, changing its
  range preset, or raising its share cap is loosening (timelock).
- `retirePool(poolId)` (governance, immediate): the registry calls `manager.retire(poolId)`
  (only the registry may call it), which runs `_sync()` first, then removes all liquidity of that
  position to the manager's idle balances; the registry marks the pool WithdrawOnly. Idle balances are
  paid out pro-rata by burn/claim and redeployed by mint pairing (§9.1) and compound.
- Removing a pool from `poolIds` is allowed only when its position liquidity is 0 and it holds no
  accounted-but-uncollected fees.

### 4.3 Parameters

All in one struct, read by the manager each call (one `SLOAD` group). Caps are `constant` in code.

| Parameter | Cap in code | Launch value | Notes |
|---|---|---|---|
| `burnDelay` | 7 days | 0 | §9.3 |
| `mintFeeBps` | 50 | 0 | fee stays in the manager, distributed to holders on next `sync` |
| `protocolFeeBps` | 1 000 (10 %) | 0 | share of collected fees, to treasury accrual |
| `depegBps` | 1 … 200 | 50 | max \|spot − par\| for mint, compound, applyRange |
| `supplyCap` | — | per chain, e.g. 100 000e18 | max `totalSupply` after a mint; burn is unaffected |
| `maxPoolShareBps` (default for new pools) | 5 000 | 3 000 | |
| `compoundThreshold` | — | chain-specific, e.g. 5e18 on L2, 500e18 on Ethereum | per position, value at par |
| `selectionWindow` | 1 … 30 days | 7 days | fee-yield window for pool selection (§8) |
| `oracle` | — | unisafe `ChainlinkPriceOracle` address of the chain | `IPriceOracle` |
| `treasury` | — | Safe | receives protocol-fee accrual |

Staleness, sequencer uptime and the spot-vs-reference tolerance are **owned by the oracle** (its
per-feed heartbeat, sequencer feed, `maxSpotDeviationBps`); the manager does not duplicate them.

### 4.4 Governance and delays

- Owner: Safe 2-of-3 (`Ownable2Step`).
- **Tightening is immediate**: lower `depegBps`, pool → WithdrawOnly, `retirePool`, token
  `mintable = false`, lower share caps, lower `supplyCap`, raise `compoundThreshold`, `pauseMint()`.
- **Hurts holders → timelock both ways**: `burnDelay` and `mintFeeBps` (raising them is "tightening" for
  the protocol but loosening against holders' expectations), so both directions go through the queue.
- **Everything else is loosening** and goes through an in-contract queue: `queue(bytes data)` stores
  `eta = now + 48 h` under `keccak256(data)`; `execute(data)` after `eta`; `cancel(hash)`.
  `TIMELOCK = 48 hours` is a code constant. Every change emits an event with old and new values.
  This includes changing `oracle` or `treasury`, adding a pool/token, pool → Active, a range preset,
  raising `protocolFeeBps`, `supplyCap` or a share cap, `selectionWindow`, `unpauseMint()`.
- There is **no pause of burn or claim**.

---

## 5. NoUSD token

### 5.1 Storage

```solidity
// slot A per holder
struct Account {
    uint128 balance;
    uint120 checkpoint;   // accPerShare at last touch (see 5.2)
    uint8   flags;        // bit0 = excluded, bit1 = classified, bit2 = manual (mode chosen by the holder)
}
mapping(address => Account) internal _accounts;
mapping(address => uint256) public accrued;      // slot B, value at par (18 dec)
mapping(address => mapping(address => uint256)) public allowance;

uint256 public totalSupply;
uint256 public excludedSupply;   // Σ balance of excluded accounts
uint256 public accPerShare;      // value per 1e18 noUSD, scaled by ACC_SCALE = 1e18 (see 5.2)
uint256 public totalUnclaimed;   // Σ accrued + not-yet-checkpointed earnings, value at par
uint256 public treasuryAccrued;  // protocol-fee accrual, value at par
address public immutable manager;
```

- ERC-20 plus the signature standards of §5.6. Written by hand on top of OZ 5.x interfaces (do **not** subclass OZ
  `ERC20`: its `_balances` cannot hold the packed layout). Run an ERC-20 property suite against it.
- `balance` is `uint128`: supply above 3.4e20 noUSD is impossible by construction; `_mint` MUST revert
  if it would overflow.

### 5.2 Accumulator

- `accPerShare` grows only in `distribute(uint256 value) returns (uint256 remainder)` (onlyManager,
  called by `sync`):
  - `eligible = totalSupply − excludedSupply`;
  - if `eligible == 0`: `treasuryAccrued += value`, `remainder = 0`;
  - else `delta = value × ACC_SCALE / eligible` (round down); `accPerShare += delta`;
    `distributed = delta × eligible / ACC_SCALE` (**round up**: holders settle with a floor over spans
    that may cover several distributions, so a floored total could fall below their sum and make a
    later `consumeAccrued` underflow; `distributed ≤ value` because `delta` is floored);
    `totalUnclaimed += distributed`;
    `remainder = value − distributed`. The manager adds `remainder` to `carry` (§6), so dust is
    distributed by a later `sync`.
- `checkpoint` is stored as `uint120`. `accPerShare` MUST fit: with ACC_SCALE = 1e18, 2^120 ≈ 1.3e36
  allows 1.3e18 value units per 1e18 noUSD — unreachable. Revert in `distribute` if exceeded.
- **Settle** an account (`_settle(a)`), used on every balance change and on `claim`:
  ```
  if (!excluded(a)) accrued[a] += balance(a) × (accPerShare − checkpoint(a)) / ACC_SCALE
  checkpoint(a) = accPerShare
  ```
  Skip the `accrued` write when the delta is 0. Never write `accrued` from non-zero to exactly 0:
  `consumeAccrued` leaves 1 wei (gas: avoids a 20k re-init).
- `totalUnclaimed −= paid` in `consumeAccrued`.
- **Transfer**: `_settle(from); _settle(to);` then move balances; maintain `excludedSupply` if exactly
  one side is excluded. Self-transfer settles once.

### 5.3 Accrual modes (Blast-style)

- An address is classified lazily, the first time it receives noUSD (`classified` flag unset):
  - `code.length == 0` → EOA → accrues.
  - code is an EIP-7702 delegation designator (`code.length == 23` and starts with `0xef0100`) →
    treated as EOA → accrues.
  - otherwise (a contract) → **excluded** unless it has opted in.
- `configureAccrual(bool on)`: called by the address itself; a contract opts in (`on = true`) or out.
  An EOA MAY opt out. Settles before switching; moves its balance in/out of `excludedSupply`; sets
  `manual`, after which `reclassify` leaves the address alone.
- `reclassify(address a)` (anyone): no-op if `a` is `manual`. Otherwise, if `a` now has real code
  (non-7702), mark it excluded (settle first; what it accrued stays claimable); if it has no code or a
  7702 designator, mark it accruing. No-op when the mode does not change. (An "opted-in" bit alone would
  let `reclassify` undo an EOA's own opt-out.)
- Contracts under construction (`code.length == 0` in constructor) are classified as EOA; `reclassify`
  fixes it later. The manager itself is excluded (it holds the burn-queue escrow).

### 5.4 Manager-only functions

```solidity
function mint(address to, uint256 amount) external;                 // settle(to) first
function burnFrom(address from, uint256 amount) external;           // settle(from) first; holder or manager escrow
function distribute(uint256 value) external returns (uint256 remainder);
function consumeAccrued(address a) external returns (uint256 paid); // settle(a); paid = accrued[a] − 1
function accrueTreasury(uint256 value) external;                    // protocol fee share
function consumeTreasury() external returns (uint256 paid);         // paid = treasuryAccrued; zeroes it
```

`consumeAccrued` settles `a`, takes `accrued[a] − 1` (0 if `accrued[a] ≤ 1`), decreases
`totalUnclaimed` by it and returns it.

### 5.5 Views

`pendingAccrued(a)` = `accrued[a] + balance × (accPerShare − checkpoint) / ACC_SCALE` (0 term if
excluded). `isExcluded(a)`, `eligibleSupply()`.

### 5.6 Standards and gasless transfers

| Standard | In v1 | Notes |
|---|---|---|
| ERC-6093 | yes | OZ `IERC20Errors` custom errors |
| EIP-2612 `permit` | yes | sequential nonces (OZ `Nonces`); extra overload with `bytes signature` (as USDC v2.2) |
| EIP-3009 transfer / receive / cancel with authorization | yes | USDC semantics: random `bytes32` nonces, each used once (`authorizationState`); nonces separate from permit; `receiveWithAuthorization` only by the payee; x402-compatible |
| ERC-7598 | yes | `bytes signature` overloads of the EIP-3009 functions |
| ERC-1271 | yes | for permit and EIP-3009: ECDSA is tried first, then ERC-1271 if the signer has code — OZ `SignatureChecker` alone would reject plain key signatures of EIP-7702 delegated EOAs |
| ERC-5267 `eip712Domain()` | yes | OZ `EIP712`, domain name `noUSD`, version `1`, chain id, token address |
| ERC-3156 flash mint | **no** | a loan inflates eligible supply; a `sync` inside it would hand the borrower part of the distribution |
| ERC-1363, ERC-7674, ERC-7802 / bridgeable, built-in Permit2 allowance | no | little use, extra surface; no bridging in v1; an immutable token cannot revoke a Permit2 bug |

Every signed transfer goes through the same `_transfer` (settle both sides, lazy classification of `to`).
OZ 5.7's `ERC20TransferAuthorization` is not used as a model: it reads the nonce as keyed-sequential,
which rejects the random nonces USDC/x402 clients send.

---

## 6. Manager state

```solidity
struct Position {
    int24 tickLower; int24 tickUpper;   // current range of this pool's position
    uint256 fg0Accounted;               // feeGrowthInside0X128 already turned into accPerShare
    uint256 fg1Accounted;
}
mapping(PoolId => Position) public positions;

struct Obs { uint64 t; uint256 fg0; uint256 fg1; }   // feeGrowthGlobal points for selection
mapping(PoolId => Obs[2]) public obs;                 // [older, newer], rotated by sync every selectionWindow

mapping(Currency => uint256) public idle;            // manager-held tokens counted in the body
uint256 public carry;                                // undistributed value (dust, mint fees)

struct BurnRequest { address owner; address to; uint128 amount; uint64 readyAt; uint128 minOut; bool done; }
BurnRequest[] public burnQueue; uint256 public queueHead;
uint256 public escrowed;                             // noUSD held by the manager for pending requests
```

**Body** = all position liquidity + `idle` + uncollected fees. Invariant (at par, up to rounding and
in-range composition drift):

```
value(body) ≈ totalSupply + totalUnclaimed + treasuryAccrued + carry
```

No function values the body with a price. Mint values what the minter actually added; burn and claim
pay a **fraction** of every position and of idle; sync values fee amounts at par.

When a position is first created (first add at its range), `fgXAccounted` is set to
`getFeeGrowthInside` of that range in the same call.

---

## 7. Oracle and peg checks

The unisafe guard `IPriceOracle.check(PoolKey key, bool zeroForOne, uint256 amountIn, uint256 amountOut)`
with `amountIn = 0` judges the pool's spot (`slot0`) against the ratio of the two Chainlink USD feeds
(`usd0 / usd1` — the dollar cancels, so it is a relative stable/stable reference). It:
- reverts `SpotPriceOutOfBounds` if spot deviates more than its `maxSpotDeviationBps`;
- returns `true` if it had fresh references and the spot is in bounds;
- returns `false` (no opinion) when a feed is missing/stale/pinned or the L2 sequencer is down / in grace.

The manager defines:

```
_spotVouched(key)  := oracle.check(key, false, 0, 0) == true   // reverts propagate; false → OracleNoOpinion
_atPar(key)        := |spotPrice(key) − 1| ≤ depegBps            // price of currency1 per currency0, normalized
_pegOk(key)        := _spotVouched(key) && _atPar(key)
```

- **Mint** requires `_pegOk` on the pool it swaps in and the pool it adds to, checked **after** the swap
  and the add, inside the unlock callback (so the final state is judged).
- **applyRange** requires `_pegOk` before acting.
- **Compound** requires `_atPar` (spot only, no oracle) before adding: adding liquidity at a manipulated
  price is a sandwich target; `_atPar` bounds the loss to second order in `depegBps`.
- **Burn, claim, sync, compound never call the oracle.** Burn and claim are in-kind and protected by
  the caller's `minOut`; sync counts real amounts.
- Why the external reference is needed although value is at par: a v4 spot can be moved inside one
  transaction (flash loan) almost for free; hookless v4 pools keep no TWAP. Chainlink only proves the
  spot is not manipulated; the depeg decision itself is the Uniswap spot vs par.
- Unichain-like case (no feed for a token): `check` returns `false` → mint through that pool is closed;
  burn/claim work. Fail-closed, no special code.

---

## 8. Pool selection on mint (hybrid)

Input: deposit token `t`. Candidates: `Active` pools that contain `t`, whose current tick is inside the
position's range, whose `ourLiquidity / poolLiquidity < maxShareBps`, and where `t.mintable`.

Score per candidate (on-chain, from `obs`):
```
feeYield = Δ(feeGrowthGlobal0 + feeGrowthGlobal1, normalized) over [obs.older.t, now] per unit liquidity
score    = feeYield × L_pool / (L_pool + L_ours + L_new) × weight      // L_new estimated from the deposit
```
Pick the max score; ties → lower index. If no candidate: revert `NoPoolForToken`.

- **Add pool** = the chosen pool. **Swap pool** = the registered `Active` pool with the same pair and the
  lowest fee (may be the add pool itself). With disjoint pairs (the Ethereum launch set) they coincide.
- `obs` rotation happens in `sync` (§9.4): when `now ≥ obs.newer.t + selectionWindow`, `older = newer`
  and `newer` = current `feeGrowthGlobal0/1`. The effective window is between `selectionWindow` and
  `2 × selectionWindow`. Until a pool has an `older` point its `feeYield` is 0 and it is chosen only if it
  is the sole candidate.
- The share cap is also enforced **after** the add (§9.1): a mint that would push our share above
  `maxShareBps` reverts `CapExceeded`.

---

## 9. Manager functions

All external entry points are `nonReentrant`. Functions taking `deadline` revert `Expired` if
`block.timestamp > deadline`. Payouts in burn/claim are taken from the PoolManager into the manager and
then transferred to `to`; a token transfer that fails reverts the whole call with
`PayoutFailed(token, to)` — the caller should retry with another `to` (e.g. a blacklisted recipient). A
paused token blocks burn until it is unpaused; that is the token's property, not the protocol's.

### 9.1 `mint(Currency token, uint256 amount, uint256 minOut, address to, uint256 deadline) returns (uint256 out)`

1. Checks: deadline; not `mintPaused`; `tokens[token].mintable`; `amount > 0`.
2. `_sync()` (§9.4) — accrual is up to date before the supply changes.
3. Pull `amount` from `msg.sender` (`transferFrom`, SafeERC20).
4. Select pools (§8). Let `u` be the other currency of the add pool.
5. `poolManager.unlock(data)` → in the callback:
   a. **Pair with idle.** From the add position's ratio at the current price (`LiquidityAmounts`),
      compute `need_u` — the amount of `u` that pairs with the whole deposit. Take
      `k = min(idle[u], need_u)` from `idle[u]`. If `k == need_u`, no swap.
   b. Otherwise compute the swap amount `s` so that `amount − s` of `t` and `k + swapOut` of `u` fit
      the ratio (`LiquidityAmounts` + one-step correction; leftover allowed) and `swap` in the swap pool
      (exact input `s`, `sqrtPriceLimit` = depeg bound).
   c. `modifyLiquidity` on the add pool, `liquidityDelta > 0`, `salt = 0`. Its `callerDelta` also
      contains this position's **fees** (v4 credits fees on any modify): those fee amounts go to `idle`
      (they were already accounted by `_sync` in step 2 — see §9.4).
   d. `_pegOk` on both pools; share cap of the add pool after the add.
   e. settle / take with `CurrencySettler` patterns; check `msg.sender == poolManager`.
6. `added = Σ norm(amounts added as liquidity) − norm(k)` — only the minter's contribution (the idle
   `k` already belonged to holders). Leftovers of the minter's tokens (in `t` or `u`) are refunded to
   `msg.sender`.
7. `fee = added × mintFeeBps / 10 000`; `out = added − fee`; `carry += fee`.
8. `require(out ≥ minOut)`; `require(totalSupply + out ≤ supplyCap)`; `token.mint(to, out)`.

Reverts if the swap or the add is impossible (out of range, breaker, share cap, supply cap, slippage).
Pairing with idle costs the minter no swap fee and is value-neutral for holders at par.

### 9.2 `burn(uint256 x, address to, uint256 minOut, uint256 deadline)` — instant path (`burnDelay == 0`)

1. Deadline; `_sync()`.
2. `D = totalSupply + totalUnclaimed + treasuryAccrued + carry`, computed **before** steps 3–4.
3. Accrued of the holder: `a = token.consumeAccrued(msg.sender)` (paid in the same call). Fraction
   `f = (x + a) / D` (WAD, round down).
4. `token.burnFrom(msg.sender, x)`.
5. One unlock: for each position with liquidity, `modifyLiquidity(−floor(L × f))` — the delta includes
   all the position's uncollected fees; fees go to `idle` first, then the principal removed plus
   `floor(idle[c] × f)` of every currency are taken to the manager.
6. Transfer the payout to `to` per currency (`PayoutFailed` on failure). `require(Σ norm(paid) ≥ minOut)`
   else `Slippage`.
7. Remaining collected fees stay in `idle`; the keeper's `compound` re-adds them.

If `burnDelay > 0`, `burn` reverts `UseRequestBurn`.

Gas target (Ethereum launch, 3 positions): ≤ 500k.

### 9.3 Delayed burn (`burnDelay > 0`)

- `requestBurn(uint256 x, address to, uint256 minOut) returns (uint256 id)`: transfers `x` noUSD from the
  holder to the manager (settles the holder; their accrued stays claimable with `claim`; the escrow is
  excluded and stops accruing); `escrowed += x`; pushes
  `{owner, to, x, readyAt = now + burnDelay, minOut}`.
- `executeBurns(uint256 n)` (anyone): one `_sync()`, then processes up to `n` matured, not-done requests
  FIFO from `queueHead`, each as §9.2 steps 2, 5, 6 with `a = 0`, burning from the escrow
  (`escrowed −= x`). **The fraction is computed at execution**, never at request. A request whose
  execution fails (`Slippage` or `PayoutFailed`) is **skipped** (event `BurnSkipped`) and stays pending;
  `queueHead` advances only over done requests.
- `executeBurn(uint256 id)` (anyone): a single matured request, out of order; reverts on failure.
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
- `L` is the manager's position liquidity (`getPositionInfo`). `fgXAccounted` is the manager's own
  record, **not** v4's `feeGrowthInsideLast` (which only moves on modify). After any `modifyLiquidity`
  the manager does not reset `fgXAccounted`: fees credited by v4 at that moment are the same fees
  `sync` counted. Every function that changes `L` runs `_sync()` first.
- `F += carry; carry = 0`.
- `cut = F × protocolFeeBps / 10 000` → `token.accrueTreasury(cut)`;
  `carry += token.distribute(F − cut)` (the remainder).
- Rotate `obs` of each pool if `now ≥ obs.newer.t + selectionWindow` (§8).
- No token transfers, no oracle, no swaps. Gas target: ≤ 60k + 40k per position.

`sync` runs inside mint, burn, claim, executeBurns, compound, applyRange, retire, and by the keeper
(hourly on L2, daily on Ethereum).

### 9.5 `claim(address to, uint256 minOut, uint256 deadline) returns (uint256 paid)`

1. Deadline; `_sync()`; `D` as §9.2 step 2.
2. `a = token.consumeAccrued(msg.sender)`; `f = a / D`.
3. Pay `floor(L × f)` of every position (one unlock, fees to idle as in §9.2) and `floor(idle × f)` of
   every currency to `to`, in kind; `minOut` on Σ norm.
4. `claimTreasury(address to, uint256 minOut, uint256 deadline)` — same for `consumeTreasury()`,
   callable only by `treasury`.

Never delayed. Accrued does not compound.

### 9.6 `compound(PoolId id)` (anyone)

- `_sync()`. Requires the position's uncollected fees (from §9.4 math, at par) + its pair's `idle` ≥
  `compoundThreshold`, and `_atPar(key)`.
- One unlock: `modifyLiquidity(0)` to collect, then add as much of `idle[c0], idle[c1]` as fits the
  current ratio. No swap. Leftover stays in `idle` (and is later paired by mint, §9.1).

### 9.7 `applyRange(PoolId id)` (anyone) — no automatic recenter

Positions sit at the registry preset around par. For stable/stable pools leaving a ±1–2 % range means
the spot is already further from par than `depegBps`, so recentering onto the current tick would chase a
depeg; v1 does not do it. An out-of-range position is skipped by mint selection and waits for the price
to return, or governance retires the pool.

A range is changed only by governance: a new preset in the registry (timelock), then `applyRange(id)`:
- Conditions: pool `Active`; the position's range differs from the registry preset; `_pegOk(key)`.
- Action: `_sync()`; one unlock: remove all liquidity → `idle`; add as much as fits at the preset range;
  **no swap**; leftover stays in `idle`. `fgXAccounted` is initialized from `getFeeGrowthInside` of the
  new range.

### 9.8 `reclassify(address a)` — forwards to the token (§5.3).

### 9.9 `burnStray()` (anyone)

noUSD sent to the manager by plain `transfer` (balance above `escrowed`) has no owner. `burnStray`
burns `balanceOf(manager) − escrowed` without payout: the body stays, so it is a donation to holders.

---

## 10. Events and errors (minimum)

Events: `Minted(minter, to, token, amountIn, added, idleUsed, fee, out, addPool, swapPool)`,
`Burned(owner, to, x, accruedPaid, fractionWad)`, `BurnRequested(id, owner, to, x, readyAt, minOut)`,
`BurnExecuted(id, fractionWad)`, `BurnSkipped(id, reason)`, `BurnCancelled(id)`,
`Claimed(holder, to, value, fractionWad)`, `Synced(value, cut, accPerShare)`,
`Compounded(poolId, added0, added1)`, `RangeApplied(poolId, oldLower, oldUpper, newLower, newUpper)`,
`Retired(poolId)`, `StrayBurned(amount)`, `AccrualModeChanged(account, excluded)`,
registry `ChangeQueued/Executed/Cancelled`, `PoolStatusChanged`, `ParamChanged`.

Errors: `MintPaused`, `TokenNotMintable`, `NoPoolForToken`, `PegCheckFailed(poolId)`,
`OracleNoOpinion(poolId)`, `Slippage`, `Expired`, `SupplyCapExceeded`, `PayoutFailed(token, to)`,
`UseRequestBurn`, `NotMatured`, `RangeUnchanged`, `BelowCompoundThreshold`, `CapExceeded`,
`TimelockNotReady`, `NotPoolManager`, `NotRegistry`.

---

## 11. Security notes

- **Inflation attack** does not apply: noUSD is minted for value added at par, not at a share price, and
  nobody can add to the manager's positions (a pool `donate` reaches the manager through `sync` as fees
  and is distributed normally).
- **Buy-before-sync**: profitable only after ~1.75 days without `sync` in a 0.01 % DEX pool for
  noUSD; hourly sync on L2 / daily on Ethereum keeps it unprofitable. Mint and burn always sync.
- **Par arbitrage inside `depegBps`**: bounded by `depegBps`; levers are `mintFeeBps` and `burnDelay`.
  Idle pairing on mint does not widen it: the minter is credited only for their own tokens.
- **Sandwiching removals** (burn, claim, delayed burn): moving the price shifts the in-kind payout and
  lowers its value at par; the caller's `minOut` (stored in the request for delayed burn) bounds it.
- **Sandwiching adds**: mint is judged by `_pegOk` after the add; applyRange by `_pegOk`; compound by
  `_atPar`. The holders' loss is second order in the allowed deviation.
- **Transfer error of L**: between `sync`s the sender keeps the yield of the transferred amount;
  bounded by one sync interval of yield.
- **Reentrancy**: all external entry points `nonReentrant` (transient-storage guard). Admitted tokens
  are plain ERC-20s; the manager still follows checks-effects-interactions; payouts happen last.
- **No recenter drain** (lesson from unisafe VolatileLPManager H-VOL-1): no function swaps the body;
  `applyRange` takes no caller input and only moves to a timelocked preset.
- **Frozen recipient**: a token refusing a transfer reverts with `PayoutFailed(token, to)`; the holder
  retries with another `to`. A delayed request with a frozen `to` is skipped and can be cancelled.
- **Oracle owner** is outside noUSD governance; the registry can replace the oracle address via the
  timelock.
- **Guarded launch**: `supplyCap` limits exposure of the unaudited, immutable contracts.
- **Rounding** always against the caller; `uint128` balance overflow reverts.

---

## 12. Launch configuration

Only existing hookless v4 pools; tokens without a pool are not admitted; the registry decides which
pools are Active. Data as of 2026-11-24 (Uniswap data.v2, Chainlink directory). The PoolManager address
and the initial parameters per chain live in `script/config/<chainId>.json`.

### Ethereum (1) — initial deployment

| Pair | fee (pips) | tickSpacing | poolId | TVL | apr7d | Launch status |
|---|---|---|---|---|---|---|
| USDe / USDC | 25 | 1 | `0x56fc29b86900aa0afa6e20b020429bffba1105cfb45070492c67529b46eb48c1` | $861k | 10.8 % | Active |
| DAI / USDT | 68 | 1 | `0xf6e8088529094bc485561fa2a03e3d19c9a60f5d99a997e8fe16ab4ca2db277a` | $596k | 1.5 % | Active |
| USDS / RLUSD | 5 | 1 | `0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f` | $50M | 0.17 % | registered, WithdrawOnly (low yield) |

Tokens: USDe `0x4c9EDD5852cd905f086C759E8383e09bff1E68B3`, USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`,
DAI `0x6B175474E89094C44Da98b954EedeAC495271d0F`, USDT `0xdAC17F958D2ee523a2206206994597C13D831ec7`,
USDS `0xdC035D45d973E3EC169d2276DDab16f1e407384F`, RLUSD `0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD`.
Mintable at launch: USDe, USDC, DAI, USDT.
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
- Layout: `src/NoUSD.sol`, `src/NoUSDPositionManager.sol`, `src/NoUSDRegistry.sol`, `src/lib/*`,
  `src/interfaces/*`, `test/`, `script/Deploy.s.sol` + `script/config/<chainId>.json`.
- CI (GitHub Actions): `forge fmt --check` → `forge build --sizes` → `forge test -vvv`; fork tests
  env-gated (`ETH_RPC`, `ARB_RPC`, …) and skipped without RPC.

## 14. Tests (acceptance)

Unit / fuzz:
- Accumulator: worked example of the vision (Alice 600k, Bob 400k, transfer 200k to Carol at 12:00,
  sync F = $100 at 24:00, Carol burns, Bob claims) reproduces 40 / 40 / 20.
- `distribute` remainder goes to `carry` and is distributed later; nothing is lost.
- Transfer settles both sides; self-transfer; excluded ↔ accruing transfers keep `excludedSupply`.
- Accrual modes: EOA, contract, 7702 designator, opt-in/out, `reclassify` both directions.
- `consumeAccrued` leaves 1 wei; `uint128` overflow reverts.
- Registry: caps enforced; tightening immediate; loosening only after 48 h; cancel; `retire` only via
  the registry and syncs first.
- Mint: idle pairing (full, partial, none); minter credited without the idle part; share cap after add;
  `supplyCap`; deadline; leftovers refunded in both currencies.
- Burn/claim: `minOut`, deadline, `PayoutFailed` names the token and recipient.
- Delayed burn: fraction at execution; cancel; FIFO and out-of-order; no accrual in queue; a failing
  request is skipped and does not block the queue.
- `applyRange`: only after a preset change, refused under depeg / no oracle opinion; no swap.
- `compound` refused when not `_atPar`. `burnStray` burns only above `escrowed`.

Invariants (handler-based):
- Σ balances = `totalSupply`; Σ excluded balances = `excludedSupply`.
- `totalUnclaimed` = Σ pendingAccrued over holders (± rounding).
- With the pool price held fixed: value(body) ≥ totalSupply + totalUnclaimed + treasuryAccrued + carry − ε
  (no value created). Price moves inside the range are tested separately (bounded drift).
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
- Launch `supplyCap` value per chain.

---

## Changes in v1.1 (2026-11-25, spec review)

- `NoUSDVault` renamed to `NoUSDPositionManager`; the token's `vault` → `manager`.
- **Recenter removed** (§9.7): for stable pools out of range = depeg, and the old condition `_atPar`
  could never hold for an out-of-range position. Replaced by governance preset + permissionless
  `applyRange`. Parameters `recenterAfter`, `recenterCooldown` and position fields `outOfRangeSince`,
  `lastRecenter` removed.
- **Mint pairs the deposit with idle** of the other currency before swapping (§9.1); the minter is
  credited only for their own tokens. Idle from retire/compound leftovers is redeployed this way.
- **Slippage and deadline**: `minOut` + `deadline` on burn and claim, `deadline` on mint, `minOut` stored
  in delayed-burn requests; failing requests are skipped, not blocking.
- **`PayoutFailed(token, to)`**: payouts go through the manager; a refused transfer reverts with the
  token and recipient named.
- **`selectionWindow`** made real: `obs` rotate every window, not daily.
- **`supplyCap`** parameter (guarded launch).
- `retire` via the registry, with `_sync()` first; `distribute` returns its remainder to `carry`;
  `consumeAccrued(a)` / `consumeTreasury()` signatures; `fgXAccounted` initialized on position creation;
  share cap also checked after the add; mint leftovers refunded in both currencies; `D` fixed before
  consuming accrued; collect+remove in one modify; `requestBurn` no longer pays accrued (claim does);
  `compound` requires `_atPar`; `burnStray`; invariant tests with the price held fixed.
