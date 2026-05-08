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
| IdentityRegistry    | `0x498CFfaF1F54C355df050098Dc40f9804F21dBAe` |
| ReputationRegistry  | `0x7172fFaDa6850D6601D32A1034972430CC77397A` |
| ValidationRegistry  | `0x734c8eD562c981eEB2D7544A5046144208A776a7` |
| ProviderRegistry    | `0x80C9718CE4FF51f9B690cEEE137bE5c27874D870` |
| PaymentRouter       | `0x2194984EFfB3596B05ECe7e7FdA09D8B21B4afF5` |
| ReputationStorage   | `0x4107f1F86A74849c705D4758c594D9586ed9dE74` |
| X402Adapter         | `0x24f9a2137376c131cc0054aE51F29401921FB991` |
| PermitAdapter       | `0xF26ded83D6173649410968B7c7af58C4408E7A73` |
| ApprovalAdapter     | `0xf15c07352B9366432B1eAFf86b199F46b83FC420` |
| EAS                 | `0x4200000000000000000000000000000000000021` |
| Schema Registry     | `0x4200000000000000000000000000000000000020` |

EAS schema UIDs (resolver = ReputationStorage):
- Outcome: `0x70b722c935f300a4e499f81ccba050252a4546c9b1368914eadab0c996616702`
- Confirmation: `0x1b1cf50e45b670cfbfc5821e3f4e828d6a068275ef0ea3966763b54d0d3c01a5`

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
