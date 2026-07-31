# Pre-Mainnet Audit Fixes Specification

Status: Implemented; release rehearsal pending | Target: `develop` | Release impact: Mainnet blocker

## 1. Purpose

This specification fixes two findings from the final pre-Mainnet audit: the release manifest does not prove that live bytecode was built from the audited source commit, and reputation eligibility does not detect symmetric or shared discoverable control over both identities.

The fixes must preserve the current payment, refund, sanctions, administration, and deployment-dark-state behavior.

## 2. Non-goals

- Do not change payment routing, commission calculation, refund accounting, or token custody.
- Do not add backwards-compatibility or migration logic. Mainnet will use a fresh deployment.
- Do not attempt to discover every ERC-721 operator. `isApprovedForAll` is not enumerable, so a shared third-party operator that is neither a known settlement participant nor a current per-token approvee cannot be discovered on-chain.
- Do not replace the reviewed release manifest or Safe approval process.

## 3. Fix A: Bind the audited build to live bytecode

### 3.1 Security property

Before an admin-acceptance or payment-activation batch is approved, the release process must prove this complete chain:

```text
clean audited Git commit
        ↓ pinned reproducible local build
expected proxy and implementation runtime hashes
        ↓ exact manifest comparison
live proxy code, implementation addresses, and implementation code
```

A manifest that describes live bytecode correctly but falsely names the source commit must fail release verification.

### 3.2 Trusted inputs

The manifest remains the reviewed record for deployment addresses, configuration, and governance. It must not be the sole source of both the expected runtime hashes and the live runtime hashes being checked.

Expected hashes must be reproduced from a clean checkout of the manifest's source commit. Live hashes must be read from the target chain.

### 3.3 Requirements

#### BUILD-1: Strict source commit

`build.sourceCommit` must be exactly 40 lowercase hexadecimal characters, be nonzero, and equal `git rev-parse HEAD`. The trusted release job must derive `HEAD` itself; a caller-supplied environment value is not proof of the checked-out commit.

#### BUILD-2: Clean and pinned checkout

The trusted release job must fail if:

- the main worktree has tracked or untracked changes;
- any submodule has changes or is at a commit different from its recorded gitlink;
- `foundry.lock` differs from the audited commit; or
- the designated release ref (`develop`, `main`, or the release tag) does not contain `HEAD`.

Generated build output may be excluded from the cleanliness check only when it is created after the source check passes.
Detached `HEAD` is valid when the designated release ref contains it. Signers must run the release tooling from a fresh Linux clone or the pinned release container so platform-specific file-mode behavior cannot invalidate the cleanliness result.

#### BUILD-3: Reproduce local implementation hashes

The release verifier must calculate the deployed-runtime code hash from the local Foundry artifact in this exact order: `AgentIndex`, `DaskiValidationRegistry`, `ProviderRegistry`, `ServiceRegistry`, `PaymentRouter`, `ReputationStorage`, `X402Adapter`, `PermitAdapter`, and `ApprovalAdapter`.

Each implementation inherits OpenZeppelin `UUPSUpgradeable`, whose runtime contains the immutable `__self` address. Foundry artifacts contain placeholders while deployed bytecode contains the implementation address. Using artifact/build-info metadata, the verifier must prove every immutable reference resolves to `UUPSUpgradeable.__self`, fail closed on any other immutable, patch every `__self` region with the 32-byte encoding of that contract's manifest implementation address, and hash the patched deployed runtime including compiler metadata.

Each patched local hash must equal the corresponding `contracts.implementationRuntimeCodehashes` entry. A mismatch must fail before any governance payload is emitted. Creation bytecode must never be used.

#### BUILD-4: Reproduce local proxy hashes

The verifier must hash the deployed runtime bytecode from the pinned OpenZeppelin `ERC1967Proxy` artifact. The artifact must contain no immutable or unresolved library references.

All nine `contracts.proxyRuntimeCodehashes` entries must equal this local artifact hash. A manifest/live pair that agrees on non-reviewed proxy bytecode must fail before any governance payload is emitted.

