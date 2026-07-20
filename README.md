# Daski Contracts

[Daski](https://sandbox.daski.io) is marketplace infrastructure for the agent
economy — an open coordination layer where AI agents discover services, settle
payment in USDC on Base, and accumulate on-chain reputation, all over open
standards (MCP, x402, A2A, ERC-8004). This repo is the on-chain protocol:
provider registry, rail-agnostic payment routing, and bilateral reputation
backed by EAS attestations — built on top of the **canonical ERC-8004
registries**. For the full protocol design, read the
[whitepaper](https://sandbox.daski.io/MarketplaceProtocolWhitePaper.pdf).

**Status:** the Base Sepolia addresses below run the previous pre-production
revision. The current revision requires a fresh deployment; an external audit
is still pending.

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
| **PaymentRouter**      | Rail-agnostic settlement that splits accepted tokens between provider/service wallet and the payment treasury. Per-token policy independently controls payment acceptance and reputation eligibility/minimums. It validates (provider, service) on every settlement, namespaces replay protection, and excludes relationships provable from on-chain identity state at settlement time from reputation. |
| **X402Adapter**        | EIP-3009 `transferWithAuthorization` rail (Circle USDC). |
| **PermitAdapter**      | EIP-2612 permit rail. |
| **ApprovalAdapter**    | Plain `approve` + `transferFrom` rail (fallback). |
| **DaskiValidationRegistry** | Daski-specific, ERC-8004-inspired validation requests with namespaced keys and paginated reads. `validationRequest` returns `computeValidationKey(agentId, requestHash)`; calls and paginated lists use that key, while events carry both it and the raw payload hash. This intentionally avoids the draft registry's global request-hash squatting and unbounded getter behavior rather than claiming drop-in compatibility. |
| **ReputationStorage**  | Bilateral reputation resolver: qualified payments contribute to counters, providers record outcomes, and buyers confirm. Payment/refund mirroring is retryable so a resolver outage cannot block settlement. EAS-backed; counters split per-provider AND per-service. Resolver addresses and schema UIDs are permanently locked by one-time configuration finalization before payment rails can be enabled. |
| **MockUSDC**           | Testnet ERC-20 (6 decimals, public mint). Test deploys only. |

All contracts are UUPS-upgradeable (OpenZeppelin v5) behind a 2-step admin.
Fresh deployments require one deployed governance contract (multisig or
timelock) as the pending admin of every proxy. Payment rails remain disabled
until that governance contract accepts every admin role.

Allowlisted adapters are trusted to authenticate or establish buyer consent
and to deliver the exact settlement amount. Adapter enablement verifies the
adapter's router binding on-chain; deployment verification additionally checks
its exact AgentIndex binding.

## Deployments

### Base Sepolia (chain id `84532`) — deployed 2026-07-12

> The addresses below run the previous storage/API revision. This
> pre-production change intentionally does not include upgrade compatibility;
> deploy a fresh stack before relying on the current payment and reputation
> APIs. The retired DirectTransferAdapter is still enabled as an adapter on
> this deployed router — the gateway's external-facilitator (x402 Bazaar)
> rail still settles through it — and is dropped at the next fresh
> deployment.

Canonical ERC-8004 singletons (external, never Daski-deployed):
IdentityRegistry `0x8004A818BFB912233c491871b3d84c89A494BD9e`,
ReputationRegistry `0x8004B663056A597Dffe9eCcC1965A193B7388713`.

| Contract              | Address                                      |
|-----------------------|----------------------------------------------|
| USDC (Circle)         | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| AgentIndex            | `0xf1Aa86a69aBA5750B15FAba3026B8e5CBe7Db519` |
| ValidationRegistry (legacy API) | `0x7b4F7eab04D6459D15caC6D26685b49C25613591` |
| ProviderRegistry      | `0x9Ae6337534B2e16e93862D4CC8AD76B1778758e4` |
| ServiceRegistry       | `0x0dA4E956f5b0C504d0c57FD43E7BBF69bA9b0E00` |
| PaymentRouter         | `0x358A5fd242938BAD8b162551ACAC987953c93DC3` |
| ReputationStorage     | `0xDc26A0c4Ec361F61D3dE56f729F8d6a6DBFCA75E` |
| X402Adapter           | `0xab6E1a96D0262F484EEdAf3AEEd81f6c41758BD2` |
| PermitAdapter         | `0x486B72084399716F0C058F5238F6e7f0B0D58038` |
| ApprovalAdapter       | `0x71783d4FdEC13569DA6311F1941F3c4E0b0B89F7` |
| DirectTransferAdapter (retired) | `0x41147a69e01d658c0290B0e30D7BFEBFC9c481A6` |
| EAS                   | `0x4200000000000000000000000000000000000021` |
| Schema Registry       | `0x4200000000000000000000000000000000000020` |

EAS schema UIDs (resolver = ReputationStorage):
- Outcome: `0x463fb742a0d186de10c8060e6ab6dbf9a6970e6913439f8ffe826b4bc6f56801`
- Confirmation: `0xbdf480e91d9566952262fa3bf185872119b37f6c743be6df86603e6cf0717ed5`

Machine-readable copy: [`deployments/base-sepolia.json`](deployments/base-sepolia.json)

Retiring this legacy stack is an operator action, not a proxy upgrade. At the
retirement block, re-check that the router holds no USDC, call
`setAcceptedToken(USDC, false)`, disable DirectTransfer/X402/Permit/Approval,
and scan all historical `AdapterSet` and `AcceptedTokenSet` events for any
other enabled entries. Then replace the old router address in every dependent
service. Bare token transfers can arrive at any time, so repeat the balance
check immediately before and after quiescing the router.

The previous (pre-canonical-migration) stack at PaymentRouter
`0x78f9b15F…459d8f` is orphaned, along with Daski's legacy
Identity/Reputation registries — historical record in the deploy-testnet
repo's deployment records.

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
forge test       # 244 tests across 15 suites
forge test -vvv  # verbose
forge fmt
```

| Suite | Tests |
|---|---|
| PaymentRouter         | 78 |
| ReputationStorage     | 35 |
| ReputationConfiguration | 10 |
| ServiceRegistry       | 26 |
| AgentIndex            | 19 |
| ProviderRegistry      | 19 |
| X402Adapter           | 15 |
| DaskiValidationRegistry | 16 |
| PermitAdapter         | 6  |
| ApprovalAdapter       | 5  |
| DeploymentValidation  | 4  |
| DeploymentGuards      | 5  |
| Integration           | 3  |
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
export ADMIN_ADDRESS=<deployed multisig or timelock>
# REQUIRED: the canonical ERC-8004 IdentityRegistry for the target chain.
#   Base Sepolia: 0x8004A818BFB912233c491871b3d84c89A494BD9e
#   Base mainnet: 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
export IDENTITY_REGISTRY_ADDRESS=0x8004A818BFB912233c491871b3d84c89A494BD9e

# REQUIRED: deployed USDC-compatible token for the target chain.
#   Base Sepolia (Circle): 0x036CbD53842c5426634e7929541eC2318f3dCF7e
#   Base mainnet:          0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e

# Optional (defaults shown)
export LISTING_FEE=1000000   # 1 USDC
export COMMISSION_BPS=500    # 5%
export USDC_REPUTATION_MINIMUM=250000 # $0.25 in Circle USDC units

forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast
```

On Base mainnet and Base Sepolia, deployment enforces the pinned canonical
IdentityRegistry, Circle USDC, EAS, and SchemaRegistry addresses. It also
checks ERC-165/ERC-721 support, six-decimal USDC semantics, the EAS
SchemaRegistry binding, both registered schemas, and every cross-contract
wiring relationship. Unsupported chains are rejected unless the operator
explicitly sets `ALLOW_UNSUPPORTED_CHAIN=true`; semantic dependency checks
still apply.

For an isolated non-mainnet environment without a token, deploy the
unrestricted-mint test double separately, then supply its logged address to
the production-shaped deployment:

```bash
forge script script/DeployMockUSDC.s.sol --rpc-url <RPC_URL> --broadcast
export USDC_ADDRESS=<logged MockUSDC address>
export ALLOW_UNSUPPORTED_CHAIN=true
forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast
```

`Deploy.s.sol` never creates a mock token or silently substitutes one for a
missing production dependency.

`Deploy.s.sol` creates a dark deployment: ReputationStorage is configured, but
no token or adapter is enabled. Contract addresses, EAS schema UIDs, and
resolver wiring are logged at the end. Follow [DEPLOYMENT_RUNBOOK.md](DEPLOYMENT_RUNBOOK.md)
to execute the two Safe batches and both verification phases.

After exporting the logged component addresses and schema UIDs, run the
read-only verifier first with `DEPLOYMENT_ACTIVE=false` after all admin roles
have been accepted, then with `DEPLOYMENT_ACTIVE=true` after the activation
batch:

```bash
export IDENTITY_REGISTRY_ADDRESS=<canonical-address>
export USDC_ADDRESS=<circle-usdc-address>
export EAS_ADDRESS=0x4200000000000000000000000000000000000021
export EAS_SCHEMA_REGISTRY_ADDRESS=0x4200000000000000000000000000000000000020
export PROVIDER_TREASURY_ADDRESS=<address>
export PAYMENT_TREASURY_ADDRESS=<address>
export ADMIN_ADDRESS=<governance-contract-address>
export AGENT_INDEX_ADDRESS=<address>
export DASKI_VALIDATION_REGISTRY_ADDRESS=<address>
export PROVIDER_REGISTRY_ADDRESS=<address>
export SERVICE_REGISTRY_ADDRESS=<address>
export PAYMENT_ROUTER_ADDRESS=<address>
export REPUTATION_STORAGE_ADDRESS=<address>
export X402_ADAPTER_ADDRESS=<address>
export PERMIT_ADAPTER_ADDRESS=<address>
export APPROVAL_ADAPTER_ADDRESS=<address>
export OUTCOME_SCHEMA_UID=<bytes32>
export CONFIRMATION_SCHEMA_UID=<bytes32>
export LISTING_FEE=1000000
export COMMISSION_BPS=500
export USDC_REPUTATION_MINIMUM=250000

# Copy the nine implementation code hashes logged by Deploy.s.sol.
export AGENT_INDEX_IMPLEMENTATION_CODEHASH=<bytes32>
export DASKI_VALIDATION_REGISTRY_IMPLEMENTATION_CODEHASH=<bytes32>
export PROVIDER_REGISTRY_IMPLEMENTATION_CODEHASH=<bytes32>
export SERVICE_REGISTRY_IMPLEMENTATION_CODEHASH=<bytes32>
export PAYMENT_ROUTER_IMPLEMENTATION_CODEHASH=<bytes32>
export REPUTATION_STORAGE_IMPLEMENTATION_CODEHASH=<bytes32>
export X402_ADAPTER_IMPLEMENTATION_CODEHASH=<bytes32>
export PERMIT_ADAPTER_IMPLEMENTATION_CODEHASH=<bytes32>
export APPROVAL_ADAPTER_IMPLEMENTATION_CODEHASH=<bytes32>

export DEPLOYMENT_ACTIVE=false
forge script script/VerifyDeployment.s.sol --rpc-url <RPC_URL>

# After the Safe activation batch:
export DEPLOYMENT_ACTIVE=true
forge script script/VerifyDeployment.s.sol --rpc-url <RPC_URL>
```

ProviderRegistry and PaymentRouter treasury controls are intentionally
independent. A governance treasury change must review both destinations and
record whether equality or divergence is intended.

EIP-3009 payments use `X402Adapter`, which executes the token authorization
and router settlement atomically. The authorization nonce commits to
`(serviceRef, providerAgentId, serviceId)` so a relayer cannot redirect it.

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
