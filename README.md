# Daski Contracts

[Daski](https://sandbox.daski.io) is marketplace infrastructure for the agent
economy — an open coordination layer where AI agents discover services, settle
payment in USDC on Base, and accumulate on-chain reputation, all over open
standards (MCP, x402, A2A, ERC-8004). This repo is the on-chain protocol:
identity, provider registry, rail-agnostic payment routing, and bilateral
reputation backed by EAS attestations. For the full protocol design, read the
[whitepaper](https://sandbox.daski.io/MarketplaceProtocolWhitePaper.pdf).

**Status:** v1 deployed on Base Sepolia. 217 unit + integration tests passing.
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
| **DirectTransferAdapter** | External-facilitator rail (x402 Bazaar): attributes payments that a third-party facilitator (Coinbase CDP) settled as bare EIP-3009 transfers into the router, running the split + payment record as a follow-up tx. Attributor-gated (the Daski gateway). |
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
| IdentityRegistry    | `0xa03bd7e27dB0A942B2C30d6d4bCCD78724FC1E83` |
| ReputationRegistry  | `0x3bB1ead34f04141C3e7791D9588e4F2017a0f38e` |
| ValidationRegistry  | `0x13411C888Ececa7dA2078D8fC386118881Fc6E00` |
| ProviderRegistry    | `0x3D3f1ACA48D5f8AC7cf910d2e075426B7894C2B8` |
| ServiceRegistry     | `0x68e9d4c55309f71E3C4Fe70fba0983a5De7d4303` |
| PaymentRouter       | `0x78f9b15F9b228Acd8D5A85eF4DAfef2164459d8f` |
| ReputationStorage   | `0x6D657941343494605be3B86c7a60422621d2e97f` |
| X402Adapter         | `0x20027cED25D8A9a79B385B6cD57432a6950aD032` |
| PermitAdapter       | `0xE377F3bB81B238E4F9f2B9EB4CAC3052de833FFA` |
| ApprovalAdapter     | `0xC270B04B994aC2B10442613eD1744FE77327427E` |
| EAS                 | `0x4200000000000000000000000000000000000021` |
| Schema Registry     | `0x4200000000000000000000000000000000000020` |

EAS schema UIDs (resolver = ReputationStorage):
- Outcome: `0x6c9458ad1048bb37075c352d48fa6530d2302c33fad8303a572e64528171bbfd`
- Confirmation: `0xd83d8f2044d492d9606841e85786f2b9b32a83b66f444924758e88b966f78597`

Machine-readable copy: [`deployments/base-sepolia.json`](deployments/base-sepolia.json)

DirectTransferAdapter (external-facilitator / Bazaar rail) is **not yet
deployed** — roll it out with [`script/AddDirectAdapter.s.sol`](script/AddDirectAdapter.s.sol)
(see [Deploy](#deploy)) and record the proxy address here and in the JSON.

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
8. Adapters (X402/Permit/Approval/DirectTransfer) — registered with PaymentRouter
```

## Development

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test       # 217 tests across 12 suites
forge test -vvv  # verbose
forge fmt
```

| Suite | Tests |
|---|---|
| PaymentRouter         | 50 |
| IdentityRegistry      | 31 |
| ReputationStorage     | 27 |
| ServiceRegistry       | 24 |
| ProviderRegistry      | 19 |
| ReputationRegistry    | 17 |
| X402Adapter           | 14 |
| ValidationRegistry    | 13 |
| DirectTransferAdapter | 10 |
| PermitAdapter         | 5  |
| ApprovalAdapter       | 4  |
| Integration           | 3  |

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

### Add DirectTransferAdapter to an existing deployment (x402 Bazaar rail)

`Deploy.s.sol` includes the adapter for **fresh** stacks. To add the rail to
an already-running deployment (e.g. the current Base Sepolia sandbox) use the
targeted script — it deploys only the adapter and wires it to the existing
router, without touching anything else:

```bash
export DEPLOYER_PRIVATE_KEY=<key>                # pays gas; becomes adapter admin
export PAYMENT_ROUTER_ADDRESS=<existing router proxy>
export IDENTITY_REGISTRY_ADDRESS=<existing identity proxy>
# Gateway facilitator wallet — allowed to call attribute(). Strongly
# recommended to set here; the rail cannot settle without an attributor.
export ATTRIBUTOR_ADDRESS=<gateway facilitator wallet>
# Optional: hand adapter admin to a multisig (2-step; new admin must acceptAdmin())
# export ADMIN_ADDRESS=<multisig>

forge script script/AddDirectAdapter.s.sol --rpc-url <RPC_URL> --broadcast
```

The script registers the adapter with the router automatically when the
deployer is the router admin (testnet convention); otherwise it prints the
exact `PaymentRouter.setAdapter(<proxy>, true)` call for the real admin.

After the deploy:

1. Record the **proxy** address in the Deployments table above and in
   `deployments/<network>.json`.
2. Point the gateway at it and redeploy (Railway):
   ```bash
   railway variables --service gateway --skip-deploys \
     --set DIRECT_ADAPTER_ADDRESS=<adapter proxy>
   railway redeploy --service gateway
   ```
   Setting `DIRECT_ADAPTER_ADDRESS` is what mounts the gateway's
   `/x402/services/:tokenId/:skillId` routes (see daski-gateway
   `.env.example` — `EXTERNAL_FACILITATOR_URL` defaults per network;
   mainnet CDP settles additionally need
   `EXTERNAL_FACILITATOR_AUTH_HEADER`).
3. Sanity-check: `GET <gateway>/x402/services/<providerAgentId>/<skillId>`
   should return an HTTP 402 with `accepts[]` + `extensions.bazaar`. The
   first successful CDP-facilitated settle for a resource is what makes
   the Bazaar index it.

## Security

This protocol has not yet been audited. For non-security bugs, please open a
GitHub issue. For security-relevant findings, please use GitHub's [private
vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
instead of opening a public issue.

## License

[MIT](LICENSE)
