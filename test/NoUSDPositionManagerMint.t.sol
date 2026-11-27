// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {NoUSDRegistry} from "../src/NoUSDRegistry.sol";
import {NoUSDPositionManager} from "../src/NoUSDPositionManager.sol";
import {PoolSelection} from "../src/lib/PoolSelection.sol";
import {BurnRequest} from "../src/lib/ManagerTypes.sol";
import {ManagerFixture, MockOracle, StableToken} from "./utils/ManagerFixture.sol";

/// @notice Manager part 2 against a real PoolManager: mint, compound, applyRange, delayed burn (spec §9).
contract NoUSDPositionManagerMintTest is ManagerFixture {
    uint256 internal constant DEADLINE = type(uint256).max;

    // ───────────── mint ─────────────

    function test_mint_depositBecomesWorkingLiquidity() public {
        uint256 out = _mint(tA, 10_000, alice);
        // Nearly all of the deposit works; the rest comes back as refunds; only the swap costs.
        assertGe(out, 9_990e18);
        assertApproxEqRel(out + _valueOf(alice), 10_000e18, 0.0002e18);
        assertEq(token.balanceOf(alice), out);
        assertGt(mgr.positionLiquidity(idAB), 0);
        _assertSolvent();
        // Refunds: what came back plus what was minted never exceeds the deposit.
        assertLe(out + _valueOf(alice), 10_000e18);
    }

    function test_mint_thenBurn_roundTripCostIsSwapOnly() public {
        uint256 out = _mint(tA, 10_000, alice);
        uint256 refunds = _valueOf(alice);
        vm.prank(alice);
        mgr.burn(out, alice, 0, DEADLINE);
        uint256 back = _valueOf(alice);
        assertApproxEqRel(back, 10_000e18, 0.0002e18);
        assertGe(back, out + refunds - 1e13, "burn returns at least what was credited");
    }

    function test_mint_pairsWithIdle_noSwap() public {
        // ≈ 10 000 B of idle (holders' money): a retired pool's liquidity waiting in the manager.
        _seed(keyBC, 10_000, bob);
        reg.retirePool(idBC);
        uint256 idleB = mgr.idle(_c(tB));
        assertApproxEqRel(idleB, 10_000e6, 0.001e18);
        vm.recordLogs();
        uint256 out = _mint(tA, 4_000, alice);
        _assertNoSwap();
        // The minter is credited for her own A only; about 4 000 B of idle went into the position with it.
        assertApproxEqRel(out, 4_000e18, 0.00001e18);
        assertApproxEqRel(mgr.idle(_c(tB)), idleB - 4_000e6, 0.001e18);
        _assertSolvent();
    }

    function test_mint_partialIdle_swapsTheRest() public {
        _seed(keyBC, 1_000, bob);
        reg.retirePool(idBC);
        uint256 out = _mint(tA, 10_000, alice);
        assertEq(mgr.idle(_c(tB)), 0, "idle used up");
        assertGe(out, 9_990e18);
        assertApproxEqRel(out + _valueOf(alice), 10_000e18, 0.0002e18);
        _assertSolvent();
    }

    function test_mint_picksHigherYieldPool() public {
        // B is in both pools. Build an older observation, then make BC earn far more than AB.
        mgr.sync();
        skip(7 days);
        _churn(keyBC, 200_000, 5);
        _churn(keyAB, 1_000, 1);
        mgr.sync(); // rotates: older = day 0, newer = now
        skip(1 hours);
        vm.recordLogs();
        _mint(tB, 1_000, alice);
        assertEq(PoolId.unwrap(_mintedAddPool()), PoolId.unwrap(idBC));
    }

    function test_mint_soleCandidateWithoutHistory() public {
        // No observations yet: A is only in AB, so AB is chosen with a zero score.
        vm.recordLogs();
        _mint(tA, 100, alice);
        assertEq(PoolId.unwrap(_mintedAddPool()), PoolId.unwrap(idAB));
    }

    function test_mint_noPoolForToken() public {
        StableToken tD = new StableToken("D", 18);
        _timelocked(abi.encodeCall(NoUSDRegistry.admitToken, (_c(tD), true)));
        tD.mint(alice, 1e18);
        vm.startPrank(alice);
        tD.approve(address(mgr), 1e18);
        vm.expectRevert(PoolSelection.NoPoolForToken.selector);
        mgr.mint(_c(tD), 1e18, 0, alice, DEADLINE);
        vm.stopPrank();
    }

    function test_mint_shareCapAfterAdd() public {
        // Outside liquidity is wide; a large concentrated add would exceed 30 % of the active liquidity.
        tA.mint(alice, 5_000_000e18);
        vm.startPrank(alice);
        tA.approve(address(mgr), type(uint256).max);
        vm.expectRevert(NoUSDPositionManager.CapExceeded.selector);
        mgr.mint(_c(tA), 5_000_000e18, 0, alice, DEADLINE);
        vm.stopPrank();
    }

    function test_mint_guards() public {
        tA.mint(alice, 10e18);
        vm.startPrank(alice);
        tA.approve(address(mgr), type(uint256).max);
        vm.expectRevert(NoUSDPositionManager.Expired.selector);
        mgr.mint(_c(tA), 1e18, 0, alice, block.timestamp - 1);
        vm.expectRevert(NoUSDPositionManager.ZeroAmount.selector);
        mgr.mint(_c(tA), 0, 0, alice, DEADLINE);
        vm.expectPartialRevert(NoUSDPositionManager.Slippage.selector);
        mgr.mint(_c(tA), 1e18, 1e18, alice, DEADLINE);
        vm.stopPrank();

        reg.setMintable(_c(tA), false);
        vm.prank(alice);
        vm.expectRevert(NoUSDPositionManager.TokenNotMintable.selector);
        mgr.mint(_c(tA), 1e18, 0, alice, DEADLINE);

        reg.pauseMint();
        vm.prank(alice);
        vm.expectRevert(NoUSDPositionManager.MintPaused.selector);
        mgr.mint(_c(tA), 1e18, 0, alice, DEADLINE);
    }

    function test_mint_supplyCap() public {
        reg.setSupplyCap(1_000e18);
        tA.mint(alice, 2_000e18);
        vm.startPrank(alice);
        tA.approve(address(mgr), type(uint256).max);
        vm.expectRevert(NoUSDPositionManager.SupplyCapExceeded.selector);
        mgr.mint(_c(tA), 2_000e18, 0, alice, DEADLINE);
        mgr.mint(_c(tA), 900e18, 0, alice, DEADLINE);
        vm.stopPrank();
    }

    function test_mint_oracleNoOpinion_closesMint() public {
        oracle.setMode(MockOracle.Mode.NoOpinion);
        tA.mint(alice, 10e18);
        vm.startPrank(alice);
        tA.approve(address(mgr), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NoUSDPositionManager.OracleNoOpinion.selector, idAB));
        mgr.mint(_c(tA), 10e18, 0, alice, DEADLINE);
        vm.stopPrank();
    }

    function test_mint_oracleRevertPropagates() public {
        oracle.setMode(MockOracle.Mode.Revert);
        tA.mint(alice, 10e18);
        vm.startPrank(alice);
        tA.approve(address(mgr), type(uint256).max);
        vm.expectRevert(MockOracle.SpotPriceOutOfBounds.selector);
        mgr.mint(_c(tA), 10e18, 0, alice, DEADLINE);
        vm.stopPrank();
    }

    function test_mint_refusedOffPeg() public {
        _pushPrice(keyAB, 70); // 70 ticks above par: inside the ±100 range, beyond depegBps 50
        tA.mint(alice, 100e18);
        vm.startPrank(alice);
        tA.approve(address(mgr), type(uint256).max);
        vm.expectRevert();
        mgr.mint(_c(tA), 100e18, 0, alice, DEADLINE);
        vm.stopPrank();
    }

    function test_mint_feeGoesToHolders() public {
        _mint(tA, 10_000, bob);
        _timelocked(abi.encodeCall(NoUSDRegistry.setMintFeeBps, (10)));
        uint256 accBefore = token.pendingAccrued(bob);
        uint256 outA = _mint(tA, 10_000, alice);
        uint256 fee = outA / 999; // 0.1 % of the credited value
        assertApproxEqRel(token.pendingAccrued(bob) - accBefore, fee, 0.01e18, "fee distributed at mint");
        assertEq(token.pendingAccrued(alice), 0, "the minter earns none of her own fee");
        _assertSolvent();
    }

    /// @dev Regression: the first add into a pool that already earned fees (any live pool) must not count
    /// the pool's history. v4 initializes our range's ticks in that add, which shifts feeGrowthInside.
    function test_mint_firstIntoPoolWithFeeHistory_noPhantomFees() public {
        _churn(keyAB, 50_000, 5);
        _mint(tA, 1_000, alice);
        mgr.sync();
        assertEq(token.totalUnclaimed() + mgr.carry(), 0);
        _churn(keyAB, 50_000, 1);
        mgr.sync();
        assertGt(token.totalUnclaimed(), 0, "fees after entry are counted");
        assertLt(token.totalUnclaimed(), 1e18, "and only those");
        _assertSolvent();
    }

    /// @dev Regression: a position emptied by retire must not count, on its next add, the fees the pool
    /// earned while it held nothing.
    function test_mint_intoReactivatedPool_noPhantomFees() public {
        _seed(keyAB, 10_000, alice);
        reg.retirePool(idAB);
        _timelocked(abi.encodeCall(NoUSDRegistry.setPoolStatus, (idAB, NoUSDRegistry.PoolStatus.Active)));
        _churn(keyAB, 50_000, 5); // fees accrue in the pool while our position is empty
        mgr.sync();
        uint256 before = token.totalUnclaimed() + mgr.carry();
        _mint(tA, 1_000, bob);
        mgr.sync();
        assertLe(token.totalUnclaimed() + mgr.carry() - before, 1e12, "no fees from the empty period");
        _assertSolvent();
    }

    // ───────────── compound ─────────────

    function test_compound_reinvestsFeesAndIdle() public {
        _mint(tA, 10_000, alice);
        _churn(keyAB, 50_000, 5);
        uint128 before = mgr.positionLiquidity(idAB);
        mgr.compound(idAB);
        assertGt(mgr.positionLiquidity(idAB), before);
        assertLe(mgr.idle(keyAB.currency0) * 1 + mgr.idle(keyAB.currency1) * 1e12, 1e18, "almost all reinvested");
        _assertSolvent();
    }

    function test_compound_threshold() public {
        _mint(tA, 10_000, alice);
        reg.setCompoundThreshold(1_000e18);
        _churn(keyAB, 1_000, 1);
        vm.expectRevert(NoUSDPositionManager.BelowCompoundThreshold.selector);
        mgr.compound(idAB);
    }

    function test_compound_refusedOffPegAndInactive() public {
        _mint(tA, 10_000, alice);
        _churn(keyAB, 50_000, 5);
        _pushPrice(keyAB, 70);
        vm.expectRevert(abi.encodeWithSelector(NoUSDPositionManager.PegCheckFailed.selector, idAB));
        mgr.compound(idAB);
        reg.setPoolStatus(idAB, NoUSDRegistry.PoolStatus.WithdrawOnly);
        vm.expectRevert(NoUSDPositionManager.PoolNotActive.selector);
        mgr.compound(idAB);
    }

    // ───────────── applyRange ─────────────

    function test_applyRange_movesToNewPreset() public {
        _mint(tA, 10_000, alice);
        vm.expectRevert(NoUSDPositionManager.RangeUnchanged.selector);
        mgr.applyRange(idAB);
        int24 par = reg.parTick(keyAB);
        _timelocked(abi.encodeCall(NoUSDRegistry.setPoolRange, (idAB, par - 200, par + 200)));
        uint256 liabBefore = _liabilities();
        mgr.applyRange(idAB);
        (int24 lo, int24 hi,,,,,,,,) = mgr.positions(idAB);
        assertEq(lo, par - 200);
        assertEq(hi, par + 200);
        assertGt(mgr.positionLiquidity(idAB), 0);
        assertEq(_liabilities(), liabBefore);
        _assertSolvent();
    }

    function test_applyRange_needsOracle() public {
        _mint(tA, 10_000, alice);
        int24 par = reg.parTick(keyAB);
        _timelocked(abi.encodeCall(NoUSDRegistry.setPoolRange, (idAB, par - 200, par + 200)));
        oracle.setMode(MockOracle.Mode.NoOpinion);
        vm.expectRevert(abi.encodeWithSelector(NoUSDPositionManager.OracleNoOpinion.selector, idAB));
        mgr.applyRange(idAB);
    }

    // ───────────── delayed burn ─────────────

    function _enableDelay() internal {
        _timelocked(abi.encodeCall(NoUSDRegistry.setBurnDelay, (1 days)));
    }

    function test_delayedBurn_requestThenExecute() public {
        uint256 out = _mint(tA, 10_000, alice);
        _enableDelay();
        vm.prank(alice);
        uint256 id = mgr.requestBurn(out, alice, 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(mgr.escrowed(), out);
        vm.expectRevert(NoUSDPositionManager.NotMatured.selector);
        mgr.executeBurn(id);
        skip(1 days);
        vm.prank(makeAddr("keeper"));
        mgr.executeBurn(id);
        assertEq(mgr.escrowed(), 0);
        assertEq(mgr.queueHead(), 1);
        assertApproxEqRel(_valueOf(alice), 10_000e18, 0.0002e18);
    }

    function test_delayedBurn_escrowEarnsNothing() public {
        uint256 outA = _mint(tA, 10_000, alice);
        _mint(tA, 10_000, bob);
        _enableDelay();
        vm.prank(alice);
        mgr.requestBurn(outA, alice, 0);
        uint256 bobBefore = token.pendingAccrued(bob);
        uint256 unclaimedBefore = token.totalUnclaimed();
        _churn(keyAB, 50_000, 5);
        mgr.sync();
        // Bob is the only eligible holder; the escrow (manager, a contract) is excluded.
        assertApproxEqAbs(token.pendingAccrued(bob) - bobBefore, token.totalUnclaimed() - unclaimedBefore, 10);
        assertEq(token.pendingAccrued(address(mgr)), 0);
    }

    function test_delayedBurn_cancel() public {
        uint256 out = _mint(tA, 10_000, alice);
        _enableDelay();
        vm.prank(alice);
        uint256 id = mgr.requestBurn(out, alice, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NotRequestOwner()"));
        mgr.cancelBurn(id);
        vm.prank(alice);
        mgr.cancelBurn(id);
        assertEq(token.balanceOf(alice), out);
        assertEq(mgr.escrowed(), 0);
        skip(1 days);
        vm.expectRevert(abi.encodeWithSignature("AlreadyDone()"));
        mgr.executeBurn(id);
    }

    function test_executeBurns_skipsFailingAndContinues() public {
        uint256 outA = _mint(tA, 10_000, alice);
        uint256 outB = _mint(tA, 10_000, bob);
        _enableDelay();
        vm.prank(alice);
        uint256 idA = mgr.requestBurn(outA, alice, type(uint128).max); // impossible minOut
        vm.prank(bob);
        uint256 idB = mgr.requestBurn(outB, bob, 0);
        skip(1 days);
        uint256 n = mgr.executeBurns(10);
        assertEq(n, 1);
        assertFalse(mgr.burnRequest(idA).done, "skipped, still pending");
        assertTrue(mgr.burnRequest(idB).done);
        assertEq(mgr.queueHead(), idA, "head waits at the pending request");
        vm.prank(alice);
        mgr.cancelBurn(idA);
        assertEq(mgr.queueHead(), 2);
        _assertSolvent();
    }

    function test_burnStray_respectsEscrow() public {
        uint256 out = _mint(tA, 10_000, alice);
        _enableDelay();
        vm.prank(alice);
        mgr.requestBurn(out / 2, alice, 0);
        mgr.burnStray();
        assertEq(token.balanceOf(address(mgr)), out / 2, "escrow untouched");
    }

    function test_executeOneFromQueue_onlySelf() public {
        vm.expectRevert(NoUSDPositionManager.NotSelf.selector);
        mgr.executeOneFromQueue(0);
    }

    // ───────────── helpers ─────────────

    /// @dev Moves a pool's price `ticks` above par with an exact-output swap through the outside liquidity.
    function _pushPrice(PoolKey memory key, int24 ticks) internal {
        int24 target = reg.parTick(key) + ticks;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(1e30),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _assertNoSwap() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != swapTopic, "unexpected swap");
        }
    }

    function _mintedAddPool() internal returns (PoolId) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = NoUSDPositionManager.Minted.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                (,,,,, PoolId addPool,) =
                    abi.decode(logs[i].data, (Currency, uint256, uint256, uint256, uint256, PoolId, PoolId));
                return addPool;
            }
        }
        revert("no Minted event");
    }
}
