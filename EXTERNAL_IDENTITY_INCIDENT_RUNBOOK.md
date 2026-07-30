# External Identity Dependency Incident Runbook

## Scope and residual trust

Daski depends on the canonical ERC-8004 identity registry for ownership and
operator authorization. The pause control limits damage after an unexpected
registry change; it does not remove trust in the registry owner or eliminate
the interval between detection and confirmed pause transactions. Mainnet
sign-off must record the registry governance model and explicitly accept that
residual interval and the guardian's denial-of-service authority.

## Production prerequisites

- Run `script/monitor_external_identity.py` from the release-operations
  environment against the reviewed manifest and wrapper-generated
  `summary.json`. The monitor verifies the summary's manifest hash and uses its
  effective release hash for evidence.
- Deploy the committed `ops/external-identity-monitor.service` definition (or
  a byte-for-byte equivalent container worker) with the environment schema in
  `ops/external-identity-monitor.env.example`. The pre-start check must pass
  before the continuously running process is considered healthy.
- Copy `ops/external-identity-monitor-deployment.example.json` into the
  effective-release evidence directory and fill every field from the deployed
  service. Hash the exact deployed service definition plus its redacted
  configuration; never archive RPC credentials or signer secrets.
- Back the guardian with a dedicated HSM/KMS key whose only Daski authority is
  `pauseExternalDependency()`. The adapter command must sign, submit, wait for
  confirmation, and print the transaction hash.
- Fund the guardian on Base, alert on its balance and signer/RPC health, and
  test the path on the release-candidate environment before Mainnet approval.
- Record the measured detection-to-confirmed-pause objective, polling interval,
  RPC provider, escalation contacts, key rotation procedure, and Safe fallback
  location in the private operations system. Placeholders are not acceptable
  at Mainnet sign-off.

The monitor invokes the configured guardian adapter with:

```text
<guardian-command> <guardian-args> \
  --target <proxy> \
  --calldata <pauseExternalDependency selector> \
  --rpc-url <Base RPC> \
  --effective-release-hash <bytes32>
```

After it has attempted the pause sequence, the monitor invokes the configured
alert adapter with:

```text
<alert-command> <alert-args> \
  --evidence-dir <alert-evidence-directory> \
  --effective-release-hash <bytes32> \
  --manifest-hash <bytes32>
```

## Automated response

The monitor compares the proxy and implementation codehashes, ERC-1967
implementation and admin slots, `owner()`, and `getVersion()` with the manifest.
On a mismatch it:

1. pauses `PaymentRouter`;
2. pauses AgentIndex, DaskiValidationRegistry, ProviderRegistry, and
   ServiceRegistry;
3. pauses ReputationStorage and the three adapters;
4. confirms `externalDependencyPaused()` on every proxy; and
5. archives the observation and guardian transaction outputs under the
   effective release hash, then exits nonzero for alerting.

An RPC failure before the core slots and codehashes can be observed exits
nonzero without signing. A metadata call that fails after those observations is
treated as a compatibility mismatch and authorizes the guardian. Operations
must investigate every monitor or provider failure.

## Manual Safe fallback

Use the reviewed `pause` batch emitted by `script/release.py` if the guardian
path is unhealthy. Signers must verify the effective release hash and the nine
targets. The Safe batch is atomic, while the automated guardian deliberately
orders PaymentRouter first to minimize payment exposure.

## Investigation and recovery

1. Keep all proxies paused and preserve the monitor evidence and receipts.
2. Determine whether the observation is an authorized registry change, an
   attack, or a monitor/RPC fault.
3. If the registry is unchanged and the alert was false, rerun the release
   wrapper with the current reviewed manifest.
4. If any pinned identity property changed, create a new base manifest and
   complete security review; facilitator revisions cannot approve this change.
5. Emit the `unpause` batch. Only the Safe may execute it, and the wrapper must
   first reproduce the build and revalidate every identity pin.
6. Archive the unpause evidence and measure the actual detection and response
   times. Update the objective or escalation policy when it was missed.

Guardian rotation is a Safe-controlled all-nine configuration change. Pause the
stack before removing a guardian, fund and health-check the replacement, update
the reviewed governance profile, and verify all nine proxies before unpausing.
