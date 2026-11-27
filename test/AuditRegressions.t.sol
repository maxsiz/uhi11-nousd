// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NoUSDPositionManager} from "../src/NoUSDPositionManager.sol";
import {NoUSDRegistry} from "../src/NoUSDRegistry.sol";
import {ManagerFixture} from "./utils/ManagerFixture.sol";

/// @dev A contract holder: excluded from accrual by default (spec §5.3).
contract ContractHolder {}

/// @dev StableToken's storage layout plus a Tether-style transfer fee: min(value × bps / 10 000, max), kept by
/// `feeSink`. Etched over a fixture token to model USDT switching its fee on.
contract FeeStableToken is ERC20 {
    uint8 internal immutable _dec;
    mapping(address => bool) public blocked; // StableToken's slot
    uint256 public basisPointsRate;
    uint256 public maximumFee;
    address public feeSink;

    constructor(string memory n, uint8 dec) ERC20(n, n) {
        _dec = dec;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }

    function setFee(uint256 bps, uint256 maxFee, address sink) external {
        basisPointsRate = bps;
        maximumFee = maxFee;
        feeSink = sink;
    }

    function _update(address from, address to, uint256 v) internal override {
        if (from == address(0) || to == address(0) || basisPointsRate == 0) return super._update(from, to, v);
        uint256 fee = v * basisPointsRate / 10_000;
        if (fee > maximumFee) fee = maximumFee;
        super._update(from, to, v - fee);
        if (fee != 0) super._update(from, feeSink, fee);
    }
}

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

    /// @dev L-07: with a transfer fee on the deposit token, mint credited the requested amount although
    /// settle() received less; the shortfall came out of holders' idle claims of that token.
    function test_L07_feeOnTransferDeposit_creditsWhatArrived() public {
        _seed(keyAB, 50_000, bob);
        _seed(keyBC, 20_000, bob);
        reg.retirePool(idBC); // holders' B now sits idle
        _markCredit();
        uint256 idleB = mgr.idle(_c(tB));
        vm.etch(address(tB), address(new FeeStableToken("B", 6)).code);
        FeeStableToken(address(tB)).setFee(19, 49e6, makeAddr("tetherOwner")); // Tether's hard caps
        for (uint256 i; i < 5; ++i) {
            _mint(tB, 10_000, alice);
        }
        assertGe(mgr.idle(_c(tB)) + 1e6, idleB, "holders' idle B is not spent on the minter's fee");
        _assertSolvent();
    }

    /// @dev L-04: a request made while burnDelay was 0 matured at once and stayed an instant exit after the
    /// delay was raised. Requests now need a delay; with none, burn is the path.
    function test_L04_requestBurnNeedsDelay() public {
        uint256 out = _mint(tA, 1_000, alice);
        vm.prank(alice);
        vm.expectRevert(NoUSDPositionManager.UseBurn.selector);
        mgr.requestBurn(out, alice, 0);
    }
}
