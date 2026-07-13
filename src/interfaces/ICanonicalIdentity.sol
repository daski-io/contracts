// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IIdentityRegistry} from "./IIdentityRegistry.sol";

/// @notice Combined view of the canonical ERC-8004 Identity Registry: the
///         ERC-721 surface (ownerOf / approvals / transfers) plus the
///         ERC-8004 registration + agentWallet surface. Daski deploys no
///         identity registry of its own — the stack talks to the canonical
///         per-chain singleton through this interface:
///           Base mainnet  0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
///           Base Sepolia  0x8004A818BFB912233c491871b3d84c89A494BD9e
/// @dev The canonical registry does NOT auto-set `agentWallet` at
///      registration (unlike the retired Daski registry) — callers MUST
///      treat a zero `getAgentWallet` as "unset, fall back to ownerOf".
interface ICanonicalIdentity is IERC721, IIdentityRegistry {}
