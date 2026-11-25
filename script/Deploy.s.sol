// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NoUSD} from "../src/NoUSD.sol";
import {NoUSDPositionManager} from "../src/NoUSDPositionManager.sol";
import {NoUSDRegistry} from "../src/NoUSDRegistry.sol";

/// @notice Deploys registry → manager → token and wires the registry to the manager (spec §2).
/// Per-chain addresses come from script/config/<chainId>.json; the owner Safe from env NOUSD_OWNER.
/// The registry is wired by the deployer and ownership is handed to the Safe via Ownable2Step.
contract Deploy is Script {
    struct Deployment {
        NoUSDRegistry registry;
        NoUSDPositionManager manager;
        NoUSD token;
    }

    error WiringMismatch();

    function run() external returns (Deployment memory d) {
        string memory json = vm.readFile(string.concat("script/config/", vm.toString(block.chainid), ".json"));
        IPoolManager poolManager = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        address owner = vm.envAddress("NOUSD_OWNER");

        vm.startBroadcast();
        d = deploy(msg.sender, poolManager);
        d.registry.transferOwnership(owner);
        vm.stopBroadcast();
    }

    /// @dev The deployer must be the account broadcasting (or the test contract): the token address is
    /// precomputed from its nonce.
    function deploy(address deployer, IPoolManager poolManager) public returns (Deployment memory d) {
        d.registry = new NoUSDRegistry(deployer);
        // The token is created right after the manager, so its address is the deployer's next-but-one nonce.
        address tokenAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        d.manager = new NoUSDPositionManager(NoUSD(tokenAddr), d.registry, poolManager);
        d.token = new NoUSD(address(d.manager));
        if (address(d.token) != tokenAddr) revert WiringMismatch();
        d.registry.setManager(address(d.manager));
    }
}
