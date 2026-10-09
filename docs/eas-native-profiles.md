# Native EAS compatibility fixtures

`test/EASNativeProfiles.t.sol` executes the exact EAS and SchemaRegistry
implementation runtime captured from the canonical Base and Base Sepolia
predeploys. These are offline EVM tests, not mocked signature verification.
They exercise the real verifier and the local Daski ReputationStorage resolver.
No deployment, wallet funding, network request or contract upgrade occurs in CI.

| Chain | EAS version/domain | Implementation | Finalized fixture block |
| --- | --- | --- | --- |
| Base (8453) | 1.0.1 / 1.0.1 | `0xbeb5fc579115071764c7423a4f12edde41f106ed` | 51965149 |
| Base Sepolia (84532) | 1.2.0 / 1.2.0 | `0xc0d3c0d3c0d3c0d3c0d3c0d3c0d3c0d3c0d30021` | 47475468 |

The JSON fixtures record block hash, timestamp, canonical public RPC,
implementation address, runtime/code hashes, observed version, domain separator
and both signed type hashes. They contain public bytecode only. Tests verify
its hash before installing it at the canonical predeploy address, preserving
its immutable registry and domain bindings. The local chain ID matches the
captured network. Storage is fresh: these tests do not clone user attestations
or validate a historical production order.

Coverage includes exact ordered signed types, domain separation, attester and
recipient attribution, delegated attestation and revocation, shared nonce
consumption, invalid-signature rollback, replay rejection, the three-attestation
cap and final revocation. Base 1.0.1 has no delegation deadline and no
`increaseNonce` cancellation entry point. Its deadline-bearing selector fails.

`test/EASNativeDirectReviews.t.sol` runs the direct path on the same two
runtimes: a contract account that is the order's payer, standing in for an
ERC-4337 wallet such as a Circle agent wallet, calls EAS `attest` and
`revoke` itself with the exact calls the buyer CLI validates. The tests check
the `Attested` and `Revoked` topics the buyer binds, attester attribution,
refUID chaining, the cap, revocation, an untouched delegated nonce, and the
resolver's own refusals of a stale reference and of another account. The
direct path is identical on both versions; they differ only in delegation.
The Base 1.0.1 runtime contains no ERC-1271 `isValidSignature` selector at
all, so a contract wallet there can review only directly.

`test/ReputationRecovery.t.sol` sends provider recovery attestations through
the same two runtimes, single and batched: EAS-assigned uids and times, each
admission refusal, EAS's own refusal of a revocable recovery under the
irrevocable schema, and its refusal to revoke a recorded recovery.
`test/ReputationUpgradePreservation.t.sol` populates a 2.1.0 resolver through
them before upgrading it in place, and `test/DeployReputationStorage.t.sol`
runs the whole deployment script against them.

**The deployed Base Sepolia runtime expires only when timestamp > deadline.**
Equality still succeeds; zero remains nonexpiring. This differs from the
[`eas-contracts` v1.2.0 verifier source](https://github.com/ethereum-attestation-service/eas-contracts/blob/d89635a1c82fe4518d18bf8dcb622cf0dd535ba0/contracts/eip1271/EIP1271Verifier.sol),
which uses `deadline <= _time()`. A package tag or contract version string does
not establish the behavior of a deployed implementation. New application
signatures must use a bounded nonzero deadline on the supported deadline
profile, and retirement must honor the actual strict comparison.

The legacy reference signed fields are documented in the
[historical EIP712Verifier](https://github.com/ethereum-attestation-service/eas-contracts/blob/v1.0.0/contracts/eip712/EIP712Verifier.sol).
The executable fixtures, not a mutable deployment ABI catalog, are the
regression authority for these two identities. A changed code hash requires
reviewed replacement fixtures and profile qualification; it must not silently
inherit support because `version()` is familiar.

The EAS runtime derives from MIT-licensed Ethereum Attestation Service,
Optimism and OpenZeppelin components. The EAS license is preserved beside the
fixtures; the repository's existing OpenZeppelin dependencies preserve their
licenses. These test-only additions make no change to Daski deployed code,
ABIs, storage layouts or recorded history.
