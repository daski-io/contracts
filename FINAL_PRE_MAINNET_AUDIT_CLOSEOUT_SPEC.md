# Final Pre-Mainnet Audit Closeout Specification

Status: Draft for implementation | Target: `develop` | Release impact:
Mainnet blocker | Date: 2026-07-30

Primary repository: `daski`

Affected repositories and systems:

- `daski`
- `daski-gateway`
- release CI and Base Sepolia release operations

This specification is a closeout delta for
`FINAL_PRE_MAINNET_AUDIT_REMEDIATION_SPEC.md` and
`.claude/MAINNET_HARDENING_SPEC.md`. Requirements already satisfied by those
documents remain in force and MUST NOT be reimplemented through a parallel
release path.

The words MUST, MUST NOT, SHOULD, and MAY are normative.

## 1. Decision

Mainnet deployment and activation MUST remain blocked until every acceptance
criterion in section 8 is satisfied.

The closeout has three objectives:

1. prove the complete `daski-exact` receive-authorization path against the
   pinned Circle USDC contracts on Base Mainnet and Base Sepolia;
2. make the archived compiler-input and provenance-marker claims match the
   actual inputs and effective release being reviewed; and
3. execute and archive the clean-clone, independent-reproduction, deployment,
   governance, monitoring, and recovery ceremony required by the prior
   remediation.

No Solidity production behavior change is expected. If implementation reveals
that a production contract ABI, storage layout, authorization rule, payment
flow, or governance rule must change, stop this closeout and require a focused
security review of that change before continuing.

Implementation SHOULD proceed in this order:

1. land Fix A as a coordinated contracts-tooling and gateway change;
2. land Fix B and reproduce its new hashes;
3. land the automated portions of Fix C; and
4. execute the Base Sepolia and Mainnet release gates.

Completing an earlier stage does not authorize Mainnet. In particular, the
breaking manifest change and removal of the gateway domain fallback MUST be
coordinated with Base Sepolia re-manifesting, gateway configuration, and
release-operations changes rather than deployed from one repository in
isolation.

## 2. Findings addressed

| ID | Finding | Required disposition |
|---|---|---|
| CLOSE-1 | Contract tests exercise a local `"USDC"` EIP-712 domain and only a Base Sepolia nonce vector; they do not execute the adapter against either pinned Circle token | Add chain-specific domain validation, shared full-signature vectors, and pinned Base fork tests |
| CLOSE-2 | The gateway defaults `USDC_NAME` to `"USDC"` on every chain, while Base Mainnet USDC uses `"USD Coin"` | Remove the unsafe production fallback and fail readiness when the configured domain differs from the live pinned token |
| CLOSE-3 | `compilerInputHash` is reconstructed from artifact metadata instead of the generated compiler inputs/build-info | Derive and archive the hash from the actual selected build-info compiler inputs |
| CLOSE-4 | The wrapper-created provenance marker is not bound to the effective release hash | Introduce a run-local marker schema bound to the manifest, revisions, effective release, and build hashes |
| CLOSE-5 | Clean-clone release E2E, independent reproduction, storage-layout CI, live rehearsal, and monitor deployment remain incomplete | Add the automated gates and archive the two-environment and Base Sepolia operational evidence |

## 3. Security and release invariants

The completed release MUST preserve all of the following:

- Base Mainnet payment requirements use Circle USDC at
  `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` with EIP-712 name
  `"USD Coin"`, version `"2"`, and 6 decimals.
- Base Sepolia payment requirements use Circle USDC at
  `0x036CbD53842c5426634e7929541eC2318f3dCF7e` with EIP-712 name
  `"USDC"`, version `"2"`, and 6 decimals.
- A live gateway never serves a payment requirement until the token address,
  decimals, name, version, and `DOMAIN_SEPARATOR()` have been checked against
  its reviewed release configuration.
- A valid gateway-produced authorization succeeds through the real Circle
  `receiveWithAuthorization(..., bytes)` implementation on both Base chains.
- A fork test MUST NOT replace, etch, mock, or wrap the pinned token code.
- `build.compilerInputHash` identifies the complete compiler inputs actually
  used for every release target, not a reconstruction from output artifacts.
- Every governance or verification script invocation consumes a fresh
  wrapper-created marker for the exact effective release hash used by that
  invocation.
- A marker for one revision set, effective release, or wrapper run cannot be
  reused accidentally for another.
