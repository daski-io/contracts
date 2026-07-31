// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {AgentIndex} from "../../src/AgentIndex.sol";
import {DaskiValidationRegistry} from "../../src/DaskiValidationRegistry.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../../src/ServiceRegistry.sol";
import {PaymentRouter} from "../../src/PaymentRouter.sol";
import {ReputationStorage} from "../../src/ReputationStorage.sol";
import {X402Adapter} from "../../src/adapters/X402Adapter.sol";
import {PermitAdapter} from "../../src/adapters/PermitAdapter.sol";
import {ApprovalAdapter} from "../../src/adapters/ApprovalAdapter.sol";
import {Admin2StepUpgradeable} from "../../src/utils/Admin2StepUpgradeable.sol";
import {DeploymentValidation} from "../../script/DeploymentValidation.sol";
import {MockEAS} from "./MockEAS.sol";
import {MockSanctionsList} from "../mocks/MockSanctionsList.sol";

contract ReleaseCeremonyIdentity is Initializable, ERC165 {
    address private _owner;
    string private _version;

    function initialize(address owner_) external initializer {
        _owner = owner_;
        _version = "2.0.0";
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function getVersion() external view returns (string memory) {
        return _version;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC165).interfaceId
            || super.supportsInterface(interfaceId);
    }
}

contract ReleaseCeremonyUsdc is ERC20 {
    bytes32 private immutable _DOMAIN_SEPARATOR;

    constructor() ERC20("USDC", "USDC") {
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USDC"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function version() external pure returns (string memory) {
        return "2";
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _DOMAIN_SEPARATOR;
    }
}

