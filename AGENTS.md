---
title: contracts agent instructions
status: canonical
authority: repository implementation and current release-engine decisions
owner: repository maintainers
effective-date: 2026-10-16
last-verified: 2026-10-16
supersedes: earlier local-path or split-coordinator guidance where inconsistent
superseded-by: none
sensitivity: public-safe
related-repositories: daski-io/contracts; see interface owners below
review-trigger: architecture, toolchain, interface or release-process change
---

# Contracts contributor guide

Owns Solidity/Foundry contracts, deployment-script source, ABI exports and contract
tests. Read README, `docs/release-readiness.md`, `foundry.toml`, storage-layout baselines
and `.github/workflows/test.yml`. Current payment contracts are immutable
`OutcomeSplitter` and `OutcomeSplitterFactory`; retired PaymentRouter/adapters must
not return. Understand upgradeable registries from current code, not old stack diagrams.

## Compatibility and governance

- Preserve proxy storage, deployed addresses and recorded history. State whether a
  change is history-compatible and provide reviewed storage/upgrade evidence. Mainnet
  is never reset; a fresh test environment is not a production upgrade strategy.
- Pair every consumed ABI change with gateway/provider and any other actual consumers.
  Consumers own their ABI fragments; verify them against the exact exported artifact.
- Contract upgrades ride on the authorized release through deploy-mainnet. The engine
  proposes the reviewed governance Safe batch; the authorized Safe owner signs and
  executes it. Never broadcast from a local development session or infer signing
  authority from permission to implement, test, push or prepare documentation.
- Do not invent fallback deployments, replacement identities or compatibility paths to
  bypass an upgrade failure. Resolve the owning compatibility or governance requirement.

## Local checks

Use the Foundry/solc pins in CI and `foundry.toml`. Required gates are
`forge fmt --check`, `forge build --sizes`, `python3 script/check_storage_layout.py`,
`forge test`, coverage, pinned Slither and ABI export. The readiness guide defines the
full evidence. Use disposable local/fork state for explicitly scoped checks; a test
or push never authorizes a live transaction. Do not copy private audits, incident
material, keys or deployment state into this public repository.

## Shared work and release boundary

These instructions apply to every agent and contributor. `AGENTS.md` is canonical;
`CLAUDE.md` only imports it. Read this guide, README, relevant nested instructions,
Git status, package/toolchain files and CI before editing. If working from a shared
Daski workspace, explicitly read its root guide, repository map and development
workflow too; a standalone clone must remain usable without private workspace paths.

Use one task branch/worktree and one writer per checkout. Preserve other work.
Identify affected sibling repositories, interface consumers and tests before changing
a shared contract. Keep durable implementation knowledge in tracked docs and private
operational material in its owning private system, not in assistant memory.

Work targets `develop` or a reviewed branch into it. Integration is distinct from
release. The release engine in [daski-io/deploy-mainnet](https://github.com/daski-io/deploy-mainnet)
owns **both sandbox and production**. Read its current `AGENTS.md`,
`docs/release-map.md`, `docs/runbooks/release-engine.md` and handoff schema before an
operation. Never substitute a direct `main`/`sandbox` push or merge, Railway deploy,
package publication or contract broadcast for that process. Even engine `prep` can
sign a catalog epoch or propose a Safe batch; it is not an unsigned local check.
A build request does not authorize release, paid tests, signing or business actions.
Use existing owner authorization within its scope and honor the engine's actual stops.

Keep secrets, customer data, private audits and raw operational logs out of commits.
Never add AI attribution or co-author trailers to commits or pull requests.
