// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationDependencyValidation} from "../script/ReputationDependencyValidation.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {
    ReputationIdentityDependencyStub,
    ReputationProviderDependencyStub,
    ReputationProviderWiringOnlyStub,
    ReputationServiceDependencyStub,
    ReputationServiceWiringOnlyStub,
    ReputationUsdcDependencyStub
} from "./helpers/ReputationDependencyStubs.sol";

contract ReputationDependencyValidationHarness is ReputationDependencyValidation {
    function validate(
        address identityRegistry,
        address providerRegistry,
        address serviceRegistry,
        address sanctionsOracle,
        address canonicalToken
    ) external view {
        _validateDependencies(identityRegistry, providerRegistry, serviceRegistry, sanctionsOracle, canonicalToken);
    }
}

contract ReputationDependencyValidationTest is Test {
    ReputationDependencyValidationHarness private validator;
    ReputationIdentityDependencyStub private identity;
    ReputationUsdcDependencyStub private token;
    MockSanctionsList private sanctions;
    ReputationProviderDependencyStub private provider;
    ReputationServiceDependencyStub private service;

    function setUp() public {
        validator = new ReputationDependencyValidationHarness();
        identity = new ReputationIdentityDependencyStub();
        token = new ReputationUsdcDependencyStub();
        sanctions = new MockSanctionsList();
        provider = new ReputationProviderDependencyStub(address(identity), address(token), address(sanctions));
        service = new ReputationServiceDependencyStub(address(identity), address(provider), address(sanctions));
    }

    function test_acceptsCompleteConsistentDependencyGraph() public view {
        _validate(address(identity), address(provider), address(service), address(sanctions), address(token));
    }

    function test_rejectsMissingDependencyCode() public {
        address missing = makeAddr("missing");
        vm.expectRevert("identity not contract");
        _validate(missing, address(provider), address(service), address(sanctions), address(token));
        vm.expectRevert("provider registry not contract");
        _validate(address(identity), missing, address(service), address(sanctions), address(token));
        vm.expectRevert("service registry not contract");
        _validate(address(identity), address(provider), missing, address(sanctions), address(token));
        vm.expectRevert("sanctions oracle not contract");
        _validate(address(identity), address(provider), address(service), missing, address(token));
        vm.expectRevert("token not contract");
        _validate(address(identity), address(provider), address(service), address(sanctions), missing);
    }

    function test_rejectsProviderWithoutRegistrationProbe() public {
        ReputationProviderWiringOnlyStub incompleteProvider =
            new ReputationProviderWiringOnlyStub(address(identity), address(token), address(sanctions));
        ReputationServiceDependencyStub linkedService =
            new ReputationServiceDependencyStub(address(identity), address(incompleteProvider), address(sanctions));

        vm.expectRevert("invalid provider registry");
        _validate(
            address(identity), address(incompleteProvider), address(linkedService), address(sanctions), address(token)
        );
    }

    function test_rejectsServiceWithoutExistsProbe() public {
        ReputationServiceWiringOnlyStub incompleteService =
            new ReputationServiceWiringOnlyStub(address(identity), address(provider), address(sanctions));

        vm.expectRevert("invalid service registry");
        _validate(address(identity), address(provider), address(incompleteService), address(sanctions), address(token));
    }

    function test_rejectsCrossWiredProviderDependencies() public {
        ReputationIdentityDependencyStub otherIdentity = new ReputationIdentityDependencyStub();
        ReputationProviderDependencyStub wrongIdentity =
            new ReputationProviderDependencyStub(address(otherIdentity), address(token), address(sanctions));
        vm.expectRevert("provider identity mismatch");
        _validate(address(identity), address(wrongIdentity), address(service), address(sanctions), address(token));

        ReputationUsdcDependencyStub otherToken = new ReputationUsdcDependencyStub();
        ReputationProviderDependencyStub wrongToken =
            new ReputationProviderDependencyStub(address(identity), address(otherToken), address(sanctions));
        vm.expectRevert("provider token mismatch");
        _validate(address(identity), address(wrongToken), address(service), address(sanctions), address(token));

        MockSanctionsList otherOracle = new MockSanctionsList();
        ReputationProviderDependencyStub wrongOracle =
            new ReputationProviderDependencyStub(address(identity), address(token), address(otherOracle));
        vm.expectRevert("provider sanctions mismatch");
        _validate(address(identity), address(wrongOracle), address(service), address(sanctions), address(token));
    }

    function test_rejectsCrossWiredServiceDependencies() public {
        ReputationIdentityDependencyStub otherIdentity = new ReputationIdentityDependencyStub();
        ReputationServiceDependencyStub wrongIdentity =
            new ReputationServiceDependencyStub(address(otherIdentity), address(provider), address(sanctions));
        vm.expectRevert("service identity mismatch");
        _validate(address(identity), address(provider), address(wrongIdentity), address(sanctions), address(token));

        ReputationProviderDependencyStub otherProvider =
            new ReputationProviderDependencyStub(address(identity), address(token), address(sanctions));
        ReputationServiceDependencyStub wrongProvider =
            new ReputationServiceDependencyStub(address(identity), address(otherProvider), address(sanctions));
        vm.expectRevert("service provider mismatch");
        _validate(address(identity), address(provider), address(wrongProvider), address(sanctions), address(token));

        MockSanctionsList otherOracle = new MockSanctionsList();
        ReputationServiceDependencyStub wrongOracle =
            new ReputationServiceDependencyStub(address(identity), address(provider), address(otherOracle));
        vm.expectRevert("service sanctions mismatch");
        _validate(address(identity), address(provider), address(wrongOracle), address(sanctions), address(token));
    }

    function _validate(
        address identityRegistry,
        address providerRegistry,
        address serviceRegistry,
        address sanctionsOracle,
        address canonicalToken
    ) private view {
        validator.validate(identityRegistry, providerRegistry, serviceRegistry, sanctionsOracle, canonicalToken);
    }
}
