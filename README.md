# Daski Standard-Rail Contracts

This repository contains Daski's marketplace identity, catalog, validation,
standard-order reputation, and standard Exact-EVM payment contracts.

## Standard-rail payment contracts

- `OutcomeSplitter` is an immutable payment destination for one listed outcome
  epoch. It holds the canonical token and permissionlessly releases its entire
  balance to the immutable provider and Daski commission recipients.
- `OutcomeSplitterFactory` deploys splitters deterministically with CREATE2.

There is no custom x402 scheme, settlement router, payment adapter, or mutable
financial route in the active contract set. Buyers sign ordinary EIP-3009
USDC authorizations whose `to` address is the outcome splitter.

## Marketplace contracts

- `AgentIndex` adds verified wallet-to-agent lookup and delegated registration
  around the canonical ERC-8004 Identity Registry.
- `ProviderRegistry` records Daski marketplace providers.
- `ServiceRegistry` records versioned provider catalog entries.
- `ValidationRegistry` records agent-scoped validation requests and
  responses.
- `ReputationStorage` is the fresh EAS-backed standard-order reputation
  ledger. The gateway registers finalized paid orders, the provider records
  terminal outcomes, and payers can submit or revoke delivery confirmation.

These contracts are independent of the standard payment route. Restoring them
does not restore `PaymentRouter`, `X402Adapter`, `PermitAdapter`, or
`ApprovalAdapter`.

Provider and service registration on chain is canonical and permissionless
subject to ownership, listing-fee, sanctions, and active-state checks. Gateway
enrollment is optional metadata/orchestration policy: it cannot make an
otherwise invalid service valid or invalidate a valid chain record. Skills
remain in provider-hosted service cards; these contracts contain no provider,
product, skill, jurisdiction, or gateway-visibility allowlist.

The repository retains `RetireStack.s.sol` only as a kill-switch for already
deployed legacy routers. It cannot deploy or activate the retired payment
stack. `deployments/base-sepolia.json` distinguishes the retained marketplace
contracts from retired payment contracts.

## Build and test

```bash
forge fmt --check
forge build --sizes
python3 script/check_storage_layout.py
forge test -vvv
forge coverage --skip script --exclude-tests --no-match-coverage 'script/' --report summary
```

Before pushing to `develop`, satisfy [docs/release-readiness.md](docs/release-readiness.md): `develop` must always be releasable, and the release coordinator only checks that CI passed on the exact commit.

## Deployment inputs

Deploy and finalize the fresh standard-order reputation resolver with
`DeployReputationStorage.s.sol`. Deploy the shared factory with
`DeployOutcomeSplitterFactory.s.sol`, then one splitter per reviewed outcome
with `DeployOutcomeSplitter.s.sol`. Validate and write the public artifact with
`WriteOutcomeSplitterManifest.s.sol`.

The splitter scripts run on Base and Base Sepolia and refuse every other chain.
They bind each splitter to the executing chain and to the reviewed canonical
Circle USDC address for that chain, and the activation gate refuses any other
token. The commands are the same on both chains; supply the RPC endpoints of
the chain being deployed to.

`WriteOutcomeSplitterManifest.s.sol` is the sole activation gate and must run
against a fork of that chain pinned to the claimed activation block (Base
Sepolia shown):

```bash
export STANDARD_RAIL_PRIMARY_RPC_URL="$BASE_SEPOLIA_RPC_URL"
export STANDARD_RAIL_SECONDARY_RPC_URL="$INDEPENDENT_BASE_SEPOLIA_RPC_URL"

forge script script/WriteOutcomeSplitterManifest.s.sol:WriteOutcomeSplitterManifest \
  --fork-url "$BASE_SEPOLIA_RPC_URL" \
  --fork-block-number "$STANDARD_RAIL_SPLITTER_ACTIVATION_BLOCK_NUMBER" \
  --no-storage-caching
```

The two `STANDARD_RAIL_*_RPC_URL` values must be distinct endpoints operated by
independent providers. The script hashes the activation block's raw RLP header
on the executed fork and on both RPC views, requires every hash to match the
manifest input, and requires both providers' `finalized` heads to cover the
activation block. Each reported finalized-head hash is also checked against
the raw header returned by that provider. Circle USDC readiness, starting
balance, and release sequence are then checked using ordinary calls on the
original activation fork. The mandatory `--no-storage-caching` flag prevents
cached pre-reorg fork state from being labeled with the finalized block hash.

