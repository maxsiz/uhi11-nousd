// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {NoUSD} from "./NoUSD.sol";
import {NoUSDRegistry} from "./NoUSDRegistry.sol";
import {INoUSDPositionManager} from "./interfaces/INoUSDPositionManager.sol";

/// @title NoUSDPositionManager
/// @notice Owns every Uniswap v4 position backing noUSD (docs/spec.md §6, §9). Burn and claim pay a
/// fraction of every position and of the idle balances, in kind; sync turns pool fees into the token's
/// accumulator. Every maintenance call is permissionless and condition-checked; no address can move funds.
/// @dev Not related to v4-periphery's PositionManager: this contract talks to PoolManager directly, owns
/// one position per registered pool (salt 0) and implements IUnlockCallback.
contract NoUSDPositionManager is INoUSDPositionManager, IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    struct Position {
        int24 tickLower; // current range; lower == upper == 0 means not created yet
        int24 tickUpper;
        uint256 fg0Accounted; // feeGrowthInside0X128 already turned into accPerShare
        uint256 fg1Accounted;
    }

    /// @notice feeGrowthGlobal point of a pool, for the pool-selection signal (spec §8).
    struct Obs {
        uint64 t;
        uint256 fg0;
        uint256 fg1;
    }

    enum Action {
        Payout,
        Retire,
        Add
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

    /// @dev Every currency the manager has held, so idle of a removed pool's currency is still paid out.
    Currency[] internal _currencies;
    mapping(Currency => uint256) internal _scale; // 10**(18 - decimals), cached from the registry

    event Synced(uint256 value, uint256 cut, uint256 accPerShare);
    event Burned(address indexed owner, address indexed to, uint256 x, uint256 accruedPaid, uint256 fractionWad);
    event Claimed(address indexed holder, address indexed to, uint256 value, uint256 fractionWad);
    event Retired(PoolId indexed id);
    event StrayBurned(uint256 amount);

    error ZeroAddress();
    error Expired();
    error UseRequestBurn();
    error Slippage(uint256 paid, uint256 minOut);
    error PayoutFailed(Currency token, address to);
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
        if (registry.params().burnDelay != 0) revert UseRequestBurn();
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
        uint256 d = _denominator();
        uint256 a = token.consumeAccrued(msg.sender);
        if (a != 0) paid = _payout(a, d, to, minOut);
        else if (minOut != 0) revert Slippage(0, minOut);
        emit Claimed(msg.sender, to, a, a == 0 ? 0 : FullMath.mulDiv(a, 1e18, d));
    }

    /// @notice Pays the treasury's protocol-fee accrual, like `claim`. Only the treasury.
    function claimTreasury(address to, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 paid)
    {
        if (msg.sender != registry.params().treasury) revert NotTreasury();
        _sync();
        uint256 d = _denominator();
        uint256 a = token.consumeTreasury();
        if (a != 0) paid = _payout(a, d, to, minOut);
        else if (minOut != 0) revert Slippage(0, minOut);
        emit Claimed(msg.sender, to, a, a == 0 ? 0 : FullMath.mulDiv(a, 1e18, d));
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
        if (action == Action.Retire) {
            _retireInUnlock(abi.decode(data, (PoolId)));
            return "";
        }
        (PoolId id, uint128 liquidity) = abi.decode(data, (PoolId, uint128));
        (uint256 amount0, uint256 amount1) = _addInUnlock(id, liquidity);
        return abi.encode(amount0, amount1);
    }

    // ───────────────────────────── internals: accounting ─────────────────────────────

    function _sync() internal {
        NoUSDRegistry.Params memory p = registry.params();
        PoolId[] memory ids = registry.poolIds();
        uint256 value;
        for (uint256 i; i < ids.length; ++i) {
            PoolId id = ids[i];
            PoolKey memory key = registry.pool(id).key;
            Position storage pos = positions[id];
            uint128 liquidity = _liquidity(id, pos);
            if (liquidity != 0) {
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
        uint160 sa = TickMath.getSqrtPriceAtTick(pos.tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(pos.tickUpper);
        uint256 a0;
        uint256 a1;
        if (sp <= sa) {
            a0 = SqrtPriceMath.getAmount0Delta(sa, sb, liquidity, false);
        } else if (sp < sb) {
            a0 = SqrtPriceMath.getAmount0Delta(sp, sb, liquidity, false);
            a1 = SqrtPriceMath.getAmount1Delta(sa, sp, liquidity, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sa, sb, liquidity, false);
        }
        return a0 * _scaleOf(key.currency0) + a1 * _scaleOf(key.currency1);
    }

    // ───────────────────────────── internals: payouts ─────────────────────────────

    /// @dev Takes num/den of every position and of idle into the manager, then pays `to`.
    function _payout(uint256 num, uint256 den, address to, uint256 minOut) internal returns (uint256 paid) {
        bytes memory ret = poolManager.unlock(abi.encode(Action.Payout, abi.encode(num, den)));
        uint256[] memory amounts = abi.decode(ret, (uint256[]));
        uint256 n = amounts.length;
        for (uint256 i; i < n; ++i) {
            paid += amounts[i] * _scale[_currencies[i]];
        }
        if (paid < minOut) revert Slippage(paid, minOut);
        for (uint256 i; i < n; ++i) {
            if (amounts[i] != 0) _send(_currencies[i], to, amounts[i]);
        }
    }

    /// @dev Removes num/den of each position's liquidity (the delta also collects all its fees, which go to
    /// idle first), adds num/den of each idle balance, and takes everything owed into the manager.
    /// Returns the payout per entry of `_currencies`.
    function _payoutInUnlock(uint256 num, uint256 den) internal returns (uint256[] memory amounts) {
        PoolId[] memory ids = registry.poolIds();
        // Pools are visited first so new currencies get indexed before the payout array is sized.
        int256[] memory principal0 = new int256[](ids.length);
        int256[] memory principal1 = new int256[](ids.length);
        PoolKey[] memory keys = new PoolKey[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            PoolId id = ids[i];
            Position storage pos = positions[id];
            uint128 liquidity = _liquidity(id, pos);
            if (liquidity == 0) continue;
            keys[i] = registry.pool(id).key;
            uint256 remove = FullMath.mulDiv(liquidity, num, den);
            (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
                keys[i],
                ModifyLiquidityParams({
                    tickLower: pos.tickLower,
                    tickUpper: pos.tickUpper,
                    liquidityDelta: -int256(remove),
                    salt: bytes32(0)
                }),
                ""
            );
            _creditIdle(keys[i].currency0, fees.amount0());
            _creditIdle(keys[i].currency1, fees.amount1());
            principal0[i] = int256(delta.amount0()) - fees.amount0();
            principal1[i] = int256(delta.amount1()) - fees.amount1();
            _take(keys[i].currency0, delta.amount0());
            _take(keys[i].currency1, delta.amount1());
        }
        uint256 n = _currencies.length;
        amounts = new uint256[](n);
        for (uint256 i; i < ids.length; ++i) {
            if (principal0[i] == 0 && principal1[i] == 0) continue;
            amounts[_indexOf(keys[i].currency0)] += uint256(principal0[i]);
            amounts[_indexOf(keys[i].currency1)] += uint256(principal1[i]);
        }
        for (uint256 i; i < n; ++i) {
            Currency c = _currencies[i];
            uint256 share = FullMath.mulDiv(idle[c], num, den);
            if (share != 0) {
                idle[c] -= share;
                amounts[i] += share;
            }
        }
    }

    function _retireInUnlock(PoolId id) internal {
        Position storage pos = positions[id];
        uint128 liquidity = _liquidity(id, pos);
        if (liquidity == 0) return;
        PoolKey memory key = registry.pool(id).key;
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        _creditIdle(key.currency0, delta.amount0());
        _creditIdle(key.currency1, delta.amount1());
        _take(key.currency0, delta.amount0());
        _take(key.currency1, delta.amount1());
    }

    /// @dev Adds `liquidity` to the pool's position, creating it at the registry preset if needed, and pays
    /// for it from the manager's token balance. Fees credited by the modify go to idle. Callers sync first.
    /// @return amount0 amount1 Tokens put into the position (principal only).
    function _addInUnlock(PoolId id, uint128 liquidity) internal returns (uint256 amount0, uint256 amount1) {
        NoUSDRegistry.PoolConfig memory cfg = registry.pool(id);
        Position storage pos = positions[id];
        if (pos.tickLower == pos.tickUpper) {
            pos.tickLower = cfg.tickLower;
            pos.tickUpper = cfg.tickUpper;
            (pos.fg0Accounted, pos.fg1Accounted) = poolManager.getFeeGrowthInside(id, cfg.tickLower, cfg.tickUpper);
            _noteCurrency(cfg.key.currency0);
            _noteCurrency(cfg.key.currency1);
        }
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            cfg.key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        _creditIdle(cfg.key.currency0, fees.amount0());
        _creditIdle(cfg.key.currency1, fees.amount1());
        amount0 = uint256(-(int256(delta.amount0()) - fees.amount0()));
        amount1 = uint256(-(int256(delta.amount1()) - fees.amount1()));
        _settleOrTake(cfg.key.currency0, delta.amount0());
        _settleOrTake(cfg.key.currency1, delta.amount1());
    }

    // ───────────────────────────── internals: token movements ─────────────────────────────

    function _creditIdle(Currency c, int128 amount) internal {
        if (amount > 0) idle[c] += uint128(amount);
    }

    /// @dev Takes a positive delta into the manager.
    function _take(Currency c, int128 amount) internal {
        if (amount > 0) poolManager.take(c, address(this), uint128(amount));
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
