// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NoUSD} from "./NoUSD.sol";
import {NoUSDRegistry} from "./NoUSDRegistry.sol";

/// @title NoUSDPositionManager
/// @notice Owns every Uniswap v4 position backing noUSD. Mint, burn (instant and delayed), claim,
/// sync, compound and applyRange live here; every maintenance call is permissionless and
/// condition-checked. No address can move funds.
/// @dev Scaffold: functions are added per docs/spec.md §6 and §9. Not related to v4-periphery's
/// PositionManager: this contract talks to PoolManager directly.
contract NoUSDPositionManager {
    NoUSD public immutable token;
    NoUSDRegistry public immutable registry;
    IPoolManager public immutable poolManager;

    error ZeroAddress();

    /// @param token_ Address of the NoUSD token, precomputed: the token is deployed after the manager.
    constructor(NoUSD token_, NoUSDRegistry registry_, IPoolManager poolManager_) {
        if (address(token_) == address(0) || address(registry_) == address(0) || address(poolManager_) == address(0)) {
            revert ZeroAddress();
        }
        token = token_;
        registry = registry_;
        poolManager = poolManager_;
    }
}
