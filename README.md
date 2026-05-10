# Daski Contracts

[Daski](https://sandbox.daski.io) is marketplace infrastructure for the agent
economy — an open coordination layer where AI agents discover services, settle
payment in USDC on Base, and accumulate on-chain reputation, all over open
standards (MCP, x402, A2A, ERC-8004). This repo is the on-chain protocol:
identity, provider registry, rail-agnostic payment routing, and bilateral
reputation backed by EAS attestations. For the full protocol design, read the
[whitepaper](https://sandbox.daski.io/MarketplaceProtocolWhitePaper.pdf).

**Status:** v1 deployed on Base Sepolia. 209 unit + integration tests passing.
Audit pending.

## Contracts

| Contract            | Purpose |
|---------------------|---------|
| **IdentityRegistry**   | ERC-8004 identity for every actor — buyers, gateway, providers. One NFT per *operator*; services live in `ServiceRegistry`. Enforces a 1:1 wallet ↔ agent invariant. |
| **ProviderRegistry**   | Provider listings: USDC listing fee, active toggle. Gates ERC-8004 agents into the Daski "provider" role. |
| **ServiceRegistry**    | Per-provider service catalog. A service is a row, not its own NFT — keyed by `keccak256(providerAgentId, skillId, version)`. |
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
| IdentityRegistry    | `0xF6d62Fb7AC723C745E9a9Ea6c11B8562db7D6109` |
| ReputationRegistry  | `0xa0641ffBd9e533756f2b79f46b751b621CEE2483` |
| ValidationRegistry  | `0x796D4ae756fB0B603442a4Ec9be03C428afF086a` |
| ProviderRegistry    | `0x3b941dB8d64cbE91366C90EfFB4141e779a35717` |
| ServiceRegistry     | `0x8e5397978A10527e4b4F7a61d7565956dF66368b` |
| PaymentRouter       | `0xb91880314637985298b9353BF0C139c4cB7DdFA3` |
| ReputationStorage   | `0xC03E48bc244452A5D042969694eA7f3aeD0B3338` |
| X402Adapter         | `0x09d6B61EA9844Ba0d9ecc4E3280670782EDa6f5D` |
| PermitAdapter       | `0xedD3460e4B18dbE1136553e5CDC81a1528f948f5` |
| ApprovalAdapter     | `0x1586Dea86b7abf231dD7E6bFde05C5BAA474b082` |
| EAS                 | `0x4200000000000000000000000000000000000021` |
| Schema Registry     | `0x4200000000000000000000000000000000000020` |

EAS schema UIDs (resolver = ReputationStorage):
- Outcome: `0xa61ee8c25187ab94ca4008e8b8e57af59c2461a849bca1202d5ff951c668868b`
- Confirmation: `0xf89caf3be9ed938aadaf1421bb02b428482efb5c3ab87406ba95837052b0ab03`

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
forge test       # 209 tests across 11 suites
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
| Integration         | 2  |

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