#### BUILD-5: Verify and pin the compiler profile

The reproduced build must use Solidity `0.8.24`, optimizer enabled with 200 runs, `via_ir = true`, and `evm_version = "cancun"`.

`foundry.toml` must explicitly pin the EVM version. The manifest's `.build` object and the release evidence must record the EVM version, full Solidity build identifier, and exact Foundry version. The local verifier must compare these values with the artifact metadata and active toolchain, not merely trust the manifest.

A second clean environment using the same recorded Foundry version must reproduce all nine patched implementation hashes and the proxy artifact hash.

#### BUILD-6: Verify live runtime identity

The existing live checks must remain:

- proxy runtime code hash equals the reviewed proxy hash;
- ERC-1967 implementation slot equals the reviewed implementation address;
- live implementation runtime code hash equals the manifest hash; and
- implementation reports the expected UUPS proxiable UUID.

This check must run against the same manifest hash that passed BUILD-1 through BUILD-5.

#### BUILD-7: Gate governance actions

Both admin acceptance and payment activation require a successful build provenance result for the exact manifest hash being executed.

For a manual multisig ceremony, Safe signers must receive:

- the manifest and its hash;
- the clean source commit;
- the nine reproduced local implementation hashes;
- the live verification result; and
- the exact MultiSend payload.

Changing any of these inputs invalidates the approval package.

The trusted release wrapper and local verifier must be part of the audited source commit. Signers must execute the wrapper from the clean checkout used for reproduction; an unreviewed local helper or pre-existing build directory is not acceptable evidence.

#### BUILD-8: Remove or validate declarative duplicates

Manifest fields presented to reviewers must either be validated or removed. In particular, `schemas.outcome.definition` and `schemas.confirmation.definition` must not remain as ignored descriptive values. If retained, each must be compared with the canonical schema string used by the contracts.

### 3.4 Recommended implementation shape

Keep the two concerns separate:

- A local build verifier patches allowed immutables and compares manifest hashes with Foundry artifacts.
- The existing chain verifier compares manifest addresses and hashes with live runtime state.

A small trusted release wrapper should derive the Git commit and cleanliness state directly rather than accepting them as caller-supplied environment values. Solidity verification code may consume the result, but an environment variable alone is not proof of the Git state.
The wrapper must build from a fresh output directory, run the local verifier before the chain verifier, bind all evidence to the manifest hash, and emit a governance payload only after both checks pass.
Run the repository's coverage command immediately after widening the eligibility helper so stack-pressure failures are found during implementation rather than release validation.

### 3.5 Required tests

Add focused tests covering:

- valid clean build and matching artifact hashes;
- malformed, uppercase, zero, and wrong source commits;
- dirty main worktree and dirty submodule rejection in the release job;
- correct UUPS immutable patching for all nine implementation addresses;
- rejection of a wrong implementation address or any unexpected immutable reference;
- one incorrect local implementation hash among otherwise correct entries;
- manifest and live bytecode agreeing with each other while local bytecode differs;
- local `ERC1967Proxy` artifact mismatch even when manifest and live proxy bytecode agree;
- wrong compiler settings, EVM version, or Foundry version;
- ignored or mismatched schema definitions;
- implementation address or ERC-1967 slot mismatch;
- admin-acceptance refusal when provenance has not passed; and
- activation refusal when provenance belongs to a different manifest hash.

At least one end-to-end release test must exercise manifest loading, local artifact verification, live stack verification, and governance payload generation together. Direct tests are required for `ReleaseManifest`, `VerifyDeployment`, and both branches of `ExecuteGovernanceBatches`.

## 4. Fix B: Symmetric reputation control-overlap detection

### 4.1 Security property

A payment must be reputation-ineligible when known on-chain settlement participants or current per-token approvees overlap, or when one of those discoverable controllers has ERC-721 approval authority over the counterparty agent.

Payment settlement must still succeed; only `reputationEligible` changes.

