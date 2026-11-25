// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NoUSD} from "../src/NoUSD.sol";
import {NoUSDPositionManager} from "../src/NoUSDPositionManager.sol";
import {NoUSDRegistry} from "../src/NoUSDRegistry.sol";

/// @notice Deployment order and immutable wiring (spec §2), without the script's vm.broadcast.
contract DeployTest is Test {
    IPoolManager internal constant PM = IPoolManager(address(0xBEEF));

    function test_wiring() public {
        NoUSDRegistry registry = new NoUSDRegistry(address(this));
        address tokenAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        NoUSDPositionManager manager = new NoUSDPositionManager(NoUSD(tokenAddr), registry, PM);
        NoUSD token = new NoUSD(address(manager));
        registry.setManager(address(manager));

        assertEq(address(token), tokenAddr, "precomputed token address");
        assertEq(address(manager.token()), address(token));
        assertEq(address(manager.registry()), address(registry));
        assertEq(address(manager.poolManager()), address(PM));
        assertEq(token.manager(), address(manager));
        assertEq(registry.manager(), address(manager));
    }

    function test_setManager_once() public {
        NoUSDRegistry registry = new NoUSDRegistry(address(this));
        registry.setManager(address(1));
        vm.expectRevert(NoUSDRegistry.ManagerAlreadySet.selector);
        registry.setManager(address(2));
    }

    function test_setManager_onlyOwner() public {
        NoUSDRegistry registry = new NoUSDRegistry(address(this));
        vm.prank(address(0xA11CE));
        vm.expectRevert();
        registry.setManager(address(1));
    }

    function test_token_metadata() public {
        NoUSD token = new NoUSD(address(1));
        assertEq(token.name(), "noUSD");
        assertEq(token.symbol(), "noUSD");
        assertEq(token.decimals(), 18);
    }
}
