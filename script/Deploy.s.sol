// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {AgentIdentityRegistry} from "../src/AgentIdentityRegistry.sol";

contract DeployScript is Script {
    function run() external returns (AgentIdentityRegistry) {
        // Base Sepolia USDC address
        address usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        
        vm.startBroadcast();
        
        AgentIdentityRegistry registry = new AgentIdentityRegistry(usdc);
        
        vm.stopBroadcast();
        
        return registry;
    }
}
