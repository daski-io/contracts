# Daski Standard-Rail Contracts

This repository contains the on-chain contracts used by Daski's standard
Exact-EVM payment rail.

## Active contracts

- `OutcomeSplitter` is an immutable payment destination for one listed outcome
  epoch. It holds the canonical token and permissionlessly releases its entire
  balance to the immutable provider and Daski commission recipients.
- `OutcomeSplitterFactory` deploys splitters deterministically with CREATE2.

There is no custom x402 scheme, settlement router, payment adapter, or mutable
financial route in the active contract set. Buyers sign ordinary EIP-3009
USDC authorizations whose `to` address is the outcome splitter.

The repository retains `RetireStack.s.sol` only as a kill-switch for already
deployed legacy routers. It cannot deploy or activate the retired stack.
`deployments/base-sepolia.json` is historical evidence and is explicitly
marked retired; no runtime should consume it as current configuration.

## Build and test

```bash
forge fmt --check
forge build --sizes
forge test -vvv
forge coverage --ir-minimum --exclude-tests --no-match-coverage 'script/' --report summary
```

## Testnet deployment inputs

Deploy the shared factory with `DeployOutcomeSplitterFactory.s.sol`, then one
splitter per reviewed outcome with `DeployOutcomeSplitter.s.sol`. Validate and
write the public artifact with `WriteOutcomeSplitterManifest.s.sol`.

The scripts require the `STANDARD_RAIL_*` values named in their source. They
are deployment tooling only; running tests or pushing this repository does not
deploy contracts.

## Security

The splitter rejects native currency, non-contract tokens, zero or conflicting
recipients, invalid commission rates, empty listing commitments, wrong-chain
construction, fee-on-transfer behavior, partial release, and reentrancy.

## License

MIT. See [LICENSE](LICENSE).
