// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {NoUSD} from "../src/NoUSD.sol";

/// @dev A holder that is a contract (excluded by default).
contract Holder {
    function optIn(NoUSD token, bool on) external {
        token.configureAccrual(on);
    }

    function send(NoUSD token, address to, uint256 value) external {
        token.transfer(to, value);
    }
}

/// @notice Unit tests of the NoUSD token (spec §5). The test contract is the manager.
contract NoUSDTest is Test {
    NoUSD internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        token = new NoUSD(address(this));
    }

    // ───────────── ERC-20 ─────────────

    function test_metadata() public view {
        assertEq(token.name(), "noUSD");
        assertEq(token.symbol(), "noUSD");
        assertEq(token.decimals(), 18);
        assertEq(token.manager(), address(this));
    }

    function test_transfer() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 40e18));
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_transfer_insufficient() public {
        token.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 2e18));
        token.transfer(bob, 2e18);
    }

    function test_transfer_toZero() public {
        token.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_transferFrom_allowance() public {
        token.mint(alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 4e18);
        vm.prank(bob);
        token.transferFrom(alice, carol, 3e18);
        assertEq(token.allowance(alice, bob), 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 1e18, 2e18));
        token.transferFrom(alice, carol, 2e18);
    }

    function test_transferFrom_infiniteAllowance() public {
        token.mint(alice, 10e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 3e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_selfTransfer() public {
        token.mint(alice, 10e18);
        token.distribute(5e18);
        vm.prank(alice);
        token.transfer(alice, 4e18);
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.accrued(alice), 5e18);
    }

    function test_onlyManager() public {
        vm.startPrank(alice);
        vm.expectRevert(NoUSD.NotManager.selector);
        token.mint(alice, 1);
        vm.expectRevert(NoUSD.NotManager.selector);
        token.burnFrom(alice, 1);
        vm.expectRevert(NoUSD.NotManager.selector);
        token.distribute(1);
        vm.expectRevert(NoUSD.NotManager.selector);
        token.consumeAccrued(alice);
        vm.expectRevert(NoUSD.NotManager.selector);
        token.accrueTreasury(1);
        vm.expectRevert(NoUSD.NotManager.selector);
        token.consumeTreasury();
        vm.stopPrank();
    }

    function test_pullToManager() public {
        token.mint(alice, 10e18);
        token.distribute(5e18);
        token.pullToManager(alice, 4e18);
        assertEq(token.balanceOf(address(this)), 4e18);
        assertEq(token.accrued(alice), 5e18, "settled before the move");
        assertTrue(token.isExcluded(address(this)), "manager is a contract, excluded");
        vm.prank(alice);
        vm.expectRevert(NoUSD.NotManager.selector);
        token.pullToManager(alice, 1);
    }

    function test_mint_overflowReverts() public {
        token.mint(alice, type(uint128).max);
        vm.expectRevert(NoUSD.BalanceOverflow.selector);
        token.mint(alice, 1);
    }

    function test_burnFrom() public {
        token.mint(alice, 10e18);
        token.burnFrom(alice, 4e18);
        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.totalSupply(), 6e18);
    }

    // ───────────── accumulator (spec §5.2, §14 worked example) ─────────────

    /// @notice Alice 600k, Bob 400k; 12:00 Alice → Carol 200k; 24:00 sync $100; Carol burns 100k and is
    /// paid her accrued; Bob claims. Variant L gives 40 / 40 / 20.
    function test_workedExample_40_40_20() public {
        token.mint(alice, 600_000e18);
        token.mint(bob, 400_000e18);

        vm.prank(alice);
        token.transfer(carol, 200_000e18);

        assertEq(token.distribute(100e18), 0);
        assertEq(token.totalUnclaimed(), 100e18);

        uint256 carolPaid = token.consumeAccrued(carol);
        token.burnFrom(carol, 100_000e18);
        uint256 bobPaid = token.consumeAccrued(bob);

        // 1 wei stays in each consumed slot.
        assertEq(carolPaid, 20e18 - 1);
        assertEq(bobPaid, 40e18 - 1);
        assertEq(token.pendingAccrued(alice), 40e18);
        assertEq(token.totalUnclaimed(), 40e18 + 2);
    }

    function test_distribute_remainderCarried() public {
        token.mint(alice, 3);
        token.mint(bob, 4);
        // eligible = 7 wei: 10e18 / 7 leaves a remainder.
        uint256 value = 10;
        uint256 remainder = token.distribute(value);
        uint256 distributed = token.totalUnclaimed();
        assertEq(distributed + remainder, value);
        assertGe(distributed, token.pendingAccrued(alice) + token.pendingAccrued(bob));
    }

    function test_distribute_noEligible_toTreasury() public {
        Holder h = new Holder();
        token.mint(address(h), 5e18); // contract → excluded
        assertEq(token.distribute(7e18), 0);
        assertEq(token.treasuryAccrued(), 7e18);
        assertEq(token.accPerShare(), 0);
    }

    function test_distribute_overflowReverts() public {
        token.mint(alice, 1);
        vm.expectRevert(NoUSD.AccumulatorOverflow.selector);
        token.distribute(2e18);
    }

    function test_newHolder_earnsOnlyAfterEntry() public {
        token.mint(alice, 100e18);
        token.distribute(10e18);
        token.mint(bob, 100e18);
        assertEq(token.pendingAccrued(bob), 0);
        token.distribute(20e18);
        assertEq(token.pendingAccrued(alice), 20e18);
        assertEq(token.pendingAccrued(bob), 10e18);
    }

    function test_consumeAccrued_leavesOneWei() public {
        token.mint(alice, 100e18);
        token.distribute(10e18);
        assertEq(token.consumeAccrued(alice), 10e18 - 1);
        assertEq(token.accrued(alice), 1);
        assertEq(token.consumeAccrued(alice), 0);
        token.distribute(5e18);
        assertEq(token.consumeAccrued(alice), 5e18);
        assertEq(token.accrued(alice), 1);
    }

    function test_treasury() public {
        token.accrueTreasury(3e18);
        assertEq(token.consumeTreasury(), 3e18);
        assertEq(token.treasuryAccrued(), 0);
    }

    // ───────────── accrual modes (spec §5.3) ─────────────

    function test_contractExcludedByDefault() public {
        Holder h = new Holder();
        token.mint(alice, 100e18);
        token.mint(address(h), 100e18);
        assertTrue(token.isExcluded(address(h)));
        assertEq(token.excludedSupply(), 100e18);
        token.distribute(10e18);
        assertEq(token.pendingAccrued(alice), 10e18);
        assertEq(token.pendingAccrued(address(h)), 0);
    }

    function test_transfer_excludedSupplyBothWays() public {
        Holder h = new Holder();
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.transfer(address(h), 30e18);
        assertEq(token.excludedSupply(), 30e18);
        h.send(token, bob, 10e18);
        assertEq(token.excludedSupply(), 20e18);
        assertEq(token.eligibleSupply(), 80e18);
    }

    function test_7702Delegation_isEOA() public {
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(0xC0DE)));
        token.mint(delegated, 1e18);
        assertFalse(token.isExcluded(delegated));
    }

    function test_contractOptIn() public {
        Holder h = new Holder();
        token.mint(address(h), 50e18);
        h.optIn(token, true);
        assertFalse(token.isExcluded(address(h)));
        assertEq(token.excludedSupply(), 0);
        token.distribute(5e18);
        assertEq(token.pendingAccrued(address(h)), 5e18);
    }

    function test_eoaOptOut_survivesReclassify() public {
        token.mint(alice, 50e18);
        token.mint(bob, 50e18);
        vm.prank(alice);
        token.configureAccrual(false);
        token.reclassify(alice); // must not undo the holder's own choice
        assertTrue(token.isExcluded(alice));
        token.distribute(10e18);
        assertEq(token.pendingAccrued(alice), 0);
        assertEq(token.pendingAccrued(bob), 10e18);
    }

    function test_optOut_keepsAccrued() public {
        token.mint(alice, 100e18);
        token.distribute(10e18);
        vm.prank(alice);
        token.configureAccrual(false);
        assertEq(token.pendingAccrued(alice), 10e18);
    }

    function test_reclassify_bothDirections() public {
        address a = makeAddr("lateContract");
        token.mint(a, 100e18);
        token.distribute(10e18);
        assertFalse(token.isExcluded(a));

        vm.etch(a, hex"6000");
        token.reclassify(a);
        assertTrue(token.isExcluded(a));
        assertEq(token.excludedSupply(), 100e18);
        assertEq(token.pendingAccrued(a), 10e18, "accrued before exclusion stays");

        vm.etch(a, "");
        token.reclassify(a);
        assertFalse(token.isExcluded(a));
        assertEq(token.excludedSupply(), 0);
    }

    function test_reclassify_noopWhenUnchanged() public {
        token.mint(alice, 1e18);
        vm.recordLogs();
        token.reclassify(alice);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ───────────── fuzz ─────────────

    function testFuzz_distributionConservesValue(uint96 a, uint96 b, uint96 c, uint96 value) public {
        vm.assume(uint256(a) + b + c > 0);
        token.mint(alice, a);
        token.mint(bob, b);
        token.mint(carol, c);
        uint256 remainder;
        // Bound value so accPerShare fits in uint120 for tiny supplies.
        uint256 v = bound(value, 0, (uint256(a) + b + c) * 1e18);
        remainder = token.distribute(v);
        uint256 sumPending = token.pendingAccrued(alice) + token.pendingAccrued(bob) + token.pendingAccrued(carol);
        assertEq(token.totalUnclaimed() + remainder, v);
        assertLe(sumPending, token.totalUnclaimed());
        assertLe(token.totalUnclaimed() - sumPending, 4, "dust: under 1 wei per holder plus 1 from rounding up");
    }
}
