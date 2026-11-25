// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title NoUSDRegistry
/// @notice Admitted tokens, registered pools, parameters with hard caps, oracle and treasury of one
/// noUSD deployment. Owned by a Safe; tightening is immediate, loosening goes through a 48 h queue.
/// @dev Scaffold: storage and functions are added per docs/spec.md §4.
contract NoUSDRegistry is Ownable2Step {
    /// @notice Delay for every loosening change (spec §4.4).
    uint256 public constant TIMELOCK = 48 hours;
    /// @notice Maximum number of registered pools (spec §4.2).
    uint256 public constant MAX_POOLS = 8;

    // Hard caps on parameters (spec §4.3).
    uint256 public constant MAX_BURN_DELAY = 7 days;
    uint256 public constant MAX_MINT_FEE_BPS = 50;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1_000;
    uint256 public constant MIN_DEPEG_BPS = 1;
    uint256 public constant MAX_DEPEG_BPS = 200;
    uint256 public constant MAX_POOL_SHARE_BPS = 5_000;
    uint256 public constant MIN_SELECTION_WINDOW = 1 days;
    uint256 public constant MAX_SELECTION_WINDOW = 30 days;

    /// @notice The position manager allowed to be called by `retirePool`; set once after deployment.
    address public manager;

    error ManagerAlreadySet();
    error ZeroAddress();

    event ManagerSet(address manager);

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Wires the manager once, after it is deployed (deployment order: registry → manager → token).
    function setManager(address manager_) external onlyOwner {
        if (manager != address(0)) revert ManagerAlreadySet();
        if (manager_ == address(0)) revert ZeroAddress();
        manager = manager_;
        emit ManagerSet(manager_);
    }
}
