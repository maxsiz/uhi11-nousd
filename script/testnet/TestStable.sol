// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Testnet-only stand-in for a stablecoin: a plain ERC-20 with an open faucet. Unichain Sepolia
/// has no stable/stable v4 pools, so the test deployment creates its own. Never deploy on a mainnet.
contract TestStable is ERC20 {
    uint8 internal immutable _decimals;
    /// @notice Most one `faucet` call can mint, in whole tokens.
    uint256 public constant MAX_FAUCET_UNITS = 1_000_000;

    error FaucetLimit();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mints `amount` (in base units) to `to`. Anyone may call.
    function faucet(address to, uint256 amount) external {
        if (amount > MAX_FAUCET_UNITS * 10 ** _decimals) revert FaucetLimit();
        _mint(to, amount);
    }
}
