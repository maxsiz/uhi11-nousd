// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {Position as V4Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {NoUSD} from "./NoUSD.sol";
import {NoUSDRegistry} from "./NoUSDRegistry.sol";
import {INoUSDPositionManager} from "./interfaces/INoUSDPositionManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {Book, BurnRequest, Obs, Position} from "./lib/ManagerTypes.sol";
import {BurnQueue} from "./lib/BurnQueue.sol";
import {PoolSelection} from "./lib/PoolSelection.sol";
import {PositionMath} from "./lib/PositionMath.sol";
import {SwapStep} from "./lib/SwapStep.sol";
import {Settlement} from "./lib/Settlement.sol";

/// @title NoUSDPositionManager
/// @notice Owns every Uniswap v4 position backing noUSD (docs/spec.md §6, §9). Mint adds a deposit to the
/// best pool in one transaction; burn and claim pay a fraction of every position and of the idle balances,
/// in kind; sync turns pool fees into the token's accumulator. Every maintenance call is permissionless
/// and condition-checked; no address can move funds.
/// @dev Not related to v4-periphery's PositionManager: this contract talks to PoolManager directly, owns
/// one position per registered pool (salt 0) and implements IUnlockCallback. Idle balances are held as
/// ERC-6909 claims on the PoolManager, so payouts go from the PoolManager straight to the recipient and
/// collecting fees costs no ERC-20 transfer. Every callback ends by resolving each currency's delta:
/// pay the recipient, and mint or burn claims for the rest (the change of idle).
contract NoUSDPositionManager is INoUSDPositionManager, IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    enum Action {
        Payout,
        Retire,
        Add, // test harness only
        Mint,
        Compound,
        ApplyRange
    }

    /// @dev Working state of the mint callback.
    struct MintState {
        bool tIs0; // the deposit token is currency0 of the add pool
        uint256 k; // idle of the other token paired with the deposit
        uint256 tLeft; // deposit left after the swap
        uint256 swapOut; // other token bought by the swap
    }

    /// @dev Outcome of the mint callback.
    struct MintResult {
        uint256 value; // minter's contribution at par, before the mint fee
        uint256 refundT; // deposit token returned
        uint256 refundU; // other token returned (swap output not used)
        Currency u;
    }

    NoUSD public immutable token;
    NoUSDRegistry public immutable registry;
    IPoolManager public immutable poolManager;

    mapping(PoolId => Position) public positions;
    /// @notice [older, newer] feeGrowthGlobal points, rotated by sync once per selectionWindow.
    mapping(PoolId => Obs[2]) internal _obs;
    /// @notice Idle balances counted in the body (collected fees, retired liquidity, leftovers), held as the
    /// manager's ERC-6909 claims on the PoolManager; with the currency list and decimals. Read with `idle`.
    Book internal _book;
    /// @notice Undistributed value at par: rounding remainders and mint fees, distributed by the next sync.
    uint256 public carry;
    /// @notice noUSD held for pending delayed-burn requests.
    uint256 public escrowed;

    BurnRequest[] internal _burnQueue;
    /// @notice First request that may still be pending; everything before it is done.
    uint256 public queueHead;

    event Minted(
        address indexed minter,
        address indexed to,
        Currency token,
        uint256 amountIn,
        uint256 value,
        uint256 fee,
        uint256 out,
        PoolId addPool,
        PoolId swapPool
    );
    event Synced(uint256 value, uint256 cut);
    event Burned(address indexed owner, address indexed to, uint256 x, uint256 accruedPaid, uint256 fractionWad);
    event BurnRequested(
        uint256 indexed id, address indexed owner, address to, uint256 x, uint256 readyAt, uint256 minOut
    );
    event BurnExecuted(uint256 indexed id, uint256 fractionWad);
    event BurnSkipped(uint256 indexed id, bytes reason);
    event BurnCancelled(uint256 indexed id);
    event Claimed(address indexed holder, address indexed to, uint256 value, uint256 fractionWad);
    event Compounded(PoolId indexed id, uint256 added0, uint256 added1);
    event RangeApplied(PoolId indexed id, int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper);
    event Retired(PoolId indexed id);
    event StrayBurned(uint256 amount);

    error ZeroAddress();
    error Expired();
    error MintPaused();
    error TokenNotMintable();
    error ZeroAmount();
    error SupplyCapExceeded();
    error CapExceeded();
    error PegCheckFailed(PoolId id);
    error OracleNoOpinion(PoolId id);
    error UseRequestBurn();
    error NotMatured();
    error AlreadyDone();
    error NotRequestOwner();
    error NotSelf();
    error Slippage(uint256 paid, uint256 minOut);
    error PayoutFailed(Currency token, address to);
    error BelowCompoundThreshold();
    error PoolNotActive();
    error RangeUnchanged();
    error NotPoolManager();
    error NotRegistry();
    error NotTreasury();

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @param token_ Address of the NoUSD token, precomputed: the token is deployed after the manager.
    constructor(NoUSD token_, NoUSDRegistry registry_, IPoolManager poolManager_) {
        if (address(token_) == address(0) || address(registry_) == address(0) || address(poolManager_) == address(0)) {
            revert ZeroAddress();
        }
        token = token_;
        registry = registry_;
        poolManager = poolManager_;
    }

    // ───────────────────────────── mint (spec §9.1) ─────────────────────────────

    /// @notice Deposits `amount` of an admitted stable and mints noUSD for the value it adds at par. In one
    /// transaction the deposit goes into the PoolManager, is paired with idle of the other currency, the
    /// rest swapped in the cheapest pool of the pair, and added to the best pool; both pools must be at par
    /// and vouched by the oracle. Leftovers are refunded. Reverts instead of leaving anything waiting.
    function mint(Currency t, uint256 amount, uint256 minOut, address to, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 out)
    {
        NoUSDRegistry.Params memory p = _params();
        if (p.mintPaused) revert MintPaused();
        if (!registry.tokens(t).mintable) revert TokenNotMintable();
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        _sync(p.protocolFeeBps, p.selectionWindow);

        (PoolId addId, PoolId swapId) = PoolSelection.select(positions, _obs, registry, poolManager, t, amount);
        MintResult memory r = abi.decode(
            _unlock(abi.encode(Action.Mint, abi.encode(addId, swapId, t, amount, msg.sender)), msg.sender), (MintResult)
        );

        uint256 fee = r.value * p.mintFeeBps / 10_000;
        out = r.value - fee;
        carry += fee;
        if (out < minOut) revert Slippage(out, minOut);
        if (token.totalSupply() + out > p.supplyCap) revert SupplyCapExceeded();
        token.mint(to, out);
        emit Minted(msg.sender, to, t, amount, r.value, fee, out, addId, swapId);
    }

    // ───────────────────────────── sync (spec §9.4) ─────────────────────────────

    /// @notice Turns the fees earned by every position since the last sync into the token's accumulator,
    /// valued at par, and rotates the pool-selection points. Moves no tokens. Anyone may call.
    function sync() external nonReentrant {
        NoUSDRegistry.CoreParams memory c = registry.coreParams();
        _sync(c.protocolFeeBps, c.selectionWindow);
    }

    // ───────────────────────────── burn and claim (spec §9.2, §9.5) ─────────────────────────────

    /// @notice Burns `x` noUSD and sends `to` the fraction (x + accrued) / D of every position and of the
    /// idle balances, in kind. Reverts with PayoutFailed if a token refuses `to`; pick another recipient.
    /// @param minOut Minimum total payout at par (18 decimals), against sandwiching.
    function burn(uint256 x, address to, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
    {
        NoUSDRegistry.CoreParams memory c = registry.coreParams();
        if (c.burnDelay != 0) revert UseRequestBurn();
        _sync(c.protocolFeeBps, c.selectionWindow);
        uint256 d = _denominator();
        uint256 a = token.consumeAccrued(msg.sender);
        token.burnFrom(msg.sender, x);
        _payout(x + a, d, to, minOut);
        emit Burned(msg.sender, to, x, a, FullMath.mulDiv(x + a, 1e18, d));
    }

    /// @notice Pays the caller's accrued fees in kind, as a fraction of every position and of idle.
    function claim(address to, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 paid)
    {
        _syncNow();
        uint256 d = _denominator(); // before consuming: D includes the claimed accrual (spec §9.2)
        paid = _claim(token.consumeAccrued(msg.sender), d, to, minOut);
    }

    /// @notice Pays the treasury's protocol-fee accrual, like `claim`. Only the treasury.
    function claimTreasury(address to, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 paid)
    {
        if (msg.sender != _params().treasury) revert NotTreasury();
        _syncNow();
        uint256 d = _denominator();
        paid = _claim(token.consumeTreasury(), d, to, minOut);
    }

    // ───────────────────────────── delayed burn (spec §9.3) ─────────────────────────────

    /// @notice Escrows `x` noUSD for a burn executable after `burnDelay`. The escrow stops accruing; what
    /// the holder accrued so far stays claimable. The fraction is computed at execution.
    function requestBurn(uint256 x, address to, uint256 minOut) external nonReentrant returns (uint256 id) {
        if (x == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        token.pullToManager(msg.sender, x);
        escrowed += x;
        id = BurnQueue.push(_burnQueue, msg.sender, to, x, minOut, registry.coreParams().burnDelay);
    }

    /// @notice Executes up to `n` matured requests FIFO from the queue head. A request that fails
    /// (Slippage, PayoutFailed) is skipped and stays pending. Anyone may call.
    function executeBurns(uint256 n) external nonReentrant returns (uint256 executed) {
        _syncNow();
        uint256 len = _burnQueue.length;
        uint256 visited;
        for (uint256 i = queueHead; i < len && visited < n; ++i) {
            BurnRequest storage r = _burnQueue[i];
            if (r.done) continue;
            ++visited;
            if (r.readyAt > block.timestamp) continue;
            try this.executeOneFromQueue(i) {
                ++executed;
            } catch (bytes memory reason) {
                emit BurnSkipped(i, reason);
            }
        }
        _advanceHead();
    }

    /// @notice Executes one matured request out of order; reverts if it fails. Anyone may call.
    function executeBurn(uint256 id) external nonReentrant {
        _syncNow();
        _executeOne(id);
        _advanceHead();
    }

    /// @dev Entry for executeBurns' try/catch; only this contract may call it.
    function executeOneFromQueue(uint256 id) external {
        if (msg.sender != address(this)) revert NotSelf();
        _executeOne(id);
    }

    /// @notice Cancels a pending request and returns the noUSD to its owner. No accrual for the time queued.
    function cancelBurn(uint256 id) external nonReentrant {
        uint256 amount = BurnQueue.cancel(_burnQueue, id, msg.sender);
        escrowed -= amount;
        token.transfer(msg.sender, amount);
        _advanceHead();
    }

    // ───────────────────────────── maintenance (spec §9.6, §9.7) ─────────────────────────────

    /// @notice Collects a position's fees and re-adds as much of the pair's idle as fits, without a swap.
    /// Needs uncollected fees + pair idle ≥ compoundThreshold and the spot at par. Anyone may call.
    function compound(PoolId id) external nonReentrant {
        NoUSDRegistry.PoolConfig memory cfg = _cfg(id);
        if (cfg.status != NoUSDRegistry.PoolStatus.Active) revert PoolNotActive();
        NoUSDRegistry.Params memory p = _params();
        _sync(p.protocolFeeBps, p.selectionWindow);
        if (_compoundable(id, cfg.key) < p.compoundThreshold) revert BelowCompoundThreshold();
        _requireAtPar(id, cfg.key, p.depegBps);
        (uint256 a0, uint256 a1) =
            abi.decode(_unlock(abi.encode(Action.Compound, abi.encode(id)), address(0)), (uint256, uint256));
        emit Compounded(id, a0, a1);
    }

    /// @notice Moves a position to the registry's range preset after a timelocked preset change: removes all
    /// liquidity to idle and re-adds as much as fits, without a swap. Needs both pegs. Anyone may call.
    function applyRange(PoolId id) external nonReentrant {
        NoUSDRegistry.PoolConfig memory cfg = _cfg(id);
        if (cfg.status != NoUSDRegistry.PoolStatus.Active) revert PoolNotActive();
        Position storage pos = positions[id];
        // Not created yet: the first mint uses the preset anyway.
        if (pos.tickLower == pos.tickUpper || (pos.tickLower == cfg.tickLower && pos.tickUpper == cfg.tickUpper)) {
            revert RangeUnchanged();
        }
        NoUSDRegistry.Params memory p = _params();
        _pegOk(id, cfg.key, p.depegBps, p.oracle);
        _sync(p.protocolFeeBps, p.selectionWindow);
        (int24 oldLower, int24 oldUpper) = (pos.tickLower, pos.tickUpper);
        _unlock(abi.encode(Action.ApplyRange, abi.encode(id)), address(0));
        emit RangeApplied(id, oldLower, oldUpper, cfg.tickLower, cfg.tickUpper);
    }

    // ───────────────────────────── registry hooks (spec §4.2) ─────────────────────────────

    /// @inheritdoc INoUSDPositionManager
    function retire(PoolId id) external nonReentrant {
        if (msg.sender != address(registry)) revert NotRegistry();
        _syncNow();
        _unlock(abi.encode(Action.Retire, abi.encode(id)), address(0));
        emit Retired(id);
    }

    /// @inheritdoc INoUSDPositionManager
    /// @dev With zero liquidity no fees accrue, and the last modify already paid out every earned fee.
    function isPositionEmpty(PoolId id) external view returns (bool) {
        return _liquidity(id, positions[id]) == 0;
    }

    // ───────────────────────────── housekeeping ─────────────────────────────

    /// @notice Burns noUSD sent to the manager by plain transfer (above the delayed-burn escrow). The body
    /// stays, so this is a donation to holders (spec §9.9).
    function burnStray() external nonReentrant {
        uint256 stray = token.balanceOf(address(this)) - escrowed;
        if (stray == 0) return;
        token.burnFrom(address(this), stray);
        emit StrayBurned(stray);
    }

    /// @notice Forwards to the token (spec §5.3).
    function reclassify(address a) external {
        token.reclassify(a);
    }

    // ───────────────────────────── views ─────────────────────────────

    function obs(PoolId id) external view returns (Obs memory older, Obs memory newer) {
        return (_obs[id][0], _obs[id][1]);
    }

    /// @notice Idle balance of a currency (held as ERC-6909 claims on the PoolManager).
    function idle(Currency c) external view returns (uint256) {
        return _book.idle[Currency.unwrap(c)];
    }

    function currencies() external view returns (address[] memory) {
        return _book.currencies;
    }

    function burnRequest(uint256 id) external view returns (BurnRequest memory) {
        return _burnQueue[id];
    }

    /// @notice The manager's liquidity in the pool's position.
    function positionLiquidity(PoolId id) external view returns (uint128) {
        return _liquidity(id, positions[id]);
    }

    // ───────────────────────────── unlock callback ─────────────────────────────

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, bytes memory data) = abi.decode(raw, (Action, bytes));
        if (action == Action.Payout) {
            (uint256 num, uint256 den, address to, uint256 minOut) =
                abi.decode(data, (uint256, uint256, address, uint256));
            return abi.encode(
                Settlement.payout(
                    poolManager, positions, _book, registry.poolIds(), Settlement.Payout(num, den, to, minOut)
                )
            );
        }
        if (action == Action.Mint) return abi.encode(_mintInUnlock(data));
        if (action == Action.Add) return _addForTest(data);
        PoolId id = abi.decode(data, (PoolId));
        Position storage pos = positions[id];
        if (action == Action.Retire) {
            _removeAllToIdle(id, pos);
            return "";
        }
        if (action == Action.ApplyRange) {
            _removeAllToIdle(id, pos);
            NoUSDRegistry.PoolConfig memory cfg = _cfg(id);
            pos.tickLower = cfg.tickLower;
            pos.tickUpper = cfg.tickUpper;
        }
        // Compound and ApplyRange: deploy the pair's idle without a swap.
        (uint256 a0, uint256 a1) = _deployIdle(id);
        return abi.encode(a0, a1);
    }

    /// @dev Hook for the test harness (Action.Add); no production path issues this action.
    function _addForTest(bytes memory) internal virtual returns (bytes memory) {
        revert NotSelf();
    }

    // ───────────────────────────── internals: registry reads ─────────────────────────────
    // One call site each: every external call that returns a struct carries its own decoder.

    function _params() internal view returns (NoUSDRegistry.Params memory) {
        return registry.params();
    }

    function _cfg(PoolId id) internal view returns (NoUSDRegistry.PoolConfig memory) {
        return registry.pool(id);
    }

    function _parTick(PoolKey memory key) internal view returns (int24) {
        return registry.parTick(key);
    }

    function _syncNow() internal {
        NoUSDRegistry.CoreParams memory c = registry.coreParams();
        _sync(c.protocolFeeBps, c.selectionWindow);
    }

    // ───────────────────────────── internals: accounting ─────────────────────────────

    function _sync(uint256 protocolFeeBps, uint256 window) internal {
        PoolId[] memory ids = registry.poolIds();
        uint256 value;
        for (uint256 i; i < ids.length; ++i) {
            PoolId id = ids[i];
            Position storage pos = positions[id];
            uint128 liquidity = _liquidity(id, pos);
            if (liquidity != 0) {
                (uint256 fgi0, uint256 fgi1) = poolManager.getFeeGrowthInside(id, pos.tickLower, pos.tickUpper);
                // Fee growth wraps like in v4; the difference is the growth since the last sync. Unchanged
                // counters are not rewritten.
                uint256 acc0 = pos.fg0Accounted;
                if (fgi0 != acc0) {
                    unchecked {
                        value += FullMath.mulDiv(fgi0 - acc0, liquidity, FixedPoint128.Q128) * 10
                        ** (18 - pos.decimals0);
                    }
                    pos.fg0Accounted = fgi0;
                }
                uint256 acc1 = pos.fg1Accounted;
                if (fgi1 != acc1) {
                    unchecked {
                        value += FullMath.mulDiv(fgi1 - acc1, liquidity, FixedPoint128.Q128) * 10
                        ** (18 - pos.decimals1);
                    }
                    pos.fg1Accounted = fgi1;
                }
            }
            _rotateObs(id, window);
        }
        value += carry;
        if (value == 0) return;
        uint256 cut = value * protocolFeeBps / 10_000;
        if (cut != 0) token.accrueTreasury(cut);
        carry = value == cut ? 0 : token.distribute(value - cut);
        emit Synced(value, cut);
    }

    function _rotateObs(PoolId id, uint256 window) internal {
        Obs[2] storage o = _obs[id];
        uint64 t = o[1].t;
        if (t != 0 && block.timestamp < t + window) return;
        (uint256 g0, uint256 g1) = poolManager.getFeeGrowthGlobals(id);
        if (t != 0) o[0] = o[1];
        o[1] = Obs({t: uint64(block.timestamp), fg0: g0, fg1: g1});
    }

    /// @dev D of spec §9.2: everything the body backs. Read before any burn or consume.
    function _denominator() internal view returns (uint256) {
        return token.liabilities() + carry;
    }

    function _claim(uint256 a, uint256 d, address to, uint256 minOut) internal returns (uint256 paid) {
        if (a != 0) paid = _payout(a, d, to, minOut);
        else if (minOut != 0) revert Slippage(0, minOut);
        emit Claimed(msg.sender, to, a, a == 0 ? 0 : FullMath.mulDiv(a, 1e18, d));
    }

    function _executeOne(uint256 id) internal {
        BurnRequest storage r = _burnQueue[id];
        if (r.done) revert AlreadyDone();
        if (r.readyAt > block.timestamp) revert NotMatured();
        r.done = true;
        uint256 x = r.amount;
        uint256 d = _denominator();
        escrowed -= x;
        token.burnFrom(address(this), x);
        _payout(x, d, r.to, r.minOut);
        emit BurnExecuted(id, FullMath.mulDiv(x, 1e18, d));
    }

    function _advanceHead() internal {
        queueHead = BurnQueue.advance(_burnQueue, queueHead);
    }

    /// @dev Value at par of a position's uncollected fees plus the pair's idle.
    function _compoundable(PoolId id, PoolKey memory key) internal view returns (uint256) {
        Position storage pos = positions[id];
        uint256 f0 = _book.idle[Currency.unwrap(key.currency0)];
        uint256 f1 = _book.idle[Currency.unwrap(key.currency1)];
        if (pos.tickLower != pos.tickUpper) {
            (uint256 u0, uint256 u1) =
                PositionMath.uncollectedFees(poolManager, id, address(this), pos.tickLower, pos.tickUpper);
            f0 += u0;
            f1 += u1;
        }
        return f0 * registry.scale(key.currency0) + f1 * registry.scale(key.currency1);
    }

    /// @dev Inline rather than through Settlement: it runs once per pool in every sync, and a library call
    /// costs more than the read itself.
    function _liquidity(PoolId id, Position storage pos) internal view returns (uint128) {
        (int24 lo, int24 hi) = (pos.tickLower, pos.tickUpper);
        if (lo == hi) return 0;
        return poolManager.getPositionLiquidity(id, V4Position.calculatePositionKey(address(this), lo, hi, bytes32(0)));
    }

    /// @dev Value at par of `liquidity` of the position at the current price, rounded down. A minter is
    /// credited this, not the rounded-up amounts v4 charged, so adding never creates value.
    function _liquidityValue(PoolId id, Position storage pos, uint128 liquidity) internal view returns (uint256) {
        (uint160 sp,,,) = poolManager.getSlot0(id);
        (uint256 a0, uint256 a1) = PositionMath.amountsForLiquidity(sp, pos.tickLower, pos.tickUpper, liquidity);
        return a0 * 10 ** (18 - pos.decimals0) + a1 * 10 ** (18 - pos.decimals1);
    }

    function _keyOf(Position storage pos) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: pos.currency0,
            currency1: pos.currency1,
            fee: pos.fee,
            tickSpacing: pos.tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    // ───────────────────────────── internals: peg (spec §7) ─────────────────────────────

    /// @dev |spot − par| ≤ depegBps, measured in ticks (1 tick ≈ 1 bp).
    function _requireAtPar(PoolId id, PoolKey memory key, uint256 depegBps) internal view {
        (, int24 tick,,) = poolManager.getSlot0(id);
        int256 diff = int256(tick) - _parTick(key);
        if (diff < 0) diff = -diff;
        if (uint256(diff) > depegBps) revert PegCheckFailed(id);
    }

    /// @dev At par and vouched by the unisafe oracle (reverts of the oracle propagate).
    function _pegOk(PoolId id, PoolKey memory key, uint256 depegBps, address oracle) internal view {
        _requireAtPar(id, key, depegBps);
        if (!IPriceOracle(oracle).check(key, false, 0, 0)) revert OracleNoOpinion(id);
    }

    // ───────────────────────────── internals: unlock bodies ─────────────────────────────

    /// @dev Takes the deposit into the PoolManager, pairs it with idle, swaps the rest, adds, refunds the
    /// minter and checks pegs and the share cap (spec §9.1 step 5).
    function _mintInUnlock(bytes memory data) internal returns (MintResult memory r) {
        (PoolId addId, PoolId swapId, Currency t, uint256 amount, address minter) =
            abi.decode(data, (PoolId, PoolId, Currency, uint256, address));
        NoUSDRegistry.PoolConfig memory cfg = _cfg(addId);
        Position storage pos = _ensurePosition(addId, cfg);

        // The deposit goes straight from the minter into the PoolManager (credit to the manager).
        poolManager.sync(t);
        IERC20(Currency.unwrap(t)).safeTransferFrom(minter, address(poolManager), amount);
        poolManager.settle();

        MintState memory m;
        m.tIs0 = Currency.unwrap(cfg.key.currency0) == Currency.unwrap(t);
        r.u = m.tIs0 ? cfg.key.currency1 : cfg.key.currency0;
        NoUSDRegistry.Params memory p = _params();

        // The other currency the whole deposit would need, and how much idle covers.
        uint256 needU = _counterpart(addId, pos, m.tIs0, amount);
        m.k = _book.idle[Currency.unwrap(r.u)] < needU ? _book.idle[Currency.unwrap(r.u)] : needU;
        m.tLeft = amount;
        // Two passes, approaching from below: a swap moves the price, and in a narrow range the ratio the
        // position wants moves about 1 % per tick, so the first pass swaps 90 % of the estimate and the
        // second swaps what the new ratio still lacks. Leftovers are refunded.
        for (uint256 pass; pass < 2 && m.k + m.swapOut < needU; ++pass) {
            (uint256 paidT, uint256 got) = _swapForPair(swapId, t, m.tLeft, needU, m.k + m.swapOut, p, pass == 0);
            if (paidT == 0) break;
            m.tLeft -= paidT;
            m.swapOut += got;
            needU = _counterpart(addId, pos, m.tIs0, m.tLeft);
        }
        _addPaired(addId, cfg.key, pos, m, r);
        _resolve(t, r.refundT, minter);
        _resolve(r.u, r.refundU, minter);

        _pegOk(addId, cfg.key, p.depegBps, p.oracle);
        if (PoolId.unwrap(swapId) != PoolId.unwrap(addId) && m.swapOut != 0) {
            _pegOk(swapId, _cfg(swapId).key, p.depegBps, p.oracle);
        }
        if (uint256(_liquidity(addId, pos)) * 10_000 > uint256(poolManager.getLiquidity(addId)) * cfg.maxShareBps) {
            revert CapExceeded();
        }
    }

    /// @dev Adds the liquidity that the rest of the deposit and k + swapOut of the other token make, then
    /// books what was used: idle first (up to k), the rest of the other token is the minter's swap output.
    function _addPaired(PoolId id, PoolKey memory key, Position storage pos, MintState memory m, MintResult memory r)
        internal
    {
        (uint160 sp,,,) = poolManager.getSlot0(id);
        uint256 uAmount = m.k + m.swapOut;
        uint128 liquidity = PositionMath.liquidityForAmounts(
            sp, pos.tickLower, pos.tickUpper, m.tIs0 ? m.tLeft : uAmount, m.tIs0 ? uAmount : m.tLeft
        );
        (uint256 used0, uint256 used1) = _add(id, pos, liquidity);
        (uint256 usedT, uint256 usedU) = m.tIs0 ? (used0, used1) : (used1, used0);
        uint256 idleUsed = usedU < m.k ? usedU : m.k;
        r.refundT = m.tLeft - usedT;
        // The minter brought swapOut of the other token and used (usedU − idleUsed) of it.
        r.refundU = m.swapOut + idleUsed - usedU;
        // Credited: the added liquidity, rounded down, minus the holders' idle it consumed.
        r.value = _liquidityValue(id, pos, liquidity) - idleUsed * _book.scale[Currency.unwrap(r.u)];
    }

    /// @dev Amount of the other currency that pairs with `amount` of the deposit at the current price.
    function _counterpart(PoolId id, Position storage pos, bool tIs0, uint256 amount) internal view returns (uint256) {
        (uint160 sp,,,) = poolManager.getSlot0(id);
        return PositionMath.counterpart(sp, pos.tickLower, pos.tickUpper, tIs0, amount);
    }

    /// @dev Swaps the part of the deposit the position's ratio still lacks, in the swap pool, never past
    /// par ± depegBps (SwapStep, delegatecalled; its deltas are resolved with the add).
    function _swapForPair(
        PoolId swapId,
        Currency t,
        uint256 amount,
        uint256 needU,
        uint256 have,
        NoUSDRegistry.Params memory p,
        bool damp
    ) internal returns (uint256, uint256) {
        PoolKey memory key = _cfg(swapId).key;
        return SwapStep.swapForPair(
            poolManager,
            key,
            SwapStep.Request({
                t: t, amount: amount, needU: needU, have: have, parTick: _parTick(key), depegBps: p.depegBps, damp: damp
            })
        );
    }

    /// @dev All liquidity of the position (and its fees) to idle.
    function _removeAllToIdle(PoolId id, Position storage pos) internal {
        uint128 liquidity = _liquidity(id, pos);
        if (liquidity == 0) return;
        _modify(_keyOf(pos), pos, -int256(uint256(liquidity)));
        _resolve(pos.currency0, 0, address(0));
        _resolve(pos.currency1, 0, address(0));
    }

    /// @dev Collects the position's fees and adds as much of the pair's idle (with those fees) as fits the
    /// current ratio. Creates the position at the preset if needed.
    function _deployIdle(PoolId id) internal returns (uint256 used0, uint256 used1) {
        Position storage pos = _ensurePosition(id, _cfg(id));
        PoolKey memory key = _keyOf(pos);
        if (_liquidity(id, pos) != 0) _modify(key, pos, 0); // fees → credit
        uint256 a0 = _book.idle[Currency.unwrap(key.currency0)]
            + uint256(poolManager.currencyDelta(address(this), key.currency0));
        uint256 a1 = _book.idle[Currency.unwrap(key.currency1)]
            + uint256(poolManager.currencyDelta(address(this), key.currency1));
        (uint160 sp,,,) = poolManager.getSlot0(id);
        // One wei of margin per side: amounts owed for the floored liquidity are rounded up.
        uint128 liquidity = PositionMath.liquidityForAmounts(
            sp, pos.tickLower, pos.tickUpper, a0 == 0 ? 0 : a0 - 1, a1 == 0 ? 0 : a1 - 1
        );
        if (liquidity != 0) (used0, used1) = _add(id, pos, liquidity);
        _resolve(key.currency0, 0, address(0));
        _resolve(key.currency1, 0, address(0));
    }

    /// @dev Creates the manager's position record at the registry preset on first use (the fee counters are
    /// set by the first `_add`).
    function _ensurePosition(PoolId id, NoUSDRegistry.PoolConfig memory cfg) internal returns (Position storage pos) {
        pos = positions[id];
        if (pos.tickLower != pos.tickUpper) return pos;
        pos.tickLower = cfg.tickLower;
        pos.tickUpper = cfg.tickUpper;
        pos.fee = cfg.key.fee;
        pos.tickSpacing = cfg.key.tickSpacing;
        pos.currency0 = cfg.key.currency0;
        pos.currency1 = cfg.key.currency1;
        pos.decimals0 = _noteCurrency(cfg.key.currency0);
        pos.decimals1 = _noteCurrency(cfg.key.currency1);
    }

    /// @dev Registers a currency for idle payouts on first sight; returns its decimals.
    function _noteCurrency(Currency c) internal returns (uint8 decimals) {
        decimals = registry.tokens(c).decimals;
        if (_book.scale[Currency.unwrap(c)] != 0) return decimals;
        _book.scale[Currency.unwrap(c)] = 10 ** (18 - decimals);
        _book.currencies.push(Currency.unwrap(c));
    }

    /// @dev Adds liquidity. When the position held none, the fee counters are (re)based on the range's fee
    /// growth *after* the add: v4 initializes the range's ticks in this modify if nobody else uses them,
    /// which shifts feeGrowthInside, and an emptied position must not count fees from its empty period.
    function _add(PoolId id, Position storage pos, uint128 liquidity) internal returns (uint256 p0, uint256 p1) {
        bool wasEmpty = _liquidity(id, pos) == 0;
        (p0, p1) = Settlement.modify(poolManager, pos, int256(uint256(liquidity)));
        if (wasEmpty) {
            (pos.fg0Accounted, pos.fg1Accounted) = poolManager.getFeeGrowthInside(id, pos.tickLower, pos.tickUpper);
        }
    }

    function _modify(PoolKey memory, Position storage pos, int256 liquidityDelta) internal returns (uint256, uint256) {
        return Settlement.modify(poolManager, pos, liquidityDelta);
    }

    // ───────────────────────────── internals: settlement ─────────────────────────────

    function _resolve(Currency c, uint256 pay, address to) internal {
        Settlement.resolve(poolManager, _book, c, pay, to);
    }

    /// @dev unlock that turns a refused token transfer to `payee` (v4 wraps it as WrappedError naming the
    /// token) into PayoutFailed(token, payee). Other reverts bubble unchanged.
    function _unlock(bytes memory data, address payee) internal returns (bytes memory) {
        try poolManager.unlock(data) returns (bytes memory ret) {
            return ret;
        } catch (bytes memory err) {
            if (err.length >= 36 && bytes4(err) == CustomRevert.WrappedError.selector) {
                address target;
                assembly ("memory-safe") {
                    target := mload(add(err, 36))
                }
                revert PayoutFailed(Currency.wrap(target), payee);
            }
            assembly ("memory-safe") {
                revert(add(err, 32), mload(err))
            }
        }
    }

    /// @dev Takes num/den of every position and of idle, paid by the PoolManager straight to `to`.
    function _payout(uint256 num, uint256 den, address to, uint256 minOut) internal returns (uint256) {
        return abi.decode(_unlock(abi.encode(Action.Payout, abi.encode(num, den, to, minOut)), to), (uint256));
    }
}