abstract contract ReleaseCeremonyStackBuilder is Test {
    struct CeremonyFixture {
        DeploymentValidation.Stack stack;
        address[9] implementations;
        address identityImplementation;
        address eas;
        bytes32 outcomeSchemaUid;
        bytes32 confirmationSchemaUid;
    }

    function _deployCeremonyStack(address deployer, address safe, address guardian, address facilitator)
        internal
        returns (CeremonyFixture memory fixture)
    {
        MockSanctionsList sanctions = new MockSanctionsList();
        MockEAS eas = new MockEAS();
        ReleaseCeremonyUsdc usdc = new ReleaseCeremonyUsdc();
        ReleaseCeremonyIdentity identityImplementation = new ReleaseCeremonyIdentity();
        ERC1967Proxy identity = new ERC1967Proxy(
            address(identityImplementation), abi.encodeCall(ReleaseCeremonyIdentity.initialize, (deployer))
        );

        AgentIndex agentIndexImplementation = new AgentIndex();
        AgentIndex agentIndex = AgentIndex(
            address(
                new ERC1967Proxy(
                    address(agentIndexImplementation),
                    abi.encodeCall(AgentIndex.initialize, (address(identity), address(sanctions), deployer))
                )
            )
        );
        DaskiValidationRegistry validationImplementation = new DaskiValidationRegistry();
        DaskiValidationRegistry validation = DaskiValidationRegistry(
            address(
                new ERC1967Proxy(
                    address(validationImplementation),
                    abi.encodeCall(
                        DaskiValidationRegistry.initialize, (address(identity), address(sanctions), deployer)
                    )
                )
            )
        );
        ProviderRegistry providerImplementation = new ProviderRegistry();
        ProviderRegistry provider = ProviderRegistry(
            address(
                new ERC1967Proxy(
                    address(providerImplementation),
                    abi.encodeCall(
                        ProviderRegistry.initialize,
                        (
                            address(identity),
                            address(usdc),
                            makeAddr("providerTreasury"),
                            1_000_000,
                            address(sanctions),
                            deployer
                        )
                    )
                )
            )
        );
        ServiceRegistry serviceImplementation = new ServiceRegistry();
        ServiceRegistry service = ServiceRegistry(
            address(
                new ERC1967Proxy(
                    address(serviceImplementation),
                    abi.encodeCall(
                        ServiceRegistry.initialize, (address(identity), address(provider), address(sanctions), deployer)
                    )
                )
            )
        );
        PaymentRouter routerImplementation = new PaymentRouter();
        PaymentRouter router = PaymentRouter(
            address(
                new ERC1967Proxy(
                    address(routerImplementation),
                    abi.encodeCall(
                        PaymentRouter.initialize,
                        (
                            address(identity),
                            address(provider),
                            address(service),
                            makeAddr("paymentTreasury"),
                            500,
                            address(sanctions),
                            deployer
                        )
                    )
                )
            )
        );
        ReputationStorage reputationImplementation = new ReputationStorage();
        ReputationStorage reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(reputationImplementation),
                    abi.encodeCall(ReputationStorage.initialize, (address(router), address(sanctions), deployer))
                )
            )
        );
        X402Adapter x402Implementation = new X402Adapter();
        X402Adapter x402 = X402Adapter(
            address(
                new ERC1967Proxy(
                    address(x402Implementation),
                    abi.encodeCall(
                        X402Adapter.initialize, (address(router), address(agentIndex), address(sanctions), deployer)
                    )
                )
            )
        );
        PermitAdapter permitImplementation = new PermitAdapter();
        PermitAdapter permit = PermitAdapter(
            address(
                new ERC1967Proxy(
                    address(permitImplementation),
                    abi.encodeCall(
                        PermitAdapter.initialize, (address(router), address(agentIndex), address(sanctions), deployer)
                    )
                )
            )
        );
        ApprovalAdapter approvalImplementation = new ApprovalAdapter();
        ApprovalAdapter approval = ApprovalAdapter(
            address(
                new ERC1967Proxy(
                    address(approvalImplementation),
                    abi.encodeCall(
                        ApprovalAdapter.initialize, (address(router), address(agentIndex), address(sanctions), deployer)
                    )
                )
            )
        );

        fixture = CeremonyFixture({
            stack: DeploymentValidation.Stack({
                identity: address(identity),
                usdc: address(usdc),
                providerTreasury: provider.treasury(),
                paymentTreasury: router.treasury(),
                sanctionsOracle: address(sanctions),
                agentIndex: address(agentIndex),
                daskiValidationRegistry: address(validation),
                providerRegistry: address(provider),
                serviceRegistry: address(service),
                router: address(router),
                reputation: address(reputation),
                x402Adapter: address(x402),
                permitAdapter: address(permit),
                approvalAdapter: address(approval),
                listingFee: 1_000_000,
                commissionBps: 500,
                reputationMinimum: 250_000
            }),
            implementations: [
                address(agentIndexImplementation),
                address(validationImplementation),
                address(providerImplementation),
                address(serviceImplementation),
                address(routerImplementation),
                address(reputationImplementation),
                address(x402Implementation),
                address(permitImplementation),
                address(approvalImplementation)
            ],
            identityImplementation: address(identityImplementation),
            eas: address(eas),
            outcomeSchemaUid: bytes32(0),
            confirmationSchemaUid: bytes32(0)
        });

        fixture.outcomeSchemaUid = eas.register(DeploymentValidation.outcomeSchema(), address(reputation), false);
        fixture.confirmationSchemaUid =
            eas.register(DeploymentValidation.confirmationSchema(), address(reputation), true);

        vm.startPrank(deployer);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(fixture.outcomeSchemaUid);
        reputation.setConfirmationSchema(fixture.confirmationSchemaUid);
        reputation.finalizeConfiguration();
        router.setReputationStorage(address(reputation));
        x402.setFacilitatorAuthorization(facilitator, true);
        address[9] memory contracts_ = DeploymentValidation.adminContracts(fixture.stack);
        for (uint256 i = 0; i < contracts_.length; i++) {
            Admin2StepUpgradeable(contracts_[i]).setPauseGuardian(guardian);
            Admin2StepUpgradeable(contracts_[i]).transferAdmin(safe);
        }
        vm.stopPrank();
    }
}
