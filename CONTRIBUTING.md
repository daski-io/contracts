# Contributing

Daski is in invite-only testnet, so we're not yet open to broad contributions.
This file will be expanded with PR guidelines, style, and testing requirements
once contributions open up.

In the meantime:

- **Bugs / questions:** open a [GitHub issue](https://github.com/daski-io/contracts/issues).
- **Security findings:** use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
  rather than opening a public issue.

If you want to run the contracts locally, see the [README](README.md). All
tests should pass on a clean clone (`forge test`); please include a regression
test with any reproducer.

## Branching

`develop` is the integration branch — all work and PRs target `develop`.
`sandbox` is the testnet release branch: only the release coordinator writes
it, through the `develop` → `sandbox` release pull request. `main` marks
production and moves only by fast-forward to a release commit of `sandbox`,
performed by the production coordinator. Nobody merges into `sandbox` or
`main` by hand, and moving a branch never deploys a contract: on-chain actions
stay separate governance steps.

Every push to `develop` must satisfy the [release readiness](docs/release-readiness.md) definition of done, because the release coordinator only checks that CI passed on the exact `develop` commit it ships.
