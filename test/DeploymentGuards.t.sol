// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISchemaRegistry} from "../src/interfaces/IEAS.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {DeploymentValidationHarness} from "./helpers/DeploymentValidationHarness.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";

contract GovernanceCodeStub {}

contract SchemaRegistryCodeStub {}

contract EASRegistryPointer {
    ISchemaRegistry private immutable REGISTRY;

    constructor(ISchemaRegistry registry_) {
        REGISTRY = registry_;
    }

    function getSchemaRegistry() external view returns (ISchemaRegistry) {
        return REGISTRY;
    }
}

contract DeploymentGuardsTest is Test {
    DeploymentValidationHarness validation;
    MockSanctionsList sanctions;

    function setUp() public {
        validation = new DeploymentValidationHarness();
        sanctions = new MockSanctionsList();
    }

    function test_finalAdminMustBeASeparateContract() public {
        address deployer = makeAddr("deployer");
        vm.expectRevert("ADMIN_ADDRESS is required");
        validation.validateFinalAdmin(address(0), deployer);
        vm.expectRevert("ADMIN_ADDRESS must differ from deployer");
        validation.validateFinalAdmin(deployer, deployer);
        vm.expectRevert("ADMIN_ADDRESS must be a governance contract");
        validation.validateFinalAdmin(makeAddr("eoaAdmin"), deployer);

        validation.validateFinalAdmin(address(new GovernanceCodeStub()), deployer);
    }

    function test_externalDependenciesRejectUnsupportedChain() public {
        MockCanonicalIdentityRegistry identity = new MockCanonicalIdentityRegistry();
        MockUSDC usdc = new MockUSDC();
        MockEAS eas = new MockEAS();

        vm.expectRevert("unsupported chain");
        validation.validateExternalDependencies(
            address(identity), address(usdc), address(eas), address(eas), address(sanctions), false, true
        );
    }

    function test_externalDependenciesRejectOracleWithoutCode() public {
        MockCanonicalIdentityRegistry identity = new MockCanonicalIdentityRegistry();
        MockUSDC usdc = new MockUSDC();
        MockEAS eas = new MockEAS();

        vm.expectRevert("sanctions oracle has no code");
        validation.validateExternalDependencies(
            address(identity), address(usdc), address(eas), address(eas), makeAddr("missingOracle"), true, true
        );
    }

    function test_baseSepoliaRequiresExplicitMockOracleFlag() public {
        MockCanonicalIdentityRegistry identityTemplate = new MockCanonicalIdentityRegistry();
        MockUSDC usdcTemplate = new MockUSDC();
        MockEAS easTemplate = new MockEAS();
        SchemaRegistryCodeStub schemaTemplate = new SchemaRegistryCodeStub();
        address canonicalIdentity = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
        address canonicalUsdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        address canonicalEas = 0x4200000000000000000000000000000000000021;
        address canonicalSchema = 0x4200000000000000000000000000000000000020;
        vm.etch(canonicalIdentity, address(identityTemplate).code);
        vm.etch(canonicalUsdc, address(usdcTemplate).code);
        vm.etch(canonicalEas, address(easTemplate).code);
        vm.etch(canonicalSchema, address(schemaTemplate).code);
        vm.chainId(84532);

        vm.expectRevert("mock sanctions oracle not allowed");
        validation.validateExternalDependencies(
            canonicalIdentity, canonicalUsdc, canonicalEas, canonicalSchema, address(sanctions), false, false
        );
    }

    function test_externalDependenciesRejectWrongBaseSepoliaUsdc() public {
        MockCanonicalIdentityRegistry identityTemplate = new MockCanonicalIdentityRegistry();
        MockUSDC usdc = new MockUSDC();
        MockEAS easTemplate = new MockEAS();
        SchemaRegistryCodeStub schemaTemplate = new SchemaRegistryCodeStub();
        address canonicalIdentity = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
        address canonicalEas = 0x4200000000000000000000000000000000000021;
        address canonicalSchema = 0x4200000000000000000000000000000000000020;
        vm.etch(canonicalIdentity, address(identityTemplate).code);
        vm.etch(canonicalEas, address(easTemplate).code);
        vm.etch(canonicalSchema, address(schemaTemplate).code);
        vm.chainId(84532);

        vm.expectRevert("wrong Base Sepolia USDC");
        validation.validateExternalDependencies(
            canonicalIdentity, address(usdc), canonicalEas, canonicalSchema, address(sanctions), false, true
        );
    }

    function test_externalDependenciesRejectWrongBaseSepoliaIdentity() public {
        MockCanonicalIdentityRegistry identity = new MockCanonicalIdentityRegistry();
        MockUSDC usdcTemplate = new MockUSDC();
        MockEAS easTemplate = new MockEAS();
        SchemaRegistryCodeStub schemaTemplate = new SchemaRegistryCodeStub();
        address canonicalUsdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        address canonicalEas = 0x4200000000000000000000000000000000000021;
        address canonicalSchema = 0x4200000000000000000000000000000000000020;
        vm.etch(canonicalUsdc, address(usdcTemplate).code);
        vm.etch(canonicalEas, address(easTemplate).code);
        vm.etch(canonicalSchema, address(schemaTemplate).code);
        vm.chainId(84532);

        vm.expectRevert("wrong Base Sepolia identity");
        validation.validateExternalDependencies(
            address(identity), canonicalUsdc, canonicalEas, canonicalSchema, address(sanctions), false, true
        );
    }

    function test_externalDependenciesRejectWrongEasRegistry() public {
        MockCanonicalIdentityRegistry identity = new MockCanonicalIdentityRegistry();
        MockUSDC usdc = new MockUSDC();
        MockEAS expectedRegistry = new MockEAS();
        EASRegistryPointer eas = new EASRegistryPointer(ISchemaRegistry(address(new SchemaRegistryCodeStub())));

        vm.expectRevert("wrong EAS schema registry");
        validation.validateExternalDependencies(
            address(identity), address(usdc), address(eas), address(expectedRegistry), address(sanctions), true, true
        );
    }
}
