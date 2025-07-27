// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {SwapidoEthChainResolver} from "../src/SwapidoEthChainResolver.sol";
import {IEscrowFactory} from "cross-chain-swap/interfaces/IEscrowFactory.sol";
import {IOrderMixin} from "limit-order-protocol/interfaces/IOrderMixin.sol";

contract DeploySwapidoEthChainResolver is Script {
    function run() external {
        // Get deployment parameters from environment
        address escrowFactory = vm.envOr("ESCROW_FACTORY", address(0));
        address limitOrderProtocol = vm.envOr("LIMIT_ORDER_PROTOCOL", address(0));
        address owner = vm.envOr("RESOLVER_OWNER", msg.sender);

        // Validate parameters
        require(escrowFactory != address(0), "ESCROW_FACTORY not set");
        require(limitOrderProtocol != address(0), "LIMIT_ORDER_PROTOCOL not set");
        require(owner != address(0), "RESOLVER_OWNER not set");

        vm.startBroadcast();

        // Deploy the SwapidoEthChainResolver
        SwapidoEthChainResolver resolver = new SwapidoEthChainResolver(
            IEscrowFactory(escrowFactory),
            IOrderMixin(limitOrderProtocol),
            owner
        );

        console.log("SwapidoEthChainResolver deployed at:", address(resolver));
        console.log("Owner:", resolver.owner());
        console.log("Escrow Factory:", resolver.escrowFactory());
        console.log("Limit Order Protocol:", resolver.limitOrderProtocol());

        vm.stopBroadcast();
    }
}