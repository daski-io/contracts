// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Attestation} from "./IEAS.sol";

/// @notice EAS schema resolver interface. A resolver is a contract bound to
///         a schema at registration time; EAS calls `attest`/`revoke` on the
///         resolver during every attestation/revocation against that schema
///         and reverts the whole operation if the resolver returns false
///         (or itself reverts).
///
/// Mirrors the canonical EAS ISchemaResolver (eas-contracts/contracts/resolver/ISchemaResolver.sol).
interface ISchemaResolver {
    /// @notice Whether the resolver accepts arbitrary ETH forwarded by the
    ///         attester. Daski's resolver does not — return false.
    function isPayable() external view returns (bool);

    /// @notice Called by EAS during an `attest` on a schema this resolver
    ///         is bound to.
    /// @return true to accept, false (or revert) to reject. Reverting is
    ///         preferred when you want to surface a reason.
    function attest(Attestation calldata attestation) external payable returns (bool);

    /// @notice Multi-attest variant. Daski's resolver processes each entry
    ///         via `onAttest` one-by-one; implementation just iterates.
    function multiAttest(Attestation[] calldata attestations, uint256[] calldata values) external payable returns (bool);

    /// @notice Called by EAS during a `revoke`.
    function revoke(Attestation calldata attestation) external payable returns (bool);

    /// @notice Multi-revoke variant.
    function multiRevoke(Attestation[] calldata attestations, uint256[] calldata values) external payable returns (bool);
}
