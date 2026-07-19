// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {ISchemaResolver} from "../src/interfaces/ISchemaResolver.sol";
import {
    Attestation,
    AttestationRequest,
    AttestationRequestData,
    RevocationRequest,
    RevocationRequestData
} from "../src/interfaces/IEAS.sol";

contract PermissiveResolver is ISchemaResolver {
    function version() external pure returns (string memory) {
        return "1";
    }

    function isPayable() external pure returns (bool) {
        return false;
    }

    function attest(Attestation calldata) external payable returns (bool) {
        return true;
    }

    function multiAttest(Attestation[] calldata, uint256[] calldata) external payable returns (bool) {
        return true;
    }

    function revoke(Attestation calldata) external payable returns (bool) {
        return true;
    }

    function multiRevoke(Attestation[] calldata, uint256[] calldata) external payable returns (bool) {
        return true;
    }
}

contract MockEASTest is Test {
    function test_revocableSchemaCannotRevokeIrrevocableAttestation() public {
        MockEAS eas = new MockEAS();
        PermissiveResolver resolver = new PermissiveResolver();
        bytes32 schema = eas.register("bytes data", address(resolver), true);
        AttestationRequest memory request = AttestationRequest({
            schema: schema,
            data: AttestationRequestData({
                recipient: address(this),
                expirationTime: 0,
                revocable: false,
                refUID: bytes32(0),
                data: bytes("data"),
                value: 0
            })
        });
        bytes32 uid = eas.attest(request);

        vm.expectRevert("attestation not revocable");
        eas.revoke(RevocationRequest({schema: schema, data: RevocationRequestData({uid: uid, value: 0})}));
    }
}
