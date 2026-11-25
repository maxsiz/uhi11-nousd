// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {NoUSDPositionManager} from "../../src/NoUSDPositionManager.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployTestnet} from "../../script/testnet/DeployTestnet.s.sol";
import {TestStable} from "../../script/testnet/TestStable.sol";
import {IOracleAdmin, WireTestFeeds} from "../../script/testnet/WireTestFeeds.s.sol";

/// @notice Dry run of the Unichain Sepolia deployment (script/testnet) against the live chain: the real
/// PoolManager and the real unisafe oracle, its feeds wired by pranking the oracle owner. Needs
/// WEB3_QUICKNODE_UNI_SEP (behind the `unichain-sepolia` RPC alias) in .env; skipped without it.
contract UnichainSepoliaForkTest is Test {
    uint256 internal constant DEADLINE = type(uint256).max;

    DeployTestnet internal script;
    WireTestFeeds internal feeds;
    Deploy.Deployment internal d;
    TestStable internal usdc;
    TestStable internal usdt;
    TestStable internal dai;
    PoolSwapTest internal swapRouter;
    PoolKey[] internal keys;

    address internal alice = makeAddr("alice");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        if (bytes(vm.envOr("WEB3_QUICKNODE_UNI_SEP", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("unichain-sepolia");
        script = new DeployTestnet();
        feeds = new WireTestFeeds();
        DeployTestnet.TestEnv memory env;
        (d, env) = script.deployAll(address(script), treasury);
        usdc = env.usdc;
        usdt = env.usdt;
        dai = env.dai;
        swapRouter = env.swapRouter;
        for (uint256 i; i < env.keys.length; ++i) {
            keys.push(env.keys[i]);
        }

        IOracleAdmin oracle = IOracleAdmin(script.ORACLE());
        vm.startPrank(oracle.owner());
        oracle.setFeed(Currency.wrap(address(usdc)), feeds.USDC_USD(), feeds.HEARTBEAT(), 6);
        oracle.setFeed(Currency.wrap(address(usdt)), feeds.USDT_USD(), feeds.HEARTBEAT(), 6);
        oracle.setFeed(Currency.wrap(address(dai)), feeds.USDC_USD(), feeds.HEARTBEAT(), 18);
        vm.stopPrank();
    }

    function _mint(address who, TestStable t, uint256 units) internal returns (uint256 out) {
        uint256 amount = units * 10 ** t.decimals();
        vm.startPrank(who);
        t.faucet(who, amount);
        t.approve(address(d.manager), amount);
        out = d.manager.mint(Currency.wrap(address(t)), amount, 0, who, DEADLINE);
        vm.stopPrank();
    }

    function test_unichainSepolia_wiring() public view {
        assertEq(address(d.manager.poolManager()), address(script.POOL_MANAGER()));
        assertEq(d.registry.params().oracle, script.ORACLE());
        assertEq(d.registry.poolCount(), 3);
        assertEq(d.registry.manager(), address(d.manager));
    }

    function test_unichainSepolia_mintWithEachToken_thenRedeem() public {
        TestStable[3] memory all = [usdc, usdt, dai];
        for (uint256 i; i < all.length; ++i) {
            uint256 out = _mint(alice, all[i], 10_000);
            // value at par minus swap cost and rounding: within 0.5 %
            assertApproxEqRel(out, 10_000e18, 0.005e18, "mint value");
        }
        uint256 bal = d.token.balanceOf(alice);
        vm.prank(alice);
        d.manager.burn(bal / 2, alice, 0, DEADLINE);
        uint256 back = usdc.balanceOf(alice) * 1e12 + usdt.balanceOf(alice) * 1e12 + dai.balanceOf(alice);
        // in kind at par: never less than the noUSD burned, at most 1 % more (mint rounds in the body's favour)
        assertGe(back, bal / 2, "redeem value");
        assertApproxEqRel(back, bal / 2, 0.01e18, "redeem value");
        assertEq(d.token.balanceOf(alice), bal - bal / 2);
    }

    /// @dev The demo of the depeg guard: push a pool off par with the deployed swap router, then a mint that
    /// needs it reverts, while redeem keeps working.
    function test_unichainSepolia_offPar_closesMint_notRedeem() public {
        _mint(alice, usdc, 10_000);
        _mint(alice, usdt, 10_000);
        _mint(alice, dai, 10_000);

        address whale = makeAddr("whale");
        vm.startPrank(whale);
        for (uint256 i; i < keys.length; ++i) {
            PoolKey memory key = keys[i];
            TestStable t0 = TestStable(Currency.unwrap(key.currency0));
            t0.faucet(whale, 200_000 * 10 ** t0.decimals());
            t0.approve(address(swapRouter), type(uint256).max);
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(200_000 * 10 ** t0.decimals()),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        vm.stopPrank();

        uint256 amount = 1_000e6;
        vm.startPrank(alice);
        usdc.faucet(alice, amount);
        usdc.approve(address(d.manager), amount);
        vm.expectRevert();
        d.manager.mint(Currency.wrap(address(usdc)), amount, 0, alice, DEADLINE);
        uint256 bal = d.token.balanceOf(alice);
        d.manager.burn(bal, alice, 0, DEADLINE);
        vm.stopPrank();
        assertEq(d.token.balanceOf(alice), 0);
    }
}
