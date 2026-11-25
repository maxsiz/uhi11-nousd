// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {NoUSDRegistry} from "../NoUSDRegistry.sol";
import {Obs, Position} from "./ManagerTypes.sol";

/// @title PoolSelection
/// @notice Hybrid pool choice on mint (spec §8): among Active pools holding the deposit token, in range and
/// under their share cap, the best `feeYield × L_pool / (L_pool + L_ours + L_new) × weight`; the swap pool
/// is the cheapest Active pool of the same pair. External library: linked at deploy, runs on the manager's
/// storage through delegatecall, keeps the manager under EIP-170.
library PoolSelection {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error NoPoolForToken();

    struct Candidate {
        PoolId id;
        uint256 score;
        bool found;
    }

    /// @dev Call context, kept in memory to stay within the stack limit.
    struct Ctx {
        NoUSDRegistry registry;
        IPoolManager pm;
        Currency t;
        uint256 amount;
    }

    /// @dev Range and liquidity snapshot of one candidate.
    struct Snap {
        uint160 sp;
        int24 lo;
        int24 hi;
        uint256 lPool;
        uint256 lOurs;
    }

    function select(
        mapping(PoolId => Position) storage positions,
        mapping(PoolId => Obs[2]) storage obs,
        NoUSDRegistry registry,
        IPoolManager pm,
        Currency t,
        uint256 amount
    ) public view returns (PoolId addId, PoolId swapId) {
        Ctx memory c = Ctx(registry, pm, t, amount);
        PoolId[] memory ids = registry.poolIds();
        Candidate memory best;
        for (uint256 i; i < ids.length; ++i) {
            (bool ok, uint256 score) = _score(c, positions[ids[i]], obs[ids[i]][0], ids[i]);
            if (ok && (!best.found || score > best.score)) best = Candidate(ids[i], score, true);
        }
        if (!best.found) revert NoPoolForToken();
        addId = best.id;
        swapId = _cheapestSamePair(registry, ids, registry.pool(addId));
    }

    function _score(Ctx memory c, Position storage pos, Obs storage older, PoolId id)
        private
        view
        returns (bool ok, uint256 score)
    {
        NoUSDRegistry.PoolConfig memory cfg = c.registry.pool(id);
        if (cfg.status != NoUSDRegistry.PoolStatus.Active) return (false, 0);
        bool tIs0 = Currency.unwrap(cfg.key.currency0) == Currency.unwrap(c.t);
        if (!tIs0 && Currency.unwrap(cfg.key.currency1) != Currency.unwrap(c.t)) return (false, 0);
        (bool inRange, Snap memory s) = _snapshot(c.pm, pos, cfg, id);
        if (!inRange || s.lOurs * 10_000 >= s.lPool * cfg.maxShareBps) return (false, 0);
        uint256 denom = s.lPool + s.lOurs + _newLiquidity(s, tIs0, c.amount);
        if (denom != 0) score = FullMath.mulDiv(_yield(older, c, id, cfg.key), s.lPool, denom) * cfg.weight;
        ok = true;
    }

    function _snapshot(IPoolManager pm, Position storage pos, NoUSDRegistry.PoolConfig memory cfg, PoolId id)
        private
        view
        returns (bool inRange, Snap memory s)
    {
        bool created = pos.tickLower != pos.tickUpper;
        s.lo = created ? pos.tickLower : cfg.tickLower;
        s.hi = created ? pos.tickUpper : cfg.tickUpper;
        int24 tick;
        (s.sp, tick,,) = pm.getSlot0(id);
        inRange = tick >= s.lo && tick < s.hi;
        s.lPool = pm.getLiquidity(id);
        // Delegatecalled: address(this) is the manager, the owner of the position.
        if (created) (s.lOurs,,) = pm.getPositionInfo(id, address(this), s.lo, s.hi, bytes32(0));
    }

    /// @dev Fee growth per unit of liquidity per second since the older point, both tokens at par.
    function _yield(Obs storage older, Ctx memory c, PoolId id, PoolKey memory key) private view returns (uint256) {
        uint256 t0 = older.t;
        if (t0 == 0 || block.timestamp <= t0) return 0;
        (uint256 g0, uint256 g1) = c.pm.getFeeGrowthGlobals(id);
        unchecked {
            return ((g0 - older.fg0)
                    * c.registry.scale(key.currency0)
                    + (g1 - older.fg1)
                    * c.registry.scale(key.currency1)) / (block.timestamp - t0);
        }
    }

    /// @dev L_new: the liquidity the whole deposit would make on its own side (an estimate, spec §8).
    function _newLiquidity(Snap memory s, bool tIs0, uint256 amount) private pure returns (uint256) {
        return tIs0
            ? LiquidityAmounts.getLiquidityForAmount0(s.sp, TickMath.getSqrtPriceAtTick(s.hi), amount)
            : LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(s.lo), s.sp, amount);
    }

    function _cheapestSamePair(NoUSDRegistry registry, PoolId[] memory ids, NoUSDRegistry.PoolConfig memory add)
        private
        view
        returns (PoolId swapId)
    {
        swapId = add.key.toId();
        uint24 fee = add.key.fee;
        for (uint256 i; i < ids.length; ++i) {
            NoUSDRegistry.PoolConfig memory c = registry.pool(ids[i]);
            if (
                c.status == NoUSDRegistry.PoolStatus.Active
                    && Currency.unwrap(c.key.currency0) == Currency.unwrap(add.key.currency0)
                    && Currency.unwrap(c.key.currency1) == Currency.unwrap(add.key.currency1) && c.key.fee < fee
            ) {
                fee = c.key.fee;
                swapId = ids[i];
            }
        }
    }
}
