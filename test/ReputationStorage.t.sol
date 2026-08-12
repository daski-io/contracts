// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {IPaymentRouter} from "../src/interfaces/IPaymentRouter.sol";
import {Attestation} from "../src/interfaces/IEAS.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";

contract HistoricalPaymentRecordSource {
    mapping(uint256 => IPaymentRouter.PaymentRecord) private _payments;

    function setPayment(uint256 paymentId, IPaymentRouter.PaymentRecord calldata payment) external {
        _payments[paymentId] = payment;
    }

    function getPayment(uint256 paymentId) external view returns (IPaymentRouter.PaymentRecord memory) {
        return _payments[paymentId];
    }

    function recordPayment(ReputationStorage reputation, uint256 paymentId) external {
        reputation.recordPayment(paymentId);
    }

    function recordRefund(ReputationStorage reputation, uint256 paymentId, uint256 amount) external {
        reputation.recordRefund(paymentId, amount);
    }
}

contract ReputationStorageTest is Test {
    address private admin = makeAddr("admin");
    address private provider = makeAddr("provider");
    address private buyer = makeAddr("buyer");
    HistoricalPaymentRecordSource private source;
    ReputationStorage private reputation;
    MockEAS private eas;
    MockSanctionsList private sanctions;
    bytes32 private outcomeSchema;
    bytes32 private confirmationSchema;

    function setUp() public {
        source = new HistoricalPaymentRecordSource();
        sanctions = new MockSanctionsList();
        ReputationStorage implementation = new ReputationStorage();
        reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(ReputationStorage.initialize, (address(source), address(sanctions), admin))
                )
            )
        );
        eas = new MockEAS();
        outcomeSchema = eas.register("uint256 paymentId,uint8 outcome", address(reputation), false);
        confirmationSchema = eas.register("uint256 paymentId,uint8 confirmation", address(reputation), true);
        vm.startPrank(admin);
        reputation.setEAS(address(eas));
        reputation.setOutcomeSchema(outcomeSchema);
        reputation.setConfirmationSchema(confirmationSchema);
        reputation.finalizeConfiguration();
        vm.stopPrank();
    }

    function test_historicalPaymentAccountingAndAttestationsRemainReadable() public {
        uint256 paymentId = 1;
        bytes32 serviceId = keccak256("domain-management");
        source.setPayment(
            paymentId,
            IPaymentRouter.PaymentRecord({
                buyerAgentId: 11,
                providerAgentId: 22,
                serviceId: serviceId,
                token: makeAddr("usdc"),
                amount: 100e6,
                cachedBuyerWallet: buyer,
                cachedProviderOwner: provider,
                cachedProviderWallet: provider,
                serviceRef: keccak256("historical-order"),
                paidAt: block.timestamp,
                reputationEligible: true
            })
        );
        source.recordPayment(reputation, paymentId);

        Attestation memory outcome = _attestation(
            keccak256("outcome"), outcomeSchema, provider, provider, abi.encode(paymentId, uint8(0)), false
        );
        vm.prank(address(eas));
        assertTrue(reputation.attest(outcome));

        Attestation memory confirmation = _attestation(
            keccak256("confirmation"), confirmationSchema, buyer, provider, abi.encode(paymentId, uint8(1)), true
        );
        vm.prank(address(eas));
        assertTrue(reputation.attest(confirmation));

        (uint256 completed,,, uint256 confirmed,, uint256 transactions) = reputation.getProviderStats(22);
        assertEq(completed, 1);
        assertEq(confirmed, 1);
        assertEq(transactions, 1);
        (,,,,, uint256 refunded, uint256 serviceTransactions) = reputation.getServiceStats(serviceId);
        assertEq(refunded, 0);
        assertEq(serviceTransactions, 1);
    }

    function test_onlyHistoricalSourceCanRecordPayment() public {
        vm.expectRevert("not payment router");
        reputation.recordPayment(1);
    }

    function test_refundAccountingUsesHistoricalRecordOnly() public {
        uint256 paymentId = 2;
        bytes32 serviceId = keccak256("mailboxes");
        source.setPayment(
            paymentId,
            IPaymentRouter.PaymentRecord({
                buyerAgentId: 33,
                providerAgentId: 44,
                serviceId: serviceId,
                token: makeAddr("usdc"),
                amount: 25e6,
                cachedBuyerWallet: buyer,
                cachedProviderOwner: provider,
                cachedProviderWallet: provider,
                serviceRef: keccak256("historical-refund"),
                paidAt: block.timestamp,
                reputationEligible: true
            })
        );
        source.recordPayment(reputation, paymentId);
        source.recordRefund(reputation, paymentId, 5e6);
        assertEq(reputation.refundedAmount(paymentId), 5e6);
        (,,,,, uint256 refunded,) = reputation.getServiceStats(serviceId);
        assertEq(refunded, 5e6);
    }

    function _attestation(
        bytes32 uid,
        bytes32 schema,
        address attester,
        address recipient,
        bytes memory data,
        bool revocable
    ) private view returns (Attestation memory) {
        return Attestation({
            uid: uid,
            schema: schema,
            time: uint64(block.timestamp),
            expirationTime: 0,
            revocationTime: 0,
            refUID: bytes32(0),
            recipient: recipient,
            attester: attester,
            revocable: revocable,
            data: data
        });
    }
}
