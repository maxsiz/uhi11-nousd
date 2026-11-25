// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title PositionMath
/// @notice Pure liquidity math of the manager (spec §9.1, §9.6): amounts of a range position, liquidity
/// for amounts, the counterpart a deposit needs, and the swap size of a mint. External library: linked at
/// deploy, keeps the manager under EIP-170.
library PositionMath {
    using StateLibrary for IPoolManager;

    /// @notice Token amounts of `liquidity` in [lo, hi) at price `sp`, rounded down.
    function amountsForLiquidity(uint160 sp, int24 lo, int24 hi, uint128 liquidity)
        public
        pure
        returns (uint256 a0, uint256 a1)
    {
        uint160 sa = TickMath.getSqrtPriceAtTick(lo);
        uint160 sb = TickMath.getSqrtPriceAtTick(hi);
        if (sp <= sa) {
            a0 = SqrtPriceMath.getAmount0Delta(sa, sb, liquidity, false);
        } else if (sp < sb) {
            a0 = SqrtPriceMath.getAmount0Delta(sp, sb, liquidity, false);
            a1 = SqrtPriceMath.getAmount1Delta(sa, sp, liquidity, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sa, sb, liquidity, false);
        }
    }

    /// @notice Largest liquidity in [lo, hi) at `sp` that `a0` and `a1` pay for (rounded down).
    function liquidityForAmounts(uint160 sp, int24 lo, int24 hi, uint256 a0, uint256 a1) public pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            sp, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), a0, a1
        );
    }

    /// @notice Amount of the other token that pairs with `amount` of the deposit token (currency0 if
    /// `tIs0`) at `sp`, rounded up.
    function counterpart(uint160 sp, int24 lo, int24 hi, bool tIs0, uint256 amount) public pure returns (uint256) {
        uint160 sa = TickMath.getSqrtPriceAtTick(lo);
        uint160 sb = TickMath.getSqrtPriceAtTick(hi);
        if (tIs0) {
            uint128 l = LiquidityAmounts.getLiquidityForAmount0(sp, sb, amount);
            return SqrtPriceMath.getAmount1Delta(sa, sp, l, true);
        }
        uint128 l1 = LiquidityAmounts.getLiquidityForAmount1(sa, sp, amount);
        return SqrtPriceMath.getAmount0Delta(sp, sb, l1, true);
    }

    /// @notice Part s of the deposit to swap so that (amount − s) and k + out(s) fit the position:
    /// s = (needU − k) / (q + ρ), with ρ = needU / amount and q the swap pool's price of the deposit token
    /// net of its fee (pips), both 1e18-scaled. Capped at `amount`.
    function swapSize(uint160 sp, uint24 fee, bool zeroForOne, uint256 amount, uint256 needU, uint256 k)
        public
        pure
        returns (uint256 s)
    {
        uint256 p18 = zeroForOne
            ? FullMath.mulDiv(FullMath.mulDiv(sp, sp, 1 << 96), 1e18, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(1 << 96, 1e18, sp), 1 << 96, sp);
        uint256 q18 = p18 * (1_000_000 - fee) / 1_000_000;
        s = FullMath.mulDiv(needU - k, 1e18, q18 + FullMath.mulDiv(needU, 1e18, amount));
        if (s > amount) s = amount;
    }

    /// @notice sqrt price at a tick (for the swap's depeg limit).
    function sqrtPriceAtTick(int24 tick) public pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    /// @notice Fees v4 owes `owner`'s position in [lo, hi) right now (paid on its next modify).
    function uncollectedFees(IPoolManager pm, PoolId id, address owner, int24 lo, int24 hi)
        public
        view
        returns (uint256 f0, uint256 f1)
    {
        (uint128 l, uint256 last0, uint256 last1) = pm.getPositionInfo(id, owner, lo, hi, bytes32(0));
        (uint256 g0, uint256 g1) = pm.getFeeGrowthInside(id, lo, hi);
        unchecked {
            f0 = FullMath.mulDiv(g0 - last0, l, FixedPoint128.Q128);
            f1 = FullMath.mulDiv(g1 - last1, l, FixedPoint128.Q128);
        }
    }
}
