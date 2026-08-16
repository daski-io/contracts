// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {ISchemaRegistry} from "../src/interfaces/IEAS.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {ReputationTestBase} from "./helpers/ReputationTestBase.sol";

contract InvalidSchemaRegistryEAS {
    address private immutable REGISTRY;

    constructor(address registry_) {
        REGISTRY = registry_;
    }

    function getSchemaRegistry() external view returns (ISchemaRegistry) {
        return ISchemaRegistry(REGISTRY);
    }
}

contract ReputationConfigurationTest is ReputationTestBase {
    function test_finalizeValidatesFreshStandardSchemas() public {
        ReputationStorage fresh = _fresh();
        MockEAS freshEas = new MockEAS();
        _setSchemas(
            fresh,
            freshEas,
            "bytes32 orderKey,uint8 outcome",
            address(fresh),
            false,
            "bytes32 orderKey,uint8 confirmation",
            address(fresh),
            true
        );
        vm.prank(admin);
        fresh.finalizeConfiguration();
        assertTrue(fresh.isConfigured());
    }

    function test_finalizeRejectsWrongResolverTextAndRevocability() public {
        ReputationStorage fresh = _fresh();
        MockEAS freshEas = new MockEAS();
        (bytes32 outcomeUid,) = _setSchemas(
            fresh,
            freshEas,
            "bytes32 orderKey,uint8 wrong",
            address(fresh),
            false,
            "bytes32 orderKey,uint8 confirmation",
            address(fresh),
            true
        );
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReputationStorageBase.WrongSchemaDefinition.selector, outcomeUid));
        fresh.finalizeConfiguration();

        fresh = _fresh();
        freshEas = new MockEAS();
        (outcomeUid,) = _setSchemas(
            fresh,
            freshEas,
            "bytes32 orderKey,uint8 outcome",
            makeAddr("wrong-resolver"),
            false,
            "bytes32 orderKey,uint8 confirmation",
            address(fresh),
            false
        );
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReputationStorageBase.WrongSchemaResolver.selector, outcomeUid));
        fresh.finalizeConfiguration();

        fresh = _fresh();
        freshEas = new MockEAS();
        (outcomeUid,) = _setSchemas(
            fresh,
            freshEas,
            "bytes32 orderKey,uint8 outcome",
            address(fresh),
            true,
            "bytes32 orderKey,uint8 confirmation",
            address(fresh),
            true
        );
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReputationStorageBase.SchemaMustBeIrrevocable.selector, outcomeUid));
        fresh.finalizeConfiguration();

        fresh = _fresh();
        freshEas = new MockEAS();
        (, bytes32 confirmationUid) = _setSchemas(
            fresh,
            freshEas,
            "bytes32 orderKey,uint8 outcome",
            address(fresh),
            false,
            "bytes32 orderKey,uint8 confirmation",
            address(fresh),
            false
        );
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReputationStorageBase.SchemaMustBeRevocable.selector, confirmationUid));
        fresh.finalizeConfiguration();
    }

    function test_finalizeRejectsSchemaRegistryWithoutCode() public {
        ReputationStorage fresh = _fresh();
        address missingRegistry = makeAddr("missing-registry");
        InvalidSchemaRegistryEAS badEas = new InvalidSchemaRegistryEAS(missingRegistry);
        vm.startPrank(admin);
        fresh.setEAS(address(badEas));
        fresh.setOutcomeSchema(keccak256("outcome"));
        fresh.setConfirmationSchema(keccak256("confirmation"));
        vm.expectRevert(abi.encodeWithSelector(ReputationStorageBase.TargetHasNoCode.selector, missingRegistry));
        fresh.finalizeConfiguration();
        vm.stopPrank();
    }

    function test_orderSignerRotationIsExplicitAndCannotSelectAdmin() public {
        address newSigner = makeAddr("new-order-signer");
        vm.prank(admin);
        reputation.setOrderSigner(newSigner);
        assertEq(reputation.orderSigner(), newSigner);

        vm.prank(admin);
        vm.expectRevert(ReputationStorageBase.InvalidOrderSigner.selector);
        reputation.setOrderSigner(admin);
    }

    function _fresh() private returns (ReputationStorage fresh) {
        ReputationStorage implementation = new ReputationStorage();
        fresh = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        ReputationStorage.initialize,
                        (
                            vm.addr(ORDER_SIGNER_KEY),
                            address(identity),
                            address(providers),
                            address(services),
                            address(sanctions),
                            token,
                            admin
                        )
                    )
                )
            )
        );
    }

    function _setSchemas(
        ReputationStorage fresh,
        MockEAS freshEas,
        string memory outcomeText,
        address outcomeResolver,
        bool outcomeRevocable,
        string memory confirmationText,
        address confirmationResolver,
        bool confirmationRevocable
    ) private returns (bytes32 outcomeUid, bytes32 confirmationUid) {
        outcomeUid = freshEas.register(outcomeText, outcomeResolver, outcomeRevocable);
        confirmationUid = freshEas.register(confirmationText, confirmationResolver, confirmationRevocable);
        vm.startPrank(admin);
        fresh.setEAS(address(freshEas));
        fresh.setOutcomeSchema(outcomeUid);
        fresh.setConfirmationSchema(confirmationUid);
        vm.stopPrank();
    }
}
