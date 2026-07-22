// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRetirableRouter {
    function admin() external view returns (address);
    function acceptedTokens(address token) external view returns (bool);
    function isAdapter(address adapter) external view returns (bool);
    function setAcceptedToken(address token, bool allowed) external;
    function setAdapter(address adapter, bool allowed) external;
}

/// @notice Quiesce a RETIRED PaymentRouter so a replaced deployment cannot
///         keep settling: disable every accepted token and every enabled
///         adapter (audit finding — old stacks must not stay live behind a
///         redeploy). Both legacy router generations expose this exact admin
///         surface.
///
///         Scope: EOA-admined legacy stacks only — the broadcaster must BE
///         the router admin. A Safe-admined router (v0.6.0+) is retired via
///         a governance batch instead.
///
///         RETIRE_PAYMENT_ROUTER_ADDRESS  the OLD router (never the live one
///                                        — this script is the kill switch)
///         RETIRE_TOKENS                  comma-separated tokens to disable
///         RETIRE_ADAPTERS                comma-separated adapters to disable
///         ALLOW_RESIDUAL_TOKEN_BALANCE   default false; a nonzero router
///                                        balance aborts (re-check, per the
///                                        README retirement procedure)
///
///         The lists must cover everything ever enabled — mappings are not
///         enumerable on-chain, so cross-check against the router's full
///         `AcceptedTokenSet`/`AdapterSet` event history before AND after.
contract RetireStack is Script {
    function run() external {
        uint256 adminKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address router = vm.envAddress("RETIRE_PAYMENT_ROUTER_ADDRESS");
        address[] memory tokens = vm.envAddress("RETIRE_TOKENS", ",");
        address[] memory adapters = vm.envAddress("RETIRE_ADAPTERS", ",");
        bool allowResidual = vm.envOr("ALLOW_RESIDUAL_TOKEN_BALANCE", false);

        address sender = vm.addr(adminKey);
        require(router.code.length > 0, "router has no code");
        require(IRetirableRouter(router).admin() == sender, "broadcaster is not the router admin");
        require(tokens.length > 0 || adapters.length > 0, "nothing to retire");

        console.log("Retiring router:", router);
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(router);
            console.log("  token", tokens[i], "router balance:", balance);
            if (balance != 0) {
                require(allowResidual, "router still holds token balance (set ALLOW_RESIDUAL_TOKEN_BALANCE to proceed)");
                console.log("  WARNING: residual balance is unrecoverable and stays behind");
            }
        }

        vm.startBroadcast(adminKey);
        execute(router, tokens, adapters);
        vm.stopBroadcast();

        for (uint256 i = 0; i < tokens.length; i++) {
            require(!IRetirableRouter(router).acceptedTokens(tokens[i]), "token still accepted");
        }
        for (uint256 i = 0; i < adapters.length; i++) {
            require(!IRetirableRouter(router).isAdapter(adapters[i]), "adapter still enabled");
        }
        console.log("Router quiesced: no accepted tokens, no enabled adapters (from the provided lists).");
        console.log("Now re-scan AcceptedTokenSet/AdapterSet history and the token balances to close out.");
    }

    /// @dev Idempotent: entries already disabled are skipped, so a partially
    ///      applied retirement can simply be re-run.
    function execute(address router, address[] memory tokens, address[] memory adapters) public {
        IRetirableRouter target = IRetirableRouter(router);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (target.acceptedTokens(tokens[i])) {
                target.setAcceptedToken(tokens[i], false);
                console.log("  disabled accepted token:", tokens[i]);
            } else {
                console.log("  token already disabled:", tokens[i]);
            }
        }
        for (uint256 i = 0; i < adapters.length; i++) {
            if (target.isAdapter(adapters[i])) {
                target.setAdapter(adapters[i], false);
                console.log("  disabled adapter:", adapters[i]);
            } else {
                console.log("  adapter already disabled:", adapters[i]);
            }
        }
    }
}
