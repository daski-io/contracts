// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AgentIndex} from "../src/AgentIndex.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {PaymentRouter} from "../src/PaymentRouter.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {IEAS, ISchemaRegistry, SchemaRecord} from "../src/interfaces/IEAS.sol";
import {Admin2StepUpgradeable} from "../src/utils/Admin2StepUpgradeable.sol";

interface IAdapterBinding {
    function router() external view returns (address);
    function agentIndex() external view returns (address);
}

/// @notice Shared deployment invariants used during deployment and by the
///         read-only post-deployment verifier.
library DeploymentValidation {
    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant BASE_SEPOLIA = 84532;

    address internal constant BASE_MAINNET_IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant BASE_SEPOLIA_IDENTITY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address internal constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant BASE_EAS = 0x4200000000000000000000000000000000000021;
    address internal constant BASE_SCHEMA_REGISTRY = 0x4200000000000000000000000000000000000020;
    string internal constant OUTCOME_SCHEMA = "uint256 paymentId,uint8 outcome";
    string internal constant CONFIRMATION_SCHEMA = "uint256 paymentId,uint8 confirmation";

    struct Stack {
        address identity;
        address usdc;
        address treasury;
        address agentIndex;
        address validationRegistry;
        address providerRegistry;
        address serviceRegistry;
        address router;
        address reputation;
        address x402Adapter;
        address permitAdapter;
        address approvalAdapter;
        uint256 listingFee;
        uint256 commissionBps;
    }

    function outcomeSchema() internal pure returns (string memory) {
        return OUTCOME_SCHEMA;
    }

    function confirmationSchema() internal pure returns (string memory) {
        return CONFIRMATION_SCHEMA;
    }

    function adapters(Stack memory deployment) internal pure returns (address[3] memory) {
        return [deployment.x402Adapter, deployment.permitAdapter, deployment.approvalAdapter];
    }

    function adminContracts(Stack memory deployment) internal pure returns (address[9] memory) {
        return [
            deployment.agentIndex,
            deployment.validationRegistry,
            deployment.providerRegistry,
            deployment.serviceRegistry,
            deployment.router,
            deployment.reputation,
            deployment.x402Adapter,
            deployment.permitAdapter,
            deployment.approvalAdapter
        ];
    }

    function validateExternalDependencies(
        address identity,
        address usdc,
        address eas,
        address schemaRegistry,
        bool allowUnsupportedChain
    ) internal view {
        require(identity.code.length > 0, "identity has no code");
        require(usdc.code.length > 0, "USDC has no code");
        require(eas.code.length > 0, "EAS has no code");
        require(schemaRegistry.code.length > 0, "schema registry has no code");

        if (block.chainid == BASE_MAINNET) {
            require(identity == BASE_MAINNET_IDENTITY, "wrong Base identity");
            require(usdc == BASE_MAINNET_USDC, "wrong Base USDC");
            _requireBaseEas(eas, schemaRegistry);
        } else if (block.chainid == BASE_SEPOLIA) {
            require(identity == BASE_SEPOLIA_IDENTITY, "wrong Base Sepolia identity");
            require(usdc == BASE_SEPOLIA_USDC, "wrong Base Sepolia USDC");
            _requireBaseEas(eas, schemaRegistry);
        } else {
            require(allowUnsupportedChain, "unsupported chain");
        }

        require(IERC165(identity).supportsInterface(type(IERC165).interfaceId), "identity lacks ERC165");
        require(IERC165(identity).supportsInterface(type(IERC721).interfaceId), "identity lacks ERC721");
        require(IERC20Metadata(usdc).decimals() == 6, "USDC must have 6 decimals");
        require(address(IEAS(eas).getSchemaRegistry()) == schemaRegistry, "wrong EAS schema registry");
    }

    function validateSchemas(
        address eas,
        address schemaRegistry,
        address reputation,
        bytes32 outcomeUid,
        bytes32 confirmationUid,
        string memory expectedOutcomeSchema,
        string memory expectedConfirmationSchema
    ) internal view {
        ReputationStorage reputationStorage = ReputationStorage(reputation);
        require(address(reputationStorage.eas()) == eas, "wrong reputation EAS");
        require(reputationStorage.outcomeSchema() == outcomeUid, "wrong stored outcome schema");
        require(reputationStorage.confirmationSchema() == confirmationUid, "wrong stored confirmation schema");

        SchemaRecord memory outcome = ISchemaRegistry(schemaRegistry).getSchema(outcomeUid);
        require(outcome.uid == outcomeUid, "outcome schema missing");
        require(outcome.resolver == reputation, "wrong outcome resolver");
        require(!outcome.revocable, "outcome schema revocable");
        require(keccak256(bytes(outcome.schema)) == keccak256(bytes(expectedOutcomeSchema)), "wrong outcome schema");

        SchemaRecord memory confirmation = ISchemaRegistry(schemaRegistry).getSchema(confirmationUid);
        require(confirmation.uid == confirmationUid, "confirmation schema missing");
        require(confirmation.resolver == reputation, "wrong confirmation resolver");
        require(confirmation.revocable, "confirmation schema not revocable");
        require(
            keccak256(bytes(confirmation.schema)) == keccak256(bytes(expectedConfirmationSchema)),
            "wrong confirmation schema"
        );
    }

    function validateWiring(Stack memory deployment) internal view {
        require(
            AgentIndex(deployment.agentIndex).getIdentityRegistry() == deployment.identity,
            "AgentIndex identity mismatch"
        );
        require(
            ValidationRegistry(deployment.validationRegistry).getIdentityRegistry() == deployment.identity,
            "ValidationRegistry identity mismatch"
        );
        require(
            address(ProviderRegistry(deployment.providerRegistry).identity()) == deployment.identity,
            "ProviderRegistry identity mismatch"
        );
        require(
            address(ProviderRegistry(deployment.providerRegistry).usdc()) == deployment.usdc,
            "ProviderRegistry USDC mismatch"
        );
        require(
            ProviderRegistry(deployment.providerRegistry).treasury() == deployment.treasury,
            "ProviderRegistry treasury mismatch"
        );
        require(
            ProviderRegistry(deployment.providerRegistry).listingFee() == deployment.listingFee,
            "ProviderRegistry listing fee mismatch"
        );
        require(
            address(ServiceRegistry(deployment.serviceRegistry).identity()) == deployment.identity,
            "ServiceRegistry identity mismatch"
        );
        require(
            address(ServiceRegistry(deployment.serviceRegistry).providerRegistry()) == deployment.providerRegistry,
            "ServiceRegistry provider mismatch"
        );

        PaymentRouter router = PaymentRouter(deployment.router);
        require(address(router.identity()) == deployment.identity, "router identity mismatch");
        require(address(router.registry()) == deployment.providerRegistry, "router provider mismatch");
        require(address(router.serviceRegistry()) == deployment.serviceRegistry, "router service mismatch");
        require(router.treasury() == deployment.treasury, "router treasury mismatch");
        require(router.commissionBps() == deployment.commissionBps, "router commission mismatch");
        require(router.reputationStorage() == deployment.reputation, "router reputation mismatch");
        require(
            address(ReputationStorage(deployment.reputation).paymentRouter()) == deployment.router,
            "reputation router mismatch"
        );
        require(ReputationStorage(deployment.reputation).isConfigured(), "reputation not configured");
        require(router.getAcceptedTokenCount() == 1, "unexpected accepted token count");
        require(router.getAcceptedTokenAt(0) == deployment.usdc, "unexpected accepted token");

        address[3] memory expectedAdapters = adapters(deployment);
        require(
            expectedAdapters[0] != expectedAdapters[1] && expectedAdapters[0] != expectedAdapters[2]
                && expectedAdapters[1] != expectedAdapters[2],
            "duplicate expected adapter"
        );
        require(router.getAdapterCount() == expectedAdapters.length, "unexpected adapter count");
        for (uint256 i = 0; i < expectedAdapters.length; i++) {
            require(router.isAdapter(expectedAdapters[i]), "adapter not enabled");
            require(IAdapterBinding(expectedAdapters[i]).router() == deployment.router, "adapter router mismatch");
            require(
                IAdapterBinding(expectedAdapters[i]).agentIndex() == deployment.agentIndex,
                "adapter AgentIndex mismatch"
            );
        }
    }

    function validatePendingAdmins(address[9] memory contracts_, address currentAdmin, address pendingAdmin)
        internal
        view
    {
        for (uint256 i = 0; i < contracts_.length; i++) {
            require(Admin2StepUpgradeable(contracts_[i]).admin() == currentAdmin, "unexpected current admin");
            require(Admin2StepUpgradeable(contracts_[i]).pendingAdmin() == pendingAdmin, "wrong pending admin");
        }
    }

    function validateAcceptedAdmins(address[9] memory contracts_, address expectedAdmin) internal view {
        require(expectedAdmin.code.length > 0, "admin has no code");
        for (uint256 i = 0; i < contracts_.length; i++) {
            require(Admin2StepUpgradeable(contracts_[i]).admin() == expectedAdmin, "admin not accepted");
            require(Admin2StepUpgradeable(contracts_[i]).pendingAdmin() == address(0), "pending admin remains");
        }
    }

    function _requireBaseEas(address eas, address schemaRegistry) private pure {
        require(eas == BASE_EAS, "wrong Base EAS");
        require(schemaRegistry == BASE_SCHEMA_REGISTRY, "wrong Base schema registry");
    }
}
