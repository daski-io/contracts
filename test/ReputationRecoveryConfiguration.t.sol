// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReputationStorage} from "../src/ReputationStorage.sol";
import {ReputationStorageBase} from "../src/reputation/ReputationStorageBase.sol";
import {Attestation, ISchemaRegistry} from "../src/interfaces/IEAS.sol";
import {NativeEASReputationTestBase} from "./helpers/NativeEASReputationTestBase.sol";

/// Binding the recovery schema and switching recovery submissions, on a resolver
/// whose configuration is finalized, against the actual SchemaRegistry runtime.
contract ReputationRecoveryConfigurationTest is NativeEASReputationTestBase {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private guardian = makeAddr("pause-guardian");

    function _legacy() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        reputation = _deployProxy(address(new ReputationStorage()));
        _finalize(reputation);
        vm.prank(admin);
        reputation.setPauseGuardian(guardian);
    }

    // ------------------------------------------------------------------
    // configureRecoverySchema
    // ------------------------------------------------------------------

    function test_onlyTheAdminConfigures() public {
        bytes32 uid = _registerRecoverySchema(address(reputation));
        address[3] memory others = [makeAddr("stranger"), guardian, vm.addr(ORDER_SIGNER_KEY)];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert("not admin");
            reputation.configureRecoverySchema(uid);
        }
        assertEq(reputation.recoverySchema(), bytes32(0));
    }

    function test_configurationRequiresFinalizedConfiguration() public {
        ReputationStorage fresh = _deployProxy(address(new ReputationStorage()));
        bytes32 uid = _registerRecoverySchema(address(fresh));
        vm.startPrank(admin);
        fresh.setEAS(NATIVE_EAS);
        fresh.setOutcomeSchema(outcomeSchema);
        fresh.setConfirmationSchema(confirmationSchema);
        vm.expectRevert(ReputationStorageBase.ConfigurationNotFinalized.selector);
        fresh.configureRecoverySchema(uid);
        vm.stopPrank();
        assertEq(fresh.recoverySchema(), bytes32(0));
    }

    function test_configurationHappensOnce() public {
        bytes32 uid = _registerRecoverySchema(address(reputation));
        vm.startPrank(admin);
        reputation.configureRecoverySchema(uid);
        vm.expectRevert(ReputationStorageBase.RecoverySchemaAlreadyConfigured.selector);
        reputation.configureRecoverySchema(uid);
        vm.expectRevert(ReputationStorageBase.RecoverySchemaAlreadyConfigured.selector);
        reputation.configureRecoverySchema(bytes32(0));
        vm.stopPrank();
        assertEq(reputation.recoverySchema(), uid);
    }

    function test_configurationRejectsZeroAndTheExistingSchemas() public {
        vm.startPrank(admin);
        vm.expectRevert(ReputationStorageBase.ZeroSchema.selector);
        reputation.configureRecoverySchema(bytes32(0));
        vm.expectRevert(ReputationStorageBase.SchemasMustDiffer.selector);
        reputation.configureRecoverySchema(outcomeSchema);
        vm.expectRevert(ReputationStorageBase.SchemasMustDiffer.selector);
        reputation.configureRecoverySchema(confirmationSchema);
        vm.stopPrank();
        assertEq(reputation.recoverySchema(), bytes32(0));
    }

    function test_configurationValidatesTheRegisteredSchema() public {
        ISchemaRegistry registry = ISchemaRegistry(NATIVE_REGISTRY);
        bytes32 missing = keccak256("unregistered-schema");
        bytes32 wrongResolver = registry.register(RECOVERY_SCHEMA, makeAddr("other-resolver"), false);
        bytes32 wrongDefinition = registry.register("bytes32 orderKey,bytes32 evidenceHash", address(reputation), false);
        bytes32 revocable = registry.register(RECOVERY_SCHEMA, address(reputation), true);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReputationStorageBase.SchemaMissing.selector, missing));
        reputation.configureRecoverySchema(missing);
        vm.expectRevert(abi.encodeWithSelector(ReputationStorageBase.WrongSchemaResolver.selector, wrongResolver));
        reputation.configureRecoverySchema(wrongResolver);
        vm.expectRevert(abi.encodeWithSelector(ReputationStorageBase.WrongSchemaDefinition.selector, wrongDefinition));
        reputation.configureRecoverySchema(wrongDefinition);
        vm.expectRevert(abi.encodeWithSelector(ReputationStorageBase.SchemaMustBeIrrevocable.selector, revocable));
        reputation.configureRecoverySchema(revocable);
        vm.stopPrank();
        assertEq(reputation.recoverySchema(), bytes32(0));
    }

    function test_configurationBindsTheSchemaAndLeavesSubmissionsDisabled() public {
        bytes32 uid = _registerRecoverySchema(address(reputation));
        vm.expectEmit(true, false, false, true, address(reputation));
        emit ReputationStorageBase.RecoverySchemaConfigured(uid);
        vm.prank(admin);
        reputation.configureRecoverySchema(uid);
        assertEq(reputation.recoverySchema(), uid);
        assertFalse(reputation.recoverySubmissionsEnabled());
    }

    function test_adminConfiguresThroughUpgradeToAndCall() public {
        bytes32 uid = _registerRecoverySchema(address(reputation));
        ReputationStorage next = new ReputationStorage();
        bytes memory configure = abi.encodeCall(reputation.configureRecoverySchema, (uid));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert("not admin");
        reputation.upgradeToAndCall(address(next), configure);

        vm.expectEmit(true, false, false, true, address(reputation));
        emit ReputationStorageBase.RecoverySchemaConfigured(uid);
        vm.prank(admin);
        reputation.upgradeToAndCall(address(next), configure);
        assertEq(address(uint160(uint256(vm.load(address(reputation), ERC1967_IMPLEMENTATION_SLOT)))), address(next));
        assertEq(reputation.recoverySchema(), uid);
    }

    function test_unconfiguredRecoverySchemaIsUnknown() public {
        bytes32 orderKey = keccak256("unconfigured-recovery");
        _register(_permit(orderKey));
        _attestOutcome(orderKey, ReputationStorageBase.TransactionOutcome.Failed);
        recoverySchema = _registerRecoverySchema(address(reputation));
        vm.prank(admin);
        reputation.setRecoverySubmissionsEnabled(true);

        vm.expectRevert(ReputationStorageBase.UnknownSchema.selector);
        _attestRecovery(providerWallet, providerWallet, orderKey, keccak256("evidence"));
        assertEq(_recovery(orderKey), abi.encode(uint64(0), bytes32(0), bytes32(0)));
        assertEq(reputation.recoveredCount(PROVIDER_AGENT_ID), 0);
        assertEq(reputation.recoveredByService(serviceId), 0);

        // An unset recovery schema never matches a zero schema either.
        Attestation memory item = Attestation({
            uid: keccak256("zero-schema"),
            schema: bytes32(0),
            time: uint64(block.timestamp),
            expirationTime: 0,
            revocationTime: 0,
            refUID: bytes32(0),
            recipient: providerWallet,
            attester: providerWallet,
            revocable: false,
            data: abi.encode(orderKey, keccak256("evidence"))
        });
        vm.prank(NATIVE_EAS);
        vm.expectRevert(ReputationStorageBase.UnknownSchema.selector);
        reputation.attest(item);
    }

    // ------------------------------------------------------------------
    // setRecoverySubmissionsEnabled
    // ------------------------------------------------------------------

    function test_adminEnablesAndDisablesSubmissions() public {
        vm.expectEmit(true, false, false, true, address(reputation));
        emit ReputationStorageBase.RecoverySubmissionsEnabledUpdated(true, admin);
        vm.prank(admin);
        reputation.setRecoverySubmissionsEnabled(true);
        assertTrue(reputation.recoverySubmissionsEnabled());

        vm.expectEmit(true, false, false, true, address(reputation));
        emit ReputationStorageBase.RecoverySubmissionsEnabledUpdated(false, admin);
        vm.prank(admin);
        reputation.setRecoverySubmissionsEnabled(false);
        assertFalse(reputation.recoverySubmissionsEnabled());
    }

    function test_guardianMayOnlyDisableSubmissions() public {
        vm.prank(admin);
        reputation.setRecoverySubmissionsEnabled(true);

        vm.prank(guardian);
        vm.expectRevert(ReputationStorageBase.RecoveryEnableRequiresAdmin.selector);
        reputation.setRecoverySubmissionsEnabled(true);
        assertTrue(reputation.recoverySubmissionsEnabled());

        vm.expectEmit(true, false, false, true, address(reputation));
        emit ReputationStorageBase.RecoverySubmissionsEnabledUpdated(false, guardian);
        vm.prank(guardian);
        reputation.setRecoverySubmissionsEnabled(false);
        assertFalse(reputation.recoverySubmissionsEnabled());

        vm.prank(guardian);
        vm.expectRevert(ReputationStorageBase.RecoveryEnableRequiresAdmin.selector);
        reputation.setRecoverySubmissionsEnabled(true);
        assertFalse(reputation.recoverySubmissionsEnabled());
    }

    function test_nobodyElseSwitchesSubmissions() public {
        address pendingAdmin = makeAddr("pending-admin");
        vm.prank(admin);
        reputation.transferAdmin(pendingAdmin);
        address[5] memory others =
            [makeAddr("stranger"), pendingAdmin, vm.addr(ORDER_SIGNER_KEY), providerWallet, NATIVE_EAS];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(ReputationStorageBase.NotAdminOrPauseGuardian.selector);
            reputation.setRecoverySubmissionsEnabled(true);
            vm.prank(others[i]);
            vm.expectRevert(ReputationStorageBase.NotAdminOrPauseGuardian.selector);
            reputation.setRecoverySubmissionsEnabled(false);
        }
        assertFalse(reputation.recoverySubmissionsEnabled());
    }
}
