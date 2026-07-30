// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCanonicalIdentityRegistry} from "../mocks/MockCanonicalIdentityRegistry.sol";
import {MockSanctionsList} from "../mocks/MockSanctionsList.sol";
import {MockReputationSink} from "./MockReputationSink.sol";
import {EIP3009Signer} from "./EIP3009Signer.sol";
import {AgentIndexSigner} from "./AgentIndexSigner.sol";
import {AgentIndex} from "../../src/AgentIndex.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";
import {ServiceRegistry} from "../../src/ServiceRegistry.sol";
import {PaymentRouter} from "../../src/PaymentRouter.sol";
import {X402Adapter} from "../../src/adapters/X402Adapter.sol";
import {IX402Adapter} from "../../src/interfaces/IX402Adapter.sol";

interface ICircleUsdc is IERC20Metadata {
    function version() external view returns (string memory);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
    function isBlacklisted(address account) external view returns (bool);
}

abstract contract X402CircleForkFixture is Test {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MockCanonicalIdentityRegistry internal identity;
    AgentIndex internal agentIndex;
    ProviderRegistry internal registry;
    ServiceRegistry internal services;
    PaymentRouter internal router;
    X402Adapter internal adapter;
    MockSanctionsList internal sanctions;
    ICircleUsdc internal usdc;

    address internal admin = makeAddr("fork-admin");
    address internal treasury = makeAddr("fork-treasury");
    address internal facilitator = makeAddr("fork-facilitator");
    address internal provider = makeAddr("fork-provider");
    uint256 internal providerAgentId;
    bytes32 internal serviceId;
    string internal usdcName;

    function _createForkAndStack(
        string memory rpcUrl,
        uint256 forkBlock,
        bytes32 expectedBlockHash,
        uint256 expectedChainId,
        address token,
        string memory expectedName,
        bytes32 expectedDomain
    ) internal {
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, expectedChainId, "fork chain");
        emit log_named_uint("Fork block", forkBlock);
        emit log_named_bytes32("Fork block hash", expectedBlockHash);

        usdc = ICircleUsdc(token);
        usdcName = expectedName;
        assertEq(usdc.decimals(), 6, "USDC decimals");
        assertEq(usdc.name(), expectedName, "USDC name");
        assertEq(usdc.version(), "2", "USDC version");
        assertEq(usdc.DOMAIN_SEPARATOR(), expectedDomain, "USDC domain");

        identity = new MockCanonicalIdentityRegistry();
        sanctions = new MockSanctionsList();
        agentIndex = AgentIndex(
            address(
                new ERC1967Proxy(
                    address(new AgentIndex()),
                    abi.encodeCall(AgentIndex.initialize, (address(identity), address(sanctions), admin))
                )
            )
        );
        registry = ProviderRegistry(
            address(
                new ERC1967Proxy(
                    address(new ProviderRegistry()),
                    abi.encodeCall(
                        ProviderRegistry.initialize,
                        (address(identity), token, treasury, 1e6, address(sanctions), admin)
                    )
                )
            )
        );
        services = ServiceRegistry(
            address(
                new ERC1967Proxy(
                    address(new ServiceRegistry()),
                    abi.encodeCall(
                        ServiceRegistry.initialize, (address(identity), address(registry), address(sanctions), admin)
                    )
                )
            )
        );
        router = PaymentRouter(
            address(
                new ERC1967Proxy(
                    address(new PaymentRouter()),
                    abi.encodeCall(
                        PaymentRouter.initialize,
                        (
                            address(identity),
                            address(registry),
                            address(services),
                            treasury,
                            500,
                            address(sanctions),
                            admin
                        )
                    )
                )
            )
        );
        adapter = X402Adapter(
            address(
                new ERC1967Proxy(
                    address(new X402Adapter()),
                    abi.encodeCall(
                        X402Adapter.initialize, (address(router), address(agentIndex), address(sanctions), admin)
                    )
                )
            )
        );
        vm.startPrank(admin);
        router.setReputationStorage(address(new MockReputationSink(address(router))));
        router.setAdapter(address(adapter), true);
        adapter.setFacilitatorAuthorization(facilitator, true);
        router.setAcceptedToken(token, true);
        router.setTokenReputationConfig(token, true, 250_000);
        vm.stopPrank();

        _seed(provider, 1e6);
        vm.prank(provider);
        providerAgentId = identity.register("ipfs://fork-provider");
        identity.forceSetAgentWallet(providerAgentId, provider);
        vm.startPrank(provider);
        usdc.approve(address(registry), 1e6);
        registry.register(providerAgentId);
        serviceId = services.registerService(providerAgentId, "fork-service", "1", "ipfs://service", address(0));
        vm.stopPrank();
    }

    function _registerBuyer(address buyer) internal returns (uint256 agentId) {
        vm.prank(buyer);
        agentId = identity.register();
        vm.prank(buyer);
        agentIndex.claim(agentId);
    }

    function _auth(
        uint256 signerKey,
        address from,
        uint256 amount,
        bytes32 serviceRef,
        bytes32 nonceSalt,
        string memory domainName,
        uint256 domainChainId
    ) internal view returns (IX402Adapter.EIP3009Auth memory auth) {
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = adapter.authNonceFor(
            address(usdc), from, amount, 0, validBefore, serviceRef, providerAgentId, serviceId, nonceSalt
        );
        auth = EIP3009Signer.signReceive(
            vm,
            signerKey,
            address(usdc),
            domainName,
            "2",
            domainChainId,
            from,
            address(adapter),
            amount,
            0,
            validBefore,
            nonce
        );
    }

    function _seed(address account, uint256 amount) internal {
        bytes32 codehashBefore = address(usdc).codehash;
        bytes32 implementationBefore = vm.load(address(usdc), IMPLEMENTATION_SLOT);
        bytes32 domainBefore = usdc.DOMAIN_SEPARATOR();
        assertFalse(usdc.isBlacklisted(account), "seed account blacklisted before");
        deal(address(usdc), account, amount);
        assertFalse(usdc.isBlacklisted(account), "seed changed blacklist state");
        assertEq(usdc.balanceOf(account), amount, "seed balance");
        assertEq(address(usdc).codehash, codehashBefore, "seed changed token code");
        assertEq(vm.load(address(usdc), IMPLEMENTATION_SLOT), implementationBefore, "seed changed implementation");
        assertEq(usdc.DOMAIN_SEPARATOR(), domainBefore, "seed changed domain");
    }

    function _registrationSignature(uint256 key, string memory uri, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return AgentIndexSigner.signRegisterWithNonce(vm, key, agentIndex, uri, 0, deadline);
    }
}