- Release evidence can be reproduced from two independent clean environments
  using the pinned Git and toolchain identities.
- PaymentRouter remains dark until admin acceptance, guardian configuration,
  and dark-state verification are complete.
- The external identity monitor is operational before Mainnet activation, and
  only the Safe can unpause the stack.

## 4. Non-goals

- Do not redesign `daski-exact`, EIP-3009, X402Adapter, PaymentRouter, EAS, or
  ERC-8004.
- Do not add an alternative payment or release path.
- Do not retain a permissive Mainnet fallback for the Sepolia USDC domain.
- Do not treat `MockUSDC` success as evidence of Circle-token compatibility.
- Do not add backwards-compatible parsing for old manifests, provenance
  markers, evidence summaries, or gateway production configuration.
- Do not refactor unrelated contracts, gateway modules, or release scripts.
- Do not use a moving fork head as the archived release test.
- Do not weaken the existing Safe, sanctions, guardian, runtime-codehash,
  source-closure, or effective-facilitator checks.

## 5. Fix A: Prove the production x402 USDC path

### 5.1 Release-manifest USDC domain

Replace the scalar `external.usdc` value with an object that binds the payment
asset and EIP-712 domain:

```json
{
  "external": {
    "usdc": {
      "address": "<pinned Circle USDC address>",
      "decimals": 6,
      "name": "<exact name() result>",
      "version": "<exact version() result>",
      "domainSeparator": "<exact DOMAIN_SEPARATOR() bytes32>"
    }
  }
}
```

X402-1. Update the example manifest, release parser, deployment validation,
evidence summary, and all callers to use only this schema.

X402-2. Before deployment output is accepted, before admin acceptance, before
activation payload generation, and during dark and operational verification,
read `decimals()`, `name()`, `version()`, and `DOMAIN_SEPARATOR()` from the
pinned USDC address. Require exact manifest matches.

X402-3. Independently compute the expected EIP-712 domain separator from the
manifest name, version, chain ID, and token address. Require it to equal both
the manifest value and the token's live `DOMAIN_SEPARATOR()`. A self-consistent
but wrong caller-supplied domain MUST fail.

Use Circle's four-field domain exactly:

```text
keccak256(abi.encode(
  keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
  ),
  keccak256(bytes(name)),
  keccak256(bytes(version)),
  chainId,
  token
))
```

X402-4. The release evidence MUST record the fork block, chain ID, token
address, runtime codehash, decimals, name, version, observed domain separator,
and independently computed domain separator.

The values observed during this audit were:

| Network | Chain ID | Decimals | Name | Version | Domain separator |
|---|---:|---:|---|---|---|
| Base Mainnet | 8453 | 6 | `USD Coin` | `2` | `0x02fa7265e7c5d81118673727957699e4d68f74cd74b7db77da710fe8a2c7834f` |
| Base Sepolia | 84532 | 6 | `USDC` | `2` | `0x71f17a3b2ff373b803d70a5a07c046c1a2bc8e89c09ef722fcb047abe94c9818` |

These observations are not permanent constants by themselves. The release
manifest MUST record values re-observed and reviewed at the pinned release
blocks.

### 5.2 Gateway domain source and readiness

X402-5. In live chain mode, `daski-gateway` MUST derive the expected USDC
address and EIP-712 domain from an explicit chain-specific reviewed
configuration. It MUST NOT default both Base chains to `"USDC"`.

X402-6. Mainnet startup MUST fail unless the configured values are exactly the
reviewed Base Mainnet values. Base Sepolia startup MUST fail unless they are
exactly the reviewed Base Sepolia values. Development mock mode MAY use a mock
domain, but that branch MUST be structurally separate from live readiness.

X402-7. If `USDC_NAME` and `USDC_VERSION` remain environment variables, they
MUST be required in live mode and MUST match the chain-specific reviewed
values. An omitted, blank, or mismatched value MUST fail configuration loading;
there is no production fallback.

X402-8. Extend gateway deployment readiness to read the live token address,
name, version, decimals, and domain separator. Readiness MUST fail closed on
each mismatch independently and expose a stable, non-sensitive check ID.

X402-9. Challenge generation, payload verification, the in-process
`DaskiExactEvmScheme`, public chain descriptors, and discovery metadata MUST all
consume the same validated domain object. They MUST NOT maintain independent
defaults.

