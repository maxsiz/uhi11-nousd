// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title NoUSD
/// @notice ERC-20 stablecoin backed by the liquidity held by NoUSDPositionManager. Pool fees are
/// distributed through an in-token accumulator (variant L, docs/spec.md §5): only `sync` on the manager
/// moves the counter; every balance change settles both sides first. Only the manager can mint, burn,
/// distribute and consume accrued.
/// @dev Written by hand, not on top of OZ ERC20: balance, accumulator checkpoint and flags share one
/// storage slot, so a transfer costs one write per side.
contract NoUSD is IERC20, IERC20Metadata, IERC20Errors {
    /// @dev Packed per-holder state (slot A of spec §5.1).
    struct Account {
        uint128 balance;
        uint120 checkpoint; // accPerShare at the last settle
        uint8 flags;
    }

    /// @notice Scale of `accPerShare`: value (18 decimals) per 1e18 noUSD, times ACC_SCALE.
    uint256 public constant ACC_SCALE = 1e18;

    uint8 internal constant EXCLUDED = 1; // does not accrue, balance counted in excludedSupply
    uint8 internal constant CLASSIFIED = 2; // EOA/contract classification done
    uint8 internal constant MANUAL = 4; // mode chosen by the holder via configureAccrual; reclassify skips it

    /// @notice The only address allowed to mint, burn, distribute and consume accrued.
    address public immutable manager;

    mapping(address => Account) internal _accounts;
    /// @notice Settled but unpaid earnings per holder, value at par (18 decimals). Never returns to 0
    /// once written: `consumeAccrued` leaves 1 wei so the slot stays warm-priced.
    mapping(address => uint256) public accrued;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalSupply;
    /// @notice Sum of balances of excluded accounts.
    uint256 public excludedSupply;
    /// @notice Value distributed per 1e18 eligible noUSD since launch, times ACC_SCALE. Only grows.
    uint256 public accPerShare;
    /// @notice Value distributed to holders and not yet paid out (settled or not).
    uint256 public totalUnclaimed;
    /// @notice Protocol-fee accrual of the treasury, value at par.
    uint256 public treasuryAccrued;

    event AccrualModeChanged(address indexed account, bool excluded);
    event Distributed(uint256 value, uint256 distributed, uint256 accPerShare);

    error NotManager();
    error ZeroAddress();
    error BalanceOverflow();
    error AccumulatorOverflow();

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    constructor(address manager_) {
        if (manager_ == address(0)) revert ZeroAddress();
        manager = manager_;
    }

    // ───────────────────────────── ERC-20 ─────────────────────────────

    function name() external pure returns (string memory) {
        return "noUSD";
    }

    function symbol() external pure returns (string memory) {
        return "noUSD";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _accounts[account].balance;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    // ───────────────────────────── manager-only (spec §5.4) ─────────────────────────────

    /// @notice Mints `amount` to `to` after settling it.
    function mint(address to, uint256 amount) external onlyManager {
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 acc = accPerShare;
        Account memory a = _receiving(to, acc);
        uint256 newBalance = uint256(a.balance) + amount;
        if (newBalance > type(uint128).max) revert BalanceOverflow();
        a.balance = uint128(newBalance);
        _accounts[to] = a;
        totalSupply += amount;
        if (a.flags & EXCLUDED != 0) excludedSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burns `amount` from `from` after settling it. The manager authorizes the holder itself.
    function burnFrom(address from, uint256 amount) external onlyManager {
        uint256 acc = accPerShare;
        Account memory a = _settled(from, _accounts[from], acc);
        if (a.balance < amount) revert ERC20InsufficientBalance(from, a.balance, amount);
        unchecked {
            a.balance -= uint128(amount);
            totalSupply -= amount;
            if (a.flags & EXCLUDED != 0) excludedSupply -= amount;
        }
        _accounts[from] = a;
        emit Transfer(from, address(0), amount);
    }

    /// @notice Moves the accumulator by `value` spread over eligible supply.
    /// @return remainder The part of `value` not distributed because of rounding; the manager carries it.
    function distribute(uint256 value) external onlyManager returns (uint256 remainder) {
        if (value == 0) return 0;
        uint256 eligible = totalSupply - excludedSupply;
        if (eligible == 0) {
            treasuryAccrued += value;
            emit Distributed(value, 0, accPerShare);
            return 0;
        }
        uint256 delta = value * ACC_SCALE / eligible;
        uint256 acc = accPerShare + delta;
        if (acc > type(uint120).max) revert AccumulatorOverflow();
        accPerShare = acc;
        // Rounded up: holders' settled earnings are floored per holder over spans that may cover several
        // distributions, so flooring here too could leave totalUnclaimed below their sum and make a later
        // consumeAccrued underflow. Never exceeds `value` because delta itself is floored.
        uint256 distributed = Math.mulDiv(delta, eligible, ACC_SCALE, Math.Rounding.Ceil);
        totalUnclaimed += distributed;
        emit Distributed(value, distributed, acc);
        return value - distributed;
    }

    /// @notice Settles `a` and takes all but 1 wei of its accrued earnings.
    function consumeAccrued(address a) external onlyManager returns (uint256 paid) {
        Account memory acct = _accounts[a];
        uint256 acc = accPerShare;
        if (acct.checkpoint != acc) _accounts[a] = _settled(a, acct, acc);
        uint256 amount = accrued[a];
        if (amount <= 1) return 0;
        unchecked {
            paid = amount - 1;
        }
        accrued[a] = 1;
        totalUnclaimed -= paid;
    }

    /// @notice Adds the protocol-fee share of a sync to the treasury accrual.
    function accrueTreasury(uint256 value) external onlyManager {
        treasuryAccrued += value;
    }

    /// @notice Takes the whole treasury accrual.
    function consumeTreasury() external onlyManager returns (uint256 paid) {
        paid = treasuryAccrued;
        treasuryAccrued = 0;
    }

    // ───────────────────────────── accrual modes (spec §5.3) ─────────────────────────────

    /// @notice Opt this address in (`on = true`) or out of fee accrual. Contracts are excluded by default;
    /// an EOA may opt out. The choice is final against `reclassify` until changed here again.
    function configureAccrual(bool on) external {
        _setMode(msg.sender, !on, MANUAL);
    }

    /// @notice Re-applies the default classification of `a` from its current code. No-op for addresses
    /// that chose their mode with `configureAccrual`. Anyone may call.
    function reclassify(address a) external {
        uint8 flags = _accounts[a].flags;
        if (flags & MANUAL != 0) return;
        _setMode(a, _isContract(a), 0);
    }

    // ───────────────────────────── views (spec §5.5) ─────────────────────────────

    /// @notice Accrued plus not yet settled earnings of `a`.
    function pendingAccrued(address a) external view returns (uint256) {
        Account memory acct = _accounts[a];
        uint256 earned;
        if (acct.flags & EXCLUDED == 0) {
            earned = uint256(acct.balance) * (accPerShare - acct.checkpoint) / ACC_SCALE;
        }
        return accrued[a] + earned;
    }

    function isExcluded(address a) external view returns (bool) {
        return _accounts[a].flags & EXCLUDED != 0;
    }

    /// @notice Supply that takes part in distributions.
    function eligibleSupply() external view returns (uint256) {
        return totalSupply - excludedSupply;
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 acc = accPerShare;
        Account memory f = _settled(from, _accounts[from], acc);
        if (f.balance < value) revert ERC20InsufficientBalance(from, f.balance, value);
        if (from == to) {
            _accounts[from] = f;
            emit Transfer(from, to, value);
            return;
        }
        Account memory t = _receiving(to, acc);
        unchecked {
            // value <= f.balance < 2^128, and the sum of all balances is totalSupply < 2^128.
            f.balance -= uint128(value);
            t.balance += uint128(value);
        }
        bool fromExcluded = f.flags & EXCLUDED != 0;
        if (fromExcluded != (t.flags & EXCLUDED != 0)) {
            if (fromExcluded) excludedSupply -= value;
            else excludedSupply += value;
        }
        _accounts[from] = f;
        _accounts[to] = t;
        emit Transfer(from, to, value);
    }

    /// @dev Loads, classifies on first receipt, and settles a receiving account.
    function _receiving(address to, uint256 acc) internal returns (Account memory a) {
        a = _accounts[to];
        if (a.flags & CLASSIFIED == 0) {
            // First receipt: the balance is 0, so excludedSupply is unaffected.
            a.flags |= CLASSIFIED;
            if (_isContract(to)) a.flags |= EXCLUDED;
            a.checkpoint = uint120(acc);
            return a;
        }
        return _settled(to, a, acc);
    }

    /// @dev Credits the earnings since the last checkpoint to `accrued` and moves the checkpoint. Writes
    /// `accrued` only when the delta is non-zero; the caller writes the packed account.
    function _settled(address owner, Account memory a, uint256 acc) internal returns (Account memory) {
        if (a.checkpoint == acc) return a;
        if (a.flags & EXCLUDED == 0 && a.balance != 0) {
            uint256 earned;
            unchecked {
                // acc only grows and checkpoint <= acc.
                earned = uint256(a.balance) * (acc - a.checkpoint) / ACC_SCALE;
            }
            if (earned != 0) accrued[owner] += earned;
        }
        a.checkpoint = uint120(acc);
        return a;
    }

    /// @dev Settles `who` and switches it to `excluded`, keeping excludedSupply in sync; `extraFlags` is
    /// OR-ed in (MANUAL for a holder's own choice).
    function _setMode(address who, bool excluded, uint8 extraFlags) internal {
        Account memory a = _settled(who, _accounts[who], accPerShare);
        bool was = a.flags & EXCLUDED != 0;
        a.flags |= CLASSIFIED | extraFlags;
        if (was != excluded) {
            if (excluded) {
                a.flags |= EXCLUDED;
                excludedSupply += a.balance;
            } else {
                a.flags &= ~EXCLUDED;
                excludedSupply -= a.balance;
            }
            emit AccrualModeChanged(who, excluded);
        }
        _accounts[who] = a;
    }

    /// @dev True for an address with real code. An EIP-7702 delegation designator (23 bytes starting with
    /// 0xef0100) counts as an EOA.
    function _isContract(address a) internal view returns (bool) {
        uint256 size = a.code.length;
        if (size == 0) return false;
        if (size != 23) return true;
        bytes3 prefix;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            extcodecopy(a, ptr, 0, 3)
            prefix := mload(ptr)
        }
        return prefix != 0xef0100;
    }

    function _approve(address owner, address spender, uint256 value) internal {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    /// @dev An allowance of type(uint256).max is infinite and is not decremented.
    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < value) revert ERC20InsufficientAllowance(spender, current, value);
        unchecked {
            allowance[owner][spender] = current - value;
        }
    }
}
