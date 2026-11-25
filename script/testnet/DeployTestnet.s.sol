// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Deploy} from "../Deploy.s.sol";
import {TestStable} from "./TestStable.sol";

/// @notice Unichain Sepolia (1301) test deployment. The chain has v4 and the unisafe price guard but no
/// stable/stable pools, so this script first creates three test stables (faucet tokens), three hookless
/// pools between them initialized at par with outside liquidity, and v4-core's test routers (the swap
/// router lets anyone push a pool off par to show the depeg guard). Then it runs the regular
/// `Deploy.deploy` with that launch set and writes every address to deployments/1301.json.
///
/// The oracle does not know the test tokens yet: its owner wires their feeds with WireTestFeeds.s.sol
/// before the first mint (until then mint reverts with OracleNoOpinion; redeem is unaffected).
contract DeployTestnet is Deploy {
    uint256 public constant CHAIN_ID = 1301;
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    /// @dev The unisafe ChainlinkPriceOracle on Unichain Sepolia (uniswap-smart-wallet deployments/1301.json).
    address public constant ORACLE = 0x36fD134928577f9fF317bF621CBa03Da26716411;

    /// @dev Outside liquidity per pool: ≈ this many tokens of each side within ±OUTSIDE_TICKS of par.
    uint256 public constant OUTSIDE_UNITS = 250_000;
    int24 public constant OUTSIDE_TICKS = 200;

    string public constant OUT_PATH = "deployments/1301.json";

    struct TestEnv {
        TestStable usdc;
        TestStable usdt;
        TestStable dai;
        PoolModifyLiquidityTest lpRouter;
        PoolSwapTest swapRouter;
        PoolKey[] keys;
    }

    error WrongChain(uint256 chainId);

    function run() external override returns (Deployment memory d) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        address owner = vm.envOr("NOUSD_OWNER", msg.sender);
        vm.startBroadcast();
        TestEnv memory env;
        (d, env) = deployAll(msg.sender, owner);
        if (owner != msg.sender) d.registry.transferOwnership(owner); // the owner then calls acceptOwnership
        vm.stopBroadcast();
        _write(d, env, owner);
    }

    /// @dev `deployer` must be the broadcasting account (or the calling test contract), as in `deploy`.
    function deployAll(address deployer, address treasury) public returns (Deployment memory d, TestEnv memory env) {
        env.usdc = new TestStable("noUSD Test USDC", "tUSDC", 6);
        env.usdt = new TestStable("noUSD Test USDT", "tUSDT", 6);
        env.dai = new TestStable("noUSD Test DAI", "tDAI", 18);
        env.lpRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
        env.swapRouter = new PoolSwapTest(POOL_MANAGER);

        Config memory cfg = testConfig(env, treasury);
        d = deploy(deployer, cfg);

        env.keys = new PoolKey[](cfg.pools.length);
        TestStable[3] memory all = [env.usdc, env.usdt, env.dai];
        for (uint256 i; i < all.length; ++i) {
            // every test token sits in two pools
            all[i].faucet(deployer, 2 * (OUTSIDE_UNITS + 1) * 10 ** all[i].decimals());
            all[i].approve(address(env.lpRouter), type(uint256).max);
        }
        for (uint256 i; i < cfg.pools.length; ++i) {
            env.keys[i] = poolKey(cfg.pools[i]);
            _initWithLiquidity(d, env, env.keys[i]);
        }
    }

    /// @notice The launch set: three test stables, all mintable, and every pair of them as an Active pool
    /// with the same ±100-tick preset as the Ethereum launch.
    function testConfig(TestEnv memory env, address treasury) public pure returns (Config memory cfg) {
        cfg.poolManager = POOL_MANAGER;
        cfg.oracle = ORACLE;
        cfg.treasury = treasury;
        cfg.supplyCap = 1_000_000e18;
        cfg.compoundThreshold = 50e18;
        cfg.tokens = new TokenEntry[](3);
        cfg.tokens[0] = TokenEntry({mintable: true, token: address(env.usdc)});
        cfg.tokens[1] = TokenEntry({mintable: true, token: address(env.usdt)});
        cfg.tokens[2] = TokenEntry({mintable: true, token: address(env.dai)});
        cfg.pools = new PoolEntry[](3);
        cfg.pools[0] = _pool(address(env.usdc), address(env.usdt), 10);
        cfg.pools[1] = _pool(address(env.dai), address(env.usdc), 5);
        cfg.pools[2] = _pool(address(env.dai), address(env.usdt), 100);
    }

    function _pool(address a, address b, uint256 fee) internal pure returns (PoolEntry memory) {
        return
            PoolEntry({currencyA: a, currencyB: b, fee: fee, halfWidthTicks: 100, status: 1, tickSpacing: 1, weight: 1});
    }

    /// @dev Initializes `key` at par and adds ≈ OUTSIDE_UNITS of each side within ±OUTSIDE_TICKS, so the
    /// pairing swap of a mint has depth to trade against.
    function _initWithLiquidity(Deployment memory d, TestEnv memory env, PoolKey memory key) internal {
        int24 par = d.registry.parTick(key);
        uint160 sp = TickMath.getSqrtPriceAtTick(par);
        POOL_MANAGER.initialize(key, sp);
        uint8 d0 = TestStable(Currency.unwrap(key.currency0)).decimals();
        uint8 d1 = TestStable(Currency.unwrap(key.currency1)).decimals();
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(
            sp,
            TickMath.getSqrtPriceAtTick(par - OUTSIDE_TICKS),
            TickMath.getSqrtPriceAtTick(par + OUTSIDE_TICKS),
            OUTSIDE_UNITS * 10 ** d0,
            OUTSIDE_UNITS * 10 ** d1
        );
        env.lpRouter
            .modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: par - OUTSIDE_TICKS,
                    tickUpper: par + OUTSIDE_TICKS,
                    liquidityDelta: int256(uint256(l)),
                    salt: 0
                }),
                ""
            );
    }

    function _write(Deployment memory d, TestEnv memory env, address owner) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "fromBlock", block.number);
        vm.serializeAddress(o, "poolManager", address(POOL_MANAGER));
        vm.serializeAddress(o, "oracle", ORACLE);
        vm.serializeAddress(o, "owner", owner);
        vm.serializeAddress(o, "registry", address(d.registry));
        vm.serializeAddress(o, "manager", address(d.manager));
        vm.serializeAddress(o, "token", address(d.token));
        vm.serializeAddress(o, "tUSDC", address(env.usdc));
        vm.serializeAddress(o, "tUSDT", address(env.usdt));
        vm.serializeAddress(o, "tDAI", address(env.dai));
        vm.serializeAddress(o, "lpRouter", address(env.lpRouter));
        vm.serializeAddress(o, "swapRouter", address(env.swapRouter));
        bytes32[] memory ids = new bytes32[](env.keys.length);
        for (uint256 i; i < env.keys.length; ++i) {
            ids[i] = keccak256(abi.encode(env.keys[i]));
        }
        string memory json = vm.serializeBytes32(o, "poolIds", ids);
        vm.writeJson(json, OUT_PATH);
    }
}