X402-10. Release operations MUST compare the gateway's public chain descriptor
with the reviewed contract release manifest before enabling traffic.

### 5.3 Signing helpers and shared vectors

X402-11. Replace the Solidity test helper's hardcoded domain with explicit
chain/token domain input or a read from the token under test. `MockUSDC` MAY
retain its local `"USDC"` domain, but comments and tests MUST describe it as
local/Sepolia-shaped rather than universally production-equivalent.

X402-12. Add committed cross-repository vectors for both Base chains. Each
vector MUST include:

- chain ID;
- USDC address, decimals, name, version, and domain separator;
- adapter, router, payer, amount, validity window, provider, service,
  `serviceRef`, and `nonceSalt`;
- derived route-bound nonce;
- complete `ReceiveWithAuthorization` struct hash;
- complete EIP-712 digest; and
- a known signer address and 65-byte signature.

The contracts and gateway test suites MUST independently reproduce every
field. A nonce-only vector is insufficient because it does not exercise the
token-domain difference.

### 5.4 Pinned Base fork tests

X402-13. Add one Base Mainnet fork suite and one Base Sepolia fork suite. Each
suite MUST use a reviewed, explicit block number and the pinned Circle USDC
address. The block number, block hash, and RPC chain ID MUST appear in test
output and archived evidence.

Fetch the pinned block hash from the fork RPC with
`eth_getBlockByNumber` through `vm.rpc` or an equivalent JSON-RPC call.
`blockhash(block.number)` MUST NOT be used as evidence because the EVM returns
zero for the current fork block.

X402-14. The fork setup MAY seed an otherwise test-controlled payer balance
with a Foundry balance-storage helper. It MUST NOT alter the token's code,
implementation slot, domain state, authorization state, blacklist logic, or
signature validation.

Circle's FiatTokenV2_2 packs the blacklist flag into the high bit of the same
word used for balances. The seeded payer MUST be a fresh address that is not
blacklisted at the pinned fork block. Assert `isBlacklisted(payer) == false`
immediately before and after balance seeding, and assert the exact seeded
balance before signing. A test that clears or changes a pre-existing blacklist
bit is invalid.

X402-15. Each fork MUST deploy the production X402Adapter and the minimum
production settlement stack needed to execute a real payment. Mocks MAY stand
in for unrelated external identity or EAS services, but X402Adapter,
PaymentRouter, the registries involved in route resolution, and Circle USDC
MUST execute their production code paths.

X402-16. On both forks, prove:

1. the chain-specific domain values match the release expectation;
2. a valid 65-byte EOA receive authorization settles;
3. a valid ERC-1271 receive authorization settles through Circle's opaque
   `bytes` signature overload;
4. the payment record and route match the signed challenge;
5. provider and treasury receive the exact split;
6. adapter and router balances return to their pre-call values;
7. Circle marks the authorization nonce used;
8. replay fails atomically; and
9. a signature made with the other Base chain's token name or chain ID fails
   without moving funds or writing Daski state.

X402-17. At least the Base Mainnet fork MUST also exercise
`settleWithRegistration`, proving registration, ERC-1271 signature validation,
Circle authorization, and settlement remain atomic.

### 5.5 CI gate

X402-18. Deterministic vectors and gateway domain/readiness tests MUST run in
normal pull-request CI without RPC secrets.

X402-19. Add a protected release-gate workflow that runs both pinned fork
suites using separately configured Base Mainnet and Base Sepolia RPC
credentials. It MUST run on the exact candidate commit and MUST be required
before either release-candidate or Mainnet approval. A skipped fork test is a
failed release gate.

Both RPC services MUST provide archival state at the committed fork blocks.
The workflow MUST preflight each endpoint by retrieving the pinned block and
the token's code and domain state at that block. An endpoint that prunes,
silently substitutes a newer block, rate-limits the required state, or cannot
prove the expected block hash MUST fail the gate rather than skip or move the
fork.

## 6. Fix B: Make release provenance claims exact

### 6.1 Compiler inputs from build-info

PROVENANCE-1. `build_release_targets` MUST provide the generated build-info
directory to the verifier. The verifier MUST enumerate the build-info compiler
units directly; artifact `rawMetadata` MUST NOT be the source of
`compilerInputHash` or the authoritative source closure.

PROVENANCE-2. Reject an empty, malformed, duplicate, or unsupported build-info
unit. Require a generated unit for every compilation unit used by:

