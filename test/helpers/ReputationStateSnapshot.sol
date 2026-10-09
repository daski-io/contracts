// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReputationStorageBase} from "../../src/reputation/ReputationStorageBase.sol";

/// Every getter of the reviewed 2.1.0 resolver ABI.
interface IReputationGetters210 {
    function MAX_CONFIRMATION_SUBMISSIONS() external view returns (uint8);
    function ORDER_TYPEHASH() external view returns (bytes32);
    function PROVIDER_IDENTITY_SNAPSHOT_V1_TYPEHASH() external view returns (bytes32);
    function REFUND_TYPEHASH() external view returns (bytes32);
    function UPGRADE_INTERFACE_VERSION() external view returns (string memory);
    function admin() external view returns (address);
    function canonicalToken() external view returns (address);
    function confirmationSchema() external view returns (bytes32);
    function eas() external view returns (address);
    function eip712Domain()
        external
        view
        returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
    function expectedConfirmationSchemaHash() external pure returns (bytes32);
    function expectedOutcomeSchemaHash() external pure returns (bytes32);
    function externalDependencyPaused() external view returns (bool);
    function getRecordCount() external view returns (uint256);
    function identityRegistry() external view returns (address);
    function isConfigured() external view returns (bool);
    function isPayable() external pure returns (bool);
    function orderSigner() external view returns (address);
    function outcomeSchema() external view returns (bytes32);
    function pauseGuardian() external view returns (address);
    function pendingAdmin() external view returns (address);
    function providerRegistry() external view returns (address);
    function sanctionsOracle() external view returns (address);
    function serviceRegistry() external view returns (address);

    function getRecord(bytes32 orderKey) external view returns (ReputationStorageBase.ReputationRecord memory);
    function refundedAmount(bytes32 orderKey) external view returns (uint256);
    function authorizationKeyUsed(bytes32 authorizationKey) external view returns (bool);
    function confirmationByUid(bytes32 uid) external view returns (uint8);
    function orderKeyByConfirmationUid(bytes32 uid) external view returns (bytes32);
    function recordKeys(uint256 index) external view returns (bytes32);

    function getProviderStats(uint256 id) external view returns (uint256, uint256, uint256, uint256, uint256, uint256);
    function completedCount(uint256 id) external view returns (uint256);
    function failedCount(uint256 id) external view returns (uint256);
    function canceledCount(uint256 id) external view returns (uint256);
    function confirmedCount(uint256 id) external view returns (uint256);
    function notConfirmedCount(uint256 id) external view returns (uint256);
    function providerTransactionCount(uint256 id) external view returns (uint256);
    function totalPaidByProvider(uint256 id) external view returns (uint256);
    function refundedAmountByProvider(uint256 id) external view returns (uint256);
    function outcomeDelayTotalByProvider(uint256 id) external view returns (uint256);
    function confirmedWeightByProvider(uint256 id) external view returns (uint256);
    function notConfirmedWeightByProvider(uint256 id) external view returns (uint256);

    function getServiceStats(bytes32 id)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256);
    function completedByService(bytes32 id) external view returns (uint256);
    function failedByService(bytes32 id) external view returns (uint256);
    function canceledByService(bytes32 id) external view returns (uint256);
    function confirmedByService(bytes32 id) external view returns (uint256);
    function notConfirmedByService(bytes32 id) external view returns (uint256);
    function serviceTransactionCount(bytes32 id) external view returns (uint256);
    function totalPaidByService(bytes32 id) external view returns (uint256);
    function refundedAmountByService(bytes32 id) external view returns (uint256);
    function confirmedWeightByService(bytes32 id) external view returns (uint256);
    function notConfirmedWeightByService(bytes32 id) external view returns (uint256);

    function getBuyerStats(address payer) external view returns (uint256, uint256, uint256);
    function payerTransactionCount(address payer) external view returns (uint256);
    function payerConfirmedCount(address payer) external view returns (uint256);
    function payerNotConfirmedCount(address payer) external view returns (uint256);
    function totalPaidByPayer(address payer) external view returns (uint256);
    function refundedAmountByPayer(address payer) external view returns (uint256);
}

