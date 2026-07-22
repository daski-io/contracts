// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RetireStack} from "../script/RetireStack.s.sol";

contract MockLegacyRouter {
    mapping(address => bool) public acceptedTokens;
    mapping(address => bool) private adapters;
    uint256 public setTokenCalls;
    uint256 public setAdapterCalls;

    function seed(address token, address adapter) external {
        acceptedTokens[token] = true;
        adapters[adapter] = true;
    }

    function isAdapter(address adapter) external view returns (bool) {
        return adapters[adapter];
    }

    function setAcceptedToken(address token, bool allowed) external {
        acceptedTokens[token] = allowed;
        setTokenCalls++;
    }

    function setAdapter(address adapter, bool allowed) external {
        adapters[adapter] = allowed;
        setAdapterCalls++;
    }
}

contract RetireStackTest is Test {
    RetireStack internal script = new RetireStack();
    MockLegacyRouter internal router = new MockLegacyRouter();

    address internal constant TOKEN = address(0x70CE);
    address internal constant ADAPTER_A = address(0xADA0);
    address internal constant ADAPTER_B = address(0xADA1);

    function test_executeDisablesTokensAndAdapters() public {
        router.seed(TOKEN, ADAPTER_A);
        router.seed(TOKEN, ADAPTER_B);

        address[] memory tokens = new address[](1);
        tokens[0] = TOKEN;
        address[] memory adapters = new address[](2);
        adapters[0] = ADAPTER_A;
        adapters[1] = ADAPTER_B;

        script.execute(address(router), tokens, adapters);

        assertFalse(router.acceptedTokens(TOKEN));
        assertFalse(router.isAdapter(ADAPTER_A));
        assertFalse(router.isAdapter(ADAPTER_B));
        assertEq(router.setTokenCalls(), 1);
        assertEq(router.setAdapterCalls(), 2);
    }

    function test_executeIsIdempotent() public {
        router.seed(TOKEN, ADAPTER_A);
        address[] memory tokens = new address[](1);
        tokens[0] = TOKEN;
        address[] memory adapters = new address[](1);
        adapters[0] = ADAPTER_A;

        script.execute(address(router), tokens, adapters);
        script.execute(address(router), tokens, adapters);

        // Second pass finds everything disabled and issues no further writes.
        assertEq(router.setTokenCalls(), 1);
        assertEq(router.setAdapterCalls(), 1);
        assertFalse(router.acceptedTokens(TOKEN));
        assertFalse(router.isAdapter(ADAPTER_A));
    }
}
