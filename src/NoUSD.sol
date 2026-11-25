// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {IERC3009} from "./interfaces/IERC3009.sol";

/// @title NoUSD
/// @notice ERC-20 stablecoin backed by the liquidity held by NoUSDPositionManager. Pool fees are
/// distributed through an in-token accumulator (variant L, docs/spec.md §5): only `sync` on the manager
/// moves the counter; every balance change settles both sides first. Only the manager can mint, burn,
/// distribute and consume accrued.
/// Gasless approvals and transfers: EIP-2612 `permit` and EIP-3009 transfer/receive with authorization
/// (USDC semantics, random bytes32 nonces), both accepting ERC-1271 signatures of smart accounts;
/// ERC-5267 domain discovery.
/// @dev Written by hand, not on top of OZ ERC20: balance, accumulator checkpoint and flags share one
/// storage slot, so a transfer costs one write per side. OZ is used for EIP-712, nonces and signature
/// checks only.
contract NoUSD is IERC20, IERC20Metadata, IERC20Errors, IERC20Permit, IERC3009, EIP712, Nonces {
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

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 private constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    /// @notice The only address allowed to mint, burn, distribute and consume accrued.
    address public immutable manager;

    /// @dev Packed Account words: balance (bits 0-127) | checkpoint (128-247) | flags (248-255). Read and
    /// written as one word through _load/_store; a struct assignment would write each field separately.
    mapping(address => uint256) internal _accounts;
    /// @notice Settled but unpaid earnings per holder, value at par (18 decimals). Never returns to 0
    /// once written: `consumeAccrued` leaves 1 wei so the slot stays warm-priced.
    mapping(address => uint256) public accrued;
    mapping(address => mapping(address => uint256)) public allowance;
    /// @dev EIP-3009 nonces: used or canceled. Separate from the sequential EIP-2612 nonces.
    mapping(address => mapping(bytes32 => bool)) private _authorizationUsed;

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
    error ERC2612ExpiredSignature(uint256 deadline);
    error ERC2612InvalidSigner();

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    /// @dev EIP-712 domain: name "noUSD", version "1", the chain id and this address, so a signature for
    /// one chain's deployment is useless on another.
    constructor(address manager_) EIP712("noUSD", "1") {
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
        return _load(account).balance;
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

    // ───────────────────────────── EIP-2612 permit ─────────────────────────────

    /// @inheritdoc IERC20Permit
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        _permit(owner, spender, value, deadline, abi.encodePacked(r, s, v));
    }

    /// @notice EIP-2612 permit with a packed or ERC-1271 signature (smart accounts), as in USDC v2.2.
    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes calldata signature)
        external
    {
        _permit(owner, spender, value, deadline, signature);
    }

    /// @inheritdoc IERC20Permit
    function nonces(address owner) public view override(IERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @inheritdoc IERC20Permit
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ───────────────────────────── EIP-3009 / ERC-7598 ─────────────────────────────

    /// @inheritdoc IERC3009
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationUsed[authorizer][nonce];
    }

    /// @inheritdoc IERC3009
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _transferWithAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            abi.encodePacked(r, s, v)
        );
    }

    /// @inheritdoc IERC3009
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        _transferWithAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
    }

    /// @inheritdoc IERC3009
    /// @dev Only the payee may submit, so a contract payee cannot be front-run into receiving funds outside
    /// its own call.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (msg.sender != to) revert CallerMustBePayee(msg.sender, to);
        _transferWithAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            abi.encodePacked(r, s, v)
        );
    }

    /// @inheritdoc IERC3009
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (msg.sender != to) revert CallerMustBePayee(msg.sender, to);
        _transferWithAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
    }

    /// @inheritdoc IERC3009
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        _cancelAuthorization(authorizer, nonce, abi.encodePacked(r, s, v));
    }

    /// @inheritdoc IERC3009
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external {
        _cancelAuthorization(authorizer, nonce, signature);
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
        _store(to, a);
        totalSupply += amount;
        if (a.flags & EXCLUDED != 0) excludedSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burns `amount` from `from` after settling it. The manager authorizes the holder itself.
    function burnFrom(address from, uint256 amount) external onlyManager {
        uint256 acc = accPerShare;
        Account memory a = _settled(from, _load(from), acc);
        if (a.balance < amount) revert ERC20InsufficientBalance(from, a.balance, amount);
        unchecked {
            a.balance -= uint128(amount);
            totalSupply -= amount;
            if (a.flags & EXCLUDED != 0) excludedSupply -= amount;
        }
        _store(from, a);
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
        Account memory acct = _load(a);
        uint256 acc = accPerShare;
        if (acct.checkpoint != acc) _store(a, _settled(a, acct, acc));
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
        uint8 flags = _load(a).flags;
        if (flags & MANUAL != 0) return;
        _setMode(a, _isContract(a), 0);
    }

    // ───────────────────────────── views (spec §5.5) ─────────────────────────────

    /// @notice Accrued plus not yet settled earnings of `a`.
    function pendingAccrued(address a) external view returns (uint256) {
        Account memory acct = _load(a);
        uint256 earned;
        if (acct.flags & EXCLUDED == 0) {
            earned = uint256(acct.balance) * (accPerShare - acct.checkpoint) / ACC_SCALE;
        }
        return accrued[a] + earned;
    }

    function isExcluded(address a) external view returns (bool) {
        return _load(a).flags & EXCLUDED != 0;
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
        Account memory f = _settled(from, _load(from), acc);
        if (f.balance < value) revert ERC20InsufficientBalance(from, f.balance, value);
        if (from == to) {
            _store(from, f);
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
        _store(from, f);
        _store(to, t);
        emit Transfer(from, to, value);
    }

    /// @dev Loads, classifies on first receipt, and settles a receiving account.
    function _receiving(address to, uint256 acc) internal returns (Account memory a) {
        a = _load(to);
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
        Account memory a = _settled(who, _load(who), accPerShare);
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
        _store(who, a);
    }

    function _load(address who) internal view returns (Account memory a) {
        uint256 w = _accounts[who];
        a.balance = uint128(w);
        a.checkpoint = uint120(w >> 128);
        a.flags = uint8(w >> 248);
    }

    function _store(address who, Account memory a) internal {
        _accounts[who] = uint256(a.balance) | (uint256(a.checkpoint) << 128) | (uint256(a.flags) << 248);
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

    function _permit(address owner, address spender, uint256 value, uint256 deadline, bytes memory signature) internal {
        if (block.timestamp > deadline) revert ERC2612ExpiredSignature(deadline);
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline)));
        if (!_isValidSignature(owner, digest, signature)) revert ERC2612InvalidSigner();
        _approve(owner, spender, value);
    }

    /// @dev Shared body of transfer/receive with authorization: time window, unused nonce, signature, then
    /// the ordinary `_transfer` (which settles both sides).
    function _transferWithAuthorization(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) internal {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid(validAfter);
        if (block.timestamp >= validBefore) revert AuthorizationExpired(validBefore);
        _useAuthorization(from, nonce);
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce)));
        if (!_isValidSignature(from, digest, signature)) revert InvalidSignature();
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    function _cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) internal {
        _useAuthorization(authorizer, nonce);
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)));
        if (!_isValidSignature(authorizer, digest, signature)) revert InvalidSignature();
        emit AuthorizationCanceled(authorizer, nonce);
    }

    /// @dev Marks an EIP-3009 nonce as used or canceled; reverts if it already was.
    function _useAuthorization(address authorizer, bytes32 nonce) internal {
        if (_authorizationUsed[authorizer][nonce]) revert AuthorizationAlreadyUsed(authorizer, nonce);
        _authorizationUsed[authorizer][nonce] = true;
    }

    /// @dev ECDSA first, then ERC-1271 if the signer has code. OZ's SignatureChecker skips ECDSA for any
    /// address with code, which would reject plain key signatures of EIP-7702 delegated EOAs whose
    /// delegate does not implement ERC-1271.
    function _isValidSignature(address signer, bytes32 digest, bytes memory signature) internal view returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;
        return signer.code.length != 0 && SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature);
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
