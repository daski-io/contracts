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
revision. The current revision requires a fresh deployment. 198 unit and
integration tests pass; an external audit is still pending.

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
ValidationRegistry remains Daski-hosted because that section of the spec is
still in flux and has no canonical deployment yet. Daski's EAS layer
(`ReputationStorage`) is the payment-verified internal ledger that drives
ranking — it is Daski-native, not ERC-8004 reputation.

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
| **ServiceRegistry**    | Per-provider product catalog. A service is a row, not its own NFT — keyed by `keccak256(providerAgentId, serviceSlug, version)`. The `serviceSlug` is a human-readable product identifier (`"domain-registration"`); skills are declared off-chain. |
| **PaymentRouter**      | Rail-agnostic settlement that splits USDC between provider/service wallet and DAO treasury. Pluggable adapters per rail. Validates (provider, service) on every settle. |
| **X402Adapter**        | EIP-3009 `transferWithAuthorization` rail (Circle USDC). |
| **PermitAdapter**      | EIP-2612 permit rail. |
| **ApprovalAdapter**    | Plain `approve` + `transferFrom` rail (fallback). |
| **ValidationRegistry** | ERC-8004 request/response attestations and summary queries (Daski-hosted until a canonical validation registry exists). Documented deviation from the draft spec: records are keyed by `computeValidationKey(agentId, requestHash)` — also returned by `validationRequest` — NOT by the raw `requestHash`; external clients must use that key for `validationResponse`/reads. The namespacing closes a cross-agent request-hash squatting vector the draft spec doesn't address. |
| **ReputationStorage**  | Bilateral reputation resolver: every payment is counted atomically, provider records outcome, buyer confirms. EAS-backed; counters split per-provider AND per-service. |
| **MockUSDC**           | Testnet ERC-20 (6 decimals, public mint). Test deploys only. |

All contracts are UUPS-upgradeable (OpenZeppelin v5) behind a 2-step admin.
Fresh deployments require one deployed governance contract (multisig or
timelock) as the pending admin of every proxy.

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
| ValidationRegistry    | `0x7b4F7eab04D6459D15caC6D26685b49C25613591` |
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
2. ValidationRegistry      (canonical IdentityRegistry)
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
forge test       # 198 tests across 10 suites
forge test -vvv  # verbose
forge fmt
```

| Suite | Tests |
|---|---|
| PaymentRouter         | 61 |
| ReputationStorage     | 33 |
| ServiceRegistry       | 24 |
| AgentIndex            | 19 |
| ProviderRegistry      | 18 |
| X402Adapter           | 14 |
| ValidationRegistry    | 17 |
| PermitAdapter         | 5  |
| ApprovalAdapter       | 4  |
| Integration           | 3  |

Tests run against `test/mocks/MockCanonicalIdentityRegistry.sol`, a faithful
double of the canonical registry surface (ERC-721 + registration +
agentWallet, IDs beginning at 0, registration-time wallet initialization, and
**no** reverse index).

## Deploy

```bash
export DEPLOYER_PRIVATE_KEY=<key>
export TREASURY_ADDRESS=<address>
export ADMIN_ADDRESS=<deployed multisig or timelock>
# REQUIRED: the canonical ERC-8004 IdentityRegistry for the target chain.
#   Base Sepolia: 0x8004A818BFB912233c491871b3d84c89A494BD9e
#   Base mainnet: 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
export IDENTITY_REGISTRY_ADDRESS=0x8004A818BFB912233c491871b3d84c89A494BD9e

# USDC token. Defaults shown:
#   Base Sepolia (Circle): 0x036CbD53842c5426634e7929541eC2318f3dCF7e
#   Base mainnet:          0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
# Omit to deploy MockUSDC instead (test deploys only).
export USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e

# Optional (defaults shown)
export LISTING_FEE=1000000   # 1 USDC
export COMMISSION_BPS=500    # 5%

forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast
```

Contract addresses, EAS schema UIDs, and resolver wiring are logged at the end
of `forge script` output. The governance contract must then call
`acceptAdmin()` on every logged proxy before the deployment is operational.

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
