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

## Testnet deployment inputs

Deploy and finalize the fresh standard-order reputation resolver with
`DeployReputationStorage.s.sol`. Deploy the shared factory with
`DeployOutcomeSplitterFactory.s.sol`, then one splitter per reviewed outcome
with `DeployOutcomeSplitter.s.sol`. Validate and write the public artifact with
`WriteOutcomeSplitterManifest.s.sol`.

`WriteOutcomeSplitterManifest.s.sol` is the sole activation gate and must run
against a Base Sepolia fork pinned to the claimed activation block:

```bash
forge script script/WriteOutcomeSplitterManifest.s.sol:WriteOutcomeSplitterManifest \
  --fork-url "$BASE_SEPOLIA_RPC_URL" \
  --fork-block-number "$STANDARD_RAIL_SPLITTER_ACTIVATION_BLOCK_NUMBER" \
  --no-storage-caching
```

The script requires the fork block number to match the manifest input, verifies
that block's canonical hash and finalized status through RPC, and checks Circle
USDC readiness, starting balance, and release sequence using ordinary calls on
that fork. The mandatory `--no-storage-caching` flag prevents cached pre-reorg
fork state from being labeled with the finalized block hash.

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

The scripts require the `STANDARD_RAIL_*` values named in their source. They
are deployment tooling only; running tests or pushing this repository does not
deploy contracts.

## Security

The splitter rejects native currency, non-contract tokens, zero or conflicting
recipients, invalid commission rates, empty listing commitments, wrong-chain
construction, fee-on-transfer behavior, partial release, and reentrancy.
The factory applies the same deployability checks before returning a predicted
CREATE2 address.

Base Sepolia release tooling requires Circle's canonical USDC address to contain
token code and report six decimals. It refuses to activate a route while USDC is
paused or the splitter or either recipient is blacklisted. Circle's pause and
blacklist controls can still stop an existing immutable route; recipients cannot
be rotated and the splitter has no rescue path. Direct native-currency transfers
revert, while EVM-forced native currency remains outside token accounting and
cannot be withdrawn.

## License

MIT. See [LICENSE](LICENSE).
