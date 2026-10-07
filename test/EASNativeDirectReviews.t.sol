// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReputationTestBase,
    RegistryCodeStub,
    ProviderRegistryStub,
    ServiceRegistryStub
} from "./helpers/ReputationTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {
    AttestationRequest,
    AttestationRequestData,
    ISchemaRegistry,
    RevocationRequest,
    RevocationRequestData
} from "../src/interfaces/IEAS.sol";

/// The smallest contract account: its owner has it call another contract.
/// Stands in for an ERC-4337 account such as a Circle agent wallet, whose
/// user operation reaches EAS as a call from the account itself.
contract ContractAccount {
    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == owner, "not owner");
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
    }
}

/// Direct delivery reviews from a contract-account payer against the actual
/// pinned EAS runtimes: the calls the buyer CLI validates and a contract
/// wallet sends itself, with no delegated signature.
abstract contract NativeEASDirectReviewTest is ReputationTestBase {
    address internal constant NATIVE_EAS = 0x4200000000000000000000000000000000000021;
    address internal constant REGISTRY = 0x4200000000000000000000000000000000000020;
    bytes32 internal constant ORDER = keccak256("native-eas-direct-review");
    bytes32 internal constant ATTESTED = keccak256("Attested(address,address,bytes32,bytes32)");
    bytes32 internal constant REVOKED = keccak256("Revoked(address,address,bytes32,bytes32)");
    address internal accountOwner = makeAddr("account-owner");
    ContractAccount internal account;

    function _legacy() internal pure virtual returns (bool);

    function setUp() public override {
        string memory fixture =
            vm.readFile(_legacy() ? "test/vectors/eas/base-8453.json" : "test/vectors/eas/base-84532.json");
        vm.chainId(_legacy() ? 8453 : 84532);
        vm.warp(1_790_000_000);
        bytes memory code = vm.parseJsonBytes(fixture, ".eas.runtimeCode");
        assertEq(keccak256(code), vm.parseJsonBytes32(fixture, ".eas.runtimeCodeHash"));
        vm.etch(NATIVE_EAS, code);
        code = vm.parseJsonBytes(fixture, ".schemaRegistry.runtimeCode");
        assertEq(keccak256(code), vm.parseJsonBytes32(fixture, ".schemaRegistry.runtimeCodeHash"));
        vm.etch(REGISTRY, code);
        account = new ContractAccount(accountOwner);
        payer = address(account);
        identity = new RegistryCodeStub();
        providers = new ProviderRegistryStub();
        services = new ServiceRegistryStub();
        sanctions = new MockSanctionsList();
        token = address(new RegistryCodeStub());
        providers.setRegistered(PROVIDER_AGENT_ID, true);
        services.setService(serviceId, PROVIDER_AGENT_ID);
        reputation = ReputationStorage(
            address(
                new ERC1967Proxy(
                    address(new ReputationStorage()),
                    abi.encodeCall(
                        ReputationStorage.initialize,
                        (
                            vm.addr(ORDER_SIGNER_KEY),
                            address(identity),
                            address(providers),
                            address(services),
                            address(sanctions),
                            token,
                            admin
                        )
                    )
                )
            )
        );
        eas = MockEAS(NATIVE_EAS);
        outcomeSchema = ISchemaRegistry(REGISTRY).register("bytes32 orderKey,uint8 outcome", address(reputation), false);
        confirmationSchema =
            ISchemaRegistry(REGISTRY).register("bytes32 orderKey,uint8 confirmation", address(reputation), true);
        vm.startPrank(admin);
        reputation.setEAS(NATIVE_EAS);
        reputation.setOutcomeSchema(outcomeSchema);
        reputation.setConfirmationSchema(confirmationSchema);
        reputation.finalizeConfiguration();
        vm.stopPrank();
        _register(_permit(ORDER));
    }

    /// The buyer's validated attest call: attest((bytes32,(address,uint64,bool,bytes32,bytes,uint256))).
    function _attestCall(uint8 choice, bytes32 refUID) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            bytes4(0xf17325e7),
            AttestationRequest(
                confirmationSchema,
                AttestationRequestData(providerWallet, 0, true, refUID, abi.encode(ORDER, choice), 0)
            )
        );
    }

    /// The buyer's validated revoke call: revoke((bytes32,(bytes32,uint256))).
    function _revokeCall(bytes32 uid) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            bytes4(0x46926267), RevocationRequest(confirmationSchema, RevocationRequestData(uid, 0))
        );
    }

    function _send(ContractAccount from, bytes memory callData) internal returns (bytes memory) {
        vm.prank(accountOwner);
        return from.execute(NATIVE_EAS, callData);
    }

    /// The uid of the one event EAS emitted with these indexed topics, as the buyer reads a receipt.
    function _eventUid(Vm.Log[] memory logs, bytes32 topic, address attester) internal view returns (bytes32 uid) {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != NATIVE_EAS || logs[i].topics.length != 4 || logs[i].topics[0] != topic) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(providerWallet))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(attester))));
            assertEq(logs[i].topics[3], confirmationSchema);
            uid = abi.decode(logs[i].data, (bytes32));
            ++found;
        }
        assertEq(found, 1);
    }

    function test_contractAccountAttestsAndRevokesDirectly() public {
        vm.recordLogs();
        bytes32 uid = abi.decode(_send(account, _attestCall(1, bytes32(0))), (bytes32));
        assertEq(_eventUid(vm.getRecordedLogs(), ATTESTED, address(account)), uid);
        assertEq(eas.getAttestation(uid).attester, address(account));
        assertEq(eas.getAttestation(uid).recipient, providerWallet);
        ReputationStorageBase.ReputationRecord memory record = reputation.getRecord(ORDER);
        assertEq(record.currentConfirmationUid, uid);
        assertEq(record.confirmationSubmissions, 1);
        assertEq(uint8(record.confirmation), 1);

        vm.recordLogs();
        _send(account, _revokeCall(uid));
        assertEq(_eventUid(vm.getRecordedLogs(), REVOKED, address(account)), uid);
        assertGt(eas.getAttestation(uid).revocationTime, 0);
        assertEq(reputation.getRecord(ORDER).currentConfirmationUid, bytes32(0));
        // Direct calls never touch the delegated nonce.
        assertEq(eas.getNonce(address(account)), 0);
    }

    function test_directReviewsChainAndKeepTheThreeSubmissionCap() public {
        bytes32 uid = abi.decode(_send(account, _attestCall(1, bytes32(0))), (bytes32));
        uid = abi.decode(_send(account, _attestCall(2, uid)), (bytes32));
        uid = abi.decode(_send(account, _attestCall(1, uid)), (bytes32));
        assertEq(reputation.getRecord(ORDER).confirmationSubmissions, 3);
        bytes memory fourth = _attestCall(2, uid);
        vm.prank(accountOwner);
        vm.expectRevert(ReputationStorageBase.ConfirmationSubmissionCap.selector);
        account.execute(NATIVE_EAS, fourth);
        _send(account, _revokeCall(uid));
        assertEq(reputation.getRecord(ORDER).currentConfirmationUid, bytes32(0));
    }

    function test_aStaleReferenceOrAnotherAccountIsRefused() public {
        bytes32 uid = abi.decode(_send(account, _attestCall(1, bytes32(0))), (bytes32));
        // The same prepared call again: its refUID is no longer the current review.
        bytes memory stale = _attestCall(1, bytes32(0));
        vm.prank(accountOwner);
        vm.expectRevert(ReputationStorageBase.MustReferenceCurrentConfirmation.selector);
        account.execute(NATIVE_EAS, stale);
        ContractAccount stranger = new ContractAccount(accountOwner);
        bytes memory foreign = _attestCall(1, uid);
        vm.prank(accountOwner);
        vm.expectRevert(ReputationStorageBase.NotOrderPayer.selector);
        stranger.execute(NATIVE_EAS, foreign);
        assertEq(reputation.getRecord(ORDER).confirmationSubmissions, 1);
    }
}

contract EASLegacy101DirectReviewTest is NativeEASDirectReviewTest {
    function _legacy() internal pure override returns (bool) {
        return true;
    }
}

contract EASDeadline120DirectReviewTest is NativeEASDirectReviewTest {
    function _legacy() internal pure override returns (bool) {
        return false;
    }
}
