// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISanctionsGuard} from "../src/interfaces/ISanctionsGuard.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {ReputationTestBase} from "./helpers/ReputationTestBase.sol";

contract ReputationRefundSanctionsTest is ReputationTestBase {
    function test_refundRechecksEveryStoredParticipantForSanctions() public {
        bytes32 orderKey = keccak256("refund-sanctions");
        ReputationStorageBase.StandardReputationOrderV1 memory order = _permit(orderKey);
        _register(order);
        ReputationStorageBase.StandardReputationRefundV1 memory refund = _refundPermit(order);
        bytes memory signature = _refundSignature(refund);
        address[4] memory participants = [payer, providerOwner, providerWallet, providerPayee];

        for (uint256 i = 0; i < participants.length; i++) {
            sanctions.setSanctioned(participants[i], true);
            vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionedAddress.selector, participants[i]));
            reputation.recordRefund(refund, signature);
            sanctions.setSanctioned(participants[i], false);
        }

        assertEq(reputation.refundedAmount(orderKey), 0);
    }

    function test_refundFailsClosedWhenSanctionsOracleIsUnavailable() public {
        bytes32 orderKey = keccak256("refund-oracle-unavailable");
        ReputationStorageBase.StandardReputationOrderV1 memory order = _permit(orderKey);
        _register(order);
        ReputationStorageBase.StandardReputationRefundV1 memory refund = _refundPermit(order);
        bytes memory signature = _refundSignature(refund);

        sanctions.setRevertChecks(true);
        vm.expectRevert(abi.encodeWithSelector(ISanctionsGuard.SanctionsOracleUnavailable.selector, address(sanctions)));
        reputation.recordRefund(refund, signature);

        assertEq(reputation.refundedAmount(orderKey), 0);
    }

    function _refundPermit(ReputationStorageBase.StandardReputationOrderV1 memory order)
        private
        view
        returns (ReputationStorageBase.StandardReputationRefundV1 memory)
    {
        return ReputationStorageBase.StandardReputationRefundV1({
            orderKey: order.orderKey,
            authorizationKey: order.authorizationKey,
            cumulativeRefundedAmount: 1,
            refundEvidenceHash: keccak256("refund-evidence"),
            validBefore: uint64(block.timestamp + 5 minutes)
        });
    }
}
