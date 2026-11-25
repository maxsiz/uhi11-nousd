// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {NoUSD} from "./NoUSD.sol";
import {NoUSDRegistry} from "./NoUSDRegistry.sol";
import {INoUSDPositionManager} from "./interfaces/INoUSDPositionManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {BurnRequest, Obs, Position} from "./lib/ManagerTypes.sol";
import {PoolSelection} from "./lib/PoolSelection.sol";
import {PositionMath} from "./lib/PositionMath.sol";
import {BurnQueue} from "./lib/BurnQueue.sol";
import {SwapStep} from "./lib/SwapStep.sol";

/// @title NoUSDPositionManager
/// @notice Owns every Uniswap v4 position backing noUSD (docs/spec.md §6, §9). Mint adds a deposit to the
/// best pool in one transaction; burn and claim pay a fraction of every position and of the idle balances,
/// in kind; sync turns pool fees into the token's accumulator. Every maintenance call is permissionless
/// and condition-checked; no address can move funds.
/// @dev Not related to v4-periphery's PositionManager: this contract talks to PoolManager directly, owns
/// one position per registered pool (salt 0) and implements IUnlockCallback.
contract NoUSDPositionManager is INoUSDPositionManager, IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    enum Action {
        Payout,
        Retire,
        Add,
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
    /// @notice Manager-held tokens counted in the body (collected fees, retired liquidity, leftovers).
    mapping(Currency => uint256) public idle;
    /// @notice Undistributed value at par: rounding remainders and mint fees, distributed by the next sync.
    uint256 public carry;
    /// @notice noUSD held for pending delayed-burn requests.
    uint256 public escrowed;

    BurnRequest[] internal _burnQueue;
    /// @notice First request that may still be pending; everything before it is done.
    uint256 public queueHead;

    /// @dev Every currency the manager has held, so idle of a removed pool's currency is still paid out.
    Currency[] internal _currencies;
    mapping(Currency => uint256) internal _scale; // 10**(18 - decimals), cached from the registry
    mapping(PoolId => PoolKey) internal _keys; // cached when the position is created

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
    event Synced(uint256 value, uint256 cut, uint256 accPerShare);
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
    /// transaction the deposit is paired with idle of the other currency, the rest swapped in the cheapest
    /// pool of the pair, and added to the best pool; both pools must be at par and vouched by the oracle.
    /// Leftovers are refunded. Reverts instead of leaving anything waiting.
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
        _sync();
        IERC20(Currency.unwrap(t)).safeTransferFrom(msg.sender, address(this), amount);

        (PoolId addId, PoolId swapId) = PoolSelection.select(positions, _obs, registry, poolManager, t, amount);
        MintResult memory r =
            abi.decode(poolManager.unlock(abi.encode(Action.Mint, abi.encode(addId, swapId, t, amount))), (MintResult));

        uint256 fee = r.value * p.mintFeeBps / 10_000;
        out = r.value - fee;
        carry += fee;
        if (out < minOut) revert Slippage(out, minOut);
        if (token.totalSupply() + out > p.supplyCap) revert SupplyCapExceeded();
        token.mint(to, out);
        if (r.refundT != 0) IERC20(Currency.unwrap(t)).safeTransfer(msg.sender, r.refundT);
        if (r.refundU != 0) IERC20(Currency.unwrap(r.u)).safeTransfer(msg.sender, r.refundU);
        emit Minted(msg.sender, to, t, amount, r.value, fee, out, addId, swapId);
    }

    // ───────────────────────────── sync (spec §9.4) ─────────────────────────────

    /// @notice Turns the fees earned by every position since the last sync into the token's accumulator,
    /// valued at par, and rotates the pool-selection points. Moves no tokens. Anyone may call.
    function sync() external nonReentrant {
        _sync();
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
        if (_params().burnDelay != 0) revert UseRequestBurn();
        _sync();
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
        _sync();
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
        _sync();
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
        id = BurnQueue.push(_burnQueue, msg.sender, to, x, minOut, _params().burnDelay);
    }

    /// @notice Executes up to `n` matured requests FIFO from the queue head. A request that fails
    /// (Slippage, PayoutFailed) is skipped and stays pending. Anyone may call.
    function executeBurns(uint256 n) external nonReentrant returns (uint256 executed) {
        _sync();
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
        _sync();
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
        _sync();
        if (_compoundable(id, cfg.key) < _params().compoundThreshold) revert BelowCompoundThreshold();
        _requireAtPar(id, cfg.key);
        (uint256 a0, uint256 a1) =
            abi.decode(poolManager.unlock(abi.encode(Action.Compound, abi.encode(id))), (uint256, uint256));
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
        _pegOk(id, cfg.key);
        _sync();
        (int24 oldLower, int24 oldUpper) = (pos.tickLower, pos.tickUpper);
        poolManager.unlock(abi.encode(Action.ApplyRange, abi.encode(id)));
        emit RangeApplied(id, oldLower, oldUpper, cfg.tickLower, cfg.tickUpper);
    }

    // ───────────────────────────── registry hooks (spec §4.2) ─────────────────────────────

    /// @inheritdoc INoUSDPositionManager
    function retire(PoolId id) external nonReentrant {
        if (msg.sender != address(registry)) revert NotRegistry();
        _sync();
        poolManager.unlock(abi.encode(Action.Retire, abi.encode(id)));
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

    function currencies() external view returns (Currency[] memory) {
        return _currencies;
    }

    function burnRequest(uint256 id) external view returns (BurnRequest memory) {
        return _burnQueue[id];
    }

    function burnQueueLength() external view returns (uint256) {
        return _burnQueue.length;
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
            (uint256 num, uint256 den) = abi.decode(data, (uint256, uint256));
            return abi.encode(_payoutInUnlock(num, den));
        }
        if (action == Action.Mint) {
            (PoolId addId, PoolId swapId, Currency t, uint256 amount) =
                abi.decode(data, (PoolId, PoolId, Currency, uint256));
            return abi.encode(_mintInUnlock(addId, swapId, t, amount));
        }
        if (action == Action.Add) return _addForTest(data);
        PoolId id = abi.decode(data, (PoolId));
        if (action == Action.Retire) {
            _retireInUnlock(id);
            return "";
        }
        if (action == Action.ApplyRange) {
            _retireInUnlock(id); // all liquidity to idle
            NoUSDRegistry.PoolConfig memory cfg = _cfg(id);
            Position storage pos = positions[id];
            pos.tickLower = cfg.tickLower;
            pos.tickUpper = cfg.tickUpper;
            (pos.fg0Accounted, pos.fg1Accounted) = poolManager.getFeeGrowthInside(id, cfg.tickLower, cfg.tickUpper);
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

    /// @dev Pool key from the manager's cache (filled when the position is created), else the registry.
    function _key(PoolId id) internal view returns (PoolKey memory key) {
        key = _keys[id];
        if (Currency.unwrap(key.currency1) == address(0)) key = _cfg(id).key;
    }

    // ───────────────────────────── internals: accounting ─────────────────────────────

    function _sync() internal {
        NoUSDRegistry.Params memory p = _params();
        PoolId[] memory ids = registry.poolIds();
        uint256 value;
        for (uint256 i; i < ids.length; ++i) {
            PoolId id = ids[i];
            Position storage pos = positions[id];
            uint128 liquidity = _liquidity(id, pos);
            if (liquidity != 0) {
                PoolKey memory key = _key(id);
                (uint256 fgi0, uint256 fgi1) = poolManager.getFeeGrowthInside(id, pos.tickLower, pos.tickUpper);
                uint256 d0;
                uint256 d1;
                unchecked {
                    // Fee growth wraps like in v4; the difference is the growth since the last sync.
                    d0 = FullMath.mulDiv(fgi0 - pos.fg0Accounted, liquidity, FixedPoint128.Q128);
                    d1 = FullMath.mulDiv(fgi1 - pos.fg1Accounted, liquidity, FixedPoint128.Q128);
                }
                pos.fg0Accounted = fgi0;
                pos.fg1Accounted = fgi1;
                value += d0 * _scaleOf(key.currency0) + d1 * _scaleOf(key.currency1);
            }
            _rotateObs(id, p.selectionWindow);
        }
        value += carry;
        carry = 0;
        uint256 cut = value * p.protocolFeeBps / 10_000;
        if (cut != 0) token.accrueTreasury(cut);
        if (value != cut) carry = token.distribute(value - cut);
        emit Synced(value, cut, token.accPerShare());
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
        return token.totalSupply() + token.totalUnclaimed() + token.treasuryAccrued() + carry;
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
    function _compoundable(PoolId id, PoolKey memory key) internal returns (uint256) {
        Position storage pos = positions[id];
        uint256 f0 = idle[key.currency0];
        uint256 f1 = idle[key.currency1];
        if (pos.tickLower != pos.tickUpper) {
            (uint256 u0, uint256 u1) =
                PositionMath.uncollectedFees(poolManager, id, address(this), pos.tickLower, pos.tickUpper);
            f0 += u0;
            f1 += u1;
        }
        return f0 * _scaleOf(key.currency0) + f1 * _scaleOf(key.currency1);
    }

    function _scaleOf(Currency c) internal returns (uint256 s) {
        s = _scale[c];
        if (s == 0) {
            s = registry.scale(c);
            _scale[c] = s;
        }
    }

    function _noteCurrency(Currency c) internal {
        if (_scale[c] != 0) return; // already known: _scaleOf fills the cache on first sight
        _scaleOf(c);
        _currencies.push(c);
    }

    function _liquidity(PoolId id, Position storage pos) internal view returns (uint128 liquidity) {
        if (pos.tickLower == pos.tickUpper) return 0;
        (liquidity,,) = poolManager.getPositionInfo(id, address(this), pos.tickLower, pos.tickUpper, bytes32(0));
    }

    /// @dev Value at par of `liquidity` of the pool's position at the current price, rounded down. A
    /// minter is credited this, not the rounded-up amounts v4 charged, so adding never creates value.
    function _liquidityValue(PoolId id, PoolKey memory key, Position storage pos, uint128 liquidity)
        internal
        returns (uint256)
    {
        (uint160 sp,,,) = poolManager.getSlot0(id);
        (uint256 a0, uint256 a1) = PositionMath.amountsForLiquidity(sp, pos.tickLower, pos.tickUpper, liquidity);
        return a0 * _scaleOf(key.currency0) + a1 * _scaleOf(key.currency1);
    }

    // ───────────────────────────── internals: peg (spec §7) ─────────────────────────────

    /// @dev |spot − par| ≤ depegBps, measured in ticks (1 tick ≈ 1 bp).
    function _requireAtPar(PoolId id, PoolKey memory key) internal view {
        (, int24 tick,,) = poolManager.getSlot0(id);
        int256 diff = int256(tick) - _parTick(key);
        if (diff < 0) diff = -diff;
        if (uint256(diff) > _params().depegBps) revert PegCheckFailed(id);
    }

    /// @dev At par and vouched by the unisafe oracle (reverts of the oracle propagate).
    function _pegOk(PoolId id, PoolKey memory key) internal view {
        _requireAtPar(id, key);
        if (!IPriceOracle(_params().oracle).check(key, false, 0, 0)) revert OracleNoOpinion(id);
    }

    // ───────────────────────────── internals: unlock bodies ─────────────────────────────

    /// @dev Pair with idle, swap the rest, add, check pegs and the share cap (spec §9.1 step 5).
    function _mintInUnlock(PoolId addId, PoolId swapId, Currency t, uint256 amount)
        internal
        returns (MintResult memory r)
    {
        NoUSDRegistry.PoolConfig memory cfg = _cfg(addId);
        Position storage pos = _ensurePosition(addId, cfg);
        MintState memory m;
        m.tIs0 = Currency.unwrap(cfg.key.currency0) == Currency.unwrap(t);
        r.u = m.tIs0 ? cfg.key.currency1 : cfg.key.currency0;

        // The other currency the whole deposit would need, and how much idle covers.
        uint256 needU = _counterpart(addId, pos, m.tIs0, amount);
        m.k = idle[r.u] < needU ? idle[r.u] : needU;
        m.tLeft = amount;
        // Two passes, approaching from below: a swap moves the price, and in a narrow range the ratio the
        // position wants moves about 1 % per tick, so the first pass swaps 90 % of the estimate and the
        // second swaps what the new ratio still lacks. Leftovers are refunded.
        for (uint256 pass; pass < 2 && m.k + m.swapOut < needU; ++pass) {
            (uint256 paidT, uint256 got) = _swapForPair(swapId, t, m.tLeft, needU, m.k + m.swapOut, pass == 0);
            if (paidT == 0) break;
            m.tLeft -= paidT;
            m.swapOut += got;
            needU = _counterpart(addId, pos, m.tIs0, m.tLeft);
        }
        _addPaired(addId, cfg.key, pos, m, r);

        _pegOk(addId, cfg.key);
        if (PoolId.unwrap(swapId) != PoolId.unwrap(addId) && m.swapOut != 0) {
            _pegOk(swapId, _key(swapId));
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
        (uint256 used0, uint256 used1) = _modify(key, pos, int256(uint256(liquidity)));
        (uint256 usedT, uint256 usedU) = m.tIs0 ? (used0, used1) : (used1, used0);
        uint256 idleUsed = usedU < m.k ? usedU : m.k;
        idle[r.u] -= idleUsed;
        r.refundT = m.tLeft - usedT;
        // The minter brought swapOut of the other token and used (usedU − idleUsed) of it.
        r.refundU = m.swapOut + idleUsed - usedU;
        // Credited: the added liquidity, rounded down, minus the holders' idle it consumed.
        r.value = _liquidityValue(id, key, pos, liquidity) - idleUsed * _scaleOf(r.u);
    }

    /// @dev Amount of the other currency that pairs with `amount` of the deposit at the current price.
    function _counterpart(PoolId id, Position storage pos, bool tIs0, uint256 amount) internal view returns (uint256) {
        (uint160 sp,,,) = poolManager.getSlot0(id);
        return PositionMath.counterpart(sp, pos.tickLower, pos.tickUpper, tIs0, amount);
    }

    /// @dev Swaps the part of the deposit the position's ratio still lacks, in the swap pool, never past
    /// par ± depegBps (SwapStep, delegatecalled).
    function _swapForPair(PoolId swapId, Currency t, uint256 amount, uint256 needU, uint256 have, bool damp)
        internal
        returns (uint256, uint256)
    {
        PoolKey memory key = _key(swapId);
        return SwapStep.swapForPair(
            poolManager,
            key,
            SwapStep.Request({
                t: t,
                amount: amount,
                needU: needU,
                have: have,
                parTick: _parTick(key),
                depegBps: _params().depegBps,
                damp: damp
            })
        );
    }

    /// @dev Removes num/den of each position's liquidity (the delta also collects all its fees, which go to
    /// idle first), adds num/den of each idle balance, and takes everything owed into the manager.
    /// Returns the payout per entry of `_currencies`.
    function _payoutInUnlock(uint256 num, uint256 den) internal returns (uint256[] memory amounts) {
        PoolId[] memory ids = registry.poolIds();
        amounts = new uint256[](_currencies.length);
        for (uint256 i; i < ids.length; ++i) {
            PoolId id = ids[i];
            Position storage pos = positions[id];
            uint128 liquidity = _liquidity(id, pos);
            if (liquidity == 0) continue;
            PoolKey memory key = _key(id);
            (uint256 got0, uint256 got1) = _modify(key, pos, -int256(FullMath.mulDiv(liquidity, num, den)));
            amounts[_indexOf(key.currency0)] += got0;
            amounts[_indexOf(key.currency1)] += got1;
        }
        for (uint256 i; i < amounts.length; ++i) {
            Currency c = _currencies[i];
            uint256 share = FullMath.mulDiv(idle[c], num, den);
            if (share != 0) {
                idle[c] -= share;
                amounts[i] += share;
            }
        }
    }

    /// @dev All liquidity of the position to idle.
    function _retireInUnlock(PoolId id) internal {
        Position storage pos = positions[id];
        uint128 liquidity = _liquidity(id, pos);
        if (liquidity == 0) return;
        PoolKey memory key = _key(id);
        (uint256 got0, uint256 got1) = _modify(key, pos, -int256(uint256(liquidity)));
        idle[key.currency0] += got0;
        idle[key.currency1] += got1;
    }

    /// @dev Collects the position's fees (to idle) and adds as much of the pair's idle as fits the current
    /// ratio. Creates the position at the preset if needed.
    function _deployIdle(PoolId id) internal returns (uint256 used0, uint256 used1) {
        NoUSDRegistry.PoolConfig memory cfg = _cfg(id);
        Position storage pos = _ensurePosition(id, cfg);
        if (_liquidity(id, pos) != 0) _modify(cfg.key, pos, 0); // fees → idle
        uint256 i0 = idle[cfg.key.currency0];
        uint256 i1 = idle[cfg.key.currency1];
        (uint160 sp,,,) = poolManager.getSlot0(id);
        // One wei of margin per side: amounts owed for the floored liquidity are rounded up.
        uint128 liquidity = PositionMath.liquidityForAmounts(
            sp, pos.tickLower, pos.tickUpper, i0 == 0 ? 0 : i0 - 1, i1 == 0 ? 0 : i1 - 1
        );
        if (liquidity == 0) return (0, 0);
        (used0, used1) = _modify(cfg.key, pos, int256(uint256(liquidity)));
        idle[cfg.key.currency0] = i0 - used0;
        idle[cfg.key.currency1] = i1 - used1;
    }

    /// @dev Creates the manager's position at the registry preset on first use.
    function _ensurePosition(PoolId id, NoUSDRegistry.PoolConfig memory cfg) internal returns (Position storage pos) {
        pos = positions[id];
        if (pos.tickLower != pos.tickUpper) return pos;
        pos.tickLower = cfg.tickLower;
        pos.tickUpper = cfg.tickUpper;
        (pos.fg0Accounted, pos.fg1Accounted) = poolManager.getFeeGrowthInside(id, cfg.tickLower, cfg.tickUpper);
        _keys[id] = cfg.key;
        _noteCurrency(cfg.key.currency0);
        _noteCurrency(cfg.key.currency1);
    }

    /// @dev modifyLiquidity on the manager's position and settlement of its delta against the manager's
    /// balance. Fees the modify credits go to idle. Returns the principal moved: tokens put in for a
    /// positive `liquidityDelta`, tokens taken out for a negative one.
    function _modify(PoolKey memory key, Position storage pos, int256 liquidityDelta)
        internal
        returns (uint256 p0, uint256 p1)
    {
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower, tickUpper: pos.tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );
        if (fees.amount0() > 0) idle[key.currency0] += uint128(fees.amount0());
        if (fees.amount1() > 0) idle[key.currency1] += uint128(fees.amount1());
        int256 q0 = int256(delta.amount0()) - fees.amount0();
        int256 q1 = int256(delta.amount1()) - fees.amount1();
        p0 = uint256(q0 < 0 ? -q0 : q0);
        p1 = uint256(q1 < 0 ? -q1 : q1);
        _settleOrTake(key.currency0, delta.amount0());
        _settleOrTake(key.currency1, delta.amount1());
    }

    // ───────────────────────────── internals: token movements ─────────────────────────────

    /// @dev Takes num/den of every position and of idle into the manager, then pays `to`.
    function _payout(uint256 num, uint256 den, address to, uint256 minOut) internal returns (uint256 paid) {
        uint256[] memory amounts =
            abi.decode(poolManager.unlock(abi.encode(Action.Payout, abi.encode(num, den))), (uint256[]));
        uint256 n = amounts.length;
        for (uint256 i; i < n; ++i) {
            paid += amounts[i] * _scale[_currencies[i]];
        }
        if (paid < minOut) revert Slippage(paid, minOut);
        for (uint256 i; i < n; ++i) {
            if (amounts[i] != 0) _send(_currencies[i], to, amounts[i]);
        }
    }

    function _settleOrTake(Currency c, int128 amount) internal {
        if (amount > 0) {
            poolManager.take(c, address(this), uint128(amount));
        } else if (amount < 0) {
            poolManager.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(poolManager), uint128(-amount));
            poolManager.settle();
        }
    }

    function _indexOf(Currency c) internal view returns (uint256 i) {
        uint256 n = _currencies.length;
        for (; i < n; ++i) {
            if (Currency.unwrap(_currencies[i]) == Currency.unwrap(c)) return i;
        }
        revert(); // unreachable: every position's currencies are noted when it is created
    }

    /// @dev Transfer that names the token and recipient on failure (spec §9: PayoutFailed).
    function _send(Currency c, address to, uint256 amount) internal {
        if (!SafeERC20.trySafeTransfer(IERC20(Currency.unwrap(c)), to, amount)) revert PayoutFailed(c, to);
    }
}
