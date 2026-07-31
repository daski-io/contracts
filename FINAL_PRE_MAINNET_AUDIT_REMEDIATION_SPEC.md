# Final Pre-Mainnet Audit Remediation Specification

Status: Core remediation implemented; clean-clone release E2E, independent
reproduction, live rehearsal, and monitor deployment pending | Target:
`develop` | Release impact: Mainnet blocker

## 1. Purpose

This specification addresses the material findings from the final pre-Mainnet
audit:

1. release builds are not fully bound to the audited Git source because ambient
   Foundry configuration and unverified source inputs can affect compilation;
2. the canonical identity registry is an upgradeable external authority over
   Daski authorization and payment routing, but its implementation and upgrade
   authority are not pinned or monitored;
3. facilitator revisions are not content-addressed as part of the archived
   release evidence; and
4. the required release-path tests and two-environment rehearsal are incomplete.

The work is complete only when every acceptance criterion in section 8 is met.

## 2. Security properties

### 2.1 Build provenance

Given a release manifest and `build.sourceCommit`, every reviewer must reproduce
the same compiler inputs and deployed bytecode without relying on caller-specific
environment variables, ignored files, global Foundry configuration, or mutable
files outside the pinned repository and submodule commits.

### 2.2 External identity dependency

No release or activation operation may proceed unless the canonical identity
proxy, implementation, runtime code, version, and upgrade authority match the
reviewed manifest. An unexpected dependency change must be detectable and must
have a narrow, fail-closed path that stops identity-dependent state changes.

### 2.3 Release evidence

The archived evidence must identify the exact base manifest, ordered revision
bytes, effective facilitator set, Safe transactions, compiler inputs, local
artifacts, live contract state, and governance payload reviewed by signers.
Replacing any one of those inputs must change the effective release hash.

## 3. Non-goals

- Do not redesign ERC-8004 or deploy a Daski identity registry.
- Do not claim that on-chain Daski code can independently inspect another
  proxy's ERC-1967 storage. External dependency state is verified through the
  trusted release job and continuous RPC monitoring.
- Do not change payment economics, refund destinations, sanctions behavior, or
  reputation calculations.
- Do not refactor unrelated contracts or add compatibility parsing for old
  manifests, old revision files, or old evidence summaries. This system is
  pre-production; all examples and callers must move to the new schema.

## 4. Fix A: Hermetic, source-bound release builds

### 4.1 Trusted build environment

`script/release.py` remains the only trusted release entry point.

BUILD-1. Resolve `forge` and `cast` to absolute paths before validation. Record
their paths, versions, and Foundry commit in the evidence summary.

BUILD-2. Before compilation, reject any inherited variable capable of changing
Foundry, DappTools, or Solidity configuration. This includes every
`FOUNDRY_*`, `DAPP_*`, and compiler-selection variable. RPC, governance sender,
and signing variables must not be present in the build subprocess.

BUILD-3. Construct the build subprocess environment from an explicit allowlist.
Use an isolated temporary home/config directory and the committed
`foundry.toml`. Invoke Forge with an explicit repository root and config path.
The command must not read a user-level or parent-directory Foundry config.

BUILD-4. The effective config must exactly match the manifest build profile and
a committed lock file containing the complete ordered effective remapping set.
The lock must include explicit `foundry.toml` remappings and every auto-derived
remapping, including nested submodule remappings such as Forge Standard Library
and OpenZeppelin. Record a canonical hash of the effective config and locked
remappings. A missing, extra, changed, or reordered effective remapping must
fail; the release job must never generate and trust the lock in the same run.

BUILD-5. Continue building into new temporary `out`, `cache`, and build-info
directories. Generate Foundry build-info for every compilation unit used by the
nine implementations, `ERC1967Proxy`, deployment script, verification script,
and governance script.

### 4.2 Compiler source closure

BUILD-6. Extract every logical source path and source content hash from the
generated compiler inputs/build-info. Reject absolute paths, parent traversal,
duplicate logical paths with different contents, and any source outside the
repository or a recorded submodule.

BUILD-7. Every compiler source must resolve to either:

- a file tracked by `build.sourceCommit`; or
- a tracked file in a recursively pinned, clean submodule at its recorded
  gitlink commit.

