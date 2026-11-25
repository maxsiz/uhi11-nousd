// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NoUSD} from "../../src/NoUSD.sol";

/// @dev A contract holder: excluded unless it opts in.
contract ContractHolder {
    function configure(NoUSD token, bool on) external {
        token.configureAccrual(on);
    }

    function send(NoUSD token, address to, uint256 value) external {
        token.transfer(to, value);
    }
}

/// @dev Drives NoUSD as its manager with random mint / burn / transfer / distribute / consume / mode
/// changes over a fixed set of EOAs and contract holders.
contract NoUSDHandler is Test {
    NoUSD public token;
    address[] public actors;
    uint256 public distributions;

    constructor() {
        token = new NoUSD(address(this));
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("eoa", vm.toString(i))));
        }
        for (uint256 i; i < 2; ++i) {
            actors.push(address(new ContractHolder()));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _isHolderContract(address a) internal view returns (bool) {
        return a.code.length != 0;
    }

    function mint(uint256 seed, uint256 amount) external {
        amount = bound(amount, 1, 1e30);
        token.mint(_actor(seed), amount);
    }

    function burn(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, token.balanceOf(a));
        token.burnFrom(a, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        if (_isHolderContract(from)) {
            ContractHolder(from).send(token, to, amount);
        } else {
            vm.prank(from);
            token.transfer(to, amount);
        }
    }

    function distribute(uint256 value) external {
        uint256 eligible = token.totalSupply() - token.excludedSupply();
        // Keep accPerShare well inside uint120 even for tiny eligible supplies.
        value = bound(value, 0, eligible == 0 ? 1e24 : eligible);
        token.distribute(value);
        ++distributions;
    }

    function consume(uint256 seed) external {
        token.consumeAccrued(_actor(seed));
    }

    function configure(uint256 seed, bool on) external {
        address a = _actor(seed);
        if (_isHolderContract(a)) {
            ContractHolder(a).configure(token, on);
        } else {
            vm.prank(a);
            token.configureAccrual(on);
        }
    }

    function reclassify(uint256 seed) external {
        token.reclassify(_actor(seed));
    }
}

/// @notice Invariants of spec §14 that concern the token alone.
contract NoUSDInvariantTest is Test {
    NoUSDHandler internal handler;
    NoUSD internal token;

    function setUp() public {
        handler = new NoUSDHandler();
        token = handler.token();
        targetContract(address(handler));
    }

    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 excluded;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            uint256 b = token.balanceOf(a);
            sum += b;
            if (token.isExcluded(a)) excluded += b;
        }
        assertEq(sum, token.totalSupply(), "sum of balances");
        assertEq(excluded, token.excludedSupply(), "sum of excluded balances");
    }

    /// @dev totalUnclaimed covers every holder's pending accrual; the gap is rounding dust, at most one
    /// wei per holder plus 1 per distribution.
    function invariant_unclaimedCoversPending() public view {
        uint256 pending;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            pending += token.pendingAccrued(handler.actors(i));
        }
        uint256 unclaimed = token.totalUnclaimed();
        assertLe(pending, unclaimed, "pending exceeds unclaimed");
        assertLe(unclaimed - pending, (n + 1) * (handler.distributions() + 1), "dust bound");
    }
}
