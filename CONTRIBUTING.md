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
`main` is the release branch (deploys across the Daski stack key off it), so
`develop` → `main` merges are deliberate, explicitly authorized release steps
only.
