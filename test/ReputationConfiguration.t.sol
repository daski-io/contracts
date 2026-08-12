// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ISchemaRegistry} from "../src/interfaces/IEAS.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";

contract PaymentRouterCodeStub {}

contract InvalidSchemaRegistryEAS {
    address private immutable REGISTRY;

    constructor(address registry_) {
        REGISTRY = registry_;
    }

    function getSchemaRegistry() external view returns (ISchemaRegistry) {
        return ISchemaRegistry(REGISTRY);
    }
}

contract ReputationConfigurationTest is Test {
    address admin = makeAddr("admin");
    PaymentRouterCodeStub router;
    MockSanctionsList sanctions;

    function setUp() public {
        router = new PaymentRouterCodeStub();
        sanctions = new MockSanctionsList();
    }

    function _fresh() internal returns (ReputationStorage reputation) {
        ReputationStorage implementation = new ReputationStorage();
        reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(ReputationStorage.initialize, (address(router), address(sanctions), admin))
                )
            )
        );
    }

    function _setSchemas(
        ReputationStorage reputation,
        MockEAS eas,
        string memory outcomeText,
        address outcomeResolver,
        bool outcomeRevocable,
        string memory confirmationText,
        address confirmationResolver,
        bool confirmationRevocable
    ) internal {
        bytes32 outcome = eas.register(outcomeText, outcomeResolver, outcomeRevocable);
        bytes32 confirmation = eas.register(confirmationText, confirmationResolver, confirmationRevocable);
        vm.startPrank(admin);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(outcome);
        reputation.setConfirmationSchema(confirmation);
        vm.stopPrank();
    }

    function test_finalizeValidatesSchemasFromConfiguredEAS() public {
        ReputationStorage reputation = _fresh();
        MockEAS eas = new MockEAS();
        _setSchemas(
            reputation,
            eas,
            "uint256 paymentId,uint8 outcome",
            address(reputation),
            false,
            "uint256 paymentId,uint8 confirmation",
            address(reputation),
            true
        );

        vm.prank(admin);
        reputation.finalizeConfiguration();
        assertTrue(reputation.isConfigured());
    }

    function test_finalizeRejectsMissingSchemaAndRemainsMutable() public {
        ReputationStorage reputation = _fresh();
        MockEAS eas = new MockEAS();
        vm.startPrank(admin);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(keccak256("missing"));
        reputation.setConfirmationSchema(keccak256("also-missing"));
        vm.expectRevert("outcome schema missing");
        reputation.finalizeConfiguration();
        reputation.setOutcomeSchema(keccak256("replacement"));
        vm.stopPrank();
        assertFalse(reputation.isConfigured());
    }

    function test_finalizeRejectsWrongOutcomeResolver() public {
        ReputationStorage reputation = _fresh();
        MockEAS eas = new MockEAS();
        _setSchemas(
            reputation,
            eas,
            "uint256 paymentId,uint8 outcome",
            makeAddr("wrongResolver"),
            false,
            "uint256 paymentId,uint8 confirmation",
            address(reputation),
            true
        );

        vm.prank(admin);
        vm.expectRevert("wrong outcome resolver");
        reputation.finalizeConfiguration();
    }

    function test_finalizeRejectsWrongSchemaText() public {
        ReputationStorage reputation = _fresh();
        MockEAS eas = new MockEAS();
        _setSchemas(
            reputation,
            eas,
            "uint256 paymentId,uint8 wrong",
            address(reputation),
            false,
            "uint256 paymentId,uint8 confirmation",
            address(reputation),
            true
        );

        vm.prank(admin);
        vm.expectRevert("wrong outcome schema");
        reputation.finalizeConfiguration();
    }

    function test_finalizeRejectsWrongConfirmationResolver() public {
        ReputationStorage reputation = _fresh();
        MockEAS eas = new MockEAS();
        _setSchemas(
            reputation,
            eas,
            "uint256 paymentId,uint8 outcome",
            address(reputation),
            false,
            "uint256 paymentId,uint8 confirmation",
            makeAddr("wrongResolver"),
            true
        );

        vm.prank(admin);
        vm.expectRevert("wrong confirmation resolver");
        reputation.finalizeConfiguration();
    }

    function test_finalizeRejectsWrongConfirmationSchemaText() public {
        ReputationStorage reputation = _fresh();
        MockEAS eas = new MockEAS();
        _setSchemas(
            reputation,
            eas,
            "uint256 paymentId,uint8 outcome",
            address(reputation),
            false,
            "uint256 paymentId,uint8 wrong",
            address(reputation),
            true
        );

        vm.prank(admin);
        vm.expectRevert("wrong confirmation schema");
        reputation.finalizeConfiguration();
    }

    function test_finalizeRejectsOutcomeRevocability() public {
        ReputationStorage reputation = _fresh();
        MockEAS eas = new MockEAS();
        _setSchemas(
            reputation,
            eas,
            "uint256 paymentId,uint8 outcome",
            address(reputation),
            true,
            "uint256 paymentId,uint8 confirmation",
            address(reputation),
            true
        );

        vm.prank(admin);
        vm.expectRevert("outcome schema revocable");
        reputation.finalizeConfiguration();
    }

    function test_finalizeRejectsConfirmationRevocability() public {
        ReputationStorage reputation = _fresh();
        MockEAS eas = new MockEAS();
        _setSchemas(
            reputation,
            eas,
            "uint256 paymentId,uint8 outcome",
            address(reputation),
            false,
            "uint256 paymentId,uint8 confirmation",
            address(reputation),
            false
        );

        vm.prank(admin);
        vm.expectRevert("confirmation schema not revocable");
        reputation.finalizeConfiguration();
    }

    function test_finalizeRejectsSchemaRegistryWithoutCode() public {
        ReputationStorage reputation = _fresh();
        InvalidSchemaRegistryEAS eas = new InvalidSchemaRegistryEAS(makeAddr("missingRegistry"));
        vm.startPrank(admin);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(keccak256("outcome"));
        reputation.setConfirmationSchema(keccak256("confirmation"));
        vm.expectRevert("schema registry has no code");
        reputation.finalizeConfiguration();
        vm.stopPrank();
    }

    function test_schemaUidsMustBeNonzeroAndDistinct() public {
        ReputationStorage reputation = _fresh();
        vm.startPrank(admin);
        vm.expectRevert("zero schema");
        reputation.setOutcomeSchema(bytes32(0));
        reputation.setOutcomeSchema(keccak256("schema"));
        vm.expectRevert("schemas must differ");
        reputation.setConfirmationSchema(keccak256("schema"));
        vm.stopPrank();
    }
}
