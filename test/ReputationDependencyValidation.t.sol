// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReputationDependencyValidation} from "../script/ReputationDependencyValidation.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";

contract EmptyDependency {}

contract IdentityDependencyStub {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC721).interfaceId;
    }

    function getAgentWallet(uint256) external pure returns (address) {
        return address(0);
    }
}

contract UsdcDependencyStub {
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract ProviderDependencyStub {
    address public immutable identity;
    address public immutable usdc;
    address public immutable sanctionsOracle;

    constructor(address identity_, address usdc_, address sanctionsOracle_) {
        identity = identity_;
        usdc = usdc_;
        sanctionsOracle = sanctionsOracle_;
    }

    function isRegistered(uint256) external pure returns (bool) {
        return false;
    }
}

contract ServiceDependencyStub {
    address public immutable identity;
    address public immutable providerRegistry;
    address public immutable sanctionsOracle;

    constructor(address identity_, address providerRegistry_, address sanctionsOracle_) {
        identity = identity_;
        providerRegistry = providerRegistry_;
        sanctionsOracle = sanctionsOracle_;
    }

    function exists(bytes32) external pure returns (bool) {
        return false;
    }
}

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
    IdentityDependencyStub private identity;
    UsdcDependencyStub private token;
    MockSanctionsList private sanctions;
    ProviderDependencyStub private provider;
    ServiceDependencyStub private service;

    function setUp() public {
        validator = new ReputationDependencyValidationHarness();
        identity = new IdentityDependencyStub();
        token = new UsdcDependencyStub();
        sanctions = new MockSanctionsList();
        provider = new ProviderDependencyStub(address(identity), address(token), address(sanctions));
        service = new ServiceDependencyStub(address(identity), address(provider), address(sanctions));
    }

    function test_acceptsCompleteConsistentDependencyGraph() public view {
        _validate(address(identity), address(provider), address(service), address(sanctions), address(token));
    }

    function test_rejectsEmptyAbiDependencies() public {
        EmptyDependency empty = new EmptyDependency();

        vm.expectRevert("invalid identity");
        _validate(address(empty), address(provider), address(service), address(sanctions), address(token));
        vm.expectRevert("invalid provider registry");
        _validate(address(identity), address(empty), address(service), address(sanctions), address(token));
        vm.expectRevert("invalid service registry");
        _validate(address(identity), address(provider), address(empty), address(sanctions), address(token));
        vm.expectRevert("invalid sanctions oracle");
        _validate(address(identity), address(provider), address(service), address(empty), address(token));
        vm.expectRevert("invalid usdc");
        _validate(address(identity), address(provider), address(service), address(sanctions), address(empty));
    }

    function test_rejectsCrossWiredProviderDependencies() public {
        IdentityDependencyStub otherIdentity = new IdentityDependencyStub();
        ProviderDependencyStub wrongIdentity =
            new ProviderDependencyStub(address(otherIdentity), address(token), address(sanctions));
        vm.expectRevert("provider identity mismatch");
        _validate(address(identity), address(wrongIdentity), address(service), address(sanctions), address(token));

        UsdcDependencyStub otherToken = new UsdcDependencyStub();
        ProviderDependencyStub wrongToken =
            new ProviderDependencyStub(address(identity), address(otherToken), address(sanctions));
        vm.expectRevert("provider token mismatch");
        _validate(address(identity), address(wrongToken), address(service), address(sanctions), address(token));

        MockSanctionsList otherOracle = new MockSanctionsList();
        ProviderDependencyStub wrongOracle =
            new ProviderDependencyStub(address(identity), address(token), address(otherOracle));
        vm.expectRevert("sanctions binding mismatch");
        _validate(address(identity), address(wrongOracle), address(service), address(sanctions), address(token));
    }

    function test_rejectsCrossWiredServiceDependencies() public {
        IdentityDependencyStub otherIdentity = new IdentityDependencyStub();
        ServiceDependencyStub wrongIdentity =
            new ServiceDependencyStub(address(otherIdentity), address(provider), address(sanctions));
        vm.expectRevert("service identity mismatch");
        _validate(address(identity), address(provider), address(wrongIdentity), address(sanctions), address(token));

        ProviderDependencyStub otherProvider =
            new ProviderDependencyStub(address(identity), address(token), address(sanctions));
        ServiceDependencyStub wrongProvider =
            new ServiceDependencyStub(address(identity), address(otherProvider), address(sanctions));
        vm.expectRevert("service provider mismatch");
        _validate(address(identity), address(provider), address(wrongProvider), address(sanctions), address(token));

        MockSanctionsList otherOracle = new MockSanctionsList();
        ServiceDependencyStub wrongOracle =
            new ServiceDependencyStub(address(identity), address(provider), address(otherOracle));
        vm.expectRevert("sanctions binding mismatch");
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
