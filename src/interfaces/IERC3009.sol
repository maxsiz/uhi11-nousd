// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IERC3009
/// @notice Transfer with authorization (EIP-3009), as implemented by USDC: the holder signs an EIP-712
/// message off-chain and anyone (or, for `receiveWithAuthorization`, only the payee) submits it. Nonces are
/// random 32-byte values, each usable once. Overloads taking `bytes signature` follow ERC-7598 so smart
/// accounts can sign through ERC-1271.
interface IERC3009 {
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    error AuthorizationNotYetValid(uint256 validAfter);
    error AuthorizationExpired(uint256 validBefore);
    error AuthorizationAlreadyUsed(address authorizer, bytes32 nonce);
    error CallerMustBePayee(address caller, address payee);
    error InvalidSignature();

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);

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
    ) external;

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;

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
    ) external;

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;

    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external;

    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external;
}
