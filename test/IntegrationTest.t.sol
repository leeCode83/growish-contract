// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/Router.sol";
import "../src/Vault.sol";
import "../src/Strategy.sol";
import "../src/MockProtocol.sol";
import "../src/MockUSDC.sol";

contract IntegrationTest is Test {
    MockUSDC public usdc;
    MockProtocol public protocolA;
    MockProtocol public protocolB;
    Strategy public strategyA;
    Strategy public strategyB;
    Vault public vault;
    Router public router;

    address public owner = address(this);
    address public feeRecipient = address(0x999);

    address[] public users;
    uint256 public constant INITIAL_BALANCE = 10000e6; // 10,000 USDC
    uint256 public constant DEPOSIT_AMOUNT = 1000e6; // 1,000 USDC

    function setUp() public {
        // 1. Deploy Tokens and Protocols
        usdc = new MockUSDC();

        // Protocol A: 10% APY (1000 basis points)
        protocolA = new MockProtocol("Mock Aave", "mAAVE", address(usdc), 1000);

        // Protocol B: 10% APY (1000 basis points)
        protocolB = new MockProtocol(
            "Mock Compound",
            "mCOMP",
            address(usdc),
            1000
        );

        // 2. Deploy Strategies
        strategyA = new Strategy(address(usdc), address(protocolA));
        strategyB = new Strategy(address(usdc), address(protocolB));

        // 3. Deploy Vault (Conservative)
        // Min rebalance gap 5% (500 bps)
        vault = new Vault(
            "Conservative Vault",
            "cvUSDC",
            address(usdc),
            500,
            feeRecipient
        );

        // 4. Deploy Router
        router = new Router(address(usdc));

        // 5. Setup Relationships

        // Router sets Vault for Conservative Risk Level (0)
        router.setVault(Router.RiskLevel.Conservative, address(vault));

        // Vault adds Strategies
        // IMPORTANT: Strategy owner must be the Vault for it to call deposit/withdraw
        strategyA.transferOwnership(address(vault));
        strategyB.transferOwnership(address(vault));

        vault.addStrategy(address(strategyA));
        vault.addStrategy(address(strategyB));

        // 6. Setup Users
        for (uint i = 0; i < 5; i++) {
            address user = address(uint160(0x1000 + i));
            users.push(user);
            usdc.mint(user, INITIAL_BALANCE);

            // Approve Router
            vm.prank(user);
            usdc.approve(address(router), type(uint256).max);
        }
    }

    function testFullFlow() public {
        console.log("=== Starting Integration Test ===");

        // ==========================================
        // 1. 5 Users Deposit
        // ==========================================
        console.log("\n--- Phase 1: Users Deposit ---");

        for (uint i = 0; i < 5; i++) {
            vm.prank(users[i]);
            router.deposit(DEPOSIT_AMOUNT, Router.RiskLevel.Conservative);
            console.log("User", i, "deposited", DEPOSIT_AMOUNT);
        }

        // Verify pending deposits
        uint256 pending = router.totalPendingDeposits(
            Router.RiskLevel.Conservative
        );
        assertEq(
            pending,
            DEPOSIT_AMOUNT * 5,
            "Total pending deposits mismatch"
        );
        console.log("Total Pending Deposits:", pending);

        // ==========================================
        // 2. Router Batch Deposit
        // ==========================================
        console.log("\n--- Phase 2: Batch Execution ---");

        // Warp time to pass batch interval (6 hours)
        vm.warp(block.timestamp + 6 hours + 1);

        // Execute batch
        router.executeBatchDeposits(Router.RiskLevel.Conservative);

        // Verify Vault received funds and deployed them
        // Since it's the first deployment and strategies are empty, it should split equally (50/50)
        // Total deposited: 5000 USDC
        // Strategy A: 2500, Strategy B: 2500

        uint256 stratABalance = strategyA.balanceOf();
        uint256 stratBBalance = strategyB.balanceOf();

        console.log("Strategy A Balance:", stratABalance);
        console.log("Strategy B Balance:", stratBBalance);

        assertEq(stratABalance, 2500e6, "Strategy A balance incorrect");
        assertEq(stratBBalance, 2500e6, "Strategy B balance incorrect");
        assertEq(vault.totalAssets(), 5000e6, "Vault total assets incorrect");

        // Users claim shares
        for (uint i = 0; i < 5; i++) {
            vm.prank(users[i]);
            router.claimDepositShares(Router.RiskLevel.Conservative);
            uint256 shares = vault.balanceOf(users[i]);
            assertGt(shares, 0, "User should have shares");
        }

        // ==========================================
        // 3. Yield Growth & Rebalancing
        // ==========================================
        console.log("\n--- Phase 3: Yield & Rebalancing ---");

        // Simulate time passing (30 days)
        vm.warp(block.timestamp + 30 days);

        // Change APY of Protocol A to 20% (was 10%)
        // Protocol B stays at 10%
        protocolA.setAPY(2000);
        console.log("Protocol A APY increased to 20%");

        // Trigger Rebalance
        // Logic:
        // Score A = 20% * 2500 (approx) = 50000
        // Score B = 10% * 2500 (approx) = 25000
        // Total Score = 75000
        // Target A = 2/3 of total
        // Target B = 1/3 of total

        vault.rebalance();

        uint256 newStratABalance = strategyA.balanceOf();
        uint256 newStratBBalance = strategyB.balanceOf();

        console.log("New Strategy A Balance:", newStratABalance);
        console.log("New Strategy B Balance:", newStratBBalance);

        assertGt(
            newStratABalance,
            newStratBBalance,
            "Strategy A should have more funds after rebalance"
        );

        // ==========================================
        // 4. Withdrawal
        // ==========================================
        console.log("\n--- Phase 4: Withdrawal ---");
        usdc.mint(address(protocolA), 10000000000);
        usdc.mint(address(protocolB), 10000000000);

        // User 0 requests withdraw
        address user = users[0];
        uint256 sharesToWithdraw = vault.balanceOf(user);

        vm.prank(user);
        vault.approve(address(router), sharesToWithdraw);

        vm.prank(user);
        router.withdraw(sharesToWithdraw, Router.RiskLevel.Conservative);
        console.log("User 0 requested withdraw of all shares");

        // Warp time for batch
        vm.warp(block.timestamp + 6 hours + 1);

        // Execute batch withdraw
        router.executeBatchWithdraws(Router.RiskLevel.Conservative);

        // User claims USDC
        uint256 balanceBefore = usdc.balanceOf(user);
        vm.prank(user);
        router.claimWithdrawAssets(Router.RiskLevel.Conservative);
        uint256 balanceAfter = usdc.balanceOf(user);

        uint256 withdrawnAmount = balanceAfter - balanceBefore;
        console.log("User 0 Withdrawn Amount:", withdrawnAmount);

        // Should be > 1000 USDC due to yield
        assertGt(
            withdrawnAmount,
            DEPOSIT_AMOUNT,
            "Withdraw amount should include yield"
        );

        console.log("=== Test Completed Successfully ===");
    }
}