Ignored, merely untracked, generated, symlink-escaped, and external source files
must fail even when their content produces the expected bytecode.

BUILD-8. Compare each compiler source hash with bytes read from the corresponding
Git object, not only the working tree. This comparison must cover all compiler
sources, including OpenZeppelin dependencies. Artifact metadata containing the
canonical UUPS source remains necessary but is not sufficient.

BUILD-9. Define `build.sourceClosureHash` as a domain-separated hash of the
sorted tuples `(logicalPath, repositoryIdentity, sourceContentHash)`. Define
`build.compilerInputHash` as a domain-separated hash of the sorted canonical
compiler inputs, including language, settings, remappings, and source hashes.
Both nonzero hashes are required in the release manifest and must match the
clean local build.

For this hash, `repositoryIdentity` is `root@<sourceCommit>` for a root file or
`<recursive-submodule-path>@<gitlink-commit>` for a submodule file. Each nested
submodule identity must use the gitlink commit recorded by its immediate parent,
not a branch name or working-tree HEAD supplied independently.

BUILD-10. Repeat the HEAD, worktree, ignored-source closure, and recursive
submodule checks after compilation and after local verification. Any mutation
between the initial check and evidence archival must discard the run.

### 4.3 Manifest and evidence changes

Replace the existing build object with the new schema; do not support missing
hash fields:

```json
{
  "build": {
    "sourceCommit": "<40 lowercase hex>",
    "sourceClosureHash": "<bytes32>",
    "compilerInputHash": "<bytes32>",
    "foundryConfigHash": "<bytes32>",
    "solcVersion": "0.8.24+commit.e11b9ed9",
    "optimizer": true,
    "optimizerRuns": 200,
    "viaIr": true,
    "evmVersion": "cancun",
    "foundryVersion": "<pinned version>",
    "foundryCommit": "<pinned commit>"
  }
}
```

BUILD-11. Archive the canonical compiler-input summary, source-closure listing,
effective Foundry config, resolved tool versions, build log, and existing local
runtime hashes. The summary must expose all four build hashes.

BUILD-12. `VerifyDeployment` and `ExecuteGovernanceBatches` must receive a
wrapper-created provenance-success marker bound to the effective release hash.
Direct script execution without that marker must fail before chain interaction
or payload generation. The marker is run-local evidence, not a reusable
caller-authored boolean. This marker is only an accidental-bypass guard: a
malicious local operator can fabricate local files and environment values.
Source/object verification, independently reproduced evidence, and signer
policy remain the provenance security boundary.

## 5. Fix B: Pin and contain the external identity dependency

### 5.1 Manifest identity

Replace `external.identityRegistry` with:

```json
{
  "external": {
    "identityRegistry": {
      "proxy": "<address>",
      "proxyRuntimeCodehash": "<bytes32>",
      "implementation": "<address>",
      "implementationRuntimeCodehash": "<bytes32>",
      "erc1967Admin": "<address, normally zero for UUPS>",
      "upgradeAuthority": "<owner address>",
      "version": "<exact getVersion result>"
    }
  }
}
```

Add the reviewed guardian to the governance profile:

```json
{
  "governance": {
    "pauseGuardian": "<address>"
  }
}
```

IDENTITY-1. Validate the proxy address against the chain allowlist and read the
ERC-1967 implementation and admin slots directly through the RPC-backed VM.
Require exact manifest matches, nonzero implementation code, and exact proxy and
implementation runtime codehashes.

IDENTITY-2. Query `owner()` through the proxy as the current UUPS upgrade
authority and `getVersion()` as a compatibility observation. Require exact
manifest matches. Add a minimal script-side interface for these accessors and
extend `MockCanonicalIdentityRegistry` with configurable values for validation
tests. A successful interface probe alone is not sufficient.

IDENTITY-3. Run the complete identity validation before deployment output is
accepted, before admin acceptance, before payload emission, before activation,
and during every dark or operational verification. Archive the observed slot
values, codehashes, authority, and version in each run. Release-candidate and
Mainnet dark/operational validation must also require all nine Daski proxies to
report the manifest guardian and the expected pause state.

