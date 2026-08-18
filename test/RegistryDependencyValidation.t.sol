// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../src/ServiceRegistry.sol";
import {ValidationRegistry} from "../src/ValidationRegistry.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract WrongDecimalsToken is ERC20 {
    constructor() ERC20("Wrong Decimals", "WRONG") {}
}

contract RegistryDependencyValidationTest is Test {
    MockCanonicalIdentityRegistry private identity;
    MockSanctionsList private sanctions;
    MockUSDC private usdc;

    address private admin = makeAddr("admin");
    address private treasury = makeAddr("treasury");

    function setUp() public {
        identity = new MockCanonicalIdentityRegistry();
        sanctions = new MockSanctionsList();
        usdc = new MockUSDC();
    }

    function test_agentIndexRejectsIdentityWithoutCode() public {
        address missingIdentity = makeAddr("missingIdentity");
        AgentIndex implementation = new AgentIndex();
        vm.expectRevert("identity not contract");
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(AgentIndex.initialize, (missingIdentity, address(sanctions), admin))
        );
    }

    function test_agentIndexRejectsWrongIdentityAbi() public {
        AgentIndex implementation = new AgentIndex();
        vm.expectRevert("invalid identity");
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(AgentIndex.initialize, (address(usdc), address(sanctions), admin))
        );
    }

    function test_providerRegistryRejectsIdentityWithoutCode() public {
        address missingIdentity = makeAddr("missingProviderIdentity");
        ProviderRegistry implementation = new ProviderRegistry();
        vm.expectRevert("identity not contract");
        _deployProviderProxy(address(implementation), missingIdentity, address(usdc));
    }

    function test_providerRegistryRejectsWrongIdentityAbi() public {
        ProviderRegistry implementation = new ProviderRegistry();
        vm.expectRevert("invalid identity");
        _deployProviderProxy(address(implementation), address(usdc), address(usdc));
    }

    function test_providerRegistryRejectsTokenWithoutCode() public {
        address missingToken = makeAddr("missingToken");
        ProviderRegistry implementation = new ProviderRegistry();
        vm.expectRevert("usdc not contract");
        _deployProviderProxy(address(implementation), address(identity), missingToken);
    }

    function test_providerRegistryRejectsWrongTokenAbi() public {
        ProviderRegistry implementation = new ProviderRegistry();
        vm.expectRevert("invalid usdc");
        _deployProviderProxy(address(implementation), address(identity), address(identity));
    }

    function test_providerRegistryRejectsWrongTokenDecimals() public {
        ProviderRegistry implementation = new ProviderRegistry();
        WrongDecimalsToken wrongDecimals = new WrongDecimalsToken();
        vm.expectRevert("invalid usdc");
        _deployProviderProxy(address(implementation), address(identity), address(wrongDecimals));
    }

    function test_serviceRegistryRejectsIdentityWithoutCode() public {
        ProviderRegistry providers = _deployProvider(address(identity), address(usdc));
        address missingIdentity = makeAddr("missingServiceIdentity");
        ServiceRegistry implementation = new ServiceRegistry();
        vm.expectRevert("identity not contract");
        _deployServicesProxy(address(implementation), missingIdentity, address(providers));
    }

    function test_serviceRegistryRejectsWrongIdentityAbi() public {
        ProviderRegistry providers = _deployProvider(address(identity), address(usdc));
        ServiceRegistry implementation = new ServiceRegistry();
        vm.expectRevert("invalid identity");
        _deployServicesProxy(address(implementation), address(usdc), address(providers));
    }

    function test_serviceRegistryRejectsProviderWithoutCode() public {
        address missingProvider = makeAddr("missingProviderRegistry");
        ServiceRegistry implementation = new ServiceRegistry();
        vm.expectRevert("provider registry not contract");
        _deployServicesProxy(address(implementation), address(identity), missingProvider);
    }

    function test_serviceRegistryRejectsWrongProviderAbi() public {
        ServiceRegistry implementation = new ServiceRegistry();
        vm.expectRevert("invalid provider registry");
        _deployServicesProxy(address(implementation), address(identity), address(usdc));
    }

    function test_serviceRegistryRejectsCrossWiredIdentity() public {
        MockCanonicalIdentityRegistry otherIdentity = new MockCanonicalIdentityRegistry();
        ProviderRegistry providers = _deployProvider(address(otherIdentity), address(usdc));
        ServiceRegistry implementation = new ServiceRegistry();

        vm.expectRevert("provider identity mismatch");
        _deployServicesProxy(address(implementation), address(identity), address(providers));
    }

    function test_validationRegistryRejectsIdentityWithoutCode() public {
        address missingIdentity = makeAddr("missingValidationIdentity");
        ValidationRegistry implementation = new ValidationRegistry();
        vm.expectRevert("identity not contract");
        _deployValidationProxy(address(implementation), missingIdentity);
    }

    function test_validationRegistryRejectsWrongIdentityAbi() public {
        ValidationRegistry implementation = new ValidationRegistry();
        vm.expectRevert("invalid identity");
        _deployValidationProxy(address(implementation), address(usdc));
    }

    function _deployProvider(address identity_, address usdc_) private returns (ProviderRegistry) {
        ProviderRegistry implementation = new ProviderRegistry();
        return _deployProviderProxy(address(implementation), identity_, usdc_);
    }

    function _deployProviderProxy(address implementation, address identity_, address usdc_)
        private
        returns (ProviderRegistry)
    {
        return ProviderRegistry(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(
                        ProviderRegistry.initialize, (identity_, usdc_, treasury, 1_000_000, address(sanctions), admin)
                    )
                )
            )
        );
    }

    function _deployServicesProxy(address implementation, address identity_, address providerRegistry_)
        private
        returns (ServiceRegistry)
    {
        return ServiceRegistry(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(
                        ServiceRegistry.initialize, (identity_, providerRegistry_, address(sanctions), admin)
                    )
                )
            )
        );
    }

    function _deployValidationProxy(address implementation, address identity_) private returns (ValidationRegistry) {
        return ValidationRegistry(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(ValidationRegistry.initialize, (identity_, address(sanctions), admin))
                )
            )
        );
    }
}
