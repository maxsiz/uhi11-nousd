// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {NoUSD} from "../src/NoUSD.sol";
import {NoUSDPositionManager} from "../src/NoUSDPositionManager.sol";
import {NoUSDRegistry} from "../src/NoUSDRegistry.sol";

/// @notice Deploys registry → manager → token (spec §2). The launch set of script/config/<chainId>.json is
/// configured while the registry is still in its setup phase; `setManager` then ends it, and ownership
/// goes to the Safe (env NOUSD_OWNER, also the treasury) through Ownable2Step.
contract Deploy is Script {
    /// @dev JSON object keys must be in alphabetical order for abi.decode of parsed JSON.
    struct TokenEntry {
        bool mintable;
        address token;
    }

    struct PoolEntry {
        address currencyA;
        address currencyB;
        uint256 fee;
        uint256 halfWidthTicks; // range preset = par tick ± this, rounded out to tickSpacing
        uint256 status; // 1 = Active, 2 = WithdrawOnly
        uint256 tickSpacing;
        uint256 weight;
    }

    struct Config {
        IPoolManager poolManager;
        address oracle;
        address treasury;
        uint128 supplyCap;
        uint128 compoundThreshold;
        TokenEntry[] tokens;
        PoolEntry[] pools;
    }

    struct Deployment {
        NoUSDRegistry registry;
        NoUSDPositionManager manager;
        NoUSD token;
    }

    error WiringMismatch();

    function run() external virtual returns (Deployment memory d) {
        address owner = vm.envAddress("NOUSD_OWNER");
        Config memory cfg = loadConfig(block.chainid, owner);
        vm.startBroadcast();
        d = deploy(msg.sender, cfg);
        d.registry.transferOwnership(owner);
        vm.stopBroadcast();
    }

    function loadConfig(uint256 chainId, address treasury) public view returns (Config memory cfg) {
        string memory json = vm.readFile(string.concat("script/config/", vm.toString(chainId), ".json"));
        cfg.poolManager = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        cfg.oracle = vm.parseJsonAddress(json, ".oracle");
        cfg.treasury = treasury;
        cfg.supplyCap = uint128(vm.parseJsonUint(json, ".supplyCap"));
        cfg.compoundThreshold = uint128(vm.parseJsonUint(json, ".compoundThreshold"));
        cfg.tokens = abi.decode(vm.parseJson(json, ".tokens"), (TokenEntry[]));
        cfg.pools = abi.decode(vm.parseJson(json, ".pools"), (PoolEntry[]));
    }

    /// @notice The v4 key of a config pool entry: currencies sorted, no hooks.
    function poolKey(PoolEntry memory p) public pure returns (PoolKey memory) {
        (address c0, address c1) = p.currencyA < p.currencyB ? (p.currencyA, p.currencyB) : (p.currencyB, p.currencyA);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: uint24(p.fee),
            tickSpacing: int24(int256(p.tickSpacing)),
            hooks: IHooks(address(0))
        });
    }

    /// @dev `deployer` must be the broadcasting account (or the calling test contract): the token address
    /// is precomputed from its nonce, and it owns the registry during setup.
    function deploy(address deployer, Config memory cfg) public returns (Deployment memory d) {
        d.registry = new NoUSDRegistry(deployer);
        configure(d.registry, cfg);
        // The token is created right after the manager: the deployer's next-but-one nonce.
        address tokenAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        d.manager = new NoUSDPositionManager(NoUSD(tokenAddr), d.registry, cfg.poolManager);
        d.token = new NoUSD(address(d.manager));
        if (address(d.token) != tokenAddr) revert WiringMismatch();
        d.registry.setManager(address(d.manager)); // ends the setup phase
    }

    /// @notice Launch configuration, applied without delay because the registry is still in setup.
    function configure(NoUSDRegistry registry, Config memory cfg) public {
        registry.setOracle(cfg.oracle);
        registry.setTreasury(cfg.treasury);
        registry.setSupplyCap(cfg.supplyCap);
        registry.setCompoundThreshold(cfg.compoundThreshold);
        for (uint256 i; i < cfg.tokens.length; ++i) {
            registry.admitToken(Currency.wrap(cfg.tokens[i].token), cfg.tokens[i].mintable);
        }
        for (uint256 i; i < cfg.pools.length; ++i) {
            PoolEntry memory p = cfg.pools[i];
            PoolKey memory key = poolKey(p);
            int24 spacing = key.tickSpacing;
            int24 par = registry.parTick(key);
            int24 half = int24(int256(p.halfWidthTicks));
            registry.addPool(
                key,
                _floor(par - half, spacing),
                _floor(par + half, spacing) + spacing,
                uint16(p.weight),
                NoUSDRegistry.PoolStatus(p.status)
            );
        }
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r < 0 ? tick - r - spacing : tick - r;
    }
}
