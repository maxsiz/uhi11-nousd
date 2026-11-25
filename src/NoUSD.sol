// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title NoUSD
/// @notice ERC-20 stablecoin backed by the liquidity held by NoUSDPositionManager. Pool fees are
/// distributed through an in-token accumulator (variant L); only the manager can mint, burn, move the
/// counter and consume accrued.
/// @dev Scaffold: ERC-20, accumulator and accrual modes are added per docs/spec.md §5. Written by hand,
/// not on top of OZ ERC20, because balances share a slot with the checkpoint and flags.
contract NoUSD {
    string public constant name = "noUSD";
    string public constant symbol = "noUSD";
    uint8 public constant decimals = 18;

    /// @notice Scale of `accPerShare` (spec §5.2).
    uint256 public constant ACC_SCALE = 1e18;

    /// @notice The only address allowed to mint, burn and distribute.
    address public immutable manager;

    error ZeroAddress();

    constructor(address manager_) {
        if (manager_ == address(0)) revert ZeroAddress();
        manager = manager_;
    }
}
