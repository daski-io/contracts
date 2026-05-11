# Daski Contracts

[Daski](https://sandbox.daski.io) is marketplace infrastructure for the agent
economy — an open coordination layer where AI agents discover services, settle
payment in USDC on Base, and accumulate on-chain reputation, all over open
standards (MCP, x402, A2A, ERC-8004). This repo is the on-chain protocol:
identity, provider registry, rail-agnostic payment routing, and bilateral
reputation backed by EAS attestations. For the full protocol design, read the
[whitepaper](https://sandbox.daski.io/MarketplaceProtocolWhitePaper.pdf).

**Status:** v1 deployed on Base Sepolia. 210 unit + integration tests passing.
Audit pending.

## Three-layer identity model

| Layer       | Where it lives                          | Identifier        | Example                |
|-------------|-----------------------------------------|-------------------|------------------------|
| Provider    | On-chain (`IdentityRegistry`, ERC-8004) | `agentId`         | Blue T Group LLC       |
| **Service** | On-chain (`ServiceRegistry`)            | `serviceId`       | "Domain Registration"  |
| Skill       | Off-chain (provider's A2A Agent Card)   | `AgentSkill.id`   | `register-domain`      |

A *service* is a marketable product — the unit of buyer discovery and reputation. A *skill* is a callable A2A method. **One service maps to one or more skills**; the mapping lives in the off-chain `serviceURI` JSON, not on-chain.

## Contracts

| Contract            | Purpose |
|---------------------|---------|
| **IdentityRegistry**   | ERC-8004 identity for every actor — buyers, gateway, providers. One NFT per *operator*; services live in `ServiceRegistry`. Enforces a 1:1 wallet ↔ agent invariant. |
| **ProviderRegistry**   | Provider listings: USDC listing fee, active toggle. Gates ERC-8004 agents into the Daski "provider" role. |
| **ServiceRegistry**    | Per-provider product catalog. A service is a row, not its own NFT — keyed by `keccak256(providerAgentId, serviceSlug, version)`. The `serviceSlug` is a human-readable product identifier (`"domain-registration"`); skills are declared off-chain. |
| **PaymentRouter**      | Rail-agnostic settlement that splits USDC between provider/service wallet and DAO treasury. Pluggable adapters per rail. Validates (provider, service) on every settle. |
| **X402Adapter**        | EIP-3009 `transferWithAuthorization` rail (Circle USDC). |
| **PermitAdapter**      | EIP-2612 permit rail. |
| **ApprovalAdapter**    | Plain `approve` + `transferFrom` rail (fallback). |
| **ReputationRegistry** | ERC-8004 public feedback events. |
| **ValidationRegistry** | ERC-8004 request/response attestations. |
| **ReputationStorage**  | Bilateral reputation resolver: provider records outcome, buyer confirms. EAS-backed; counters split per-provider AND per-service. |
| **MockUSDC**           | Testnet ERC-20 (6 decimals, public mint). Test deploys only. |

All contracts are UUPS-upgradeable (OpenZeppelin v5) behind a 2-step admin.

## Deployments

### Base Sepolia (chain id `84532`)

| Contract            | Address                                      |
|---------------------|----------------------------------------------|
| USDC (Circle)       | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| IdentityRegistry    | `0xeaaC421470c954207Eb83cA8466aFD76073AeC6a` |
| ReputationRegistry  | `0xA7818955C3481d4cf28dB7B2911Dee3D89668461` |
| ValidationRegistry  | `0x0FA6E239F1bDc7798338e853aBa515a294F14c3B` |
| ProviderRegistry    | `0xb97EEf193ab724f7Fb83C03A7536E87C746e6365` |
| ServiceRegistry     | `0xFB261Af34428a8ad00A6aa3B686527EFc9F64409` |
| PaymentRouter       | `0xd63a2E11D4E9f9a05A6d183cBa7A58E18e802Bfe` |
| ReputationStorage   | `0x20fC391ed7994c2a3e5A054A6671e9dA6Ba07612` |
| X402Adapter         | `0x5d351E9e65484053CABa86d4c957F6cb71f95a6F` |
| PermitAdapter       | `0xAC74Ce3B0E18037A34a13b3c5b6Dd58099a80a84` |
| ApprovalAdapter     | `0xee7dC5C5D22C9ce5D12ce5342cEFe7d208A158f8` |
| EAS                 | `0x4200000000000000000000000000000000000021` |
| Schema Registry     | `0x4200000000000000000000000000000000000020` |

EAS schema UIDs (resolver = ReputationStorage):
- Outcome: `0xc9ab6f5d6d2b09b1ab2fe3eeed94f74d7ff60f0313c9c2ad301764c118ac7c06`
- Confirmation: `0x39d07ff65235d34f01f3bdb90a0b5eb6a5ffbc9380e676043292a6151227b227`

Machine-readable copy: [`deployments/base-sepolia.json`](deployments/base-sepolia.json)

### Base mainnet
Not yet deployed. Pending audit.

## Architecture

UUPS proxy pattern; deploy order matters due to cross-contract dependencies:

```
1. IdentityRegistry        (no deps)
2. ReputationRegistry      (IdentityRegistry)
3. ValidationRegistry      (IdentityRegistry)
4. ProviderRegistry        (IdentityRegistry, USDC, treasury)
5. ServiceRegistry         (IdentityRegistry, ProviderRegistry)
6. PaymentRouter           (IdentityRegistry, ProviderRegistry, ServiceRegistry, USDC, treasury)
7. ReputationStorage       (IdentityRegistry, PaymentRouter, EAS, schema UIDs)
8. Adapters (X402/Permit/Approval) — registered with PaymentRouter
```

## Development

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test       # 210 tests across 11 suites
forge test -vvv  # verbose
forge fmt
```

| Suite | Tests |
|---|---|
| PaymentRouter       | 50 |
| IdentityRegistry    | 31 |
| ReputationStorage   | 26 |
| ServiceRegistry     | 24 |
| ProviderRegistry    | 24 |
| ReputationRegistry  | 17 |
| X402Adapter         | 14 |
| ValidationRegistry  | 12 |
| PermitAdapter       | 5  |
| ApprovalAdapter     | 4  |
| Integration         | 3  |

## Deploy

```bash
export DEPLOYER_PRIVATE_KEY=<key>
export TREASURY_ADDRESS=<address>

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
of `forge script` output for easy copy-paste into client configs.

## Security

This protocol has not yet been audited. For non-security bugs, please open a
GitHub issue. For security-relevant findings, please use GitHub's [private
vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
instead of opening a public issue.

## License

[MIT](LICENSE)
