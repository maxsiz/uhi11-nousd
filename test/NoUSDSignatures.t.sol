// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {NoUSD} from "../src/NoUSD.sol";
import {IERC3009} from "../src/interfaces/IERC3009.sol";

/// @dev Minimal smart account: valid if the hash is signed by its owner key.
contract MockSmartAccount is IERC1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address r,,) = ECDSA.tryRecover(hash, signature);
        return r == owner ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

/// @notice EIP-2612 permit and EIP-3009 / ERC-7598 authorizations, including ERC-1271 and EIP-7702.
contract NoUSDSignaturesTest is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant TRANSFER_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    NoUSD internal token;
    uint256 internal aliceKey;
    address internal alice;
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new NoUSD(address(this));
        (alice, aliceKey) = makeAddrAndKey("alice");
        token.mint(alice, 100e18);
        vm.warp(1_000_000);
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        return vm.sign(key, _digest(structHash));
    }

    function _packed(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, structHash);
        return abi.encodePacked(r, s, v);
    }

    function _transferHash(address from, address to, uint256 value, uint256 after_, uint256 before, bytes32 nonce)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(TRANSFER_TYPEHASH, from, to, value, after_, before, nonce));
    }

    // ───────────── ERC-5267 ─────────────

    function test_eip712Domain() public view {
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = token.eip712Domain();
        assertEq(name, "noUSD");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(token));
    }

    // ───────────── EIP-2612 ─────────────

    function test_permit() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _sign(aliceKey, keccak256(abi.encode(PERMIT_TYPEHASH, alice, bob, 5e18, 0, deadline)));
        token.permit(alice, bob, 5e18, deadline, v, r, s);
        assertEq(token.allowance(alice, bob), 5e18);
        assertEq(token.nonces(alice), 1);
    }

    function test_permit_replayReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _sign(aliceKey, keccak256(abi.encode(PERMIT_TYPEHASH, alice, bob, 5e18, 0, deadline)));
        token.permit(alice, bob, 5e18, deadline, v, r, s);
        vm.expectRevert(NoUSD.ERC2612InvalidSigner.selector);
        token.permit(alice, bob, 5e18, deadline, v, r, s);
    }

    function test_permit_expired() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) =
            _sign(aliceKey, keccak256(abi.encode(PERMIT_TYPEHASH, alice, bob, 5e18, 0, deadline)));
        vm.expectRevert(abi.encodeWithSelector(NoUSD.ERC2612ExpiredSignature.selector, deadline));
        token.permit(alice, bob, 5e18, deadline, v, r, s);
    }

    function test_permit_smartAccount1271() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        MockSmartAccount account = new MockSmartAccount(owner);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig =
            _packed(ownerKey, keccak256(abi.encode(PERMIT_TYPEHASH, address(account), bob, 7e18, 0, deadline)));
        token.permit(address(account), bob, 7e18, deadline, sig);
        assertEq(token.allowance(address(account), bob), 7e18);
    }

    function test_permit_7702DelegatedEoa() public {
        // A delegate without ERC-1271: the plain key signature must still work.
        vm.etch(alice, abi.encodePacked(hex"ef0100", address(0xC0DE)));
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _sign(aliceKey, keccak256(abi.encode(PERMIT_TYPEHASH, alice, bob, 1e18, 0, deadline)));
        token.permit(alice, bob, 1e18, deadline, v, r, s);
        assertEq(token.allowance(alice, bob), 1e18);
    }

    // ───────────── EIP-3009 ─────────────

    function test_transferWithAuthorization() public {
        bytes32 nonce = keccak256("random-1");
        uint256 before = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(aliceKey, _transferHash(alice, bob, 10e18, 0, before, nonce));
        vm.expectEmit(address(token));
        emit IERC3009.AuthorizationUsed(alice, nonce);
        vm.prank(makeAddr("relayer"));
        token.transferWithAuthorization(alice, bob, 10e18, 0, before, nonce, v, r, s);
        assertEq(token.balanceOf(bob), 10e18);
        assertTrue(token.authorizationState(alice, nonce));
    }

    function test_transferWithAuthorization_replayReverts() public {
        bytes32 nonce = keccak256("random-1");
        uint256 before = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(aliceKey, _transferHash(alice, bob, 10e18, 0, before, nonce));
        token.transferWithAuthorization(alice, bob, 10e18, 0, before, nonce, v, r, s);
        vm.expectRevert(abi.encodeWithSelector(IERC3009.AuthorizationAlreadyUsed.selector, alice, nonce));
        token.transferWithAuthorization(alice, bob, 10e18, 0, before, nonce, v, r, s);
    }

    function test_transferWithAuthorization_window() public {
        bytes32 nonce = keccak256("w");
        uint256 after_ = block.timestamp + 10;
        uint256 before = block.timestamp + 20;
        bytes memory sig = _packed(aliceKey, _transferHash(alice, bob, 1, after_, before, nonce));
        vm.expectRevert(abi.encodeWithSelector(IERC3009.AuthorizationNotYetValid.selector, after_));
        token.transferWithAuthorization(alice, bob, 1, after_, before, nonce, sig);
        vm.warp(before);
        vm.expectRevert(abi.encodeWithSelector(IERC3009.AuthorizationExpired.selector, before));
        token.transferWithAuthorization(alice, bob, 1, after_, before, nonce, sig);
        vm.warp(after_ + 1);
        token.transferWithAuthorization(alice, bob, 1, after_, before, nonce, sig);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_transferWithAuthorization_wrongSigner() public {
        (, uint256 malloryKey) = makeAddrAndKey("mallory");
        bytes32 nonce = keccak256("x");
        uint256 before = block.timestamp + 1 hours;
        bytes memory sig = _packed(malloryKey, _transferHash(alice, bob, 1e18, 0, before, nonce));
        vm.expectRevert(IERC3009.InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, 1e18, 0, before, nonce, sig);
    }

    function test_transferWithAuthorization_smartAccount7598() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        MockSmartAccount account = new MockSmartAccount(owner);
        token.mint(address(account), 5e18);
        bytes32 nonce = keccak256("sa");
        uint256 before = block.timestamp + 1 hours;
        bytes memory sig = _packed(ownerKey, _transferHash(address(account), bob, 5e18, 0, before, nonce));
        token.transferWithAuthorization(address(account), bob, 5e18, 0, before, nonce, sig);
        assertEq(token.balanceOf(bob), 5e18);
    }

    function test_receiveWithAuthorization_onlyPayee() public {
        bytes32 nonce = keccak256("recv");
        uint256 before = block.timestamp + 1 hours;
        bytes memory sig =
            _packed(aliceKey, keccak256(abi.encode(RECEIVE_TYPEHASH, alice, bob, 3e18, 0, before, nonce)));
        vm.expectRevert(abi.encodeWithSelector(IERC3009.CallerMustBePayee.selector, address(this), bob));
        token.receiveWithAuthorization(alice, bob, 3e18, 0, before, nonce, sig);
        vm.prank(bob);
        token.receiveWithAuthorization(alice, bob, 3e18, 0, before, nonce, sig);
        assertEq(token.balanceOf(bob), 3e18);
    }

    function test_receiveSignature_notUsableAsTransfer() public {
        bytes32 nonce = keccak256("recv2");
        uint256 before = block.timestamp + 1 hours;
        bytes memory sig =
            _packed(aliceKey, keccak256(abi.encode(RECEIVE_TYPEHASH, alice, bob, 3e18, 0, before, nonce)));
        vm.expectRevert(IERC3009.InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, 3e18, 0, before, nonce, sig);
    }

    function test_cancelAuthorization() public {
        bytes32 nonce = keccak256("cancel-me");
        uint256 before = block.timestamp + 1 hours;
        bytes memory transferSig = _packed(aliceKey, _transferHash(alice, bob, 1e18, 0, before, nonce));
        bytes memory cancelSig = _packed(aliceKey, keccak256(abi.encode(CANCEL_TYPEHASH, alice, nonce)));
        vm.expectEmit(address(token));
        emit IERC3009.AuthorizationCanceled(alice, nonce);
        token.cancelAuthorization(alice, nonce, cancelSig);
        vm.expectRevert(abi.encodeWithSelector(IERC3009.AuthorizationAlreadyUsed.selector, alice, nonce));
        token.transferWithAuthorization(alice, bob, 1e18, 0, before, nonce, transferSig);
    }

    // ───────────── accrual stays consistent ─────────────

    /// @dev Signed transfers go through the same settle path as plain ones.
    function test_authorizedTransfer_settlesBothSides() public {
        token.mint(bob, 100e18);
        token.distribute(20e18); // 10 each
        bytes32 nonce = keccak256("settle");
        uint256 before = block.timestamp + 1 hours;
        bytes memory sig = _packed(aliceKey, _transferHash(alice, bob, 50e18, 0, before, nonce));
        token.transferWithAuthorization(alice, bob, 50e18, 0, before, nonce, sig);
        assertEq(token.accrued(alice), 10e18);
        assertEq(token.accrued(bob), 10e18);
        token.distribute(20e18); // alice 50, bob 150
        assertEq(token.pendingAccrued(alice), 15e18);
        assertEq(token.pendingAccrued(bob), 25e18);
    }
}
