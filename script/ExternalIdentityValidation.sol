// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IExternalIdentityMetadata} from "./IExternalIdentityMetadata.sol";

/// @notice Validates the reviewed ERC-1967 identity dependency directly
///         against live proxy storage and metadata.
abstract contract ExternalIdentityValidation is Script {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function _validateExternalIdentityFromManifest(string memory source, address expectedIdentity) internal view {
        address proxy = vm.parseJsonAddress(source, ".external.identityRegistry.proxy");
        require(proxy == expectedIdentity, "identity proxy mismatch");
        require(
            proxy.codehash == vm.parseJsonBytes32(source, ".external.identityRegistry.proxyRuntimeCodehash"),
            "identity proxy fingerprint mismatch"
        );

        address implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        require(
            implementation == vm.parseJsonAddress(source, ".external.identityRegistry.implementation"),
            "identity implementation mismatch"
        );
        require(implementation.code.length > 0, "identity implementation has no code");
        require(
            implementation.codehash
                == vm.parseJsonBytes32(source, ".external.identityRegistry.implementationRuntimeCodehash"),
            "identity implementation fingerprint mismatch"
        );

        address proxyAdmin = address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
        require(
            proxyAdmin == vm.parseJsonAddress(source, ".external.identityRegistry.erc1967Admin"),
            "identity ERC1967 admin mismatch"
        );
        require(
            IExternalIdentityMetadata(proxy).owner()
                == vm.parseJsonAddress(source, ".external.identityRegistry.upgradeAuthority"),
            "identity owner mismatch"
        );
        require(
            keccak256(bytes(IExternalIdentityMetadata(proxy).getVersion()))
                == keccak256(bytes(vm.parseJsonString(source, ".external.identityRegistry.version"))),
            "identity version mismatch"
        );
    }
}