- all nine implementations;
- `ERC1967Proxy`;
- `Deploy.s.sol`;
- `VerifyDeployment.s.sol`; and
- `ExecuteGovernanceBatches.s.sol`.

Every required artifact MUST identify a selected build-info unit, and every
selected unit MUST be present in the archived evidence. Stale or unrelated
units MUST NOT silently enter the hash.

PROVENANCE-3. For each selected compiler input, read the complete `language`,
compiler identity, `settings` object, ordered remappings, libraries, and source
map from build-info. Source content MUST be replaced in the canonical summary
only by its verified Keccak-256 content hash after the bytes have been compared
with the correct Git object. The union of these selected source maps MUST drive
the existing domain-separated `sourceClosureHash`; sources found only by
scanning output artifacts MUST NOT enter it.

PROVENANCE-4. Define:

```text
unitHash = keccak256(
  "DASKI_SOLC_INPUT_V1" ||
  canonicalJson({
    compiler,
    language,
    settings,
    sources: { logicalPath: sourceContentHash }
  })
)

compilerInputHash = keccak256(
  "DASKI_COMPILER_INPUT_SET_V1" ||
  lengthPrefixed(sorted(unitHash))
)
```

Canonical JSON rules and length-prefix encoding MUST be documented and shared
by preparation, verification, tests, and independent reproduction. Do not
concatenate variable-length values without framing.

PROVENANCE-5. Keep artifact metadata validation as an independent cross-check
for compiler version, optimizer, via-IR, EVM version, source membership, UUPS
immutable provenance, and runtime bytecode. Metadata MUST NOT substitute for
the build-info compiler input.

PROVENANCE-6. Archive:

- the original selected build-info files;
- the selected-unit mapping for every required target;
- the canonical compiler-input summaries;
- every unit hash; and
- the final `compilerInputHash`.

### 6.2 Effective-release-bound marker

Replace the current marker with this schema:

```json
{
  "schema": "daski-release-provenance/v2",
  "runId": "<random nonzero bytes32>",
  "manifestHash": "<bytes32>",
  "revisionEvidenceHash": "<bytes32>",
  "effectiveReleaseHash": "<bytes32>",
  "sourceClosureHash": "<bytes32>",
  "compilerInputHash": "<bytes32>",
  "foundryConfigHash": "<bytes32>"
}
```

PROVENANCE-7. Generate a cryptographically random, nonzero `runId` for every
wrapper invocation. Create the live marker only after base-manifest,
build-info, source-closure, revision, effective-facilitator, and Safe evidence
validation have succeeded.

PROVENANCE-8. Create the live marker inside the wrapper-owned temporary
directory, not in a caller-selected location. Pass its absolute path and the
expected run ID to Forge only through the wrapper-created environment. Archive
a copy after the run; the archived copy is evidence and MUST NOT be reused as a
live marker.

PROVENANCE-9. Hash the exact canonical revision-evidence bytes consumed by the
Solidity scripts. The marker MUST bind that hash and the effective release hash
derived from those revisions.

PROVENANCE-10. `ReleaseManifest` MUST load and validate manifest and revision
evidence, derive the effective release state, and then require exact marker
matches for every field above. Validation MUST occur before live contract
reads, payload logging, payload generation, broadcast setup, or chain
interaction.

PROVENANCE-11. A marker with the correct base manifest but a different
revision-evidence hash, effective release hash, run ID, or build hash MUST fail.
An old v1 marker or missing field MUST fail; do not add compatibility parsing.

PROVENANCE-12. Recheck the Git checkout, recursive submodules, manifest bytes,
revision bytes, canonical revision evidence, and marker immediately before and
after every Forge verification or governance invocation. For broadcasting
modes, the wrapper MUST perform the final check immediately before launching
the Forge invocation that can broadcast, without regenerating or replacing any
reviewed input between the check and invocation.

The marker remains an accidental-bypass control, not protection from a
malicious operator who controls the local machine and signing key. Independent
reproduction and signer review remain the security boundary.

### 6.3 Provenance tests

Add tests that independently prove rejection of:

- missing or empty build-info;
- an artifact without a selected build-info unit;
- a selected unit not used by a required target;
- changed language, compiler identity, settings, remapping, library, source
  path, or source content;
