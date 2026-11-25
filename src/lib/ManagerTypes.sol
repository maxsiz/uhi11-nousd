// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice The manager's record of one pool position (spec §6). The first two slots hold everything sync
/// and payouts need (range, pool key, decimals), so they never ask the registry per pool.
struct Position {
    int24 tickLower; // current range; lower == upper == 0 means not created yet
    int24 tickUpper;
    uint24 fee; // pool key, cached at creation (hooks are always address(0))
    int24 tickSpacing;
    Currency currency0;
    Currency currency1;
    uint8 decimals0;
    uint8 decimals1;
    uint256 fg0Accounted; // feeGrowthInside0X128 already turned into accPerShare
    uint256 fg1Accounted;
}

/// @notice feeGrowthGlobal point of a pool, for the pool-selection signal (spec §8).
struct Obs {
    uint64 t;
    uint256 fg0;
    uint256 fg1;
}

/// @notice The manager's idle book: balances held as ERC-6909 claims on the PoolManager, decimals scale and
/// the list of every currency held. Keyed by token address (see Settlement for why).
struct Book {
    mapping(address => uint256) idle;
    mapping(address => uint256) scale; // 10**(18 - decimals)
    address[] currencies;
}

/// @notice A delayed-burn request (spec §9.3).
struct BurnRequest {
    address owner;
    uint64 readyAt;
    bool done;
    address to;
    uint128 amount;
    uint128 minOut;
}
