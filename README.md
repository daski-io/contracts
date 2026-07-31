# Daski Contracts

[Daski](https://sandbox.daski.io) is marketplace infrastructure for the agent
economy — an open coordination layer where AI agents discover services, settle
payment in USDC on Base, and accumulate on-chain reputation, all over open
standards (MCP, x402, A2A, ERC-8004). This repo is the on-chain protocol:
provider registry, rail-agnostic payment routing, and bilateral reputation
backed by EAS attestations — built on top of the **canonical ERC-8004
registries**. For the full protocol design, read the
[whitepaper](https://sandbox.daski.io/MarketplaceProtocolWhitePaper.pdf).

**Status:** the Base Sepolia addresses below are retired pre-production
infrastructure and must not be used with this revision. The current revision
requires a fresh manifest-reviewed deployment; an external audit is still
pending.

## Canonical ERC-8004 registries

Daski does **not** deploy an identity registry (or an ERC-8004 reputation
registry) of its own. Agent identity is the pair *(registry, agentId)*, and
Daski agents live in the canonical per-chain singletons that the whole
ecosystem (8004scan, indexers, other marketplaces) reads:

| Registry            | Base mainnet                                  | Base Sepolia                                  |
|---------------------|-----------------------------------------------|-----------------------------------------------|
| IdentityRegistry    | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`  | `0x8004A818BFB912233c491871b3d84c89A494BD9e`  |
| ReputationRegistry  | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`  | `0x8004B663056A597Dffe9eCcC1965A193B7388713`  |

Public ERC-8004 feedback is written to the canonical ReputationRegistry by
the gateway (off-chain, per confirmed delivery, with the EAS attestation as
evidence); no contract in this repo touches it. The ERC-8004
validation registry remains Daski-hosted because that section of the spec is
still in flux and has no canonical deployment yet. Daski's EAS layer
(`ReputationStorage`) is the payment-verified internal ledger that drives
ranking — it is Daski-native, not ERC-8004 reputation.

Provider approval, marketplace listing visibility, and the reputation shown
in discovery are gateway trust boundaries for the MVP. The contracts require
an active Daski provider and service before settlement, but their raw public
transaction counters are not a permissionless Sybil-resistance mechanism and
must not be treated as marketplace eligibility or ranking on their own.

## Three-layer identity model

| Layer       | Where it lives                                     | Identifier        | Example                |
|-------------|----------------------------------------------------|-------------------|------------------------|
| Provider    | On-chain (canonical ERC-8004 `IdentityRegistry`)   | `agentId`         | Blue T Group LLC       |
| **Service** | On-chain (Daski `ServiceRegistry`)                 | `serviceId`       | "Domain Registration"  |
| Skill       | Off-chain (provider's A2A Agent Card)              | `AgentSkill.id`   | `register-domain`      |

A *service* is a marketable product — the unit of buyer discovery and reputation. A *skill* is a callable A2A method. **One service maps to one or more skills**; the mapping lives in the off-chain `serviceURI` JSON, not on-chain.

## Contracts

| Contract            | Purpose |
|---------------------|---------|
| **AgentIndex**         | Daski companion to the canonical IdentityRegistry: a verified wallet→agentId reverse index (the canonical registry has none) plus gasless onboarding — `registerWithSig` mints a canonical agent for a fresh buyer wallet (relayer pays gas, wallet signs EIP-712 consent) and hands it the NFT. `resolve` returns an explicit found flag because agent ID 0 is valid. |
| **ProviderRegistry**   | Provider listings: USDC listing fee, active toggle. Gates canonical ERC-8004 agents into the Daski "provider" role (caller must own the agent NFT). |
| **ServiceRegistry**    | Per-provider product catalog. A service is a row, not its own NFT — keyed by `keccak256(providerAgentId, serviceSlug, version)`. Optional service payee overrides are bound to both the authorizing NFT owner and the live canonical `agentWallet`; skills are declared off-chain. |
| **PaymentRouter**      | Rail-agnostic settlement that splits accepted tokens between provider/service wallet and the payment treasury. Per-token policy independently controls payment acceptance and reputation eligibility/minimums. It validates (provider, service) on every settlement and requires the live resolved payee to match the buyer-quoted payee, namespaces replay protection, and excludes relationships provable from on-chain identity state at settlement time from reputation. |
| **X402Adapter**        | Daski's x402 V2 `daski-exact/1` rail using EIP-3009 `receiveWithAuthorization` (Circle USDC). Each opaque EOA/ERC-1271 signature is bound to the complete settlement route and a fresh client salt; only enumerated admin-allowlisted facilitators may submit it. |
| **PermitAdapter**      | EIP-2612 permit rail. |
| **ApprovalAdapter**    | Plain `approve` + `transferFrom` rail (fallback). |
| **DaskiValidationRegistry** | Daski-specific, ERC-8004-inspired validation requests with namespaced keys and paginated reads. `validationRequest` returns `computeValidationKey(agentId, requestHash)`; calls and paginated lists use that key, while events carry both it and the raw payload hash. This intentionally avoids the draft registry's global request-hash squatting and unbounded getter behavior rather than claiming drop-in compatibility. |
| **ReputationStorage**  | Bilateral reputation resolver: qualified payments contribute to counters, providers record outcomes, and buyers confirm. Payment/refund mirroring is retryable so a resolver outage cannot block settlement. EAS-backed; counters split per-provider AND per-service. Resolver addresses and schema UIDs are permanently locked by one-time configuration finalization before payment rails can be enabled. |
| **MockUSDC**           | Testnet ERC-20 (6 decimals, public mint). Test deploys only. |

All contracts are UUPS-upgradeable (OpenZeppelin v5) behind a 2-step admin.
Fresh deployments require the exact canonical Safe profile recorded in the
reviewed release manifest as the pending admin of every proxy. Payment rails
remain disabled until that Safe accepts every admin role.

Allowlisted adapters are trusted to authenticate or establish buyer consent
and to deliver the exact settlement amount. Adapter enablement verifies the
adapter's router binding on-chain; deployment verification additionally checks
its exact AgentIndex binding.

Reputation eligibility excludes direct overlap and cross-control among the
buyer payer, both NFT owners, both verified agent wallets, the service payee,
and both current per-token approvees. It checks per-token and
`isApprovedForAll` authority in both directions. ERC-721 operator sets are not
enumerable, so a shared third-party operator that is not otherwise one of
those discoverable controllers cannot be detected on-chain.

Every participant wallet is screened on-chain against the configured
Chainalysis-compatible sanctions oracle. Adapters reject payers before token
calls and the router independently rechecks live payer, controller, payee, and
treasury addresses. Covered operations fail closed when screening is
unavailable. Integrators should decode `SanctionedAddress(address)` and
`SanctionsOracleUnavailable(address)` rather than matching revert text.

## Deployments

### Base Sepolia (chain id `84532`) — release candidate, deployed 2026-07-31

The `daski-exact/1` receive-authorization stack, deployed at block
`44881793` under the release-candidate ceremony. Reviewed release manifest
hash
`0x43bff3909fb13f6ca334e578fc9bc14dbae4d50d8ccda9de0dbe55757943197d`;
effective release hash
`0x708bdd4c394ba0b3c738d78d382cbbc7cf20e46a1552b0c89f8cf0d41830408a`.

Canonical ERC-8004 singletons (external, never Daski-deployed):
IdentityRegistry `0x8004A818BFB912233c491871b3d84c89A494BD9e`,
ReputationRegistry `0x8004B663056A597Dffe9eCcC1965A193B7388713`.

| Contract              | Address                                      |
|-----------------------|----------------------------------------------|
| Governance Safe (admin, 2-of-2 RC) | `0xA8d8c478C366B80B1A122A2EA72348EB7E6B0695` |
| Pause guardian        | `0xEe040016AbcF2EF1BcaE87FEbb452c763D34342d` |
| Authorized x402 V2 facilitator | `0x08004fDdB4e7b64977D341Ad9d6B98B4d10D6ed2` |
| USDC (Circle)         | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| SanctionsOracle (MockSanctionsList) | `0xa94d2168820f349aafBa585c12E69aA387dCB815` |
| AgentIndex            | `0xA9b7ff6158E51581F253a8234EAC79411FB0e1cf` |
| DaskiValidationRegistry | `0xC3EA96dAaF863707573a342138394d51e336FBBC` |
| ProviderRegistry      | `0xba7d08a4851975b3e80550b9aa4aA6092dCBC909` |
| ServiceRegistry       | `0x79114da4DA6FbEcF1897950BB051b55c8d839840` |
| PaymentRouter         | `0xC6Ab3cB38D3AFc30aDB78849F2B02133e805d860` |
| ReputationStorage     | `0x2CA0B71a5D6C0499ec14838A8bD809351E535815` |
| X402Adapter           | `0xB83633e2A6A36bd5EaF23e8C8f8d33767EaD3d7D` |
| PermitAdapter         | `0x1Baa964376F49D256766525d5D63606757118e79` |
| ApprovalAdapter       | `0x836233ac94aEb205825A3EC1Eee60827A86582e1` |
| EAS                   | `0x4200000000000000000000000000000000000021` |
| Schema Registry       | `0x4200000000000000000000000000000000000020` |

EAS schema UIDs (resolver = ReputationStorage):
- Outcome: `0x1d5af8287b2d94fdc0d48957fb160c1d1f320bb685ace612f6999f9b59edbe28`
- Confirmation: `0xfa6d275ba3757bc258757bf197262b44c5358ab5a1e8ddff285c523e18db0858`

The 2026-07-28 generic Exact-EVM set and the 2026-07-22 and 2026-07-12
proxy sets are retired (history in the machine-readable deployment file).
Do not configure a gateway or buyer against a retired set.

Machine-readable copy: [`deployments/base-sepolia.json`](deployments/base-sepolia.json)

Retiring this legacy stack is an operator action, not a proxy upgrade. At the
retirement block, re-check that the router holds no USDC, call
`setAcceptedToken(USDC, false)`, disable DirectTransfer/X402/Permit/Approval,
and scan all historical `AdapterSet` and `AcceptedTokenSet` events for any
other enabled entries. Then replace the old router address in every dependent
service. Bare token transfers can arrive at any time, so repeat the balance
check immediately before and after quiescing the router.

`script/RetireStack.s.sol` performs the disable pass (idempotent; refuses a
router with a residual token balance unless overridden) for EOA-admined
legacy routers:

```bash
export RETIRE_PAYMENT_ROUTER_ADDRESS=<old router>
export RETIRE_TOKENS=<comma-separated tokens ever accepted>
export RETIRE_ADAPTERS=<comma-separated adapters ever enabled>
forge script script/RetireStack.s.sol --rpc-url <RPC_URL> --broadcast
```

The event-history scan before and after is still mandatory — mappings are
not enumerable, so the env lists must be proven exhaustive against the
router's full `AcceptedTokenSet`/`AdapterSet` log history. A Safe-admined
router (v0.6.0+) is retired through a governance batch instead.

The previous (pre-canonical-migration) stack at PaymentRouter
`0x78f9b15F…459d8f` is orphaned and **quiesced (2026-07-22)**: USDC
disabled, all three adapters disabled, zero balance, event history scanned
exhaustive. The seven earlier May-2026 iteration stacks (routers recorded in
this repo's `deployments/base-sepolia.json` history, all of which accepted
real Circle USDC) were swept and quiesced the same day, the same way. Legacy
Identity/Reputation registries remain orphaned — historical record in the
deploy-testnet repo's deployment records.

### Base mainnet
Not yet deployed. Pending audit.

## Architecture

UUPS proxy pattern; deploy order matters due to cross-contract dependencies.
`IdentityRegistry` below means the CANONICAL singleton (env-supplied, never
deployed by Daski):

```
1. AgentIndex              (canonical IdentityRegistry)
2. DaskiValidationRegistry (canonical IdentityRegistry)
3. ProviderRegistry        (canonical IdentityRegistry, USDC, treasury)
4. ServiceRegistry         (canonical IdentityRegistry, ProviderRegistry)
5. PaymentRouter           (canonical IdentityRegistry, ProviderRegistry, ServiceRegistry, USDC, treasury)
6. ReputationStorage       (canonical IdentityRegistry, PaymentRouter, EAS, schema UIDs)
7. Adapters (X402/Permit/Approval) — initialized with AgentIndex, registered with PaymentRouter
```

## Development

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test       # 335 tests across 20 suites
forge test -vvv  # verbose
forge fmt
```

| Suite | Tests |
|---|---|
| PaymentRouter         | 98 |
| ReputationStorage     | 39 |
| ReputationConfiguration | 10 |
| ServiceRegistry       | 28 |
| AgentIndex            | 25 |
| ProviderRegistry      | 23 |
| X402Adapter           | 26 |
| DaskiValidationRegistry | 19 |
| PermitAdapter         | 7  |
| ApprovalAdapter       | 7  |
| ReleaseManifest       | 12 |
| DeploymentValidation  | 6  |
| DeploymentGuards      | 7  |
| SafeDeployment        | 6  |
| Integration           | 4  |
| External identity validation | 9 |
| External dependency guard | 4 |
| RetireStack           | 2  |
| Canonical identity mock | 2 |
| EAS mock              | 1 |

Tests run against `test/mocks/MockCanonicalIdentityRegistry.sol`, a faithful
double of the canonical registry surface (ERC-721 + registration +
agentWallet, IDs beginning at 0, registration-time wallet initialization, and
**no** reverse index).

## Deploy

```bash
export DEPLOYER_PRIVATE_KEY=<key>
export PROVIDER_TREASURY_ADDRESS=<listing-fee treasury>
export PAYMENT_TREASURY_ADDRESS=<payment-commission treasury>
# REQUIRED: public address derived from the gateway FACILITATOR_PRIVATE_KEY.
export FACILITATOR_ADDRESS=<gateway-facilitator-address>
# Deployed governance contract (never an EOA) — see "Governance Safe" below.
export ADMIN_ADDRESS=<deployed multisig or timelock>
# REQUIRED for release candidates/Mainnet: dedicated pause-only guardian.
export PAUSE_GUARDIAN_ADDRESS=<HSM-or-KMS-backed-guardian>
# REQUIRED: the canonical ERC-8004 IdentityRegistry for the target chain.
#   Base Sepolia: 0x8004A818BFB912233c491871b3d84c89A494BD9e
#   Base mainnet: 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
export IDENTITY_REGISTRY_ADDRESS=0x8004A818BFB912233c491871b3d84c89A494BD9e

# REQUIRED: deployed USDC-compatible token for the target chain.
#   Base Sepolia (Circle): 0x036CbD53842c5426634e7929541eC2318f3dCF7e
#   Base mainnet:          0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e

# REQUIRED: Chainalysis Sanctions Oracle.
#   Base mainnet: 0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B
#   Base Sepolia: no official deployment; use an explicitly marked mock only.
export SANCTIONS_ORACLE_ADDRESS=<oracle-address>

# Optional (defaults shown)
export LISTING_FEE=1000000   # 1 USDC
export COMMISSION_BPS=500    # 5%
export USDC_REPUTATION_MINIMUM=250000 # $0.25 in Circle USDC units

forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast
```

On Base mainnet and Base Sepolia, deployment enforces the pinned canonical
IdentityRegistry, Circle USDC, EAS, and SchemaRegistry addresses. Base mainnet
also pins the documented Chainalysis oracle. Base Sepolia and isolated chains
require `ALLOW_MOCK_SANCTIONS_ORACLE=true` because Chainalysis does not publish
an official Base Sepolia deployment. Deployment also
checks ERC-165/ERC-721 support, six-decimal USDC semantics, the EAS
SchemaRegistry binding, the oracle ABI, both registered schemas, and every
cross-contract wiring relationship. Unsupported chains are rejected unless the operator
explicitly sets `ALLOW_UNSUPPORTED_CHAIN=true`; semantic dependency checks
still apply.

For an isolated non-mainnet environment without a token, deploy the
unrestricted-mint test double separately, then supply its logged address to
the production-shaped deployment:

```bash
forge script script/DeployMockUSDC.s.sol --rpc-url <RPC_URL> --broadcast
export USDC_ADDRESS=<logged MockUSDC address>
forge script script/DeployMockSanctionsList.s.sol --rpc-url <RPC_URL> --broadcast
export SANCTIONS_ORACLE_ADDRESS=<logged MockSanctionsList address>
export ALLOW_UNSUPPORTED_CHAIN=true
export ALLOW_MOCK_SANCTIONS_ORACLE=true
forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast
```

`Deploy.s.sol` never creates a mock token or silently substitutes one for a
missing production dependency.

### Governance Safe (`ADMIN_ADDRESS`)

`ADMIN_ADDRESS` must be the Safe recorded by the release manifest — an EOA or
arbitrary contract is rejected. Validation pins the canonical Safe v1.4.1
proxy runtime, SafeL2 singleton, fallback handler, owners, threshold, modules,
guard, and fallback storage. `script/SafeDeployment.sol` also pins the
SafeProxyFactory and MultiSendCallOnly deployments by runtime codehash.

Developer-only testnets may use a 1-of-1 Safe owned by the deployer:

```bash
forge script script/DeploySafe.s.sol --rpc-url <RPC_URL> --broadcast
export ADMIN_ADDRESS=<logged Safe address>
```

`SAFE_OWNERS` (comma-separated), `SAFE_THRESHOLD`, and `SAFE_SALT_NONCE`
override the defaults; the same owners+threshold+salt always yields the same
create2 address, so a fresh Safe needs a new salt. Base mainnet and every
release-candidate rehearsal require at least two owners and threshold two:

```bash
export RELEASE_CANDIDATE=true
export SAFE_OWNERS=<owner-1>,<owner-2>
export SAFE_THRESHOLD=2
forge script script/DeploySafe.s.sol --rpc-url <RPC_URL> --broadcast
```

### Staged deployment and governance batches

`Deploy.s.sol` creates a dark deployment: ReputationStorage is configured, but
no token or adapter is enabled. Contract addresses, EAS schema UIDs, and
resolver wiring are logged at the end. Accept all nine pending admin roles from
the configured governance contract before activating the token and adapters.

From a clean checkout, generate the draft manifest's reproducible build fields:

```bash
python3 script/prepare_release_build.py --release-ref origin/develop
```

Copy `deployments/release-manifest.example.json` to a release-specific file
outside the checkout, insert those build fields, and fill the remaining values
from deployment receipts. It is the single reviewed identity for chain, source
commit, pinned compiler and
Foundry profile, all nine proxies and implementations, runtime fingerprints,
the canonical identity proxy/implementation/admin/owner/version pins,
economics, schemas, the complete Safe profile and pause guardian, and the
complete facilitator set.

`script/release.py` is the trusted entry point. It requires a clean checkout,
validates the release ref and recursive submodules, rejects ambient Foundry
configuration, compares the complete effective remapping set with
`script/release-remappings.lock`, and builds with the committed config in an
isolated environment. The pinned compiler runs through
`script/solc_capture.py`; the verifier hashes the exact standard-JSON input
selected for every release target and matches every source byte to its root or
recursive-submodule Git object. Artifact metadata remains an independent
cross-check rather than the compiler-input source. The wrapper patches only
the proven OpenZeppelin UUPS `__self` immutable, compares local and manifest
runtime hashes, and pins the canonical identity implementation and upgrade
authority before governance work. Each run creates a random, temporary v2
provenance marker bound to the manifest, canonical revision evidence,
effective release, and build hashes. The archived marker is evidence and is
never reused as a live input. Evidence is archived under the effective release hash.
The evidence directory must be outside the checkout:

```bash
export RELEASE_MANIFEST=<absolute-reviewed-release-manifest.json>
export RELEASE_EVIDENCE_DIR=<absolute-evidence-directory>
export RPC_URL=<RPC_URL>

# Read-only verification while dark, or add --active after activation:
python3 script/release.py verify \
  --manifest "$RELEASE_MANIFEST" --rpc-url "$RPC_URL" \
  --release-ref origin/develop --evidence-dir "$RELEASE_EVIDENCE_DIR"

# Emit an exact payload for a reviewed multisig without broadcasting:
export GOVERNANCE_SENDER=<current-admin-address>
python3 script/release.py accept --emit-only \
  --manifest "$RELEASE_MANIFEST" --rpc-url "$RPC_URL" \
  --release-ref origin/develop --evidence-dir "$RELEASE_EVIDENCE_DIR"

# A 1-of-1 development Safe may execute by omitting --emit-only and setting:
export DEPLOYER_PRIVATE_KEY=<key>
```

Use mode `activate` for activation and provide `--gateway-url`; activation and
unpause fail unless the gateway's public chain descriptor exactly matches the
reviewed release manifest. Mode `guardian` configures the reviewed
guardian across an already-upgraded stack; include the same calls in an
existing-proxy upgrade batch. Modes `pause` and `unpause` emit or execute the
all-nine external-dependency circuit-breaker batches. An automated guardian
pauses `PaymentRouter` first and then the other proxies; the Safe batch is the
manual fallback. Only the Safe may unpause, after the wrapper verifies either
the unchanged reviewed identity pins or a newly reviewed base manifest.
Deploy `script/monitor_external_identity.py` through the release-operations
environment using
[`EXTERNAL_IDENTITY_INCIDENT_RUNBOOK.md`](EXTERNAL_IDENTITY_INCIDENT_RUNBOOK.md).
Scripted execution remains limited to a 1-of-1 development Safe;
release-candidate and Mainnet signers review the archived
`MultiSendCallOnly` payload in the Safe app. Run the protected independent
release-reproduction workflow before approval. Its two cache-isolated jobs
retain both evidence sets and require exact equality. CI separately compares
all nine normalized upgradeable layouts with
`storage-layout/baseline.json`; CI never regenerates that reviewed baseline.
The protected Circle fork workflow archives pinned-block and token-domain
preflights together with both real-token fork suites. The clean-clone release
ceremony workflow creates a recursive temporary clone and fresh Anvil chain,
regenerates the build profile with no repository output/cache, then drives the
full manifest parser through dark verification, emit-only and execution
branches for every governance mode, a finalized facilitator revision, and
final evidence archival:

```bash
python3 script/run_release_e2e.py \
  --rpc-url http://127.0.0.1:8545 \
  --evidence-dir /tmp/daski-release-e2e
```

`RELEASE_E2E_LOCAL_FIXTURE` is chain-bound to local Anvil chain ID 31337 and
is rejected by the trusted release wrapper.

Facilitator rotations are append-only manifest revisions. Copy
`deployments/release-manifest-revision.example.json` and link it to the base and
previous hashes. Generate provisional Safe payload evidence with:

```bash
python3 script/release.py revision-payload \
  --manifest "$RELEASE_MANIFEST" --revision <revision.json> \
  --rpc-url "$RPC_URL" --release-ref origin/develop \
  --evidence-dir "$RELEASE_EVIDENCE_DIR"
```

After Safe execution, record both `safeTransactionHash` and
`executionTransactionHash`, then pass every ordered revision with repeated
`--revision` arguments during verification. The wrapper verifies the Safe
receipt, `ExecutionSuccess` event, and exact decoded MultiSend payload.
Emergency revisions may only remove facilitators; planned revisions may replace
the set through normal review.

ProviderRegistry and PaymentRouter treasury controls are intentionally
independent. A governance treasury change must review both destinations and
record whether equality or divergence is intended.

x402 V2 EIP-3009 payments use the custom `daski-exact` scheme.
`X402Adapter` derives the signed nonce from chain, adapter, router, token,
payer, amount, authorization window, provider, service, expected payee,
service reference, and a fresh 32-byte client salt. It then executes
`receiveWithAuthorization`, adapter-to-router transfer, and router settlement
atomically with exact balance-delta checks. Payment replay protection remains
the router's `(buyerAgentId, providerAgentId, serviceId, serviceRef)` key; a
service reference is not globally unique. Pre-existing token dust is reported
by verification but does not block activation because settlement is
delta-based and both contracts must return to their pre-call balances.

Provider-facing services should map `SanctionedAddress(account)` to the stable
code `SANCTIONS_ADDRESS_REJECTED` (not retryable) and
`SanctionsOracleUnavailable(oracle)` to `SANCTIONS_SCREENING_UNAVAILABLE`
(retryable with a bounded policy). The contracts enforce the restriction even
when the gateway is bypassed.

Release coordination — develop→main merges, semver tags, the cross-repo
address cascade (gateway/provider env, test-suite config, website `llms.txt`),
DB resets, and post-deploy verification — lives in
[daski-io/deploy-testnet](https://github.com/daski-io/deploy-testnet).

## Security

This protocol has not yet been audited. For non-security bugs, please open a
GitHub issue. For security-relevant findings, please use GitHub's [private
vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
instead of opening a public issue.

## License

[MIT](LICENSE)