- build-info and artifact-metadata disagreement;
- a dropped or additional selected compiler unit;
- unframed or non-domain-separated hash construction;
- a marker from another wrapper run;
- a marker for another effective release or revision-evidence file;
- an archived marker reused as a live marker;
- a source, manifest, revision, or checkout mutation before broadcast; and
- direct execution of verification or governance scripts without a valid v2
  marker.

## 7. Fix C: Complete the release ceremony

### 7.1 Clean-clone end-to-end CI

RELEASE-1. Add a release E2E job that starts from a newly created temporary
clone with recursive submodules and no shared Forge cache, output directory,
ignored files, user Foundry configuration, or evidence from the invoking
checkout.

RELEASE-2. Against a fresh local Anvil chain, the job MUST exercise:

1. build-profile preparation from the pinned commit;
2. hermetic compilation and build-info/source-closure verification;
3. dark deployment with a local canonical-dependency fixture;
4. release-manifest generation and parsing;
5. dark-state verification;
6. admin-acceptance payload emission and execution;
7. guardian configuration validation;
8. activation payload emission and execution;
9. operational verification;
10. pause payload emission and execution;
11. paused-state verification;
12. Safe-only unpause emission and execution;
13. post-unpause operational verification;
14. planned facilitator revision proposal generation;
15. Safe execution and finalized revision verification;
16. final facilitator-set equivalence; and
17. complete evidence archival under the final effective release hash.

RELEASE-3. The E2E MUST directly cover the full `ReleaseManifest` parser and
both emit-only and execution branches of every supported governance mode.
Assertions only against helper functions are insufficient.

RELEASE-4. Every E2E artifact MUST remain inside a temporary test/evidence root
and be destroyed after assertions, except CI artifacts explicitly uploaded for
review. The test MUST NOT mutate committed examples or rely on the developer's
working-tree `out` or `cache`.

### 7.2 Independent reproduction

RELEASE-5. Run release reproduction in two clean, isolated jobs with:

- the same pinned Git commit and recursive submodule commits;
- the same pinned Forge and Cast version/commit;
- no shared compiler, Forge, Git, or artifact cache;
- independent temporary home and configuration directories; and
- independently generated build-info and evidence.

RELEASE-6. A comparison job MUST require exact equality of:

- effective Foundry config and remapping hashes;
- source-closure listing and hash;
- selected compiler-input summaries, unit hashes, and aggregate hash;
- proxy runtime hash;
- all nine implementation runtime hashes;
- base manifest hash;
- finalized revision hashes; and
- effective release hash.

Any mismatch blocks release and both complete evidence sets MUST be retained.

### 7.3 Storage-layout gate

RELEASE-7. Commit an audited storage-layout baseline for all nine upgradeable
contracts at the closeout implementation commit. CI MUST compare every
contract's normalized slot, offset, type, and inherited storage ordering with
that baseline.

RELEASE-8. The gate MUST specifically prove that `pauseGuardian` and
`externalDependencyPaused` share the intended former base-gap slot, the
remaining base gap begins at the next slot, and every derived contract's first
storage slot remains unchanged. Any layout difference requires explicit
review; a regenerated baseline in the same unreviewed run MUST NOT pass.

### 7.4 Base Sepolia live rehearsal

RELEASE-9. Deploy a fresh dark Base Sepolia release candidate governed by a
multi-owner, threshold-two-or-higher Safe. Configure the reviewed pause
guardian on all nine proxies before activation.

RELEASE-10. Deploy the external identity monitor as a continuously running
release-operations service before activation. Record its deployment identity,
configuration hash, effective release hash, health check, alert destination,
guardian identity, and evidence storage location.

RELEASE-11. Before activation, execute the complete gateway-to-contract x402
flow against Circle Base Sepolia USDC for:

- an existing EOA buyer;
- an existing ERC-1271 buyer;
- an unregistered buyer using atomic registration and settlement; and
- a duplicate authorization/retry attempt.

Archive the HTTP challenge and payment response with signatures redacted, the
domain and route fields, transaction receipts, payment records, balance deltas,
nonce state, and gateway correlation IDs.

RELEASE-12. Rehearse the external-dependency incident procedure:

1. create a controlled monitor mismatch without changing the live canonical
   identity contract;
2. confirm the guardian pauses PaymentRouter first and then all other proxies;
3. verify every guarded mutation fails while documented read/response/sync
   paths remain available;
