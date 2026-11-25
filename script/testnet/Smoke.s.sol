// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {NoUSD} from "../../src/NoUSD.sol";
import {NoUSDPositionManager} from "../../src/NoUSDPositionManager.sol";
import {TestStable} from "./TestStable.sol";

/// @notice End-to-end check of the Unichain Sepolia deployment by any account: faucet 1,000 of each
/// test stable, mint noUSD with each, then redeem half of it to the sender.
contract Smoke is Script {
    function run() external {
        string memory json = vm.readFile("deployments/1301.json");
        NoUSDPositionManager mgr = NoUSDPositionManager(vm.parseJsonAddress(json, ".manager"));
        NoUSD token = NoUSD(vm.parseJsonAddress(json, ".token"));
        string[3] memory names = ["tUSDC", "tUSDT", "tDAI"];
        vm.startBroadcast();
        for (uint256 i; i < names.length; ++i) {
            TestStable t = TestStable(vm.parseJsonAddress(json, string.concat(".", names[i])));
            uint256 amount = 1_000 * 10 ** t.decimals();
            t.faucet(msg.sender, amount);
            t.approve(address(mgr), amount);
            uint256 out = mgr.mint(Currency.wrap(address(t)), amount, 0, msg.sender, block.timestamp + 600);
            console.log("minted with", names[i], out);
        }
        uint256 half = token.balanceOf(msg.sender) / 2;
        mgr.burn(half, msg.sender, 0, block.timestamp + 600);
        vm.stopBroadcast();
        console.log("redeemed", half, "noUSD left", token.balanceOf(msg.sender));
    }
}
