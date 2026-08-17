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
forge test -vvv
forge coverage --ir-minimum --exclude-tests --no-match-coverage 'script/' --report summary
```

## Testnet deployment inputs

Deploy and finalize the fresh standard-order reputation resolver with
`DeployReputationStorage.s.sol`. Deploy the shared factory with
`DeployOutcomeSplitterFactory.s.sol`, then one splitter per reviewed outcome
with `DeployOutcomeSplitter.s.sol`. Validate and write the public artifact with
`WriteOutcomeSplitterManifest.s.sol`.

The deployment scripts default `MARKETPLACE_COMMISSION_BPS` to 500. A later
fee change is represented by a new immutable splitter and listing epoch.

The scripts require the `STANDARD_RAIL_*` values named in their source. They
are deployment tooling only; running tests or pushing this repository does not
deploy contracts.

## Security

The splitter rejects native currency, non-contract tokens, zero or conflicting
recipients, invalid commission rates, empty listing commitments, wrong-chain
construction, fee-on-transfer behavior, partial release, and reentrancy.

## License

MIT. See [LICENSE](LICENSE).
