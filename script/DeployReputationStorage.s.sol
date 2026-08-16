// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script} from "forge-std/Script.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {IEAS, ISchemaRegistry} from "../src/interfaces/IEAS.sol";
import {ReputationSchemas} from "../src/reputation/ReputationSchemas.sol";

/// @notice Deploys and finalizes the fresh standard-order reputation resolver.
contract DeployReputationStorage is Script {
    function run() external returns (address proxyAddress, bytes32 outcomeSchema, bytes32 confirmationSchema) {
        uint256 adminPrivateKey = vm.envUint("STANDARD_REPUTATION_ADMIN_PRIVATE_KEY");
        address admin = vm.addr(adminPrivateKey);
        address orderSigner = vm.envAddress("STANDARD_REPUTATION_ORDER_SIGNER");
        address identityRegistry = vm.envAddress("IDENTITY_REGISTRY_ADDRESS");
        address providerRegistry = vm.envAddress("PROVIDER_REGISTRY_ADDRESS");
        address serviceRegistry = vm.envAddress("SERVICE_REGISTRY_ADDRESS");
        address sanctionsOracle = vm.envAddress("SANCTIONS_ORACLE_ADDRESS");
        address canonicalToken = vm.envAddress("STANDARD_RAIL_CANONICAL_TOKEN");
        address easAddress = vm.envAddress("EAS_ADDRESS");

        require(orderSigner != admin, "order signer must be independent");

        vm.startBroadcast(adminPrivateKey);
        ReputationStorage implementation = new ReputationStorage();
        ReputationStorage reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        ReputationStorage.initialize,
                        (
                            orderSigner,
                            identityRegistry,
                            providerRegistry,
                            serviceRegistry,
                            sanctionsOracle,
                            canonicalToken,
                            admin
                        )
                    )
                )
            )
        );
        reputation.setEAS(easAddress);
        ISchemaRegistry schemaRegistry = IEAS(easAddress).getSchemaRegistry();
        outcomeSchema = _registerOrLoad(schemaRegistry, ReputationSchemas.outcomeSchema(), address(reputation), false);
        confirmationSchema =
            _registerOrLoad(schemaRegistry, ReputationSchemas.confirmationSchema(), address(reputation), true);
        reputation.setOutcomeSchema(outcomeSchema);
        reputation.setConfirmationSchema(confirmationSchema);
        reputation.finalizeConfiguration();
        vm.stopBroadcast();

        proxyAddress = address(reputation);
    }

    function _registerOrLoad(ISchemaRegistry registry, string memory schema, address resolver, bool revocable)
        private
        returns (bytes32 uid)
    {
        uid = keccak256(abi.encodePacked(schema, resolver, revocable));
        if (registry.getSchema(uid).uid == bytes32(0)) {
            uid = registry.register(schema, resolver, revocable);
        }
    }
}
