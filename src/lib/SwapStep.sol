// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionMath} from "./PositionMath.sol";

/// @title SwapStep
/// @notice The swap of a mint (spec §9.1 step 5b): swap the part of the deposit the position's ratio still
/// lacks, exact input, never past the depeg price limit. External library called inside the manager's unlock
/// callback: through delegatecall the PoolManager sees the manager as the swapper; the resulting deltas are
/// resolved by the manager at the end of the callback together with the add.
library SwapStep {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice One swap request.
    /// @param t Deposit token, sold.
    /// @param amount Deposit token still available.
    /// @param needU Other token the available deposit needs; `have` of it is already covered.
    /// @param parTick Par tick of the swap pool; the price limit is parTick ∓ depegBps.
    /// @param damp Swap 90 % of the estimate (first pass: approach the target from below).
    struct Request {
        Currency t;
        uint256 amount;
        uint256 needU;
        uint256 have;
        int24 parTick;
        uint256 depegBps;
        bool damp;
    }

    function swapForPair(IPoolManager pm, PoolKey memory key, Request memory q)
        public
        returns (uint256 paidT, uint256 gotU)
    {
        bool zeroForOne = Currency.unwrap(key.currency0) == Currency.unwrap(q.t);
        uint160 limit = _limit(q, zeroForOne);
        (uint160 sp,,,) = pm.getSlot0(key.toId());
        // Already at the depeg bound in this direction: nothing to swap (the peg check decides the mint).
        if (zeroForOne ? sp <= limit : sp >= limit) return (0, 0);
        uint256 s = PositionMath.swapSize(sp, key.fee, zeroForOne, q.amount, q.needU, q.have);
        if (q.damp) s = s * 9 / 10;
        if (s == 0) return (0, 0);
        BalanceDelta d = pm.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(s), sqrtPriceLimitX96: limit}), ""
        );
        (int128 dT, int128 dU) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        paidT = uint128(-dT);
        gotU = uint128(dU);
    }

    function _limit(Request memory q, bool zeroForOne) private pure returns (uint160) {
        int24 bound = int24(uint24(q.depegBps));
        return TickMath.getSqrtPriceAtTick(zeroForOne ? q.parTick - bound : q.parTick + bound);
    }
}
