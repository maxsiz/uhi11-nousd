// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NoUSD} from "../../src/NoUSD.sol";

/// @dev Reference: a plain OpenZeppelin ERC-20.
contract PlainToken is ERC20 {
    constructor() ERC20("plain", "PLAIN") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}

/// @notice Transfer overhead of the accumulator against a plain OZ ERC-20 measured the same way, so the
/// harness's own costs cancel out. Spec §14: ≈ 37k vs 34.5k (+2.5k) when no sync happened since the last
/// touch, ≈ 47k (+12.5k) on the first transfer after a sync.
contract NoUSDGasTest is Test {
    uint256 internal constant WARM_OVERHEAD = 2_500;
    uint256 internal constant AFTER_SYNC_OVERHEAD = 12_500;

    NoUSD internal token;
    PlainToken internal plain;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new NoUSD(address(this));
        plain = new PlainToken();
        token.mint(alice, 1_000e18);
        token.mint(bob, 1_000e18);
        plain.mint(alice, 1_000e18);
        plain.mint(bob, 1_000e18);
        token.distribute(10e18);
        // Long-lived holders: both already have a non-zero accrued slot and current checkpoints.
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function _gas(address t) internal returns (uint256 used) {
        vm.cool(t);
        vm.prank(alice);
        uint256 g = gasleft();
        ERC20(t).transfer(bob, 1e18);
        used = g - gasleft();
    }

    function test_gas_transfer_noSyncSinceLastTouch() public {
        uint256 base = _gas(address(plain));
        uint256 ours = _gas(address(token));
        emit log_named_uint("plain ERC-20", base);
        emit log_named_uint("noUSD, no sync since last touch", ours);
        assertLe(ours, base + WARM_OVERHEAD);
    }

    function test_gas_transfer_firstAfterSync() public {
        token.distribute(10e18);
        uint256 base = _gas(address(plain));
        uint256 ours = _gas(address(token));
        emit log_named_uint("plain ERC-20", base);
        emit log_named_uint("noUSD, first transfer after sync", ours);
        assertLe(ours, base + AFTER_SYNC_OVERHEAD);
    }
}
