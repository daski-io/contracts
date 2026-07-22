// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeDeployment, ISafe} from "../script/SafeDeployment.sol";

contract SafeDeploymentHarness {
    function setupInitializer(address[] memory owners, uint256 threshold) external pure returns (bytes memory) {
        return SafeDeployment.setupInitializer(owners, threshold);
    }

    function packMultiSend(address[] memory targets, bytes[] memory calls) external pure returns (bytes memory) {
        return SafeDeployment.packMultiSend(targets, calls);
    }

    function execMultiSendBatch(address safe, address sender, address[] memory targets, bytes[] memory calls) external {
        SafeDeployment.execMultiSendBatch(safe, sender, targets, calls);
    }
}

contract MockSafe {
    address public owner;
    uint256 public threshold;
    bool public execResult = true;

    address public lastTo;
    uint256 public lastValue;
    bytes public lastData;
    uint8 public lastOperation;
    bytes public lastSignatures;
    uint256 public execCalls;

    constructor(address owner_, uint256 threshold_) {
        owner = owner_;
        threshold = threshold_;
    }

    function setExecResult(bool value) external {
        execResult = value;
    }

    function isOwner(address candidate) external view returns (bool) {
        return candidate == owner;
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes memory signatures
    ) external payable returns (bool) {
        lastTo = to;
        lastValue = value;
        lastData = data;
        lastOperation = operation;
        lastSignatures = signatures;
        execCalls++;
        return execResult;
    }
}

contract SafeDeploymentTest is Test {
    SafeDeploymentHarness internal harness = new SafeDeploymentHarness();

    address internal constant OWNER = address(0xA11CE);

    function _owners(uint256 count) private pure returns (address[] memory owners) {
        owners = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            owners[i] = address(uint160(0x1000 + i));
        }
    }

    // ── setupInitializer ─────────────────────────────────────────────

    function test_setupInitializerEncodesCanonicalSetup() public view {
        address[] memory owners = _owners(2);
        bytes memory initializer = harness.setupInitializer(owners, 2);

        assertEq(bytes4(initializer), ISafe.setup.selector);
        (
            address[] memory decodedOwners,
            uint256 decodedThreshold,
            address to,
            bytes memory data,
            address fallbackHandler,
            address paymentToken,
            uint256 payment,
            address paymentReceiver
        ) = abi.decode(
            _stripSelector(initializer), (address[], uint256, address, bytes, address, address, uint256, address)
        );
        assertEq(decodedOwners.length, 2);
        assertEq(decodedOwners[0], owners[0]);
        assertEq(decodedOwners[1], owners[1]);
        assertEq(decodedThreshold, 2);
        assertEq(to, address(0));
        assertEq(data.length, 0);
        assertEq(fallbackHandler, SafeDeployment.COMPATIBILITY_FALLBACK_HANDLER);
        assertEq(paymentToken, address(0));
        assertEq(payment, 0);
        assertEq(paymentReceiver, address(0));
    }

    function test_setupInitializerRejectsBadInput() public {
        vm.expectRevert(bytes("owners required"));
        harness.setupInitializer(new address[](0), 1);

        address[] memory owners = _owners(2);
        vm.expectRevert(bytes("invalid threshold"));
        harness.setupInitializer(owners, 0);
        vm.expectRevert(bytes("invalid threshold"));
        harness.setupInitializer(owners, 3);

        owners[1] = owners[0];
        vm.expectRevert(bytes("duplicate owner"));
        harness.setupInitializer(owners, 1);

        owners[1] = address(0);
        vm.expectRevert(bytes("zero owner"));
        harness.setupInitializer(owners, 1);
    }

    // ── prevalidatedSignature ────────────────────────────────────────

    function test_prevalidatedSignatureLayout() public pure {
        bytes memory signature = SafeDeployment.prevalidatedSignature(OWNER);
        assertEq(signature.length, 65);

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        assertEq(address(uint160(uint256(r))), OWNER);
        assertEq(s, bytes32(0));
        assertEq(v, 1);
    }

    // ── packMultiSend ────────────────────────────────────────────────

    function test_packMultiSendLayout() public view {
        address[] memory targets = new address[](2);
        targets[0] = address(0xBEEF);
        targets[1] = address(0xCAFE);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature("acceptAdmin()");
        calls[1] = hex"01020304";

        bytes memory packed = harness.packMultiSend(targets, calls);
        bytes memory expected = abi.encodePacked(
            uint8(0),
            targets[0],
            uint256(0),
            uint256(calls[0].length),
            calls[0],
            uint8(0),
            targets[1],
            uint256(0),
            uint256(calls[1].length),
            calls[1]
        );
        assertEq(packed, expected);
    }

    function test_packMultiSendRejectsBadInput() public {
        vm.expectRevert(bytes("empty batch"));
        harness.packMultiSend(new address[](0), new bytes[](0));

        vm.expectRevert(bytes("length mismatch"));
        harness.packMultiSend(new address[](1), new bytes[](2));
    }

    // ── execMultiSendBatch ───────────────────────────────────────────

    function test_execMultiSendBatchBuildsSafeTransaction() public {
        MockSafe safe = new MockSafe(OWNER, 1);
        address[] memory targets = new address[](1);
        targets[0] = address(0xBEEF);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature("acceptAdmin()");

        harness.execMultiSendBatch(address(safe), OWNER, targets, calls);

        assertEq(safe.execCalls(), 1);
        assertEq(safe.lastTo(), SafeDeployment.MULTI_SEND_CALL_ONLY);
        assertEq(safe.lastValue(), 0);
        assertEq(safe.lastOperation(), SafeDeployment.OPERATION_DELEGATECALL);
        assertEq(safe.lastData(), abi.encodeWithSignature("multiSend(bytes)", harness.packMultiSend(targets, calls)));
        assertEq(safe.lastSignatures(), SafeDeployment.prevalidatedSignature(OWNER));
    }

    function test_execMultiSendBatchGuards() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0xBEEF);
        bytes[] memory calls = new bytes[](1);
        calls[0] = hex"01";

        MockSafe nonOwnerSafe = new MockSafe(address(0xD00D), 1);
        vm.expectRevert(bytes("sender is not a Safe owner"));
        harness.execMultiSendBatch(address(nonOwnerSafe), OWNER, targets, calls);

        MockSafe multisig = new MockSafe(OWNER, 2);
        vm.expectRevert(bytes("threshold > 1: execute the logged batch via the Safe app"));
        harness.execMultiSendBatch(address(multisig), OWNER, targets, calls);

        MockSafe failing = new MockSafe(OWNER, 1);
        failing.setExecResult(false);
        vm.expectRevert(bytes("Safe batch execution failed"));
        harness.execMultiSendBatch(address(failing), OWNER, targets, calls);
    }

    function _stripSelector(bytes memory data) private pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }
}