### 4.2 Requirements

#### REP-1: Preserve direct address overlap checks

The following known addresses remain part of the overlap check:

- buyer payer wallet;
- buyer NFT owner;
- buyer verified agent wallet;
- provider NFT owner;
- provider verified agent wallet; and
- resolved service payee.

Any nonzero address appearing on both sides makes the payment reputation-ineligible.

#### REP-2: Check buyer control over provider

For every nonzero buyer address, the payment is reputation-ineligible if that address:

- equals `identity.getApproved(providerAgentId)`; or
- is approved for all tokens by the provider NFT owner.

This preserves the current behavior.

#### REP-3: Check provider control over buyer

For every nonzero provider address, the payment is reputation-ineligible if that address:

- equals `identity.getApproved(buyerAgentId)`; or
- is approved for all tokens by the buyer NFT owner.

The eligibility helper must therefore receive both `buyerAgentId` and `providerAgentId`. The buyer NFT owner must be passed explicitly or identified without relying on the position of `request.buyerWallet` in the buyer-address array.

#### REP-4: Check shared discoverable controllers

The nonzero results of `identity.getApproved(buyerAgentId)` and `identity.getApproved(providerAgentId)` must be treated as controllers on their respective sides.

The payment is reputation-ineligible if:

- the two per-token approvees are the same nonzero address;
- either per-token approvee equals a known participant on the other side; or
- either per-token approvee is an `isApprovedForAll` operator for the counterparty NFT owner.

The implementation should fetch each per-token approval once and evaluate the two participant/controller sets symmetrically.

#### REP-5: Handle zero addresses safely

Zero agent wallets and absent per-token approvals must not be treated as an overlap. External identity-registry failures must continue to fail settlement closed.

#### REP-6: Preserve all other eligibility rules

The payment remains reputation-ineligible when:

- token reputation is disabled;
- amount is below the configured minimum;
- commission is zero; or
- buyer and provider agent IDs are equal.

No eligibility change may alter token transfers, emitted settlement amounts, payment replay protection, or refund rights.

### 4.3 Required tests

Add regression tests proving that reputation is ineligible when:

- provider NFT owner is approved for the buyer token;
- provider agent wallet is approved for the buyer token;
- service payee is approved for the buyer token;
- buyer owner grants `setApprovalForAll` to a provider-side address;
- buyer payer/owner/agent wallet controls the provider token;
- the same non-participant address is the per-token approvee for both tokens;
- a per-token approvee on either side is an operator for the counterparty owner; and
- any known buyer and provider address is identical.

Also prove that:

- unrelated buyer and provider identities remain eligible;
- zero agent wallets do not create a false overlap;
- payment still settles and distributes funds when reputation is excluded;
- the reputation sink records the payment as ineligible; and
- a fuzz/property test rejects every direct or cross-approval relationship constructible from the known participant sets.

The buyer-side `setApprovalForAll` regression must use a buyer agent wallet as the payer while the NFT is held by a different owner. This prevents a test from passing when an implementation incorrectly treats `buyerAddresses[0]` as the buyer NFT owner.

### 4.4 Documentation

Update contract comments and the README to describe the exact guarantee: overlap and cross-approval among known settlement participants and current per-token approvees are excluded. Do not claim detection of a shared third-party `setApprovalForAll` operator when that operator is not otherwise discoverable because operator sets cannot be enumerated.

## 5. Release acceptance criteria

The audit fixes are complete only when:

1. All BUILD and REP requirements are implemented.
2. All existing tests, invariants, and the repository's coverage command pass.
3. New regression and release-path tests pass on a clean clone.
4. A release-candidate rehearsal proves the same nine patched implementation hashes and proxy artifact hash in two clean environments using the pinned toolchain.
5. Dark-state verification passes before payment activation.
6. Operational verification passes after activation.
7. Signers reproduce the release package from the audited commit with the committed trusted wrapper.
8. The reviewed manifest, provenance evidence, Safe payload, and verification output are archived under the same manifest hash.
