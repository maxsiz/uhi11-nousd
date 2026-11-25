// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev The owner-only setter of the deployed unisafe ChainlinkPriceOracle. Not part of IPriceOracle,
/// which noUSD itself uses; only this testnet script needs it.
interface IOracleAdmin {
    function setFeed(Currency currency, address aggregator, uint32 heartbeat, uint8 tokenDecimals) external;
    function owner() external view returns (address);
}

/// @notice Wires the Unichain Sepolia test stables of deployments/1301.json into the unisafe oracle.
/// Broadcast by the oracle owner. tUSDC and tUSDT ride the chain's USDC/USD and USDT/USD feeds; there is
/// no DAI/USD feed on Unichain Sepolia, so tDAI rides USDC/USD. Feeds as in uniswap-smart-wallet
/// script/oracle_feeds.json (1301), heartbeat 86,400 s + 900 s pad.
contract WireTestFeeds is Script {
    address public constant USDC_USD = 0x25DdD2fEd0d51fe79d292Da47dd9f10AbdB4b3EC;
    address public constant USDT_USD = 0xd391fB4c7D0B88dc44530E785246112388AFA98F;
    uint32 public constant HEARTBEAT = 87_300;

    error NotOracleOwner(address sender, address owner);

    function run() external {
        string memory json = vm.readFile("deployments/1301.json");
        IOracleAdmin oracle = IOracleAdmin(vm.parseJsonAddress(json, ".oracle"));
        if (oracle.owner() != msg.sender) revert NotOracleOwner(msg.sender, oracle.owner());
        vm.startBroadcast();
        wire(oracle, json);
        vm.stopBroadcast();
    }

    function wire(IOracleAdmin oracle, string memory json) public {
        oracle.setFeed(Currency.wrap(vm.parseJsonAddress(json, ".tUSDC")), USDC_USD, HEARTBEAT, 6);
        oracle.setFeed(Currency.wrap(vm.parseJsonAddress(json, ".tUSDT")), USDT_USD, HEARTBEAT, 6);
        oracle.setFeed(Currency.wrap(vm.parseJsonAddress(json, ".tDAI")), USDC_USD, HEARTBEAT, 18);
    }
}
