# Reviewed Safe deployments

The shared deployment validator accepts canonical SafeL2 **1.4.1** and **1.5.0**
on Base (8453) and Base Sepolia (84532). It is used by reputation genesis,
marketplace registry genesis, and marketplace post-handoff verification.
It does not infer trust from `VERSION()` or accept arbitrary later versions.
No application contract ABI, storage layout, or administration behavior changes.
Existing addresses and history remain compatible; no upgrade, new epoch,
re-registration, or environment reset is required by this tooling change.

## Exact identities

Each proxy runtime selects a matching singleton and compatibility fallback
handler. All three runtimes are pinned by Keccak-256 hash. Cross-version
proxy/singleton/handler combinations, including migrated older proxies, are
outside this reviewed set and fail closed. Review migrations separately.

| Version | Proxy runtime hash | SafeL2 singleton | Compatibility fallback handler |
| --- | --- | --- | --- |
| 1.4.1 | `0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c` | `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` |
| 1.5.0 | `0x4e381985ca68b3e5d27b4425fa581c19cf33146d3f887a3cfca96f55528ea46f` | `0xEdd160fEBBD92E350D4D398fb636302fccd67C7e` | `0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4` |

Singleton and handler addresses and hashes come from the canonical entries in
[safe-deployments at 7b1fb6d](https://github.com/safe-global/safe-deployments/tree/7b1fb6d615ab2d2999550ec9166554b180e813e5/src/assets),
which list both Base networks. Test fixtures contain upstream compiled artifacts
from `@safe-global/safe-contracts@1.4.1` and
`@safe-global/safe-smart-account@1.5.0`. Their npm tarball SHA-512 integrity values
are recorded in `test/vectors/safe-*.json`; integrity was checked before extracting
artifacts, and singleton/handler runtime hashes were matched against the pinned
deployment registry. Proxy creation bytecode and runtime come from those same
artifacts. The binary fixtures are LGPL-3.0-only; see `test/vectors/LICENSE.safe`
and the upstream source links below.

## Compatibility review scope

The [1.5.0 changelog](https://github.com/safe-fndn/safe-smart-account/blob/v1.5.0/CHANGELOG.md)
and relevant proxy, module-manager, signature-execution, storage-access, and
fallback-handler interfaces were reviewed for these deployment checks.

- Proxy runtime changed; accepting only the old proxy hash rejects new Safes.
- Safe 1.5.0 adds a separate module guard. Both transaction and module guard slots
  must be zero. The unused module-guard slot must also be zero on 1.4.1.
- Modules remain disallowed; the complete empty-list sentinel is checked.
- The version-matched compatibility handler is required. The new extensible
  fallback handler is outside the reviewed configuration.
- Owner count, unique nonzero owners, and threshold checks remain unchanged.
- Safe 1.5.0 changes contract-signature handling and transaction-hash encoding.
  Integration tests use real upstream bytecode, two EOA signatures, and actual
  `execTransaction` calls to accept administration and unpause all five governed
  contracts. These tests do not establish support for arbitrary contract-owner
  wallets or their independent signing policies.

This is an integration review, not a new audit of the entire upstream Safe code.
Upstream tagged sources: [1.4.1](https://github.com/safe-fndn/safe-smart-account/tree/v1.4.1)
and [1.5.0](https://github.com/safe-fndn/safe-smart-account/tree/v1.5.0).
Future versions require explicit review of identities, storage controls, and
execution compatibility before adding another allowlist entry.

## Verification

`forge test` includes deterministic tests with real upstream Safe bytecode for
both versions on both supported chains, production deployment and post-handoff
scripts, signed admin acceptance, bootstrap privilege removal, and refusal of
unknown/mixed runtimes, altered implementations/handlers, weak thresholds,
enabled modules, and configured guards. Existing stub tests exercise malformed
owner lists and other invalid governance inputs.

An existing Safe on Base Mainnet or Base Sepolia can additionally be checked
without broadcasting:

```bash
# Supply these in the process environment without printing endpoints or secrets:
# SAFE_VALIDATION_RPC_URL: archive RPC for the Safe's Base network (8453 or 84532)
# SAFE_VALIDATION_BLOCK: reviewed finalized block number
# SAFE_VALIDATION_ADDRESS: public Safe address
forge test --match-contract SafeForkCompatibilityTest -vv
```

The fork check skips when the RPC variable is absent and fails if enabled with
missing inputs. It runs the unchanged Safe checks through both deployment
preflight paths against forked chain state. Other dependencies are local test
fixtures; this is not proof of whole-stack production readiness. CI runs the
deterministic coverage without requiring network access or RPC credentials.
