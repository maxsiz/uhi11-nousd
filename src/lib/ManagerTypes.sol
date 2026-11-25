// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The manager's record of one pool position (spec §6).
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

/// @notice A delayed-burn request (spec §9.3).
struct BurnRequest {
    address owner;
    uint64 readyAt;
    bool done;
    address to;
    uint128 amount;
    uint128 minOut;
}
