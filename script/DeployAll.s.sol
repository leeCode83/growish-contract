// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MockUSDC.sol";
import "../src/Router.sol";
import "../src/Vault.sol";
import "../src/MockProtocol.sol";
import "../src/Strategy.sol";

contract DeployAll is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MockUSDC
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC deployed at:", address(usdc));

        // 2. Deploy Router
        Router router = new Router(address(usdc));
        console.log("Router deployed at:", address(router));

        // 3. Deploy Vaults
        // Conservative: 6% gap (600 bps)
        Vault vaultConservative = new Vault(
            "Conservative Vault",
            "cvUSDC",
            address(usdc),
            600,
            msg.sender // feeRecipient
        );
        console.log(
            "Vault Conservative deployed at:",
            address(vaultConservative)
        );

        // Balanced: 4% gap (400 bps)
        Vault vaultBalanced = new Vault(
            "Balanced Vault",
            "bvUSDC",
            address(usdc),
            400,
            msg.sender
        );
        console.log("Vault Balanced deployed at:", address(vaultBalanced));

        // Aggressive: 2% gap (200 bps)
        Vault vaultAggressive = new Vault(
            "Aggressive Vault",
            "avUSDC",
            address(usdc),
            200,
            msg.sender
        );
        console.log("Vault Aggressive deployed at:", address(vaultAggressive));

        // 4. Deploy MockProtocols
        MockProtocol aave = new MockProtocol(
            "Mock Aave",
            "mAAVE",
            address(usdc),
            500 // 5% APY
        );
        console.log("MockProtocol Aave deployed at:", address(aave));

        MockProtocol compound = new MockProtocol(
            "Mock Compound",
            "mCOMP",
            address(usdc),
            700 // 7% APY
        );
        console.log("MockProtocol Compound deployed at:", address(compound));

        // 5. Deploy Strategies
        // Strategy takes (usdc, protocol, vaultCons, vaultBal, vaultAggr)
        Strategy strategyAave = new Strategy(
            address(usdc),
            address(aave),
            address(vaultConservative),
            address(vaultBalanced),
            address(vaultAggressive)
        );
        console.log("Strategy Aave deployed at:", address(strategyAave));

        Strategy strategyCompound = new Strategy(
            address(usdc),
            address(compound),
            address(vaultConservative),
            address(vaultBalanced),
            address(vaultAggressive)
        );
        console.log(
            "Strategy Compound deployed at:",
            address(strategyCompound)
        );

        // 6. Setup
        // Set vaults in Router
        router.setVault(
            Router.RiskLevel.Conservative,
            address(vaultConservative)
        );
        router.setVault(Router.RiskLevel.Balanced, address(vaultBalanced));
        router.setVault(Router.RiskLevel.Aggressive, address(vaultAggressive));

        // Add strategies to vaults
        // "Transfer kepemilikan kedua contract strategy menjadi milik setiap vault"
        // Interpreted as adding the strategies to the vaults so they can use them.
        vaultConservative.addStrategy(address(strategyAave));
        vaultConservative.addStrategy(address(strategyCompound));

        vaultBalanced.addStrategy(address(strategyAave));
        vaultBalanced.addStrategy(address(strategyCompound));

        vaultAggressive.addStrategy(address(strategyAave));
        vaultAggressive.addStrategy(address(strategyCompound));

        vm.stopBroadcast();
    }
}
