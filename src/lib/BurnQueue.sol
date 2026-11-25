// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BurnRequest} from "./ManagerTypes.sol";

/// @title BurnQueue
/// @notice Bookkeeping of the delayed-burn queue (spec §9.3). External library: runs on the manager's
/// storage through delegatecall, so its events come from the manager.
library BurnQueue {
    event BurnRequested(
        uint256 indexed id, address indexed owner, address to, uint256 x, uint256 readyAt, uint256 minOut
    );
    event BurnCancelled(uint256 indexed id);

    error NotRequestOwner();
    error AlreadyDone();

    function push(BurnRequest[] storage q, address owner, address to, uint256 x, uint256 minOut, uint256 delay)
        public
        returns (uint256 id)
    {
        uint64 readyAt = uint64(block.timestamp + delay);
        id = q.length;
        q.push(
            BurnRequest({
                owner: owner, readyAt: readyAt, done: false, to: to, amount: uint128(x), minOut: uint128(minOut)
            })
        );
        emit BurnRequested(id, owner, to, x, readyAt, minOut);
    }

    /// @notice Marks request `id` done for its owner `caller`; returns the escrowed amount to give back.
    function cancel(BurnRequest[] storage q, uint256 id, address caller) public returns (uint256 amount) {
        BurnRequest storage r = q[id];
        if (r.owner != caller) revert NotRequestOwner();
        if (r.done) revert AlreadyDone();
        r.done = true;
        amount = r.amount;
        emit BurnCancelled(id);
    }

    /// @notice First index at or after `head` that is not done.
    function advance(BurnRequest[] storage q, uint256 head) public view returns (uint256) {
        uint256 len = q.length;
        while (head < len && q[head].done) ++head;
        return head;
    }
}
