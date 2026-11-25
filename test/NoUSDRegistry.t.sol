// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {NoUSDRegistry} from "../src/NoUSDRegistry.sol";
import {INoUSDPositionManager} from "../src/interfaces/INoUSDPositionManager.sol";

contract MockToken is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, uint8 dec) ERC20(n, n) {
        _dec = dec;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}

contract MockManager is INoUSDPositionManager {
    PoolId public lastRetired;
    uint256 public retireCalls;
    bool public empty = true;

    function retire(PoolId id) external {
        lastRetired = id;
        ++retireCalls;
    }

    function isPositionEmpty(PoolId) external view returns (bool) {
        return empty;
    }

    function setEmpty(bool e) external {
        empty = e;
    }
}

/// @notice NoUSDRegistry: caps, tightening at once, loosening through the 48 h queue (spec §4).
contract NoUSDRegistryTest is Test {
    using PoolIdLibrary for PoolKey;

    NoUSDRegistry internal reg;
    MockManager internal mgr;
    Currency internal usdc; // 6 decimals
    Currency internal usdt; // 6 decimals
    Currency internal dai; // 18 decimals
    address internal safe = makeAddr("safe");

    function setUp() public {
        reg = new NoUSDRegistry(safe);
        mgr = new MockManager();
        usdc = Currency.wrap(address(new MockToken("USDC", 6)));
        usdt = Currency.wrap(address(new MockToken("USDT", 6)));
        dai = Currency.wrap(address(new MockToken("DAI", 18)));
        vm.startPrank(safe);
        reg.admitToken(usdc, true);
        reg.admitToken(usdt, true);
        reg.admitToken(dai, true);
        reg.setOracle(makeAddr("oracle"));
        reg.setTreasury(safe);
        reg.setSupplyCap(100_000e18);
        reg.addPool(_key(usdc, usdt), -100, 100, 1, NoUSDRegistry.PoolStatus.Active);
        reg.setManager(address(mgr)); // setup ends here
        vm.stopPrank();
    }

    function _key(Currency a, Currency b) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return PoolKey({currency0: c0, currency1: c1, fee: 100, tickSpacing: 1, hooks: IHooks(address(0))});
    }

    /// @dev Queue `data`, wait out the timelock and execute it as the Safe.
    function _timelocked(bytes memory data) internal {
        vm.prank(safe);
        reg.queue(data);
        skip(48 hours);
        vm.prank(safe);
        reg.execute(data);
    }

    // ───────────── setup and defaults ─────────────

    function test_defaults() public {
        NoUSDRegistry fresh = new NoUSDRegistry(safe);
        NoUSDRegistry.Params memory p = fresh.params();
        assertEq(p.depegBps, 50);
        assertEq(p.maxPoolShareBps, 3_000);
        assertEq(p.selectionWindow, 7 days);
        assertEq(p.supplyCap, 0);
        assertEq(p.oracle, address(0));
        assertFalse(p.mintPaused);
    }

    function test_setupPhase_configuredWithoutDelay() public view {
        NoUSDRegistry.Params memory p = reg.params();
        assertEq(p.supplyCap, 100_000e18);
        assertEq(reg.poolCount(), 1);
        assertEq(reg.manager(), address(mgr));
    }

    function test_setManager_once() public {
        vm.prank(safe);
        vm.expectRevert(NoUSDRegistry.ManagerAlreadySet.selector);
        reg.setManager(address(1));
    }

    function test_renounceDisabled() public {
        vm.prank(safe);
        vm.expectRevert(NoUSDRegistry.RenounceDisabled.selector);
        reg.renounceOwnership();
    }

    function test_ownershipTwoStep() public {
        address next = makeAddr("next");
        vm.prank(safe);
        reg.transferOwnership(next);
        assertEq(reg.owner(), safe);
        vm.prank(next);
        reg.acceptOwnership();
        assertEq(reg.owner(), next);
    }

    function test_strangerCannotGovern() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.pauseMint();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.queue(abi.encodeCall(NoUSDRegistry.setOracle, (stranger)));
        vm.stopPrank();
    }

    // ───────────── timelock mechanics ─────────────

    function test_loosening_requiresTimelock() public {
        vm.prank(safe);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.setOracle(makeAddr("oracle2"));
    }

    function test_queueExecute() public {
        address o2 = makeAddr("oracle2");
        _timelocked(abi.encodeCall(NoUSDRegistry.setOracle, (o2)));
        assertEq(reg.params().oracle, o2);
    }

    function test_execute_tooEarly() public {
        bytes memory data = abi.encodeCall(NoUSDRegistry.setOracle, (makeAddr("oracle2")));
        vm.prank(safe);
        reg.queue(data);
        skip(48 hours - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(NoUSDRegistry.TimelockNotReady.selector, block.timestamp + 1));
        reg.execute(data);
    }

    function test_cancel() public {
        bytes memory data = abi.encodeCall(NoUSDRegistry.setOracle, (makeAddr("oracle2")));
        vm.startPrank(safe);
        bytes32 hash = reg.queue(data);
        reg.cancel(hash);
        skip(48 hours);
        vm.expectRevert(NoUSDRegistry.NotQueued.selector);
        reg.execute(data);
        vm.stopPrank();
    }

    function test_queue_twiceReverts() public {
        bytes memory data = abi.encodeCall(NoUSDRegistry.unpauseMint, ());
        vm.startPrank(safe);
        reg.queue(data);
        vm.expectRevert(NoUSDRegistry.AlreadyQueued.selector);
        reg.queue(data);
        vm.stopPrank();
    }

    function test_execute_onlyOwner() public {
        bytes memory data = abi.encodeCall(NoUSDRegistry.unpauseMint, ());
        vm.prank(safe);
        reg.queue(data);
        skip(48 hours);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        reg.execute(data);
    }

    function test_execute_bubblesRevert() public {
        bytes memory data = abi.encodeCall(NoUSDRegistry.setProtocolFeeBps, (1_001));
        vm.prank(safe);
        reg.queue(data);
        skip(48 hours);
        vm.prank(safe);
        vm.expectRevert(NoUSDRegistry.CapExceeded.selector);
        reg.execute(data);
    }

    function test_execute_cannotReachOwnerOnlyFunctions() public {
        bytes memory data = abi.encodeCall(Ownable.transferOwnership, (makeAddr("attacker")));
        vm.prank(safe);
        reg.queue(data);
        skip(48 hours);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(reg)));
        reg.execute(data);
    }

    // ───────────── parameters ─────────────

    function test_caps() public {
        vm.startPrank(safe);
        bytes[6] memory calls = [
            abi.encodeCall(NoUSDRegistry.setBurnDelay, (7 days + 1)),
            abi.encodeCall(NoUSDRegistry.setMintFeeBps, (51)),
            abi.encodeCall(NoUSDRegistry.setProtocolFeeBps, (1_001)),
            abi.encodeCall(NoUSDRegistry.setDepegBps, (201)),
            abi.encodeCall(NoUSDRegistry.setMaxPoolShareBps, (5_001)),
            abi.encodeCall(NoUSDRegistry.setSelectionWindow, (31 days))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(reg).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(ret), NoUSDRegistry.CapExceeded.selector);
        }
        vm.expectRevert(NoUSDRegistry.CapExceeded.selector);
        reg.setDepegBps(0);
        vm.expectRevert(NoUSDRegistry.CapExceeded.selector);
        reg.setSelectionWindow(1 days - 1);
        vm.stopPrank();
    }

    function test_depeg_lowerAtOnce_raiseTimelocked() public {
        vm.startPrank(safe);
        reg.setDepegBps(30);
        assertEq(reg.params().depegBps, 30);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.setDepegBps(40);
        vm.stopPrank();
        _timelocked(abi.encodeCall(NoUSDRegistry.setDepegBps, (40)));
        assertEq(reg.params().depegBps, 40);
    }

    function test_burnDelayAndMintFee_timelockedBothWays() public {
        _timelocked(abi.encodeCall(NoUSDRegistry.setBurnDelay, (1 days)));
        _timelocked(abi.encodeCall(NoUSDRegistry.setMintFeeBps, (5)));
        vm.startPrank(safe);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.setBurnDelay(0);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.setMintFeeBps(0);
        vm.stopPrank();
    }

    function test_supplyCap_lowerAtOnce() public {
        vm.startPrank(safe);
        reg.setSupplyCap(50_000e18);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.setSupplyCap(60_000e18);
        vm.stopPrank();
    }

    function test_compoundThreshold_raiseAtOnce() public {
        vm.startPrank(safe);
        reg.setCompoundThreshold(500e18);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.setCompoundThreshold(5e18);
        vm.stopPrank();
    }

    function test_pauseAtOnce_unpauseTimelocked() public {
        vm.startPrank(safe);
        reg.pauseMint();
        assertTrue(reg.params().mintPaused);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.unpauseMint();
        vm.stopPrank();
        _timelocked(abi.encodeCall(NoUSDRegistry.unpauseMint, ()));
        assertFalse(reg.params().mintPaused);
    }

    // ───────────── tokens ─────────────

    function test_admitToken_refusals() public {
        NoUSDRegistry fresh = new NoUSDRegistry(safe);
        Currency wide = Currency.wrap(address(new MockToken("WIDE", 24)));
        vm.startPrank(safe);
        vm.expectRevert(NoUSDRegistry.UnsupportedToken.selector);
        fresh.admitToken(Currency.wrap(address(0)), true);
        vm.expectRevert(NoUSDRegistry.UnsupportedToken.selector);
        fresh.admitToken(wide, true);
        fresh.admitToken(usdc, true);
        vm.expectRevert(NoUSDRegistry.TokenAlreadyAdmitted.selector);
        fresh.admitToken(usdc, true);
        vm.stopPrank();
        assertEq(fresh.scale(usdc), 1e12);
    }

    function test_mintable_offAtOnce_onTimelocked() public {
        vm.startPrank(safe);
        reg.setMintable(usdt, false);
        assertFalse(reg.tokens(usdt).mintable);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.setMintable(usdt, true);
        vm.stopPrank();
    }

    function test_admitToken_timelockedAfterSetup() public {
        Currency usde = Currency.wrap(address(new MockToken("USDe", 18)));
        vm.prank(safe);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.admitToken(usde, true);
        _timelocked(abi.encodeCall(NoUSDRegistry.admitToken, (usde, true)));
        assertTrue(reg.tokens(usde).admitted);
        assertEq(reg.tokens(usde).decimals, 18);
    }

    // ───────────── pools ─────────────

    function test_parTick() public view {
        assertEq(reg.parTick(_key(usdc, usdt)), 0);
        PoolKey memory k = _key(usdc, dai);
        int24 t = reg.parTick(k);
        // 1 DAI-wei-scaled unit per USDC unit: price 1e12 or 1e-12 depending on order → |tick| ≈ 276324.
        if (Currency.unwrap(k.currency0) == Currency.unwrap(usdc)) {
            assertApproxEqAbs(t, 276_324, 1);
        } else {
            assertApproxEqAbs(t, -276_325, 1);
        }
    }

    function test_addPool_validations() public {
        PoolKey memory k = _key(usdc, dai);
        int24 par = reg.parTick(k);
        bytes memory ok =
            abi.encodeCall(NoUSDRegistry.addPool, (k, par - 100, par + 100, 1, NoUSDRegistry.PoolStatus.Active));

        PoolKey memory hooked = _key(usdc, dai); // memory structs alias: build a fresh key
        hooked.hooks = IHooks(address(0x1234));
        _expectExecuteRevert(
            abi.encodeCall(NoUSDRegistry.addPool, (hooked, par - 100, par + 100, 1, NoUSDRegistry.PoolStatus.Active)),
            NoUSDRegistry.PoolHasHooks.selector
        );
        _expectExecuteRevert(
            abi.encodeCall(NoUSDRegistry.addPool, (k, par + 1, par + 100, 1, NoUSDRegistry.PoolStatus.Active)),
            NoUSDRegistry.InvalidRange.selector
        );
        PoolKey memory spaced = _key(usdc, dai);
        spaced.tickSpacing = 10;
        _expectExecuteRevert(
            abi.encodeCall(NoUSDRegistry.addPool, (spaced, par - 101, par + 100, 1, NoUSDRegistry.PoolStatus.Active)),
            NoUSDRegistry.InvalidRange.selector
        );
        _expectExecuteRevert(
            abi.encodeCall(NoUSDRegistry.addPool, (k, par - 100, par + 100, 1, NoUSDRegistry.PoolStatus.None)),
            NoUSDRegistry.InvalidStatus.selector
        );

        _timelocked(ok);
        assertEq(reg.poolCount(), 2);
        NoUSDRegistry.PoolConfig memory cfg = reg.pool(k.toId());
        assertEq(cfg.maxShareBps, 3_000);
        assertEq(uint8(cfg.status), uint8(NoUSDRegistry.PoolStatus.Active));

        _expectExecuteRevert(ok, NoUSDRegistry.PoolAlreadyRegistered.selector);
    }

    function test_addPool_unadmittedToken() public {
        Currency other = Currency.wrap(address(new MockToken("X", 6)));
        bytes memory data =
            abi.encodeCall(NoUSDRegistry.addPool, (_key(usdc, other), -100, 100, 1, NoUSDRegistry.PoolStatus.Active));
        vm.prank(safe);
        reg.queue(data);
        skip(48 hours);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(NoUSDRegistry.TokenNotAdmitted.selector, other));
        reg.execute(data);
    }

    function test_addPool_maxPools() public {
        NoUSDRegistry fresh = new NoUSDRegistry(safe);
        vm.startPrank(safe);
        fresh.admitToken(usdc, true);
        fresh.admitToken(usdt, true);
        for (uint24 fee = 1; fee <= 8; ++fee) {
            PoolKey memory k = _key(usdc, usdt);
            k.fee = fee;
            fresh.addPool(k, -100, 100, 1, NoUSDRegistry.PoolStatus.Active);
        }
        PoolKey memory ninth = _key(usdc, usdt);
        ninth.fee = 9;
        vm.expectRevert(NoUSDRegistry.TooManyPools.selector);
        fresh.addPool(ninth, -100, 100, 1, NoUSDRegistry.PoolStatus.Active);
        vm.stopPrank();
    }

    function test_poolStatus_withdrawOnlyAtOnce_activeTimelocked() public {
        PoolId id = _key(usdc, usdt).toId();
        vm.startPrank(safe);
        reg.setPoolStatus(id, NoUSDRegistry.PoolStatus.WithdrawOnly);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.setPoolStatus(id, NoUSDRegistry.PoolStatus.Active);
        vm.stopPrank();
        _timelocked(abi.encodeCall(NoUSDRegistry.setPoolStatus, (id, NoUSDRegistry.PoolStatus.Active)));
        assertEq(uint8(reg.pool(id).status), uint8(NoUSDRegistry.PoolStatus.Active));
    }

    function test_poolShare_lowerAtOnce() public {
        PoolId id = _key(usdc, usdt).toId();
        vm.startPrank(safe);
        reg.setPoolShare(id, 2_000);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.setPoolShare(id, 2_500);
        vm.stopPrank();
    }

    function test_poolRange_timelockedAndChecked() public {
        PoolId id = _key(usdc, usdt).toId();
        vm.prank(safe);
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        reg.setPoolRange(id, -200, 200);
        _timelocked(abi.encodeCall(NoUSDRegistry.setPoolRange, (id, -200, 200)));
        assertEq(reg.pool(id).tickUpper, 200);
        _expectExecuteRevert(
            abi.encodeCall(NoUSDRegistry.setPoolRange, (id, 10, 200)), NoUSDRegistry.InvalidRange.selector
        );
    }

    function test_retirePool_atOnce_callsManager() public {
        PoolId id = _key(usdc, usdt).toId();
        vm.prank(safe);
        reg.retirePool(id);
        assertEq(uint8(reg.pool(id).status), uint8(NoUSDRegistry.PoolStatus.WithdrawOnly));
        assertEq(mgr.retireCalls(), 1);
        assertEq(PoolId.unwrap(mgr.lastRetired()), PoolId.unwrap(id));
    }

    function test_removePool() public {
        PoolId id = _key(usdc, usdt).toId();
        vm.startPrank(safe);
        vm.expectRevert(NoUSDRegistry.MustBeWithdrawOnly.selector);
        reg.removePool(id);
        reg.retirePool(id);
        mgr.setEmpty(false);
        vm.expectRevert(NoUSDRegistry.PositionNotEmpty.selector);
        reg.removePool(id);
        mgr.setEmpty(true);
        reg.removePool(id);
        vm.stopPrank();
        assertEq(reg.poolCount(), 0);
        vm.prank(safe);
        vm.expectRevert(NoUSDRegistry.PoolNotRegistered.selector);
        reg.setPoolWeight(id, 2);
    }

    /// @dev Queue + wait + execute, expecting the inner call to revert with `selector`.
    function _expectExecuteRevert(bytes memory data, bytes4 selector) internal {
        vm.prank(safe);
        reg.queue(data);
        skip(48 hours);
        vm.prank(safe);
        vm.expectRevert(selector);
        reg.execute(data);
        vm.prank(safe);
        reg.cancel(keccak256(data)); // the revert restored the queued entry; drop it
    }
}