IDENTITY-4. An identity implementation, codehash, admin, authority, or version
change requires a new base release manifest and security review. Facilitator
revisions must not authorize external dependency changes.

### 5.2 Fail-closed contract control

Add a shared external-dependency pause surface to
`Admin2StepUpgradeable`, consuming its reserved storage gap:

- `externalDependencyPaused`;
- `pauseGuardian`;
- an event for guardian changes and an event for pause-state changes;
- `setPauseGuardian(address)` callable only by the admin;
- `pauseExternalDependency()` callable by the admin or guardian;
- `unpauseExternalDependency()` callable only by the admin; and
- an internal `whenExternalDependencyOperational` modifier.

The guardian address and pause flag must occupy one packed storage slot and the
base storage gap must shrink by exactly one slot. Storage-layout validation must
prove that no existing slot moves in any of the nine upgradeable contracts.

IDENTITY-5. A guardian can only move the system from unpaused to paused. It
cannot unpause, change the guardian, alter configuration, upgrade a contract, or
move funds. `setPauseGuardian` must emit the old and new guardian, and setting it
to zero is permitted only while that proxy is paused. Developer deployments may
start with a zero guardian; release-candidate and Mainnet deployment,
admin-acceptance, activation, and operational verification require the same
nonzero reviewed guardian on all nine proxies.

New deployments must configure all nine guardians before admin handoff. Existing
proxies must receive the guardian in the same reviewed Safe batch that upgrades
them, using the new admin setter after each implementation upgrade; a
reinitializer is not required because the new storage defaults are valid.

IDENTITY-6. Apply the fail-closed check to identity-dependent state changes:

- `AgentIndex`: registration, claim, and unbind;
- `ProviderRegistry`: registration and active-state changes;
- `ServiceRegistry`: registration, URI changes, service-wallet changes, and
  active-state changes;
- `PaymentRouter`: settlement and refund; and
- `DaskiValidationRegistry`: validation requests.

Read-only methods, historical payment reads, validation responses by the
previously stored validator, and reputation resynchronization remain available.

IDENTITY-7. Add governance batches that pause and unpause all nine proxies
atomically. The five contracts listed in IDENTITY-6 enforce the pause; the other
four expose and record the same state so governance and verification cannot
silently diverge. Unpause only after the release wrapper has revalidated a
reviewed base manifest whose external identity pins match live observations:
the current manifest when the dependency is unchanged, or a new manifest when
IDENTITY-4 applies. Activation must prove every proxy is unpaused. A paused
proxy set must never satisfy operational verification even when accepted tokens
and adapters remain configured.

IDENTITY-8. The Mainnet runbook must continuously monitor the identity proxy's
implementation slot, admin slot, proxy codehash, implementation codehash,
`owner()`, and version. The monitor uses a dedicated HSM/KMS-backed guardian key
whose on-chain authority is limited to pausing. On mismatch it must pause
`PaymentRouter` first, then the remaining eight proxies, wait for confirmation,
and alert the security operators. A reviewed Safe pause batch remains the manual
fallback; the monitor is not expected to produce Safe threshold signatures.
Monitoring evidence and every pause transaction must be archived under the
affected effective release hash.

IDENTITY-9. Security documentation and release sign-off must state that this
control contains but does not eliminate trust in the external registry owner.
It must record the registry's governance model and the measured monitoring and
pause-response objective, guardian key custody and rotation, funding and health
checks, transaction ordering, Safe fallback, and false-positive recovery
procedure. Mainnet approval requires explicit acceptance of the remaining
detection-to-pause window and the guardian's denial-of-service authority.

## 6. Fix C: Content-addressed facilitator revisions

REVISION-1. `release.py` must read every revision once, validate it, copy the
exact bytes into the temporary pinned input set, and pass Forge only the
content-addressed effective revision evidence derived from those copies. A
source revision changing during the run must fail the post-run check.

REVISION-2. Remove the caller-authored `approved` field. Approval is proven by
an executed transaction from the manifest Safe, not by a JSON boolean. Preserve
exactly two revision kinds:

- `planned` may add, remove, or replace facilitators through normal review; and
- `emergency-remove-only` must be a nonempty subset of the immediately preceding
  effective facilitator set and must never add a facilitator.