The reputation deployment requires `STANDARD_REPUTATION_FINAL_ADMIN` to be a
canonical SafeL2 v1.4.1 proxy with a threshold of at least two, no modules, a
zero guard, and the canonical compatibility fallback handler. The Safe must
have at least two unique nonzero owners and its threshold cannot exceed the
owner count.
`STANDARD_REPUTATION_PAUSE_GUARDIAN` must be a distinct nonzero address. Review
the Safe address and owners independently as part of the release process. The
script leaves the configured proxy paused with the Safe as pending admin; the
Safe must accept administration before it can unpause the resolver.

Reputation deployment is limited to Base and Base Sepolia. It uses the
canonical EAS and SchemaRegistry addresses for the selected chain and verifies
that both have code and that EAS reports the canonical registry. Implementation
versions are recorded during release review rather than hard-coded in the
deployment script.

Standard-order reputation treats the configured order signer as the settlement
evidence authority. Signed snapshot block numbers and hashes are evidence, not
an on-chain payment or canonical-block proof. Keep the signer in hardened
custody, sign only after the required chain-finality policy, monitor its use,
and pause the resolver immediately if signer integrity is in doubt.

The deployment scripts default `MARKETPLACE_COMMISSION_BPS` to 500. A later
fee change is represented by a new immutable splitter and listing epoch.

Deploy the four marketplace registries with `DeployMarketplaceRegistries.s.sol`,
on Base or Base Sepolia only. It deploys AgentIndex, ValidationRegistry,
ProviderRegistry and ServiceRegistry as ERC-1967 UUPS proxies against
`IDENTITY_REGISTRY_ADDRESS` and `SANCTIONS_ORACLE_ADDRESS`, with the reviewed
canonical Circle USDC of the executing chain as the listing-fee token,
`PROVIDER_REGISTRY_TREASURY` as the fee recipient and
`PROVIDER_REGISTRY_LISTING_FEE` in atomic units. None of the identity registry,
sanctions oracle and token has a setter, so review those addresses
independently before deploying.
`MARKETPLACE_REGISTRIES_FINAL_ADMIN` must satisfy the same Safe rules as the
reputation deployment, and `MARKETPLACE_REGISTRIES_PAUSE_GUARDIAN` must be a
nonzero address distinct from the Safe and the broadcaster. The broadcaster
comes from the standard Foundry wallet options; the script reads no private
key. It is only the bootstrap admin: the script pauses each registry, sets the
guardian and proposes the Safe, so it ends with four paused proxies whose
pending admin is the Safe. The Safe must accept administration before it can
unpause a registry, and after acceptance the broadcaster holds no role.

After the Safe has accepted, `VerifyMarketplaceRegistries.s.sol` checks the
deployment without sending anything. Given the four proxy addresses, the
identity registry, the sanctions oracle and the Safe, it requires code and an
ERC-1967 implementation behind every proxy, the expected registry type at each
address, one shared identity registry and sanctions oracle, the reviewed USDC
as listing-fee token, ServiceRegistry pointing at the given ProviderRegistry,
and the Safe as admin with no pending admin. It returns the implementation
addresses for the release record.

The scripts require the environment values named in their source. They are
deployment tooling only; running tests or pushing this repository does not
deploy contracts.

## Security

The splitter rejects native currency, non-contract tokens, zero or conflicting
recipients, invalid commission rates, empty listing commitments, wrong-chain
construction, fee-on-transfer behavior, partial release, and reentrancy.
The factory applies the same deployability checks before returning a predicted
CREATE2 address.

Release tooling requires Circle's canonical USDC address for the executing chain
to contain token code and report six decimals. It refuses to activate a route
while USDC is paused or the splitter or either recipient is blacklisted.
Circle's pause and blacklist controls can still stop an existing immutable
route; recipients cannot be rotated and the splitter has no rescue path. Direct
native-currency transfers revert, while EVM-forced native currency remains
outside token accounting and cannot be withdrawn.

## License

MIT. See [LICENSE](LICENSE).
