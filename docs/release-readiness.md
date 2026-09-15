# Release readiness

Daski releases are driven by a two-command coordinator that lives outside this
repository. `prep` makes the next release green: it takes the tip of `develop`
as the candidate, runs the release gates, and whatever blocks the release is
fixed in the repository that owns the problem, which for contract issues is
this one, rather than patched around in the coordinator. `go` ships what
`prep` sealed. The coordinator does not rerun this repository's checks; it
only verifies that CI passed on the exact `develop` commit being shipped.
Every release-critical check for the contracts therefore lives in this
repository's CI, and `develop` must be releasable at every commit.

## Definition of done for develop

A change may be pushed to `develop` only when all of the following hold.

- [ ] CI is green on the commit: `forge fmt --check`, `forge build --sizes`,
      `python3 script/check_storage_layout.py`, `forge test`, `forge coverage`,
      Slither, and the ABI export.
- [ ] A contract change states in its PR or commit message whether it is
      history-compatible (an in-place UUPS implementation upgrade behind the
      existing proxies, keeping addresses, storage and recorded history) or
      requires a new environment epoch (new addresses, a database reset and
      re-registration, always together).
- [ ] A change to an ABI that the gateway or provider consumes opens the
      paired consumer change in the same change set. Both consumers keep
      their own ABI fragments; they do not import this repository's build
      output.
- [ ] Deployment scripts under `script/` remain runnable against a fork
      (`forge script ... --fork-url ...` with the `STANDARD_RAIL_*` inputs
      named in their source).
- [ ] Nothing is merged to `main` or tagged by hand.
- [ ] On-chain actions (deploy, upgrade, Safe batches) happen only through the
      coordinator's epoch or upgrade runbooks with explicit owner
      authorization. Running tests or pushing this repository never
      broadcasts a transaction.

## What CI proves

The workflow is `.github/workflows/test.yml`. Both jobs run on every push and
pull request.

| Job / step | Guarantee |
| --- | --- |
| Foundry project / Install Foundry | Every step below runs on the Forge release pinned in the workflow, so a local run on the same pin reproduces CI. |
| Foundry project / Run Forge fmt | `forge fmt --check`: sources match the repository formatting; a diff on `develop` is a code change, never a reformat. |
| Foundry project / Run Forge build | `forge build --sizes`: every contract, script and test compiles with the `solc` version and settings in `foundry.toml`, and every deployable contract stays under the EIP-170 runtime size limit. |
| Foundry project / Export contract ABIs | `forge inspect <Name> abi --json` for each active marketplace and payment contract (`AgentIndex`, `ProviderRegistry`, `ServiceRegistry`, `ValidationRegistry`, `ReputationStorage`, `OutcomeSplitter`, `OutcomeSplitterFactory`), each checked to be a non-empty ABI array and uploaded as the `contract-abi-<commit sha>` artifact with 90-day retention. The ABI a consumer builds against is the ABI of the exact commit. |
| Foundry project / Check upgradeable storage layouts | `python3 script/check_storage_layout.py`: the storage layout of each UUPS-upgradeable contract (`AgentIndex`, `ProviderRegistry`, `ServiceRegistry`, `ValidationRegistry`, `ReputationStorage`) equals the reviewed baseline in `storage-layout/baseline.json`. An implementation cannot move, retype or reorder storage behind the permanent proxies without a reviewed baseline change. |
| Foundry project / Run Forge tests | `forge test -vvv`: the unit, fuzz and invariant suites under `test/` pass, including the deployment-script and upgrade-safety tests. |
| Foundry project / Run Forge coverage | `forge coverage` over `src/` (scripts and tests excluded) succeeds and prints a summary in the job log. Coverage is measured, not thresholded. |
| Slither analysis / Run Slither | Slither at the version pinned in the workflow finds no high-severity issue in `src/` (`lib/`, `test/` and `script/` are filtered). |

CI does not execute the deployment scripts against a live network or a fork,
does not deploy or upgrade anything, and does not compare the exported ABI
against the gateway or provider. Those remain review steps and coordinator
gates.

## Follow-ups

- Fork dry-run of the deployment scripts in CI. `script/` is compiled and the
  deployment logic is covered by tests, but no CI step runs `forge script`
  against a Base Sepolia fork. CI has no RPC secret today, and none should be
  added without an owner decision on the endpoint and how the secret is
  handled; until then the fork run stays a local, pre-release step.
