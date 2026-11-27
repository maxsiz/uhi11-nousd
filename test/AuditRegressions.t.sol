// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NoUSDRegistry} from "../src/NoUSDRegistry.sol";
import {ManagerFixture} from "./utils/ManagerFixture.sol";

/// @dev A contract holder: excluded from accrual by default (spec §5.3).
contract ContractHolder {}

/// @notice Regression tests for the findings of the 2026-11-26 economic audit
/// (docs/audits/2026-11-26-economic-audit.md), each named after its finding id.
contract AuditRegressionsTest is ManagerFixture {
    uint256 internal constant DEADLINE = type(uint256).max;

    /// @dev H-01: eligible supply of 1 wei plus ordinary trading used to overflow accPerShare, after which
    /// every sync — and so burn, claim and mint — reverted forever.
    function test_H01_tinyEligibleSupply_doesNotBrickSync() public {
        address holder = address(new ContractHolder());
        uint256 out = _mint(tA, 50_000, holder);
        assertEq(token.totalSupply() - token.excludedSupply(), 0);
        vm.prank(holder);
        token.transfer(alice, 1); // eligible = 1 wei
        _churn(keyAB, 200_000, 5); // the manager earns well over $1.33 of fees: 1.33e18 / 1 wei overflows uint120
        mgr.sync();
        assertGt(token.treasuryAccrued(), 0, "fees over a wei of eligible supply go to the treasury");
        vm.prank(holder);
        mgr.burn(out - 1, holder, 0, DEADLINE);
        vm.prank(alice);
        mgr.burn(1, alice, 0, DEADLINE);
        _mint(tA, 1_000, bob);
        _assertSolvent();
    }

    /// @dev M-04: the mint fee sat in carry until the next sync and was then spread over eligible supply
    /// that already included the minter's new balance, so a large minter got most of it back.
    function test_M04_minterDoesNotRecoverMintFee() public {
        _mint(tA, 1_000, bob); // small eligible float
        _timelocked(abi.encodeCall(NoUSDRegistry.setMintFeeBps, (50)));
        uint256 out = _mint(tA, 100_000, alice);
        mgr.sync();
        uint256 fee = out * 50 / 9_950;
        assertLt(token.pendingAccrued(alice), fee / 100, "the minter keeps under 1 % of her fee");
        assertApproxEqRel(token.pendingAccrued(bob), fee, 0.02e18, "the fee reaches the existing holder");
        // No solvency assert here: a 100k mint after a 1k one is short of the credit-price measure by
        // about $0.23 with any fee (L-01, the add at a skewed price), which is not what this test is about.
    }

    /// @dev L-02: a mint that swaps in the pool it adds to raised feeGrowthInside with its own swap, and the
    /// next sync multiplied that growth by the post-add liquidity: claims above the fees v4 actually paid.
    function test_L02_mintOwnSwapFees_accruedOnlyOnce() public {
        _seed(keyAB, 10_000, bob);
        mgr.sync();
        uint256 accruedBefore = _claims();
        uint256 idleBefore = _idleAB();
        _mint(tA, 200_000, alice); // no idle B: swaps A→B in AB and adds to AB
        uint256 received = _idleAB() - idleBefore; // the add's modify collected the old liquidity's fees
        assertGt(received, 0, "the mint's own swap paid fees");
        mgr.sync();
        assertApproxEqAbs(_claims() - accruedBefore, received, DUST, "claims grow by the fees received");
        assertGe(_bodyValue() + DUST, _liabilities(), "no unbacked claims");
    }

    function _claims() internal view returns (uint256) {
        return token.totalUnclaimed() + token.treasuryAccrued() + mgr.carry();
    }

    function _idleAB() internal view returns (uint256) {
        return
            mgr.idle(keyAB.currency0) * reg.scale(keyAB.currency0) + mgr.idle(keyAB.currency1)
                * reg.scale(keyAB.currency1);
    }
}
