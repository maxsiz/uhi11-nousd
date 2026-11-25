// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title INoUSDPositionManager
/// @notice The part of the position manager the registry calls (spec §4.2).
interface INoUSDPositionManager {
    /// @notice Syncs, then moves all liquidity of the pool's position to idle balances. Only the registry.
    function retire(PoolId id) external;

    /// @notice True when the pool's position holds no liquidity and no accounted-but-uncollected fees, so
    /// the pool can be dropped from the registry.
    function isPositionEmpty(PoolId id) external view returns (bool);
}
