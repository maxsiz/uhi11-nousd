// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {NoUSD} from "../../src/NoUSD.sol";
import {NoUSDPositionManager} from "../../src/NoUSDPositionManager.sol";
import {NoUSDRegistry} from "../../src/NoUSDRegistry.sol";
import {Deploy} from "../../script/Deploy.s.sol";

/// @dev Minimal swap router that settles with SafeERC20: v4-core's PoolSwapTest expects a bool from
/// transferFrom, which USDT does not return.
contract SafeSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external {
        pm.unlock(abi.encode(msg.sender, key, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory key, SwapParams memory params) = abi.decode(data, (address, PoolKey, SwapParams));
        BalanceDelta d = pm.swap(key, params, "");
        _settle(key.currency0, d.amount0(), payer);
        _settle(key.currency1, d.amount1(), payer);
        return "";
    }

    function _settle(Currency c, int128 amount, address payer) internal {
        if (amount < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).safeTransferFrom(payer, address(pm), uint128(-amount));
            pm.settle();
        } else if (amount > 0) {
            pm.take(c, payer, uint128(amount));
        }
    }
}

/// @notice Ethereum mainnet fork (spec §14): the launch configuration of script/config/1.json against the
/// real pools, tokens and the deployed unisafe price guard. Needs ENVELOP_MAINNET (an RPC URL, read from
/// .env by forge); skipped without it, so CI stays green with no secrets.
contract EthereumForkTest is Test {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BLOCK = 26_490_770; // pinned: reproducible and cached
    uint256 internal constant DEADLINE = type(uint256).max;

    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    Deploy internal script;
    PoolKey[] internal launchKeys;
    NoUSDRegistry internal reg;
    NoUSDPositionManager internal mgr;
    NoUSD internal token;
    IPoolManager internal pm;
    PoolKey internal keyUsdeUsdc;
    PoolKey internal keyDaiUsdt;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        string memory rpc = vm.envOr("ENVELOP_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, BLOCK);
        script = new Deploy();
        Deploy.Config memory cfg = script.loadConfig(1, treasury);
        cfg.compoundThreshold = 1; // let the fork test compound whatever fees its own swaps produce
        Deploy.Deployment memory d = script.deploy(address(script), cfg);
        reg = d.registry;
        mgr = d.manager;
        token = d.token;
        pm = cfg.poolManager;
        for (uint256 i; i < cfg.pools.length; ++i) {
            launchKeys.push(script.poolKey(cfg.pools[i]));
        }
        keyUsdeUsdc = launchKeys[0];
        keyDaiUsdt = launchKeys[1];
    }

    // ───────────── helpers ─────────────

    function _units(address t, uint256 n) internal view returns (uint256) {
        return n * 10 ** _decimals(t);
    }

    function _decimals(address t) internal view returns (uint8) {
        (bool ok, bytes memory ret) = t.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok);
        return abi.decode(ret, (uint8));
    }

    function _mint(address who, address t, uint256 n) internal returns (uint256 out) {
        uint256 amount = _units(t, n);
        deal(t, who, amount);
        vm.startPrank(who);
        IERC20(t).forceApprove(address(mgr), amount);
        out = mgr.mint(Currency.wrap(t), amount, 0, who, DEADLINE);
        vm.stopPrank();
    }

    /// @dev Value at par a holder holds in the four launch tokens.
    function _valueOf(address who) internal view returns (uint256) {
        return IERC20(USDE).balanceOf(who) + IERC20(USDC).balanceOf(who) * 1e12 + IERC20(DAI).balanceOf(who)
            + IERC20(USDT).balanceOf(who) * 1e12;
    }

    /// @dev Round-trip volume through a pool with v4-core's test router.
    function _churn(PoolKey memory key, uint256 units, uint256 rounds) internal {
        SafeSwapRouter router = new SafeSwapRouter(pm);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        deal(c0, address(this), _units(c0, units * rounds * 2));
        deal(c1, address(this), _units(c1, units * rounds * 2));
        IERC20(c0).forceApprove(address(router), type(uint256).max);
        IERC20(c1).forceApprove(address(router), type(uint256).max);
        for (uint256 i; i < rounds; ++i) {
            router.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(_units(c0, units)),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                })
            );
            router.swap(
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(_units(c1, units)),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                })
            );
        }
    }

    // ───────────── tests ─────────────

    function test_fork_launchPoolsLiveAndInsidePresets() public view {
        for (uint256 i; i < launchKeys.length; ++i) {
            PoolKey memory key = launchKeys[i];
            (uint160 sp, int24 tick,,) = pm.getSlot0(key.toId());
            assertGt(sp, 0, "pool initialized");
            NoUSDRegistry.PoolConfig memory p = reg.pool(key.toId());
            assertGe(tick, p.tickLower, "inside preset");
            assertLt(tick, p.tickUpper, "inside preset");
        }
    }

    function test_fork_mintWithEachLaunchToken_thenBurn() public {
        address[4] memory tokens = [USDE, USDC, DAI, USDT];
        for (uint256 i; i < 4; ++i) {
            address who = makeAddr(string.concat("minter", vm.toString(i)));
            uint256 out = _mint(who, tokens[i], 1_000);
            uint256 refunds = _valueOf(who);
            assertGe(out, 995e18, "at least 99.5 % of the deposit works");
            assertApproxEqRel(out + refunds, 1_000e18, 0.003e18, "only the swap costs");
            vm.prank(who);
            mgr.burn(out, who, out * 99 / 100, DEADLINE);
            assertApproxEqRel(_valueOf(who), 1_000e18, 0.005e18, "round trip");
        }
    }

    function test_fork_feesSyncClaimCompound() public {
        _mint(alice, USDC, 20_000);
        _churn(keyUsdeUsdc, 100_000, 3);
        mgr.sync();
        uint256 accrued = token.pendingAccrued(alice);
        assertGt(accrued, 0, "real pool fees reach the holder");
        vm.prank(alice);
        uint256 paid = mgr.claim(alice, 0, DEADLINE);
        assertApproxEqRel(paid, accrued, 0.01e18);
        _churn(keyUsdeUsdc, 100_000, 1);
        mgr.compound(keyUsdeUsdc.toId());
    }

    function test_fork_staleFeeds_closeMint_burnStillWorks() public {
        uint256 out = _mint(alice, USDC, 1_000);
        skip(3 days); // past every stable feed's heartbeat: the guard has no opinion
        deal(USDC, bob, 1_000e6);
        vm.startPrank(bob);
        IERC20(USDC).forceApprove(address(mgr), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(NoUSDPositionManager.OracleNoOpinion.selector, keyUsdeUsdc.toId()));
        mgr.mint(Currency.wrap(USDC), 1_000e6, 0, bob, DEADLINE);
        vm.stopPrank();
        vm.prank(alice);
        mgr.burn(out, alice, 0, DEADLINE);
        assertApproxEqRel(_valueOf(alice), 1_000e18, 0.005e18);
    }

    /// @dev Burn across both active launch positions (four distinct tokens), after an earlier burn and
    /// claim so idle, claims and accrued slots are non-zero. Spec §9.2 target for the full launch set
    /// (three positions, six tokens) is 650k; two positions and four tokens must stay well under it.
    function test_fork_gas_burnAcrossLaunchPositions() public {
        _mint(alice, USDC, 20_000);
        _mint(alice, USDT, 20_000);
        _mint(bob, USDC, 1_000);
        _churn(keyUsdeUsdc, 50_000, 1);
        _churn(keyDaiUsdt, 50_000, 1);
        uint256 warm = token.balanceOf(bob);
        vm.prank(bob);
        mgr.burn(warm, bob, 0, DEADLINE);
        vm.prank(alice);
        mgr.claim(alice, 0, DEADLINE);
        _churn(keyUsdeUsdc, 50_000, 1);

        uint256 x = token.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 g = gasleft();
        mgr.burn(x, alice, 0, DEADLINE);
        uint256 used = g - gasleft();
        emit log_named_uint("fork burn, 2 positions, 4 tokens", used);
        assertLe(used, 650_000);

        g = gasleft();
        mgr.sync();
        emit log_named_uint("fork sync, 3 registered pools", g - gasleft());
    }
}
