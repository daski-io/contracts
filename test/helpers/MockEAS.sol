// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IEAS,
    ISchemaRegistry,
    Attestation,
    AttestationRequest,
    AttestationRequestData,
    DelegatedAttestationRequest,
    RevocationRequest,
    DelegatedRevocationRequest,
    SchemaRecord
} from "../../src/interfaces/IEAS.sol";
import {ISchemaResolver} from "../../src/interfaces/ISchemaResolver.sol";

/// @notice Minimal in-memory EAS + SchemaRegistry stand-in for Foundry tests.
///
/// Semantics matched on the hot path the resolver exercises:
///   * register()         — stores the schema + resolver, returns a UID.
///   * attest()           — builds an Attestation, calls resolver.attest().
///                          If the resolver reverts, the attest reverts too.
///   * attestByDelegation — identical, but uses `request.attester` as the
///                          attester field (signatures are NOT verified in
///                          the mock — tests assert behavior given a valid
///                          caller).
///   * revoke()           — calls resolver.revoke(); only the original
///                          attester may revoke, and only if the schema is
///                          revocable.
///
/// Not implemented: signature verification, nonce tracking, expiration
/// enforcement, multi-attest batch externals. Production EAS has all of
/// these — the resolver is agnostic to them.
contract MockEAS is IEAS, ISchemaRegistry {
    mapping(bytes32 => SchemaRecord) internal _schemas;
    mapping(bytes32 => Attestation) internal _attestations;
    uint256 internal _schemaCounter;
    uint256 internal _attestationCounter;

    // ── ISchemaRegistry ─────────────────────────────────────────────────

    function register(string calldata schema, address resolver, bool revocable) external returns (bytes32 uid) {
        _schemaCounter++;
        uid = keccak256(abi.encodePacked("schema", _schemaCounter, schema, resolver));
        _schemas[uid] = SchemaRecord({uid: uid, resolver: resolver, revocable: revocable, schema: schema});
    }

    function getSchema(bytes32 uid) external view returns (SchemaRecord memory) {
        return _schemas[uid];
    }

    // ── IEAS ────────────────────────────────────────────────────────────

    function attest(AttestationRequest calldata request) external payable returns (bytes32) {
        return _attest(request.schema, msg.sender, request.data);
    }

    function attestByDelegation(DelegatedAttestationRequest calldata request) external payable returns (bytes32) {
        return _attest(request.schema, request.attester, request.data);
    }

    function revoke(RevocationRequest calldata request) external payable {
        _revoke(request.data.uid, msg.sender);
    }

    function revokeByDelegation(DelegatedRevocationRequest calldata request) external payable {
        _revoke(request.data.uid, request.revoker);
    }

    function getAttestation(bytes32 uid) external view returns (Attestation memory) {
        return _attestations[uid];
    }

    function isAttestationValid(bytes32 uid) external view returns (bool) {
        return _attestations[uid].uid != bytes32(0);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _attest(bytes32 schema, address attester, AttestationRequestData calldata data)
        internal
        returns (bytes32 uid)
    {
        SchemaRecord memory s = _schemas[schema];
        require(s.resolver != address(0), "schema not registered");

        _attestationCounter++;
        uid = keccak256(abi.encodePacked("attestation", _attestationCounter, schema, attester));

        Attestation memory a = Attestation({
            uid: uid,
            schema: schema,
            time: uint64(block.timestamp),
            expirationTime: data.expirationTime,
            revocationTime: 0,
            refUID: data.refUID,
            recipient: data.recipient,
            attester: attester,
            revocable: data.revocable,
            data: data.data
        });
        _attestations[uid] = a;

        bool ok = ISchemaResolver(s.resolver).attest{value: data.value}(a);
        require(ok, "resolver rejected");
    }

    function _revoke(bytes32 uid, address revoker) internal {
        Attestation storage a = _attestations[uid];
        require(a.uid != bytes32(0), "no such attestation");
        require(a.attester == revoker, "not original attester");
        require(a.revocationTime == 0, "already revoked");

        SchemaRecord memory s = _schemas[a.schema];
        require(s.revocable, "schema not revocable");

        a.revocationTime = uint64(block.timestamp);

        // Pass a memory copy to the resolver — Attestation is a value type
        // here; the resolver reads fields only.
        Attestation memory snapshot = a;
        bool ok = ISchemaResolver(s.resolver).revoke(snapshot);
        require(ok, "resolver rejected");
    }
}
