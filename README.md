# Daski Contracts

[Daski](https://sandbox.daski.io) is marketplace infrastructure for the agent
economy — an open coordination layer where AI agents discover services, settle
payment in USDC on Base, and accumulate on-chain reputation, all over open
standards (MCP, x402, A2A, ERC-8004). This repo is the on-chain protocol:
identity, provider registry, rail-agnostic payment routing, and bilateral
reputation backed by EAS attestations. For the full protocol design, read the
[whitepaper](https://sandbox.daski.io/MarketplaceProtocolWhitePaper.pdf).

**Status:** v1 deployed on Base Sepolia. 148 unit + integration tests passing.
Audit pending.

## Contracts

| Contract            | Purpose |
|---------------------|---------|
| **IdentityRegistry**   | ERC-8004 identity for every actor — buyers, gateway, providers. Enforces a 1:1 wallet ↔ agent invariant. |
| **ProviderRegistry**   | Provider listings: USDC listing fee, agent-card URI, active toggle. |
| **PaymentRouter**      | Rail-agnostic settlement that splits USDC between provider wallet and DAO treasury. Pluggable adapters per rail. |
| **X402Adapter**        | EIP-3009 `transferWithAuthorization` rail (Circle USDC). |
| **PermitAdapter**      | EIP-2612 permit rail. |
| **ApprovalAdapter**    | Plain `approve` + `transferFrom` rail (fallback). |
| **ReputationRegistry** | ERC-8004 public feedback events. |
| **ValidationRegistry** | ERC-8004 request/response attestations. |
| **ReputationStorage**  | Bilateral reputation resolver: provider records outcome, buyer confirms. Backed by EAS, authenticated against on-chain payment records. |
| **MockUSDC**           | Testnet ERC-20 (6 decimals, public mint). Test deploys only. |

All contracts are UUPS-upgradeable (OpenZeppelin v5) behind a 2-step admin.

## Deployments

### Base Sepolia (chain id `84532`)

| Contract            | Address                                      |
|---------------------|----------------------------------------------|
| USDC (Circle)       | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| IdentityRegistry    | `0x14987Ec55C04c6e1e80002267C778E76292879e7` |
| ReputationRegistry  | `0xc51336a50680F1Ff562223Ad5c7E2f10382C9784` |
| ValidationRegistry  | `0xd04BBfbc44Da7a966BA49f150E8c8e90AB1EEC59` |
| ProviderRegistry    | `0x6a0090085E648ac2bFaf373C77C9F95e57775774` |
| PaymentRouter       | `0xB77A7D6F920eB0B530f9Ed3F40d58E73446BF77A` |
| ReputationStorage   | `0x731888Dcd7B3980836709759246d54Acd249974C` |
| X402Adapter         | `0x4BBfeBf3e29cEF8a9eE4555963ee0cbe1ceb3BE1` |
| PermitAdapter       | `0xF737f19C25FEF579589B15BE579bc4D993CAB11f` |
| ApprovalAdapter     | `0x5aA84D37a470250674F8338AD0CaA511fA8874F5` |
| EAS                 | `0x4200000000000000000000000000000000000021` |
| Schema Registry     | `0x4200000000000000000000000000000000000020` |

EAS schema UIDs (resolver = ReputationStorage):
- Outcome: `0x4e4d06cece5d5774dd420fb21f2a47792f872cd7fbdaf2eb4aed5fe68a0c987d`
- Confirmation: `0x09eea74aa8fbeef8bf0b3dc68ad24447e8a0cbabba92f2b3b74cc700096cd0a8`

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
5. PaymentRouter           (IdentityRegistry, ProviderRegistry, USDC, treasury)
6. ReputationStorage       (IdentityRegistry, PaymentRouter, EAS, schema UIDs)
7. Adapters (X402/Permit/Approval) — registered with PaymentRouter
```

## Development

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test       # 148 tests across 10 suites
forge test -vvv  # verbose
forge fmt
```

| Suite | Tests |
|---|---|
| IdentityRegistry    | 31 |
| PaymentRouter       | 32 |
| ReputationStorage   | 25 |
| ProviderRegistry    | 17 |
| ReputationRegistry  | 13 |
| X402Adapter         | 10 |
| ValidationRegistry  | 10 |
| PermitAdapter       | 5  |
| ApprovalAdapter     | 4  |
| Integration         | 1  |

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
