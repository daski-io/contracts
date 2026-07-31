// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Adapter for Daski's x402 V2 receive-authorization payment profile.
interface IX402Adapter {
    event FacilitatorAuthorizationSet(address indexed facilitator, bool authorized);

    struct EIP3009Auth {
        address from;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        bytes signature;
    }

    function settle(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        address expectedPayee,
        EIP3009Auth calldata auth,
        bytes32 nonceSalt
    ) external returns (uint256 paymentId);

    /// @notice Atomic gasless-registration + settle. If `auth.from` has no
    ///         agentId yet, mints one on the canonical ERC-8004 registry via
    ///         AgentIndex.registerWithSig using the supplied consent
    ///         signature, then settles in the same tx (both succeed or both
    ///         revert). If already registered, behaves exactly like `settle`.
    function settleWithRegistration(
        address token,
        uint256 amount,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        address expectedPayee,
        EIP3009Auth calldata auth,
        bytes32 nonceSalt,
        string calldata agentURI,
        uint256 registrationDeadline,
        bytes calldata registrationSignature
    ) external returns (uint256 buyerAgentId, uint256 paymentId);

    function authorizedFacilitators(address facilitator) external view returns (bool);

    function getFacilitatorCount() external view returns (uint256);

    function getFacilitatorAt(uint256 index) external view returns (address);

    function authNonceFor(
        address token,
        address payer,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 serviceRef,
        uint256 providerAgentId,
        bytes32 serviceId,
        address expectedPayee,
        bytes32 nonceSalt
    ) external view returns (bytes32);

    function setFacilitatorAuthorization(address facilitator, bool authorized) external;
}
