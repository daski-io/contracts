// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReputationTestBase,
    RegistryCodeStub,
    ProviderRegistryStub,
    ServiceRegistryStub
} from "./helpers/ReputationTestBase.sol";
import {MockSanctionsList} from "./mocks/MockSanctionsList.sol";
import {MockEAS} from "./helpers/MockEAS.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {
    AttestationRequestData,
    EIP712Signature,
    DelegatedAttestationRequest,
    ISchemaRegistry,
    RevocationRequestData
} from "../src/interfaces/IEAS.sol";

interface INativeEAS {
    function version() external view returns (string memory);
    function getDomainSeparator() external view returns (bytes32);
    function getAttestTypeHash() external pure returns (bytes32);
    function getRevokeTypeHash() external pure returns (bytes32);
}

struct LegacyAttestation {
    bytes32 schema;
    AttestationRequestData data;
    EIP712Signature signature;
    address attester;
}

struct DelegatedRevocation {
    bytes32 schema;
    RevocationRequestData data;
    EIP712Signature signature;
    address revoker;
    uint64 deadline;
}

struct LegacyRevocation {
    bytes32 schema;
    RevocationRequestData data;
    EIP712Signature signature;
    address revoker;
}

/// Actual pinned EAS and SchemaRegistry runtime, deployed offline at their
/// canonical addresses. No mock signature verification or live RPC dependency.
abstract contract NativeEASProfileTest is ReputationTestBase {
    uint256 internal constant PAYER_KEY = 0xB0B;
    address internal constant NATIVE_EAS = 0x4200000000000000000000000000000000000021;
    address internal constant REGISTRY = 0x4200000000000000000000000000000000000020;
    bytes32 internal constant ORDER = keccak256("native-eas-review");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant LEGACY_ATTEST = keccak256(
        "Attest(bytes32 schema,address recipient,uint64 expirationTime,bool revocable,bytes32 refUID,bytes data,uint256 nonce)"
    );
    bytes32 internal constant LEGACY_REVOKE = keccak256("Revoke(bytes32 schema,bytes32 uid,uint256 nonce)");
    bytes32 internal constant MODERN_ATTEST = keccak256(
        "Attest(bytes32 schema,address recipient,uint64 expirationTime,bool revocable,bytes32 refUID,bytes data,uint256 value,uint256 nonce,uint64 deadline)"
    );
    bytes32 internal constant MODERN_REVOKE =
        keccak256("Revoke(bytes32 schema,bytes32 uid,uint256 value,uint256 nonce,uint64 deadline)");

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
        assertEq(INativeEAS(NATIVE_EAS).version(), _legacy() ? "1.0.1" : "1.2.0");
        assertEq(INativeEAS(NATIVE_EAS).getDomainSeparator(), vm.parseJsonBytes32(fixture, ".getDomainSeparator"));
        payer = vm.addr(PAYER_KEY);
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

    function _domain(string memory version) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256("EAS"), keccak256(bytes(version)), block.chainid, NATIVE_EAS)
            );
    }

    function _signature(bytes32 structHash, string memory version) internal view returns (EIP712Signature memory sig) {
        (sig.v, sig.r, sig.s) =
            vm.sign(PAYER_KEY, keccak256(abi.encodePacked("\x19\x01", _domain(version), structHash)));
    }

    function _attestRequest(uint8 choice, bytes32 refUID, uint64 deadline)
        internal
        view
        returns (DelegatedAttestationRequest memory req)
    {
        req.schema = confirmationSchema;
        req.data = AttestationRequestData(providerWallet, 0, true, refUID, abi.encode(ORDER, choice), 0);
        req.attester = payer;
        req.deadline = deadline;
        bytes32 hash = _legacy()
            ? keccak256(
                abi.encode(
                    LEGACY_ATTEST,
                    req.schema,
                    req.data.recipient,
                    req.data.expirationTime,
                    req.data.revocable,
                    req.data.refUID,
                    keccak256(req.data.data),
                    eas.getNonce(payer)
                )
            )
            : keccak256(
                abi.encode(
                    MODERN_ATTEST,
                    req.schema,
                    req.data.recipient,
                    req.data.expirationTime,
                    req.data.revocable,
                    req.data.refUID,
                    keccak256(req.data.data),
                    req.data.value,
                    eas.getNonce(payer),
                    deadline
                )
            );
        req.signature = _signature(hash, _legacy() ? "1.0.1" : "1.2.0");
    }

    function _attest(DelegatedAttestationRequest memory req) internal returns (bytes32) {
        bytes memory callData = _legacy()
            ? abi.encodeWithSignature(
                "attestByDelegation((bytes32,(address,uint64,bool,bytes32,bytes,uint256),(uint8,bytes32,bytes32),address))",
                LegacyAttestation(req.schema, req.data, req.signature, req.attester)
            )
            : abi.encodeWithSignature(
                "attestByDelegation((bytes32,(address,uint64,bool,bytes32,bytes,uint256),(uint8,bytes32,bytes32),address,uint64))",
                req
            );
        (bool ok, bytes memory result) = NATIVE_EAS.call(callData);
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
        return abi.decode(result, (bytes32));
    }

    function _revoke(bytes32 uid, uint64 deadline) internal {
        bytes32 hash = _legacy()
            ? keccak256(abi.encode(LEGACY_REVOKE, confirmationSchema, uid, eas.getNonce(payer)))
            : keccak256(abi.encode(MODERN_REVOKE, confirmationSchema, uid, uint256(0), eas.getNonce(payer), deadline));
        EIP712Signature memory sig = _signature(hash, _legacy() ? "1.0.1" : "1.2.0");
        bytes memory callData = _legacy()
            ? abi.encodeWithSignature(
                "revokeByDelegation((bytes32,(bytes32,uint256),(uint8,bytes32,bytes32),address))",
                LegacyRevocation(confirmationSchema, RevocationRequestData(uid, 0), sig, payer)
            )
            : abi.encodeWithSignature(
                "revokeByDelegation((bytes32,(bytes32,uint256),(uint8,bytes32,bytes32),address,uint64))",
                DelegatedRevocation(confirmationSchema, RevocationRequestData(uid, 0), sig, payer, deadline)
            );
        (bool ok, bytes memory result) = NATIVE_EAS.call(callData);
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
    }

    function test_profileDomainAndTypeHashesAreIndependent() public view {
        assertEq(INativeEAS(NATIVE_EAS).getDomainSeparator(), _domain(_legacy() ? "1.0.1" : "1.2.0"));
        assertEq(INativeEAS(NATIVE_EAS).getAttestTypeHash(), _legacy() ? LEGACY_ATTEST : MODERN_ATTEST);
        assertEq(INativeEAS(NATIVE_EAS).getRevokeTypeHash(), _legacy() ? LEGACY_REVOKE : MODERN_REVOKE);
    }

    function test_delegatedAttestAndRevokeConsumeOneSharedNonceAndAttributePayer() public {
        bytes32 uid = _attest(_attestRequest(1, bytes32(0), uint64(block.timestamp + 300)));
        assertEq(eas.getAttestation(uid).attester, payer);
        assertEq(eas.getAttestation(uid).recipient, providerWallet);
        assertEq(eas.getNonce(payer), 1);
        assertEq(reputation.getRecord(ORDER).currentConfirmationUid, uid);
        _revoke(uid, uint64(block.timestamp + 300));
        assertEq(eas.getNonce(payer), 2);
        assertEq(reputation.getRecord(ORDER).currentConfirmationUid, bytes32(0));
    }

    function test_replayAndChangedChoiceFailWithoutConsumingNonce() public {
        DelegatedAttestationRequest memory req = _attestRequest(1, bytes32(0), uint64(block.timestamp + 300));
        req.data.data = abi.encode(ORDER, uint8(2));
        vm.expectRevert();
        _attest(req);
        assertEq(eas.getNonce(payer), 0);
        req.data.data = abi.encode(ORDER, uint8(1));
        _attest(req);
        vm.expectRevert();
        _attest(req);
        assertEq(eas.getNonce(payer), 1);
    }

    function test_realEASPreservesThreeSubmissionCapAndRevocation() public {
        bytes32 uid;
        for (uint256 i; i < 3; ++i) {
            uid = _attest(_attestRequest(1, uid, uint64(block.timestamp + 300)));
        }
        assertEq(reputation.getRecord(ORDER).confirmationSubmissions, 3);
        _revoke(uid, uint64(block.timestamp + 300));
        DelegatedAttestationRequest memory finalRequest = _attestRequest(2, bytes32(0), uint64(block.timestamp + 300));
        vm.expectRevert();
        _attest(finalRequest);
        assertEq(eas.getNonce(payer), 4);
    }
}

