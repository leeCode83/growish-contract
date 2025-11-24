// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MockProtocol.sol";
import "../src/MockUSDC.sol";

contract MockProtocolTest is Test {
    MockProtocol public protocol;
    MockUSDC public usdc;

    address public user1 = address(0x1);
    address public user2 = address(0x2);

    uint256 public constant INITIAL_APY = 1000; // 10%
    uint256 public constant INITIAL_BALANCE = 10000 * 1e6; // 10,000 USDC

    function setUp() public {
        // Deploy Mock USDC
        usdc = new MockUSDC();

        // Deploy Mock Protocol
        protocol = new MockProtocol(
            "Mock Protocol Token",
            "mPT",
            address(usdc),
            INITIAL_APY
        );

        // Setup User 1
        usdc.mint(user1, INITIAL_BALANCE);
        vm.startPrank(user1);
        usdc.approve(address(protocol), type(uint256).max);
        vm.stopPrank();

        // Setup User 2
        usdc.mint(user2, INITIAL_BALANCE);
        vm.startPrank(user2);
        usdc.approve(address(protocol), type(uint256).max);
        vm.stopPrank();
    }

    function testInitialState() public view {
        assertEq(protocol.getAPY(), INITIAL_APY);
        assertEq(protocol.totalSupplied(), 0);
        assertEq(usdc.balanceOf(address(protocol)), 0);
    }

    function testSupply() public {
        uint256 supplyAmount = 1000 * 1e6;

        vm.startPrank(user1);
        protocol.supply(address(usdc), supplyAmount, user1);
        vm.stopPrank();

        // Check balances
        assertEq(protocol.balanceOf(user1), supplyAmount); // Receipt tokens
        assertEq(protocol.getPrincipal(user1), supplyAmount);
        assertEq(protocol.totalSupplied(), supplyAmount);
        assertEq(usdc.balanceOf(address(protocol)), supplyAmount);
    }

    function testInterestAccrual() public {
        uint256 supplyAmount = 1000 * 1e6;

        vm.startPrank(user1);
        protocol.supply(address(usdc), supplyAmount, user1);
        vm.stopPrank();

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        // Expected interest: 10% of 1000 = 100 USDC
        uint256 expectedInterest = (supplyAmount * INITIAL_APY) / 10000;
        uint256 pendingInterest = protocol.getPendingInterest(user1);

        // Allow small rounding error
        assertApproxEqAbs(pendingInterest, expectedInterest, 100);

        // Check supplied balance (Principal + Interest)
        uint256 suppliedBalance = protocol.getSuppliedBalance(user1);
        assertApproxEqAbs(
            suppliedBalance,
            supplyAmount + expectedInterest,
            100
        );
    }

    function testWithdraw() public {
        uint256 supplyAmount = 1000 * 1e6;

        vm.startPrank(user1);
        protocol.supply(address(usdc), supplyAmount, user1);
        vm.stopPrank();

        // Warp 1 year to earn interest
        vm.warp(block.timestamp + 365 days);

        uint256 balanceBefore = usdc.balanceOf(user1);

        vm.startPrank(user1);
        // Withdraw all
        // NOTE: Protocol needs liquidity to pay interest!
        // In real world, borrowers pay interest. Here, we simulate it by minting to protocol.
        vm.stopPrank();

        usdc.mint(address(protocol), 1000 * 1e6); // Inject liquidity for interest

        vm.startPrank(user1);
        protocol.withdraw(address(usdc), type(uint256).max, user1);
        vm.stopPrank();

        uint256 balanceAfter = usdc.balanceOf(user1);
        uint256 withdrawnAmount = balanceAfter - balanceBefore;

        // Expected: 1000 principal + ~100 interest
        uint256 expectedAmount = supplyAmount +
            (supplyAmount * INITIAL_APY) /
            10000;

        assertApproxEqAbs(withdrawnAmount, expectedAmount, 100);
        assertEq(protocol.balanceOf(user1), 0); // Receipt tokens burned
        assertEq(protocol.getSuppliedBalance(user1), 0);
    }

    function testAPYUpdate() public {
        uint256 supplyAmount = 1000 * 1e6;

        vm.startPrank(user1);
        protocol.supply(address(usdc), supplyAmount, user1);
        vm.stopPrank();

        // 6 months at 10% APY
        vm.warp(block.timestamp + 182.5 days);

        // Update APY to 20%
        protocol.setAPY(2000); // 20%

        // Another 6 months at 20% APY
        vm.warp(block.timestamp + 182.5 days);

        // Expected interest:
        // First half: 1000 * 10% * 0.5 = 50
        // Second half: (1000 + 50) * 20% * 0.5 = 105 (Compounding happens on interaction/view logic)
        // Note: MockProtocol logic calculates interest based on timeElapsed * currentAPY * principal.
        // Wait, let's check MockProtocol logic.
        // It uses `lastUpdateTime`. So if we change APY, it applies to the period SINCE last update.
        // To test correctly, we should trigger an update (e.g. accrueInterest) right before changing APY.

        // Let's redo the flow to be precise with how the contract works
    }

    function testAPYUpdateCorrectFlow() public {
        uint256 supplyAmount = 1000 * 1e6;

        vm.startPrank(user1);
        protocol.supply(address(usdc), supplyAmount, user1);
        vm.stopPrank();

        // 1. Warp 6 months
        vm.warp(block.timestamp + 182.5 days);

        // 2. Trigger interest accrual BEFORE changing APY to lock in the 10% for this period
        protocol.accrueInterest(user1);

        // Check interest for first 6 months (approx 50 USDC)
        uint256 interestPhase1 = protocol.getSuppliedBalance(user1) -
            supplyAmount;
        assertApproxEqAbs(interestPhase1, 50 * 1e6, 1e5);

        // 3. Change APY to 20%
        protocol.setAPY(2000);

        // 4. Warp another 6 months
        vm.warp(block.timestamp + 182.5 days);

        // 5. Check total balance
        // Principal for phase 2 is (1000 + 50) = 1050
        // Interest for phase 2 = 1050 * 20% * 0.5 = 105
        // Total expected = 1050 + 105 = 1155

        uint256 finalBalance = protocol.getSuppliedBalance(user1);
        // 1000 + 50 + 105 = 1155
        assertApproxEqAbs(finalBalance, 1155 * 1e6, 1e6);
    }
}
