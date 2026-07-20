# Deployment runbook

Fresh deployments use two governance phases. PaymentRouter remains dark until
the final Safe controls every proxy.

## 0. Prepare governance

1. Deploy or select a Safe on the target Base network.
2. Verify its chain, owners, threshold, and address.
3. Set `ADMIN_ADDRESS` to the Safe. `Deploy.s.sol` rejects EOAs and the
   deployer address.
4. Set `PROVIDER_TREASURY_ADDRESS` and `PAYMENT_TREASURY_ADDRESS` separately.
   Record whether equality or divergence is intended.

## 1. Deploy dark

Run `Deploy.s.sol`. It configures EAS and ReputationStorage, leaves the
accepted-token and adapter sets empty, validates core wiring and dark state,
and starts the two-step admin transfer for all nine proxies.

Build a single Safe batch with one `acceptAdmin()` call to each proxy in the
order returned by `DeploymentValidation.adminContracts`. The deterministic
targets and calldata are defined by `GovernanceBatches.adminAcceptance`.

After execution, set `DEPLOYMENT_ACTIVE=false` and run
`VerifyDeployment.s.sol`. Archive the output with the Safe transaction.

The phase-one verifier must prove:

- every proxy admin is the Safe and every pending admin is zero;
- no payment token or adapter is active;
- ReputationStorage and both EAS schemas are finalized correctly;
- every adapter has the expected router and AgentIndex;
- every proxy implementation and codehash matches the deployment record.

## 2. Activate payments

Build one atomic Safe batch from `GovernanceBatches.paymentActivation`. It:

1. accepts Circle USDC for payment;
2. enables its configured reputation minimum;
3. enables X402Adapter;
4. enables PermitAdapter;
5. enables ApprovalAdapter.

After execution, set `DEPLOYMENT_ACTIVE=true` and run
`VerifyDeployment.s.sol` again. Archive the output with the Safe transaction.

## Ongoing governance

- Run `VerifyDeployment` after every `setAdapter` action. Enabling checks the
  router binding on-chain; verification checks the exact AgentIndex binding.
- Adapter removal never depends on adapter getters, so a broken adapter can
  always be disabled.
- Disabling an accepted token also clears its reputation configuration.
- Review both treasury destinations for every treasury change and record
  whether they should match.
- Reputation self-dealing checks use identity ownership, wallets, payees, and
  approvals as they exist at settlement time. Broader Sybil detection remains
  an off-chain responsibility.
