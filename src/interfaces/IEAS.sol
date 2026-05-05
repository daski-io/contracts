// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal EAS interfaces the Daski resolver depends on. Mirrors
///         `@ethereum-attestation-service/eas-contracts` at the struct/ABI
///         level — field ordering must match for `abi.decode` on log data to
///         work. Kept as a thin local file so the repo does not pull an
///         extra `forge install` of the full EAS codebase for a handful of
///         types.
///
/// Source references:
///   * EAS interface:      https://github.com/ethereum-attestation-service/eas-contracts/blob/master/contracts/IEAS.sol
///   * Attestation struct: https://github.com/ethereum-attestation-service/eas-contracts/blob/master/contracts/Common.sol
///   * SchemaRegistry:     https://github.com/ethereum-attestation-service/eas-contracts/blob/master/contracts/ISchemaRegistry.sol

struct Attestation {
    bytes32 uid; // EAS-assigned unique identifier
    bytes32 schema; // SchemaRegistry UID
    uint64 time; // timestamp the attestation was created
    uint64 expirationTime; // expiration (0 if none)
    uint64 revocationTime; // revocation time (0 if still valid)
    bytes32 refUID; // referenced attestation UID (linked revision / reply)
    address recipient; // subject of the attestation
    address attester; // party that produced the attestation
    bool revocable; // whether the attester can revoke later
    bytes data; // schema-encoded payload
}

struct AttestationRequestData {
    address recipient;
    uint64 expirationTime;
    bool revocable;
    bytes32 refUID;
    bytes data;
    uint256 value;
}

struct AttestationRequest {
    bytes32 schema;
    AttestationRequestData data;
}

struct DelegatedAttestationRequest {
    bytes32 schema;
    AttestationRequestData data;
    Signature signature;
    address attester;
    uint64 deadline;
}

struct RevocationRequestData {
    bytes32 uid;
    uint256 value;
}

struct RevocationRequest {
    bytes32 schema;
    RevocationRequestData data;
}

struct DelegatedRevocationRequest {
    bytes32 schema;
    RevocationRequestData data;
    Signature signature;
    address revoker;
    uint64 deadline;
}

struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

interface IEAS {
    function attest(AttestationRequest calldata request) external payable returns (bytes32);

    function attestByDelegation(DelegatedAttestationRequest calldata request) external payable returns (bytes32);

    function revoke(RevocationRequest calldata request) external payable;

    function revokeByDelegation(DelegatedRevocationRequest calldata request) external payable;

    function getAttestation(bytes32 uid) external view returns (Attestation memory);

    function isAttestationValid(bytes32 uid) external view returns (bool);
}

interface ISchemaRegistry {
    function register(string calldata schema, address resolver, bool revocable) external returns (bytes32);

    function getSchema(bytes32 uid) external view returns (SchemaRecord memory);
}

struct SchemaRecord {
    bytes32 uid;
    address resolver;
    bool revocable;
    string schema;
}
