// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
}
