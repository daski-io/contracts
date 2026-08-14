// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
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
        _setSchemas(
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
        vm.expectRevert("wrong outcome schema");
        fresh.finalizeConfiguration();

        fresh = _fresh();
        freshEas = new MockEAS();
        _setSchemas(
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
        vm.expectRevert("wrong outcome resolver");
        fresh.finalizeConfiguration();
    }

    function test_finalizeRejectsSchemaRegistryWithoutCode() public {
        ReputationStorage fresh = _fresh();
        InvalidSchemaRegistryEAS badEas = new InvalidSchemaRegistryEAS(makeAddr("missing-registry"));
        vm.startPrank(admin);
        fresh.setEAS(address(badEas));
        fresh.setOutcomeSchema(keccak256("outcome"));
        fresh.setConfirmationSchema(keccak256("confirmation"));
        vm.expectRevert("schema registry has no code");
        fresh.finalizeConfiguration();
        vm.stopPrank();
    }

    function test_orderSignerRotationIsExplicitAndCannotSelectAdmin() public {
        address newSigner = makeAddr("new-order-signer");
        vm.prank(admin);
        reputation.setOrderSigner(newSigner);
        assertEq(reputation.orderSigner(), newSigner);

        vm.prank(admin);
        vm.expectRevert("invalid order signer");
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
    ) private {
        bytes32 freshOutcome = freshEas.register(outcomeText, outcomeResolver, outcomeRevocable);
        bytes32 freshConfirmation = freshEas.register(confirmationText, confirmationResolver, confirmationRevocable);
        vm.startPrank(admin);
        fresh.setEAS(address(freshEas));
        fresh.setOutcomeSchema(freshOutcome);
        fresh.setConfirmationSchema(freshConfirmation);
        vm.stopPrank();
    }
}
