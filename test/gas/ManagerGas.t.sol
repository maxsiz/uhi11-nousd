// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {NoUSDRegistry} from "../../src/NoUSDRegistry.sol";
import {ManagerFixture} from "../utils/ManagerFixture.sol";

/// @notice Gas of the manager's hot paths against spec targets (§9.2, §9.4), three positions over three
/// tokens, steady state: sync ≤ 70k + 40k per position, burn ≤ 520k. Storage is cooled before each
/// measured call, so the numbers are close to a fresh transaction (base cost and calldata excluded).
contract ManagerGasTest is ManagerFixture {
    PoolKey internal keyAC;

    function setUp() public override {
        super.setUp();
        keyAC = _key(tA, tC);
        int24 par = reg.parTick(keyAC);
        _timelocked(
            abi.encodeCall(NoUSDRegistry.addPool, (keyAC, par - 100, par + 100, 1, NoUSDRegistry.PoolStatus.Active))
        );
        _initPool(keyAC);
        _seed(keyAB, 100_000, alice);
        _seed(keyBC, 100_000, alice);
        _seed(keyAC, 100_000, bob);
        _churn(keyAB, 50_000, 2);
        _churn(keyBC, 50_000, 2);
        _churn(keyAC, 50_000, 2);
        mgr.sync(); // obs initialized; the measured sync below does not rotate
        // Steady state: one earlier burn and claim leave idle, claims and accrued slots non-zero, as they are
        // after the first days of operation.
        uint256 warm = token.balanceOf(bob) / 100;
        vm.prank(bob);
        mgr.burn(warm, bob, 0, type(uint256).max);
        vm.prank(alice);
        mgr.claim(alice, 0, type(uint256).max);
        tA.mint(address(this), 1_000_000e18);
        tB.mint(address(this), 1_000_000e6);
        _churn(keyAB, 50_000, 1);
    }

    function _cool() internal {
        vm.cool(address(mgr));
        vm.cool(address(token));
        vm.cool(address(reg));
        vm.cool(address(pm));
        vm.cool(address(tA));
        vm.cool(address(tB));
        vm.cool(address(tC));
    }

    function test_gas_sync_threePositions() public {
        _cool();
        uint256 g = gasleft();
        mgr.sync();
        uint256 used = g - gasleft();
        emit log_named_uint("sync, 3 positions", used);
        assertLe(used, 70_000 + 3 * 40_000);
    }

    function test_gas_burn_threePositions() public {
        uint256 x = token.balanceOf(alice) / 10;
        _cool();
        vm.prank(alice);
        uint256 g = gasleft();
        mgr.burn(x, alice, 0, type(uint256).max);
        uint256 used = g - gasleft();
        emit log_named_uint("burn, 3 positions", used);
        assertLe(used, 520_000);
    }

    function test_gas_claim_threePositions() public {
        mgr.sync();
        _cool();
        vm.prank(alice);
        uint256 g = gasleft();
        mgr.claim(alice, 0, type(uint256).max);
        emit log_named_uint("claim, 3 positions", g - gasleft());
    }

    function test_gas_mint() public {
        tA.mint(alice, 10_000e18);
        vm.prank(alice);
        tA.approve(address(mgr), type(uint256).max);
        _cool();
        vm.prank(alice);
        uint256 g = gasleft();
        mgr.mint(Currency.wrap(address(tA)), 10_000e18, 0, alice, type(uint256).max);
        emit log_named_uint("mint", g - gasleft());
    }
}
