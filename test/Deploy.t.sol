// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {NoUSDRegistry} from "../src/NoUSDRegistry.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract DecimalsToken is ERC20 {
    uint8 internal immutable _dec;

    constructor(uint8 dec) ERC20("t", "t") {
        _dec = dec;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}

/// @notice Deployment order, wiring and the Ethereum launch configuration (spec §2, §12).
contract DeployTest is Test {
    using PoolIdLibrary for PoolKey;

    Deploy internal script;
    address internal treasury = makeAddr("safe");

    function setUp() public {
        script = new Deploy();
    }

    /// @dev The pool ids in script/config/1.json must be exactly the ones listed in spec §12.
    function test_ethereumConfig_poolIdsMatchSpec() public view {
        Deploy.Config memory cfg = script.loadConfig(1, treasury);
        bytes32[3] memory expected = [
            bytes32(0x56fc29b86900aa0afa6e20b020429bffba1105cfb45070492c67529b46eb48c1), // USDe/USDC
            bytes32(0xf6e8088529094bc485561fa2a03e3d19c9a60f5d99a997e8fe16ab4ca2db277a), // DAI/USDT
            bytes32(0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f) // USDS/RLUSD
        ];
        assertEq(cfg.pools.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(PoolId.unwrap(script.poolKey(cfg.pools[i]).toId()), expected[i]);
        }
        assertEq(address(cfg.poolManager), 0x000000000004444c5dc75cB358380D2e3dE08A90);
    }

    /// @dev Full deploy against the real config with the token addresses etched to mocks of the right
    /// decimals (no RPC needed).
    function test_deploy_ethereumConfig() public {
        Deploy.Config memory cfg = script.loadConfig(1, treasury);
        uint8[6] memory dec = [18, 6, 18, 6, 18, 18]; // USDe, USDC, DAI, USDT, USDS, RLUSD
        for (uint256 i; i < cfg.tokens.length; ++i) {
            vm.etch(cfg.tokens[i].token, address(new DecimalsToken(dec[i])).code);
            // immutables live in code, so the etched copy reports the right decimals
        }
        Deploy.Deployment memory d = script.deploy(address(script), cfg);

        assertEq(address(d.manager.token()), address(d.token));
        assertEq(address(d.manager.registry()), address(d.registry));
        assertEq(address(d.manager.poolManager()), address(cfg.poolManager));
        assertEq(d.token.manager(), address(d.manager));
        assertEq(d.registry.manager(), address(d.manager));
        assertEq(d.registry.poolCount(), 3);
        assertEq(d.registry.params().oracle, cfg.oracle);
        assertEq(d.registry.params().supplyCap, 100_000e18);
        assertTrue(d.registry.tokens(Currency.wrap(cfg.tokens[0].token)).mintable);
        assertFalse(d.registry.tokens(Currency.wrap(cfg.tokens[5].token)).mintable);

        PoolKey memory usdeUsdc = script.poolKey(cfg.pools[0]);
        NoUSDRegistry.PoolConfig memory p = d.registry.pool(usdeUsdc.toId());
        int24 par = d.registry.parTick(usdeUsdc);
        assertLe(p.tickLower, par - 100);
        assertGt(p.tickUpper, par + 100);
        assertEq(uint8(p.status), uint8(NoUSDRegistry.PoolStatus.Active));
        assertEq(uint8(d.registry.pool(script.poolKey(cfg.pools[2]).toId()).status), 2);

        // Setup phase is over: loosening now needs the timelock.
        vm.prank(address(script));
        vm.expectRevert(NoUSDRegistry.TimelockRequired.selector);
        d.registry.setSupplyCap(200_000e18);
    }

    function test_token_metadata() public {
        Deploy.Config memory cfg;
        cfg.poolManager = IPoolManager(address(0xBEEF));
        cfg.oracle = address(1);
        cfg.treasury = treasury;
        Deploy.Deployment memory d = script.deploy(address(script), cfg);
        assertEq(d.token.name(), "noUSD");
        assertEq(d.token.decimals(), 18);
    }
}
