// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Router.sol";
import "../src/Vault.sol";
import "../src/Strategy.sol";
import "../src/MockProtocol.sol";
import "../src/MockUSDC.sol";

contract RouterTest is Test {
    Router public router;
    Vault public vault;
    Strategy public strategy;
    MockProtocol public protocol;
    MockUSDC public usdc;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public keeper = address(0x9);
    address public feeRecipient = address(0x8);

    uint256 public constant INITIAL_BALANCE = 10000 * 1e6;
    uint256 public constant DEPOSIT_AMOUNT = 100 * 1e6;

    function setUp() public {
        // 1. Deploy Tokens & Protocol
        usdc = new MockUSDC();
        protocol = new MockProtocol(
            "Mock Protocol",
            "mPT",
            address(usdc),
            1000
        ); // 10% APY

        // 2. Deploy Strategy
        strategy = new Strategy(address(usdc), address(protocol), address(vault), address(0), address(0));

        // 3. Deploy Vault
        vault = new Vault(
            "Yield Vault",
            "yvUSDC",
            address(usdc),
            500, // 5% gap
            feeRecipient
        );

        // 4. Setup Vault
        vault.addStrategy(address(strategy));
        strategy.transferOwnership(address(vault));

        // 5. Deploy Router
        router = new Router(address(usdc));
        router.setVault(Router.RiskLevel.Balanced, address(vault));

        // 6. Setup Users
        usdc.mint(user1, INITIAL_BALANCE);
        usdc.mint(user2, INITIAL_BALANCE);

        vm.startPrank(user1);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function testDepositBatchFlow() public {
        // 1. User deposits to Router
        vm.startPrank(user1);
        router.deposit(DEPOSIT_AMOUNT, Router.RiskLevel.Balanced);
        vm.stopPrank();

        // Verify pending state
        assertEq(
            router.totalPendingDeposits(Router.RiskLevel.Balanced),
            DEPOSIT_AMOUNT
        );
        assertEq(router.getDepositUserCount(Router.RiskLevel.Balanced), 1);

        // 2. Warp time to pass batch interval
        vm.warp(block.timestamp + router.batchInterval() + 1);

        // 3. Execute Batch
        vm.startPrank(keeper);
        router.executeBatchDeposits(Router.RiskLevel.Balanced);
        vm.stopPrank();

        // Verify batch execution
        assertEq(router.totalPendingDeposits(Router.RiskLevel.Balanced), 0);
        assertEq(vault.balanceOf(address(router)), 0); // Router shouldn't hold shares, it records claimable
        // Wait, Router holds shares until user claims?
        // Let's check logic: Router receives shares from Vault.
        // In claim pattern: Router holds shares in its own address, and maps them to user in `claimableShares`.
        // So Router SHOULD hold shares.
        assertEq(vault.balanceOf(address(router)), DEPOSIT_AMOUNT); // 1:1 initially

        // Verify claimable
        uint256 claimable = router.claimableShares(
            user1,
            Router.RiskLevel.Balanced
        );
        assertEq(claimable, DEPOSIT_AMOUNT);

        // 4. User Claims Shares
        vm.startPrank(user1);
        router.claimDepositShares(Router.RiskLevel.Balanced);
        vm.stopPrank();

        // Verify final state
        assertEq(vault.balanceOf(user1), DEPOSIT_AMOUNT);
        assertEq(router.claimableShares(user1, Router.RiskLevel.Balanced), 0);
    }

    function testWithdrawBatchFlow() public {
        // Setup: User needs shares first
        testDepositBatchFlow();

        uint256 sharesToWithdraw = DEPOSIT_AMOUNT;

        // 1. User requests withdraw
        vm.startPrank(user1);
        vault.approve(address(router), sharesToWithdraw);
        router.withdraw(sharesToWithdraw, Router.RiskLevel.Balanced);
        vm.stopPrank();

        // Verify pending state
        assertEq(
            router.totalPendingWithdraws(Router.RiskLevel.Balanced),
            sharesToWithdraw
        );
        assertEq(vault.balanceOf(user1), 0); // Shares transferred to Router
        assertEq(vault.balanceOf(address(router)), sharesToWithdraw);

        // 2. Warp time
        vm.warp(block.timestamp + router.batchInterval() + 1);

        // 3. Execute Batch
        // Need liquidity in protocol for interest if any, but here we just deposited so principal is there.
        // However, if we want to be safe against "Insufficient liquidity" due to rounding or interest:
        usdc.mint(address(protocol), 1000 * 1e6); // Inject safety liquidity

        vm.startPrank(keeper);
        router.executeBatchWithdraws(Router.RiskLevel.Balanced);
        vm.stopPrank();

        // Verify batch execution
        assertEq(router.totalPendingWithdraws(Router.RiskLevel.Balanced), 0);

        // Verify claimable USDC
        uint256 claimable = router.claimableUSDC(
            user1,
            Router.RiskLevel.Balanced
        );
        assertEq(claimable, DEPOSIT_AMOUNT); // Should get back principal (approx)

        // 4. User Claims USDC
        uint256 balanceBefore = usdc.balanceOf(user1);

        vm.startPrank(user1);
        router.claimWithdrawAssets(Router.RiskLevel.Balanced);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), balanceBefore + DEPOSIT_AMOUNT);
        assertEq(router.claimableUSDC(user1, Router.RiskLevel.Balanced), 0);
    }

    function testMultipleUsersBatch() public {
        // User 1 deposits 100
        vm.startPrank(user1);
        router.deposit(DEPOSIT_AMOUNT, Router.RiskLevel.Balanced);
        vm.stopPrank();

        // User 2 deposits 200
        vm.startPrank(user2);
        router.deposit(DEPOSIT_AMOUNT * 2, Router.RiskLevel.Balanced);
        vm.stopPrank();

        // Warp
        vm.warp(block.timestamp + router.batchInterval() + 1);

        // Execute
        router.executeBatchDeposits(Router.RiskLevel.Balanced);

        // Check claimables
        assertEq(
            router.claimableShares(user1, Router.RiskLevel.Balanced),
            DEPOSIT_AMOUNT
        );
        assertEq(
            router.claimableShares(user2, Router.RiskLevel.Balanced),
            DEPOSIT_AMOUNT * 2
        );
    }
}
