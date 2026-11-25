// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {NoUSDRegistry} from "../src/NoUSDRegistry.sol";
import {NoUSDPositionManager} from "../src/NoUSDPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {ManagerFixture} from "./utils/ManagerFixture.sol";

/// @notice Manager part 1 against a real PoolManager: sync, burn, claim, treasury, retire (spec §9).
contract NoUSDPositionManagerTest is ManagerFixture {
    using StateLibrary for IPoolManager;

    uint256 internal constant DEADLINE = type(uint256).max;

    function _sync() internal {
        mgr.sync();
    }

    // ───────────── sync ─────────────

    function test_sync_noFees_noDistribution() public {
        _seed(keyAB, 10_000, alice);
        _sync();
        assertEq(token.accPerShare(), 0);
        assertEq(token.totalUnclaimed(), 0);
    }

    function test_sync_accountsFeesAtPar() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        assertApproxEqRel(v, 20_000e18, 0.001e18);
        _churn(keyAB, 50_000, 5);
        _sync();
        uint256 earned = token.pendingAccrued(alice);
        assertGt(earned, 0);
        // Single holder: everything distributed is hers, up to rounding dust.
        assertApproxEqAbs(earned, token.totalUnclaimed(), 2);
        // Swaps left the price slightly off par; valued at the par price the body covers every liability
        // exactly (the drift of spec §6 is only the price move inside the range).
        assertGe(_bodyValueAtPar(), _liabilities(), "solvent at par");
    }

    /// @dev The fees sync counts are exactly what v4 owes the position (same formula, same rounding).
    function test_sync_matchesFeesOwedByV4() public {
        _seed(keyAB, 10_000, alice);
        _churn(keyAB, 50_000, 5);
        (int24 lo, int24 hi,,) = mgr.positions(idAB);
        (uint128 l, uint256 last0, uint256 last1) = pm.getPositionInfo(idAB, address(mgr), lo, hi, bytes32(0));
        (uint256 g0, uint256 g1) = pm.getFeeGrowthInside(idAB, lo, hi);
        uint256 owed;
        unchecked {
            owed = FullMath.mulDiv(g0 - last0, l, FixedPoint128.Q128) * reg.scale(keyAB.currency0)
                + FullMath.mulDiv(g1 - last1, l, FixedPoint128.Q128) * reg.scale(keyAB.currency1);
        }
        assertGt(owed, 0);
        _sync();
        assertEq(token.totalUnclaimed() + mgr.carry(), owed);
    }

    function test_sync_secondCallDistributesNothingNew() public {
        _seed(keyAB, 10_000, alice);
        _churn(keyAB, 50_000, 3);
        _sync();
        uint256 acc = token.accPerShare();
        _sync();
        assertLe(token.accPerShare() - acc, 1, "only carried dust");
    }

    function test_sync_protocolFeeCut() public {
        reg.queue(abi.encodeCall(NoUSDRegistry.setProtocolFeeBps, (1_000)));
        skip(48 hours);
        reg.execute(abi.encodeCall(NoUSDRegistry.setProtocolFeeBps, (1_000)));
        _seed(keyAB, 10_000, alice);
        _churn(keyAB, 50_000, 5);
        _sync();
        uint256 t = token.treasuryAccrued();
        uint256 h = token.totalUnclaimed();
        assertApproxEqRel(t * 9, h, 0.001e18, "10 % to treasury");
    }

    function test_sync_rotatesObs() public {
        _sync();
        (NoUSDPositionManager.Obs memory older, NoUSDPositionManager.Obs memory newer) = mgr.obs(idAB);
        assertEq(older.t, 0);
        assertEq(newer.t, block.timestamp);
        skip(7 days - 1);
        _sync();
        (older,) = mgr.obs(idAB);
        assertEq(older.t, 0, "not yet a full window");
        skip(1);
        _churn(keyAB, 1_000, 1);
        _sync();
        (older, newer) = mgr.obs(idAB);
        assertEq(newer.t, block.timestamp);
        assertEq(older.t, block.timestamp - 7 days);
        assertGt(newer.fg0 + newer.fg1, older.fg0 + older.fg1);
    }

    // ───────────── burn ─────────────

    function test_burn_fullExit_returnsBodyAndFees() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        _churn(keyAB, 50_000, 5);
        vm.prank(alice);
        mgr.burn(v, alice, 0, DEADLINE);
        assertEq(token.totalSupply(), 0);
        // Only dust liquidity stays, backing the 1 wei left in accrued and the carried remainder.
        assertLe(mgr.positionLiquidity(idAB), 1e6);
        assertGt(_valueOf(alice), v, "deposit plus fees");
        assertLe(_bodyValue(), 1e13, "only rounding dust left");
    }

    function test_burn_proRataBetweenHolders() public {
        uint256 va = _seed(keyAB, 30_000, alice);
        uint256 vb = _seed(keyBC, 10_000, bob);
        vm.prank(bob);
        mgr.burn(vb / 2, bob, 0, DEADLINE);
        uint256 got = _valueOf(bob);
        uint256 expected = (vb / 2);
        assertApproxEqRel(got, expected, 0.0001e18);
        // Bob's share came from both positions and holds all three tokens.
        assertGt(tA.balanceOf(bob), 0);
        assertGt(tC.balanceOf(bob), 0);
        assertGe(_bodyValue() + 10, _liabilities());
        assertEq(token.balanceOf(alice), va);
    }

    function test_burn_paysAccruedToo() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        _seed(keyAB, 10_000, bob);
        _churn(keyAB, 50_000, 5);
        _sync();
        uint256 accrued = token.pendingAccrued(alice);
        vm.prank(alice);
        mgr.burn(v, alice, 0, DEADLINE);
        assertApproxEqRel(_valueOf(alice), v + accrued, 0.0001e18);
        assertLe(token.pendingAccrued(alice), 1);
    }

    function test_burn_minOut() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        vm.prank(alice);
        vm.expectPartialRevert(NoUSDPositionManager.Slippage.selector);
        mgr.burn(v, alice, v + 1e18, DEADLINE);
    }

    function test_burn_deadline() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        vm.prank(alice);
        vm.expectRevert(NoUSDPositionManager.Expired.selector);
        mgr.burn(v, alice, 0, block.timestamp - 1);
    }

    function test_burn_delayedModeRefusesInstant() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        reg.queue(abi.encodeCall(NoUSDRegistry.setBurnDelay, (1 days)));
        skip(48 hours);
        reg.execute(abi.encodeCall(NoUSDRegistry.setBurnDelay, (1 days)));
        vm.prank(alice);
        vm.expectRevert(NoUSDPositionManager.UseRequestBurn.selector);
        mgr.burn(v, alice, 0, DEADLINE);
    }

    function test_burn_payoutFailedNamesTokenAndRecipient() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        address frozen = makeAddr("frozen");
        tB.setBlocked(frozen, true);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(NoUSDPositionManager.PayoutFailed.selector, Currency.wrap(address(tB)), frozen)
        );
        mgr.burn(v, frozen, 0, DEADLINE);
        vm.prank(alice);
        mgr.burn(v, bob, 0, DEADLINE); // another recipient works
        assertGt(_valueOf(bob), 0);
    }

    // ───────────── claim ─────────────

    function test_claim_paysAccruedKeepsSupply() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        _churn(keyAB, 50_000, 5);
        _sync();
        uint256 accrued = token.pendingAccrued(alice);
        vm.prank(alice);
        uint256 paid = mgr.claim(alice, 0, DEADLINE);
        assertApproxEqRel(paid, accrued, 0.001e18);
        assertEq(token.totalSupply(), v);
        assertEq(token.balanceOf(alice), v);
        assertGe(_bodyValueAtPar(), _liabilities(), "solvent at par");
        vm.prank(alice);
        assertEq(mgr.claim(alice, 0, DEADLINE), 0);
    }

    function test_claimTreasury_onlyTreasury() public {
        reg.queue(abi.encodeCall(NoUSDRegistry.setProtocolFeeBps, (1_000)));
        skip(48 hours);
        reg.execute(abi.encodeCall(NoUSDRegistry.setProtocolFeeBps, (1_000)));
        _seed(keyAB, 10_000, alice);
        _churn(keyAB, 50_000, 5);
        vm.prank(alice);
        vm.expectRevert(NoUSDPositionManager.NotTreasury.selector);
        mgr.claimTreasury(alice, 0, DEADLINE);
        vm.prank(treasury);
        uint256 paid = mgr.claimTreasury(treasury, 0, DEADLINE);
        assertGt(paid, 0);
        assertEq(token.treasuryAccrued(), 0);
    }

    // ───────────── retire, stray, guards ─────────────

    function test_retire_movesLiquidityToIdle_burnPaysIdle() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        vm.expectRevert(NoUSDPositionManager.NotRegistry.selector);
        mgr.retire(idAB);
        reg.retirePool(idAB);
        assertEq(mgr.positionLiquidity(idAB), 0);
        assertTrue(mgr.isPositionEmpty(idAB));
        assertGt(mgr.idle(keyAB.currency0), 0);
        assertGe(_bodyValue() + 10, _liabilities());
        reg.removePool(idAB);
        vm.prank(alice);
        mgr.burn(v, alice, 0, DEADLINE);
        // Idle of the removed pool's currencies is still paid out.
        assertApproxEqRel(_valueOf(alice), v, 0.0001e18);
    }

    function test_burnStray() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        vm.prank(alice);
        token.transfer(address(mgr), v / 10);
        mgr.burnStray();
        assertEq(token.balanceOf(address(mgr)), 0);
        assertEq(token.totalSupply(), v - v / 10);
        assertGe(_bodyValue(), _liabilities());
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(NoUSDPositionManager.NotPoolManager.selector);
        mgr.unlockCallback("");
    }

    function test_reclassify_forwards() public {
        uint256 v = _seed(keyAB, 10_000, alice);
        assertEq(v, token.balanceOf(alice));
        vm.etch(alice, hex"6000");
        mgr.reclassify(alice);
        assertTrue(token.isExcluded(alice));
    }

    function test_unknownPoolIdIsEmpty() public view {
        assertTrue(mgr.isPositionEmpty(PoolId.wrap(bytes32(uint256(1)))));
    }
}
