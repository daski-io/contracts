// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {DeploymentValidationHarness} from "./helpers/DeploymentValidationHarness.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {DaskiValidationRegistry} from "../src/DaskiValidationRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {X402Adapter} from "../src/adapters/X402Adapter.sol";
import {PermitAdapter} from "../src/adapters/PermitAdapter.sol";
import {ApprovalAdapter} from "../src/adapters/ApprovalAdapter.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";
import {DeploymentValidation} from "../script/DeploymentValidation.sol";
import {GovernanceBatches, IPaymentRouterGovernance} from "../script/GovernanceBatches.sol";

contract GovernanceAdminStub {
    function accept(address target) external {
        Admin2StepUpgradeable(target).acceptAdmin();
    }
}

contract DeploymentValidationTest is Test {
    uint256 constant REPUTATION_MINIMUM = 250_000;

    MockCanonicalIdentityRegistry identity;
    MockUSDC usdc;
    MockEAS eas;
    MockSanctionsList sanctions;
    AgentIndex agentIndex;
    DaskiValidationRegistry validation;
    ProviderRegistry providers;
    ServiceRegistry services;
    PaymentRouter router;
    ReputationStorage reputation;
    X402Adapter x402;
    PermitAdapter permit;
    ApprovalAdapter approval;
    DeploymentValidation.Stack stack;
    DeploymentValidationHarness validationHarness;

    address providerTreasury = makeAddr("providerTreasury");
    address paymentTreasury = makeAddr("paymentTreasury");

    function setUp() public {
        identity = new MockCanonicalIdentityRegistry();
        usdc = new MockUSDC();
        eas = new MockEAS();
        sanctions = new MockSanctionsList();
        validationHarness = new DeploymentValidationHarness();

        agentIndex = AgentIndex(
            address(
                new ERC1967Proxy(
                    address(new AgentIndex()),
                    abi.encodeCall(AgentIndex.initialize, (address(identity), address(sanctions), address(this)))
                )
            )
        );
        validation = DaskiValidationRegistry(
            address(
                new ERC1967Proxy(
                    address(new DaskiValidationRegistry()),
                    abi.encodeCall(
                        DaskiValidationRegistry.initialize, (address(identity), address(sanctions), address(this))
                    )
                )
            )
        );
        providers = ProviderRegistry(
            address(
                new ERC1967Proxy(
                    address(new ProviderRegistry()),
                    abi.encodeCall(
                        ProviderRegistry.initialize,
                        (
                            address(identity),
                            address(usdc),
                            providerTreasury,
                            1_000_000,
                            address(sanctions),
                            address(this)
                        )
                    )
                )
            )
        );
        services = ServiceRegistry(
            address(
                new ERC1967Proxy(
                    address(new ServiceRegistry()),
                    abi.encodeCall(
                        ServiceRegistry.initialize,
                        (address(identity), address(providers), address(sanctions), address(this))
                    )
                )
            )
        );
        router = PaymentRouter(
            address(
                new ERC1967Proxy(
                    address(new PaymentRouter()),
                    abi.encodeCall(
                        PaymentRouter.initialize,
                        (
                            address(identity),
                            address(providers),
                            address(services),
                            paymentTreasury,
                            500,
                            address(sanctions),
                            address(this)
                        )
                    )
                )
            )
        );
        reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(new ReputationStorage()),
                    abi.encodeCall(ReputationStorage.initialize, (address(router), address(sanctions), address(this)))
                )
            )
        );
        x402 = X402Adapter(
            address(
                new ERC1967Proxy(
                    address(new X402Adapter()),
                    abi.encodeCall(
                        X402Adapter.initialize,
                        (address(router), address(agentIndex), address(sanctions), address(this))
                    )
                )
            )
        );
        permit = PermitAdapter(
            address(
                new ERC1967Proxy(
                    address(new PermitAdapter()),
                    abi.encodeCall(
                        PermitAdapter.initialize,
                        (address(router), address(agentIndex), address(sanctions), address(this))
                    )
                )
            )
        );
        approval = ApprovalAdapter(
            address(
                new ERC1967Proxy(
                    address(new ApprovalAdapter()),
                    abi.encodeCall(
                        ApprovalAdapter.initialize,
                        (address(router), address(agentIndex), address(sanctions), address(this))
                    )
                )
            )
        );

        bytes32 outcome = eas.register("uint256 paymentId,uint8 outcome", address(reputation), false);
        bytes32 confirmation = eas.register("uint256 paymentId,uint8 confirmation", address(reputation), true);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(outcome);
        reputation.setConfirmationSchema(confirmation);
        reputation.finalizeConfiguration();
        router.setReputationStorage(address(reputation));

        stack = DeploymentValidation.Stack({
            identity: address(identity),
            usdc: address(usdc),
            providerTreasury: providerTreasury,
            paymentTreasury: paymentTreasury,
            sanctionsOracle: address(sanctions),
            agentIndex: address(agentIndex),
            daskiValidationRegistry: address(validation),
            providerRegistry: address(providers),
            serviceRegistry: address(services),
            router: address(router),
            reputation: address(reputation),
            x402Adapter: address(x402),
            permitAdapter: address(permit),
            approvalAdapter: address(approval),
            listingFee: 1_000_000,
            commissionBps: 500,
            reputationMinimum: REPUTATION_MINIMUM
        });
    }

    function _activate() internal {
        router.setAcceptedToken(address(usdc), true);
        router.setTokenReputationConfig(address(usdc), true, REPUTATION_MINIMUM);
        router.setAdapter(address(x402), true);
        router.setAdapter(address(permit), true);
        router.setAdapter(address(approval), true);
    }

    function test_darkAndOperationalPhasesAreMutuallyExclusive() public {
        validationHarness.validateCoreWiring(stack);
        validationHarness.validateDarkState(stack);
        vm.expectRevert("unexpected accepted token count");
        validationHarness.validateOperationalState(stack);

        _activate();
        validationHarness.validateOperationalState(stack);
        vm.expectRevert("payment token already active");
        validationHarness.validateDarkState(stack);
    }

    function test_exactAgentIndexBindingIsCheckedWhileDark() public {
        AgentIndex otherIndex = AgentIndex(
            address(
                new ERC1967Proxy(
                    address(new AgentIndex()),
                    abi.encodeCall(AgentIndex.initialize, (address(identity), address(sanctions), address(this)))
                )
            )
        );
        X402Adapter wrong = X402Adapter(
            address(
                new ERC1967Proxy(
                    address(new X402Adapter()),
                    abi.encodeCall(
                        X402Adapter.initialize,
                        (address(router), address(otherIndex), address(sanctions), address(this))
                    )
                )
            )
        );
        stack.x402Adapter = address(wrong);

        vm.expectRevert("adapter AgentIndex mismatch");
        validationHarness.validateDarkState(stack);
    }

    function test_coreWiringRejectsSanctionsOracleMismatch() public {
        stack.sanctionsOracle = address(new MockSanctionsList());
        vm.expectRevert("sanctions oracle mismatch");
        validationHarness.validateCoreWiring(stack);
    }

    function test_incompleteAdminHandoffLeavesOneContractWithTheDeployer() public {
        GovernanceAdminStub governance = new GovernanceAdminStub();
        address[9] memory contracts_ = DeploymentValidation.adminContracts(stack);
        for (uint256 i = 0; i < contracts_.length; i++) {
            Admin2StepUpgradeable(contracts_[i]).transferAdmin(address(governance));
            if (i + 1 < contracts_.length) governance.accept(contracts_[i]);
        }

        for (uint256 i = 0; i + 1 < contracts_.length; i++) {
            assertEq(Admin2StepUpgradeable(contracts_[i]).admin(), address(governance));
        }
        assertEq(Admin2StepUpgradeable(contracts_[8]).admin(), address(this));
        assertEq(Admin2StepUpgradeable(contracts_[8]).pendingAdmin(), address(governance));
    }

    function test_completeFacilitatorSetIsRequired() public {
        address first = makeAddr("facilitator-1");
        address second = makeAddr("facilitator-2");
        x402.setFacilitatorAuthorization(first, true);
        x402.setFacilitatorAuthorization(second, true);

        address[] memory expected = new address[](2);
        expected[0] = first;
        expected[1] = second;
        validationHarness.validateFacilitators(address(x402), expected);

        address[] memory incomplete = new address[](1);
        incomplete[0] = first;
        vm.expectRevert("wrong facilitator count");
        validationHarness.validateFacilitators(address(x402), incomplete);

        expected[1] = makeAddr("unexpected");
        vm.expectRevert("expected facilitator missing");
        validationHarness.validateFacilitators(address(x402), expected);
    }

    function test_governanceBatchShapes() public view {
        (address[] memory acceptTargets, bytes[] memory acceptCalls) = GovernanceBatches.adminAcceptance(stack);
        assertEq(acceptTargets.length, 9);
        assertEq(acceptCalls.length, 9);
        assertEq(bytes4(acceptCalls[0]), Admin2StepUpgradeable.acceptAdmin.selector);

        (address[] memory activateTargets, bytes[] memory activateCalls) = GovernanceBatches.paymentActivation(stack);
        assertEq(activateTargets.length, 5);
        assertEq(activateCalls.length, 5);
        assertEq(bytes4(activateCalls[0]), IPaymentRouterGovernance.setAcceptedToken.selector);
        assertEq(bytes4(activateCalls[1]), IPaymentRouterGovernance.setTokenReputationConfig.selector);
        assertEq(bytes4(activateCalls[2]), IPaymentRouterGovernance.setAdapter.selector);
    }
}
