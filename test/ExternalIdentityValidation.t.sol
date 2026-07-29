// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ExternalIdentityValidation} from "../script/ExternalIdentityValidation.sol";
import {MockCanonicalIdentityRegistry} from "./mocks/MockCanonicalIdentityRegistry.sol";

contract ExternalIdentityValidationHarness is ExternalIdentityValidation {
    function validate(string calldata json, address expectedIdentity) external view {
        _validateExternalIdentityFromManifest(json, expectedIdentity);
    }
}

contract ExternalIdentityValidationTest is Test {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    ExternalIdentityValidationHarness private validator;
    MockCanonicalIdentityRegistry private implementation;
    address private proxy;
    address private authority = makeAddr("identityAuthority");

    function setUp() public {
        validator = new ExternalIdentityValidationHarness();
        implementation = new MockCanonicalIdentityRegistry();
        proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(MockCanonicalIdentityRegistry.forceSetRegistryOwner, (authority))
            )
        );
        MockCanonicalIdentityRegistry(proxy).forceSetVersion("2.0.0");
    }

    function test_acceptsExactExternalIdentity() public {
        validator.validate(
            _identityJson(
                proxy.codehash,
                address(implementation),
                address(implementation).codehash,
                address(0),
                authority,
                "2.0.0"
            ),
            proxy
        );
    }

    function test_rejectsProxyAddressMismatch() public {
        vm.expectRevert("identity proxy mismatch");
        validator.validate(
            _identityJson(
                proxy.codehash,
                address(implementation),
                address(implementation).codehash,
                address(0),
                authority,
                "2.0.0"
            ),
            address(1)
        );
    }

    function test_rejectsProxyCodehashMismatch() public {
        vm.expectRevert("identity proxy fingerprint mismatch");
        validator.validate(
            _identityJson(
                bytes32(uint256(1)),
                address(implementation),
                address(implementation).codehash,
                address(0),
                authority,
                "2.0.0"
            ),
            proxy
        );
    }

    function test_rejectsImplementationAddressMismatch() public {
        vm.expectRevert("identity implementation mismatch");
        validator.validate(
            _identityJson(proxy.codehash, address(1), address(implementation).codehash, address(0), authority, "2.0.0"),
            proxy
        );
    }

    function test_rejectsImplementationCodehashMismatch() public {
        vm.expectRevert("identity implementation fingerprint mismatch");
        validator.validate(
            _identityJson(proxy.codehash, address(implementation), bytes32(uint256(1)), address(0), authority, "2.0.0"),
            proxy
        );
    }

    function test_rejectsAdminSlotMismatch() public {
        vm.store(proxy, ADMIN_SLOT, bytes32(uint256(uint160(address(2)))));
        vm.expectRevert("identity ERC1967 admin mismatch");
        validator.validate(
            _identityJson(
                proxy.codehash,
                address(implementation),
                address(implementation).codehash,
                address(0),
                authority,
                "2.0.0"
            ),
            proxy
        );
    }

    function test_rejectsOwnerMismatch() public {
        vm.expectRevert("identity owner mismatch");
        validator.validate(
            _identityJson(
                proxy.codehash,
                address(implementation),
                address(implementation).codehash,
                address(0),
                address(3),
                "2.0.0"
            ),
            proxy
        );
    }

    function test_rejectsVersionMismatch() public {
        vm.expectRevert("identity version mismatch");
        validator.validate(
            _identityJson(
                proxy.codehash,
                address(implementation),
                address(implementation).codehash,
                address(0),
                authority,
                "3.0.0"
            ),
            proxy
        );
    }

    function test_rejectsImplementationWithoutCode() public {
        address missingImplementation = address(4);
        vm.store(proxy, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(missingImplementation))));
        vm.expectRevert("identity implementation has no code");
        validator.validate(
            _identityJson(proxy.codehash, missingImplementation, bytes32(uint256(1)), address(0), authority, "2.0.0"),
            proxy
        );
    }

    function _identityJson(
        bytes32 proxyHash,
        address expectedImplementation,
        bytes32 implementationHash,
        address admin,
        address owner,
        string memory version
    ) private returns (string memory json) {
        string memory object = "identity";
        vm.serializeAddress(object, "proxy", proxy);
        vm.serializeBytes32(object, "proxyRuntimeCodehash", proxyHash);
        vm.serializeAddress(object, "implementation", expectedImplementation);
        vm.serializeBytes32(object, "implementationRuntimeCodehash", implementationHash);
        vm.serializeAddress(object, "erc1967Admin", admin);
        vm.serializeAddress(object, "upgradeAuthority", owner);
        string memory identity = vm.serializeString(object, "version", version);
        return string.concat('{"external":{"identityRegistry":', identity, "}}");
    }
}