contract EASLegacy101Test is NativeEASProfileTest {
    function _legacy() internal pure override returns (bool) {
        return true;
    }

    function test_legacyAuthorizationDoesNotExpireAndHasNoNonceCancellation() public {
        DelegatedAttestationRequest memory req = _attestRequest(1, bytes32(0), 0);
        vm.warp(block.timestamp + 365 days);
        (bool canceled,) = NATIVE_EAS.call(abi.encodeWithSignature("increaseNonce(uint256)", 1));
        assertFalse(canceled);
        _attest(req);
        assertEq(eas.getNonce(payer), 1);
    }

    function test_mainnetRejectsDeadlineBearingSelector() public {
        DelegatedAttestationRequest memory req = _attestRequest(1, bytes32(0), uint64(block.timestamp + 300));
        vm.expectRevert();
        eas.attestByDelegation(req);
        assertEq(eas.getNonce(payer), 0);
    }
}

contract EASDeadline120Test is NativeEASProfileTest {
    function _legacy() internal pure override returns (bool) {
        return false;
    }

    function test_nonzeroDeadlineIsStillValidAtEquality() public {
        uint64 deadline = uint64(block.timestamp + 300);
        DelegatedAttestationRequest memory req = _attestRequest(1, bytes32(0), deadline);
        vm.warp(deadline);
        _attest(req);
        assertEq(eas.getNonce(payer), 1);
    }

    function test_nonzeroDeadlineExpiresStrictlyAfterAndZeroRemainsLive() public {
        uint64 deadline = uint64(block.timestamp + 300);
        DelegatedAttestationRequest memory req = _attestRequest(1, bytes32(0), deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(bytes4(keccak256("DeadlineExpired()")));
        _attest(req);
        assertEq(eas.getNonce(payer), 0);
        req = _attestRequest(1, bytes32(0), 0);
        vm.warp(block.timestamp + 365 days);
        _attest(req);
        assertEq(eas.getNonce(payer), 1);
    }
}