/// Before/after evidence that a change left the resolver's existing state alone:
/// the raw return data of every getter the 2.1.0 resolver exposes, and the raw
/// storage words of its reviewed layout (storage-layout/baseline.json) and of
/// every populated record, index and counter.
abstract contract ReputationStateSnapshot is Test {
    struct SnapshotKeys {
        bytes32[] orders;
        bytes32[] authorizations;
        bytes32[] confirmationUids;
        uint256[] providers;
        bytes32[] services;
        address[] payers;
    }

    /// Slots 0..180: the shared base, the reputation state and its trailing gap.
    uint256 internal constant LAYOUT_SLOTS = 181;
    uint256 internal constant RECORDS_SLOT = 100;
    uint256 internal constant RECORD_KEYS_SLOT = 101;
    uint256 internal constant AUTHORIZATION_KEY_USED_SLOT = 102;
    uint256 internal constant REFUNDED_AMOUNT_SLOT = 103;
    uint256 internal constant CONFIRMATION_BY_UID_SLOT = 104;
    uint256 internal constant ORDER_KEY_BY_CONFIRMATION_UID_SLOT = 105;
    uint256 internal constant RECORD_WORDS = 16;
    /// ERC-7201 namespaces of OpenZeppelin Initializable and EIP712 (four words).
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 internal constant EIP712_SLOT = 0xa16a46d94261c7517cc8ff89f61c0ce93598e3c849801011dee649a6a557d100;
    uint256 internal constant NAMESPACE_WORDS = 5;

    function _getterResults(address target, SnapshotKeys memory keys) internal view returns (bytes[] memory results) {
        bytes[] memory calls = _getterCalls(target, keys);
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory data) = target.staticcall(calls[i]);
            assertTrue(ok, "getter reverted");
            results[i] = data;
        }
    }

    function _assertSameResults(bytes[] memory before, bytes[] memory afterwards) internal pure {
        assertEq(before.length, afterwards.length, "getter count");
        for (uint256 i; i < before.length; ++i) {
            assertEq(before[i], afterwards[i], string.concat("getter result ", vm.toString(i)));
        }
    }

    function _getterCalls(address target, SnapshotKeys memory keys) internal view returns (bytes[] memory calls) {
        uint256 records = IReputationGetters210(target).getRecordCount();
        calls = new bytes[](
            _globalSelectors().length + keys.orders.length * 2 + keys.authorizations.length
                + keys.confirmationUids.length * 2 + records + keys.providers.length * _providerSelectors().length
                + keys.services.length * _serviceSelectors().length + keys.payers.length * _payerSelectors().length
        );
        uint256 n = _append(calls, 0, _globalSelectors(), "");
        for (uint256 i; i < keys.orders.length; ++i) {
            n = _append(calls, n, _orderSelectors(), abi.encode(keys.orders[i]));
        }
        for (uint256 i; i < keys.authorizations.length; ++i) {
            n = _append(
                calls,
                n,
                _single(IReputationGetters210.authorizationKeyUsed.selector),
                abi.encode(keys.authorizations[i])
            );
        }
        for (uint256 i; i < keys.confirmationUids.length; ++i) {
            n = _append(calls, n, _confirmationSelectors(), abi.encode(keys.confirmationUids[i]));
        }
        for (uint256 i; i < records; ++i) {
            n = _append(calls, n, _single(IReputationGetters210.recordKeys.selector), abi.encode(i));
        }
        for (uint256 i; i < keys.providers.length; ++i) {
            n = _append(calls, n, _providerSelectors(), abi.encode(keys.providers[i]));
        }
        for (uint256 i; i < keys.services.length; ++i) {
            n = _append(calls, n, _serviceSelectors(), abi.encode(keys.services[i]));
        }
        for (uint256 i; i < keys.payers.length; ++i) {
            n = _append(calls, n, _payerSelectors(), abi.encode(keys.payers[i]));
        }
        assertEq(n, calls.length);
    }

    function _rawWords(address target, SnapshotKeys memory keys) internal view returns (bytes32[] memory words) {
        uint256 records = IReputationGetters210(target).getRecordCount();
        words = new bytes32[](
            LAYOUT_SLOTS + NAMESPACE_WORDS + keys.orders.length * (RECORD_WORDS + 1) + records
                + keys.authorizations.length + keys.confirmationUids.length * 2 + keys.providers.length * 11
                + keys.services.length * 10 + keys.payers.length * 5
        );
        uint256 n;
        for (uint256 slot; slot < LAYOUT_SLOTS; ++slot) {
            words[n++] = vm.load(target, bytes32(slot));
        }
        words[n++] = vm.load(target, INITIALIZABLE_SLOT);
        for (uint256 i; i < NAMESPACE_WORDS - 1; ++i) {
            words[n++] = vm.load(target, bytes32(uint256(EIP712_SLOT) + i));
        }
        for (uint256 i; i < keys.orders.length; ++i) {
            n = _loadRun(target, words, n, _mappingSlot(keys.orders[i], RECORDS_SLOT), RECORD_WORDS);
            n = _loadRun(target, words, n, _mappingSlot(keys.orders[i], REFUNDED_AMOUNT_SLOT), 1);
        }
        n = _loadRun(target, words, n, uint256(keccak256(abi.encode(RECORD_KEYS_SLOT))), records);
        for (uint256 i; i < keys.authorizations.length; ++i) {
            n = _loadRun(target, words, n, _mappingSlot(keys.authorizations[i], AUTHORIZATION_KEY_USED_SLOT), 1);
        }
        for (uint256 i; i < keys.confirmationUids.length; ++i) {
            n = _loadRun(target, words, n, _mappingSlot(keys.confirmationUids[i], CONFIRMATION_BY_UID_SLOT), 1);
            n = _loadRun(
                target, words, n, _mappingSlot(keys.confirmationUids[i], ORDER_KEY_BY_CONFIRMATION_UID_SLOT), 1
            );
        }
        for (uint256 i; i < keys.providers.length; ++i) {
            n = _loadMappings(target, words, n, bytes32(keys.providers[i]), _providerMappingSlots());
        }
        for (uint256 i; i < keys.services.length; ++i) {
            n = _loadMappings(target, words, n, keys.services[i], _serviceMappingSlots());
        }
        for (uint256 i; i < keys.payers.length; ++i) {
            n = _loadMappings(target, words, n, bytes32(uint256(uint160(keys.payers[i]))), _payerMappingSlots());
        }
        assertEq(n, words.length);
    }

    function _mappingSlot(bytes32 key, uint256 slot) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, slot)));
    }

    function _append(bytes[] memory calls, uint256 n, bytes4[] memory selectors, bytes memory argument)
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < selectors.length; ++i) {
            calls[n++] = bytes.concat(selectors[i], argument);
        }
        return n;
    }

    function _loadRun(address target, bytes32[] memory words, uint256 n, uint256 first, uint256 count)
        private
        view
        returns (uint256)
    {
        for (uint256 i; i < count; ++i) {
            words[n++] = vm.load(target, bytes32(first + i));
        }
        return n;
    }

    function _loadMappings(address target, bytes32[] memory words, uint256 n, bytes32 key, uint256[] memory slots)
        private
        view
        returns (uint256)
    {
        for (uint256 i; i < slots.length; ++i) {
            words[n++] = vm.load(target, bytes32(_mappingSlot(key, slots[i])));
        }
        return n;
    }

    function _single(bytes4 selector) private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    /// Every argument-free getter of the 2.1.0 ABI except version(), which an upgrade changes, and
    /// proxiableUUID(), which is not callable through the proxy.
    function _globalSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](24);
        s[0] = IReputationGetters210.MAX_CONFIRMATION_SUBMISSIONS.selector;
        s[1] = IReputationGetters210.ORDER_TYPEHASH.selector;
        s[2] = IReputationGetters210.PROVIDER_IDENTITY_SNAPSHOT_V1_TYPEHASH.selector;
        s[3] = IReputationGetters210.REFUND_TYPEHASH.selector;
        s[4] = IReputationGetters210.UPGRADE_INTERFACE_VERSION.selector;
        s[5] = IReputationGetters210.admin.selector;
        s[6] = IReputationGetters210.canonicalToken.selector;
        s[7] = IReputationGetters210.confirmationSchema.selector;
        s[8] = IReputationGetters210.eas.selector;
        s[9] = IReputationGetters210.eip712Domain.selector;
        s[10] = IReputationGetters210.expectedConfirmationSchemaHash.selector;
        s[11] = IReputationGetters210.expectedOutcomeSchemaHash.selector;
        s[12] = IReputationGetters210.externalDependencyPaused.selector;
        s[13] = IReputationGetters210.getRecordCount.selector;
        s[14] = IReputationGetters210.identityRegistry.selector;
        s[15] = IReputationGetters210.isConfigured.selector;
        s[16] = IReputationGetters210.isPayable.selector;
        s[17] = IReputationGetters210.orderSigner.selector;
        s[18] = IReputationGetters210.outcomeSchema.selector;
        s[19] = IReputationGetters210.pauseGuardian.selector;
        s[20] = IReputationGetters210.pendingAdmin.selector;
        s[21] = IReputationGetters210.providerRegistry.selector;
        s[22] = IReputationGetters210.sanctionsOracle.selector;
        s[23] = IReputationGetters210.serviceRegistry.selector;
    }

    function _orderSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = IReputationGetters210.getRecord.selector;
        s[1] = IReputationGetters210.refundedAmount.selector;
    }

    function _confirmationSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = IReputationGetters210.confirmationByUid.selector;
        s[1] = IReputationGetters210.orderKeyByConfirmationUid.selector;
    }

    function _providerSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = IReputationGetters210.getProviderStats.selector;
        s[1] = IReputationGetters210.completedCount.selector;
        s[2] = IReputationGetters210.failedCount.selector;
        s[3] = IReputationGetters210.canceledCount.selector;
        s[4] = IReputationGetters210.confirmedCount.selector;
        s[5] = IReputationGetters210.notConfirmedCount.selector;
        s[6] = IReputationGetters210.providerTransactionCount.selector;
        s[7] = IReputationGetters210.totalPaidByProvider.selector;
        s[8] = IReputationGetters210.refundedAmountByProvider.selector;
        s[9] = IReputationGetters210.outcomeDelayTotalByProvider.selector;
        s[10] = IReputationGetters210.confirmedWeightByProvider.selector;
        s[11] = IReputationGetters210.notConfirmedWeightByProvider.selector;
    }

    function _serviceSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = IReputationGetters210.getServiceStats.selector;
        s[1] = IReputationGetters210.completedByService.selector;
        s[2] = IReputationGetters210.failedByService.selector;
        s[3] = IReputationGetters210.canceledByService.selector;
        s[4] = IReputationGetters210.confirmedByService.selector;
        s[5] = IReputationGetters210.notConfirmedByService.selector;
        s[6] = IReputationGetters210.serviceTransactionCount.selector;
        s[7] = IReputationGetters210.totalPaidByService.selector;
        s[8] = IReputationGetters210.refundedAmountByService.selector;
        s[9] = IReputationGetters210.confirmedWeightByService.selector;
        s[10] = IReputationGetters210.notConfirmedWeightByService.selector;
    }

    function _payerSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = IReputationGetters210.getBuyerStats.selector;
        s[1] = IReputationGetters210.payerTransactionCount.selector;
        s[2] = IReputationGetters210.payerConfirmedCount.selector;
        s[3] = IReputationGetters210.payerNotConfirmedCount.selector;
        s[4] = IReputationGetters210.totalPaidByPayer.selector;
        s[5] = IReputationGetters210.refundedAmountByPayer.selector;
    }

    /// Per-provider counter mappings of the reviewed layout.
    function _providerMappingSlots() private pure returns (uint256[] memory s) {
        s = new uint256[](11);
        for (uint256 i; i < 9; ++i) {
            s[i] = 106 + i; // completed .. outcomeDelayTotalByProvider
        }
        s[9] = 128; // confirmedWeightByProvider
        s[10] = 129; // notConfirmedWeightByProvider
    }

    /// Per-service counter mappings of the reviewed layout.
    function _serviceMappingSlots() private pure returns (uint256[] memory s) {
        s = new uint256[](10);
        for (uint256 i; i < 8; ++i) {
            s[i] = 115 + i; // completedByService .. refundedAmountByService
        }
        s[8] = 130; // confirmedWeightByService
        s[9] = 131; // notConfirmedWeightByService
    }

    /// Per-payer counter mappings of the reviewed layout.
    function _payerMappingSlots() private pure returns (uint256[] memory s) {
        s = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            s[i] = 123 + i; // payerTransactionCount .. refundedAmountByPayer
        }
    }
}
