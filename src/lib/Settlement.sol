// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Position as V4Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Book, Position} from "./ManagerTypes.sol";

/// @title Settlement
/// @notice The manager's dealings with the PoolManager inside an unlock (spec §9): modify a position, pay
/// a fraction of the body, and close each currency's delta — the payout goes from the PoolManager to the
/// recipient, the rest is the change of idle, held as the manager's ERC-6909 claims. External library:
/// delegatecalled, so the PoolManager sees the manager; keeps the manager under EIP-170. The idle book uses
/// plain addresses: solc 0.8.26 crashes (internal error) on a public library function taking a storage
/// array of a user-defined value type such as Currency.
library Settlement {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    error Slippage(uint256 paid, uint256 minOut);

    /// @notice The manager's liquidity in a position (0 if not created).
    function liquidity(IPoolManager pm, PoolId id, Position storage pos) public view returns (uint128) {
        if (pos.tickLower == pos.tickUpper) return 0;
        return pm.getPositionLiquidity(
            id, V4Position.calculatePositionKey(address(this), pos.tickLower, pos.tickUpper, bytes32(0))
        );
    }

    /// @notice modifyLiquidity on the manager's position. Returns the principal moved (tokens put in for a
    /// positive `liquidityDelta`, taken out for a negative one); fees stay in the delta and end in idle.
    function modify(IPoolManager pm, Position storage pos, int256 liquidityDelta)
        public
        returns (uint256 p0, uint256 p1)
    {
        (BalanceDelta delta, BalanceDelta fees) = pm.modifyLiquidity(
            PoolKey({
                currency0: pos.currency0,
                currency1: pos.currency1,
                fee: pos.fee,
                tickSpacing: pos.tickSpacing,
                hooks: IHooks(address(0))
            }),
            ModifyLiquidityParams({
                tickLower: pos.tickLower, tickUpper: pos.tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );
        int256 q0 = int256(delta.amount0()) - fees.amount0();
        int256 q1 = int256(delta.amount1()) - fees.amount1();
        p0 = uint256(q0 < 0 ? -q0 : q0);
        p1 = uint256(q1 < 0 ? -q1 : q1);
    }

    /// @notice Closes the manager's delta in `c`: `pay` goes from the PoolManager to `to`; what remains is
    /// the change of idle, booked as ERC-6909 claims (minted if positive, burned if negative).
    function resolve(IPoolManager pm, Book storage book, Currency c, uint256 pay, address to) public {
        int256 net = pm.currencyDelta(address(this), c) - int256(pay);
        if (net > 0) {
            pm.mint(address(this), c.toId(), uint256(net));
            book.idle[Currency.unwrap(c)] += uint256(net);
        } else if (net < 0) {
            pm.burn(address(this), c.toId(), uint256(-net));
            book.idle[Currency.unwrap(c)] -= uint256(-net);
        }
        if (pay != 0) pm.take(c, to, pay);
    }

    /// @notice A payout: num/den of the body to `to`, at least `minOut` at par.
    struct Payout {
        uint256 num;
        uint256 den;
        address to;
        uint256 minOut;
    }

    /// @notice Removes num/den of each position's liquidity (the delta also collects all its fees, which
    /// join idle), adds num/den of each idle balance, and resolves every currency with the payout sent to
    /// `to`. Returns the payout at par; reverts Slippage below `minOut`.
    function payout(
        IPoolManager pm,
        mapping(PoolId => Position) storage positions,
        Book storage book,
        PoolId[] memory ids,
        Payout memory q
    ) public returns (uint256 paid) {
        uint256[] memory amounts = _removeShare(pm, positions, book.currencies, ids, q.num, q.den);
        uint256 n = amounts.length;
        for (uint256 i; i < n; ++i) {
            address c = book.currencies[i];
            // Idle including the fees just collected: what the PoolManager owes beyond the principal.
            uint256 avail = book.idle[c] + uint256(pm.currencyDelta(address(this), Currency.wrap(c))) - amounts[i];
            amounts[i] += FullMath.mulDiv(avail, q.num, q.den);
            paid += amounts[i] * book.scale[c];
        }
        if (paid < q.minOut) revert Slippage(paid, q.minOut);
        for (uint256 i; i < n; ++i) {
            resolve(pm, book, Currency.wrap(book.currencies[i]), amounts[i], q.to);
        }
    }

    function _removeShare(
        IPoolManager pm,
        mapping(PoolId => Position) storage positions,
        address[] storage currencies,
        PoolId[] memory ids,
        uint256 num,
        uint256 den
    ) private returns (uint256[] memory amounts) {
        amounts = new uint256[](currencies.length);
        for (uint256 i; i < ids.length; ++i) {
            Position storage pos = positions[ids[i]];
            uint128 l = liquidity(pm, ids[i], pos);
            if (l == 0) continue;
            (uint256 got0, uint256 got1) = modify(pm, pos, -int256(FullMath.mulDiv(l, num, den)));
            amounts[_indexOf(currencies, pos.currency0)] += got0;
            amounts[_indexOf(currencies, pos.currency1)] += got1;
        }
    }

    function _indexOf(address[] storage currencies, Currency c) private view returns (uint256 i) {
        uint256 n = currencies.length;
        for (; i < n; ++i) {
            if (currencies[i] == Currency.unwrap(c)) return i;
        }
        revert(); // unreachable: every position's currencies are noted when it is created
    }
}