4. archive all pause transactions and alert evidence;
5. restore the reviewed monitor configuration;
6. verify the unchanged live identity against the release manifest;
7. execute the atomic Safe unpause batch; and
8. run operational verification and one successful post-recovery payment.

RELEASE-13. The rehearsal MUST use the same binaries, configuration schema,
marker schema, monitor service definition, and signer instructions intended for
Mainnet. A unit-test-only or manually edited substitute does not satisfy this
requirement.

### 7.5 Mainnet release gate

Immediately before Mainnet admin acceptance and again before activation:

- rerun both pinned Circle fork suites on the candidate commit;
- confirm the two independent reproduction outputs are identical;
- verify live Mainnet USDC domain fields against the reviewed manifest;
- verify the canonical identity observations and all nine Daski runtime
  identities;
- confirm the monitor and pause guardian are operational;
- run dark-state verification with a fresh v2 provenance marker; and
- have Safe signers reproduce and review the exact payload and evidence package
  by effective release hash.

No item may be waived by a manual note. A failed or unavailable dependency
keeps the deployment dark.

## 8. Acceptance criteria

This closeout is complete only when:

1. Every X402, PROVENANCE, and RELEASE requirement above is implemented.
2. Base Mainnet and Base Sepolia full-signature vectors pass independently in
   the contracts and gateway repositories.
3. Both pinned Circle fork suites pass on the exact candidate commit.
4. Gateway live readiness fails on wrong address, name, version, decimals, or
   domain separator and succeeds on both reviewed Base configurations.
5. `compilerInputHash` is produced only from selected generated build-info
   compiler inputs and is independently reproduced.
6. Every verification and governance branch rejects an absent, stale, or
   differently bound v2 provenance marker.
7. Foundry formatting, build, size, unit, fuzz, invariant, coverage, storage
   layout, and Slither checks pass.
8. Gateway formatting, type checking, build, unit, integration, deployment
   readiness, and existing security checks pass.
9. The clean-clone release E2E passes in CI and archives reviewable evidence.
10. Two independent clean environments produce identical hashes and selected
    compiler-input summaries.
11. The fresh Base Sepolia release rehearsal, real Circle USDC payments,
    monitor-triggered pause, Safe unpause, and post-recovery payment are
    archived.
12. Mainnet dark-state verification passes with live USDC and identity
    observations immediately before admin acceptance and activation.
13. The prior remediation specification status is updated to complete only
    after all evidence exists.
14. No unresolved TODO, FIXME, skipped release test, or waived acceptance item
    remains.

## 9. Required evidence package

The final signer-facing package MUST contain:

- candidate Git commit and recursive submodule identities;
- pinned Forge, Cast, and Solidity identities;
- both complete independent build evidence directories;
- canonical build-info/compiler-input summaries and hashes;
- source-closure and effective Foundry configuration evidence;
- storage-layout baseline and comparison output;
- Base Mainnet and Base Sepolia fork blocks, block hashes, token observations,
  and test logs;
- base manifest, ordered finalized revisions, revision-evidence hash, and
  effective release hash;
- every v2 provenance marker archived under its run/effective-release
  evidence;
- local clean-clone E2E logs and Safe payloads;
- Base Sepolia deployment, payment, pause, unpause, monitor, and recovery
  evidence;
- Mainnet dark-state verification output;
- monitor service identity and health evidence; and
- a signer checklist that names every reviewed hash and payload.

Signatures, private keys, raw signed transactions not required for recovery,
RPC credentials, and other secrets MUST NOT appear in CI output or the
signer-facing archive.

## 10. Expected implementation areas

### `daski`

- `deployments/release-manifest.example.json`
- `script/DeploymentValidation.sol`
- `script/ReleaseManifest.sol`
- `script/release.py`
- `script/release_build.py`
- `script/verify_release_build.py`
- release, deployment, storage-layout, and fork tests
- `.github/workflows/`
- README and deployment/runbook release instructions

### `daski-gateway`

- `src/config.ts`
- `src/payment/requirementResponse.ts`
- `src/payment/daskiClient.ts`
- deployment-readiness types, ABI, and viem implementation
- public chain descriptor generation
- domain, signing-vector, readiness, and live-flow tests
- `.env.example` and operator-facing deployment documentation

### Release operations

- protected fork-test RPC configuration
- two-environment reproduction and comparison
- Base Sepolia monitor deployment
- pause/unpause rehearsal automation and evidence retention
- Mainnet signer checklist and release gate