Reject every other kind and apply the subset rule during both proposal and final
verification.

Replace the revision schema with:

```json
{
  "revision": 1,
  "kind": "planned",
  "baseManifestHash": "<bytes32>",
  "previousManifestHash": "<base manifest or previous revision hash>",
  "safeTransactionHash": "<Safe transaction hash>",
  "executionTransactionHash": "<chain transaction hash>",
  "authorizedFacilitators": ["<address>"]
}
```

REVISION-3. Define a `revisionIntentHash` from the domain, chain ID, revision
number, kind, base manifest hash, previous manifest/revision hash, and ordered
authorized facilitator set. It deliberately excludes both transaction hashes
so the reviewed intent remains stable through proposal and execution.

For a finalized revision, define `revisionHash` as the hash of its exact bytes
and retain the ordered `baseManifestHash` and `previousManifestHash` chain.
Define:

`effectiveReleaseHash = keccak256(domain, chainId, baseManifestHash, orderedRevisionHashes)`.

With no revisions, the ordered list is empty but the same formula applies. A new
revision links to the base manifest hash when it is first, or to the preceding
finalized `revisionHash`.

REVISION-4. Implement this explicit lifecycle:

1. **Draft and payload emission:** add a dedicated revision-payload action to
   `release.py`. It requires `executionTransactionHash` to be zero; both
   transaction hashes may initially be zero. It validates the intent, revision
   chain, kind, subset rule, current live facilitator set, Safe identity, and
   Safe nonce, then emits the exact Safe/MultiSend payload,
   `revisionIntentHash`, and expected Safe transaction hash. Draft evidence is
   provisional and keyed by `revisionIntentHash`.
2. **Safe proposal and review:** populate `safeTransactionHash` with the hash
   produced by the reviewed Safe proposal while
   `executionTransactionHash` remains zero. Re-running payload validation must
   reproduce the same intent, payload, and Safe transaction hash before
   signatures are collected.
3. **Finalization:** after successful execution, populate
   `executionTransactionHash`. Final verification requires both transaction
   hashes to be nonzero and receipt-verified. Only this stage produces a
   `revisionHash`, changes `effectiveReleaseHash`, or qualifies as final release
   evidence.

Normal verify, accept, activate, and operational modes must reject any supplied
revision that has not reached finalization. A payload-emission run must reject a
nonzero execution transaction hash so an already executed revision cannot be
silently reused as a new proposal.

REVISION-5. For a finalized revision, fetch the receipt identified by
`executionTransactionHash` and require that it succeeded and contains an
`ExecutionSuccess` event from the configured Safe for the declared
`safeTransactionHash`. Decode the executed Safe/MultiSend transaction and
require its facilitator calls and final set to exactly match the revision
intent. A zero, missing, failed, foreign, or unrelated transaction must fail.

REVISION-6. Archive finalized revisions as ordered, hash-named files. The
evidence summary must include the base manifest hash, every revision intent
hash, revision hash, Safe transaction hash, and execution transaction hash, the
final chain hash, effective facilitator set, and `effectiveReleaseHash`.
Final evidence directories and signer-facing completed-release output must be
keyed by the effective release hash rather than the base hash alone.

REVISION-7. `ReleaseManifest` must return the effective release hash and log it
from verification and governance scripts. Proposal instructions must identify
the base manifest hash, previous revision hash, and revision intent hash. Final
Safe/release review instructions must additionally identify the finalized
revision hash and effective release hash.

## 7. Required tests and validation

### 7.1 Hermetic-build tests

Add focused tests proving rejection of:

- every ambient Foundry/DappTools/compiler override, especially remappings;
- an ignored source selected by a more-specific remapping;
- an untracked, absolute, parent-traversing, symlink-escaped, or external source;
- source metadata that disagrees with the Git object;
- a dirty or wrong recursive submodule;
- a source or checkout mutation during compilation;
- an incomplete effective-remapping lock that lists only explicit remappings;
- a wrong root, direct-submodule, or nested-submodule repository identity;
- an effective config, source-closure, or compiler-input hash mismatch; and
- a direct verification/governance script run without wrapper provenance.

Retain the existing compiler-setting, UUPS immutable, proxy, implementation,
and local-versus-live bytecode mismatch tests.

### 7.2 Identity tests

Test every external identity field independently: proxy codehash,
implementation slot/address/codehash, admin slot, authority, interface support,
and version. Each mismatch must block verify, accept, and activate paths.

Test guardian/admin authorization, one-way guardian behavior, atomic pause and
unpause batches, guardian initialization during an existing-proxy upgrade,
zero-guardian restrictions, all-nine guardian/state validation, false-positive
recovery using an unchanged manifest, activation refusal while paused, and
every guarded function listed in IDENTITY-6. Confirm allowed read, response, and
sync paths still work. Run storage-layout checks for all nine upgradeable
contracts and prove the new packed slot consumes only the corresponding base
storage-gap slot.

### 7.3 Revision and end-to-end tests

Test both supported revision kinds; emergency subset enforcement; rejection of
an emergency addition or unsupported kind; draft, proposal, and finalized
transaction-hash rules; stable intent hashing; revision byte replacement;
ordering and previous-hash links; Safe nonce/hash reproduction; Safe identity;
receipt/event success; decoded payload equivalence; final facilitator
equivalence; and effective release hash changes. Prove draft/proposal revisions
cannot enter final evidence or change the effective release hash.

Directly exercise the full `ReleaseManifest` parser, `VerifyDeployment`, and
both emit-only and execution branches of `ExecuteGovernanceBatches`.

At least one automated end-to-end test must start from a clean temporary clone
and exercise:

1. manifest and revision loading;
2. hermetic compilation and source-closure verification;
3. deployment to a local chain;
4. dark-state verification;
5. admin-acceptance payload generation and execution;
6. activation payload generation and execution;
7. operational verification; and
8. complete base evidence archival under the effective release hash;
9. revision proposal generation and Safe execution;
10. revision finalization and receipt/payload verification; and
11. final revision evidence archival under the updated effective release hash.

## 8. Release acceptance criteria

The remediation is complete only when:

1. Every BUILD, IDENTITY, and REVISION requirement is implemented.
2. Manifest and revision examples, README instructions, interfaces, modules,
   services, scripts, and DTO-like Solidity structs use only the new schema.
3. All Foundry, Python, invariant, formatting, size, coverage, and static checks
   pass on a clean clone.
4. The required direct and end-to-end tests pass in CI.
5. Two independent clean environments using the pinned toolchain produce the
   same config, source-closure, compiler-input, proxy, implementation, base
   manifest, revision, and effective release hashes.
6. Mainnet identity observations match the reviewed manifest immediately before
   admin acceptance and activation.
7. The pause guardian and continuous dependency monitor are operational and a
   pause/unpause rehearsal has been archived.
8. Dark-state verification passes before activation and operational
   verification passes afterward.
9. Signers reproduce and review the exact payload and evidence package by
   effective release hash.
10. The earlier pre-Mainnet audit-fix specification is updated from
    `release rehearsal pending` only after all evidence above exists.

## 9. Expected implementation areas

- `script/release.py`
- `script/verify_release_build.py`
- a committed full effective-remapping lock used by the release wrapper
- `script/ReleaseBuildProfile.sol`
- `script/ReleaseManifest.sol`
- `script/DeploymentValidation.sol`
- a minimal script-side identity metadata/ownership interface
- `script/VerifyDeployment.s.sol`
- `script/ExecuteGovernanceBatches.s.sol`
- `script/GovernanceBatches.sol`
- `deployments/release-manifest.example.json`
- `deployments/release-manifest-revision.example.json`
- `src/utils/Admin2StepUpgradeable.sol`
- the external-dependency governance interface used by Safe batches
- `src/AgentIndex.sol`
- `src/ProviderRegistry.sol`
- `src/ServiceRegistry.sol`
- `src/PaymentRouter.sol` and its storage/admin/interface surfaces
- `src/DaskiValidationRegistry.sol`
- `test/mocks/MockCanonicalIdentityRegistry.sol`
- related Foundry and Python tests
- `README.md`
- the Mainnet monitor and incident runbook in the release-operations repository

Keep the release, external-dependency, and revision validators in focused
helpers when a touched file would otherwise exceed approximately 250 lines.
