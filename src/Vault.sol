// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IStrategy.sol";

/**
 * @title Vault
 * @notice Pool dana user dengan strategi alokasi dinamis
 * @dev Menggunakan APY-Weighted allocation untuk rebalancing
 */
contract Vault is ERC20, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ State Variables ============

    IERC20 public immutable asset;

    // List of active strategies
    IStrategy[] public strategies;

    // Configuration
    uint256 public minRebalanceGap; // Basis points (e.g., 600 = 6%)
    address public feeRecipient;
    uint256 public performanceFee = 500; // 5% (basis points)

    // Constants
    uint256 private constant BASIS_POINTS = 10000;

    // ============ Events ============

    event Deposit(address indexed user, uint256 assets, uint256 shares);
    event Redeem(address indexed user, uint256 shares, uint256 assets);
    event StrategyAdded(address strategy);
    event StrategyRemoved(address strategy);
    event Rebalanced(uint256 timestamp, uint256 totalAssets);
    event Compounded(uint256 earned, uint256 fee, uint256 timestamp);

    // ============ Constructor ============

    constructor(
        string memory _name,
        string memory _symbol,
        address _asset,
        uint256 _minRebalanceGap,
        address _feeRecipient
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        require(_asset != address(0), "Invalid asset");
        require(_feeRecipient != address(0), "Invalid fee recipient");

        asset = IERC20(_asset);
        minRebalanceGap = _minRebalanceGap;
        feeRecipient = _feeRecipient;
    }

    // ============ Core Functions ============

    /**
     * @notice Deposit assets and receive shares
     * @param assets Amount of assets to deposit
     */
    function deposit(uint256 assets) external nonReentrant whenNotPaused {
        require(assets > 0, "Amount must be > 0");

        uint256 shares;
        if (totalSupply() == 0) {
            shares = assets;
        } else {
            shares = (assets * totalSupply()) / totalAssets();
        }

        // Transfer assets from user
        asset.safeTransferFrom(msg.sender, address(this), assets);

        // Mint shares
        _mint(msg.sender, shares);

        // Deploy to strategies based on current weights
        _deploy(assets);

        emit Deposit(msg.sender, assets, shares);
    }

    /**
     * @notice Redeem shares for assets
     * @param shares Amount of shares to redeem
     */
    function redeem(uint256 shares) external nonReentrant {
        require(shares > 0, "Shares must be > 0");
        require(balanceOf(msg.sender) >= shares, "Insufficient balance");

        uint256 assets = (shares * totalAssets()) / totalSupply();

        // Burn shares
        _burn(msg.sender, shares);

        // Withdraw from strategies if needed
        uint256 float = asset.balanceOf(address(this));
        if (float < assets) {
            _withdrawFromStrategies(assets - float);
        }

        // Transfer assets to user
        asset.safeTransfer(msg.sender, assets);

        emit Redeem(msg.sender, shares, assets);
    }

    // ============ Strategy Management ============

    function addStrategy(address _strategy) external onlyOwner {
        require(_strategy != address(0), "Invalid strategy");
        strategies.push(IStrategy(_strategy));

        // Approve strategy to spend vault's assets
        asset.approve(_strategy, type(uint256).max);

        emit StrategyAdded(_strategy);
    }

    function removeStrategy(uint256 index) external onlyOwner {
        require(index < strategies.length, "Index out of bounds");

        IStrategy strategy = strategies[index];

        // Withdraw all funds from strategy
        strategy.withdrawAll();

        // Revoke approval
        asset.approve(address(strategy), 0);

        // Remove from array (swap and pop)
        strategies[index] = strategies[strategies.length - 1];
        strategies.pop();

        emit StrategyRemoved(address(strategy));
    }

    // ============ Rebalancing Logic ============

    /**
     * @notice Rebalance funds across strategies based on APY-Weighted algorithm
     * @dev Weight_i = (APY_i * Health_i) / Sum(APY_j * Health_j)
     */
    function rebalance() external nonReentrant {
        require(strategies.length > 0, "No strategies");

        // 1. Check if rebalance is needed (Gap Check)
        uint256 maxAPY = 0;
        uint256 currentWeightedAPY = 0;
        uint256 totalVal = totalAssets();

        if (totalVal == 0) return;

        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 apy = strategies[i].getAPY();
            if (apy > maxAPY) maxAPY = apy;

            uint256 strategyBal = strategies[i].balanceOf();
            currentWeightedAPY += (apy * strategyBal);
        }
        currentWeightedAPY = currentWeightedAPY / totalVal;

        if (maxAPY <= currentWeightedAPY + minRebalanceGap) {
            // Gap is too small, no need to rebalance
            return;
        }

        // 2. Calculate Scores and Total Score
        uint256[] memory scores = new uint256[](strategies.length);
        uint256 totalScore = 0;

        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 apy = strategies[i].getAPY();
            uint256 health = strategies[i].balanceOf(); // Using TVL as health score

            if (health == 0) health = 1e6; // Base weight for empty strategy

            scores[i] = apy * health;
            totalScore += scores[i];
        }

        // 3. Execute Rebalance (Optimized Delta)
        uint256 availableAssets = asset.balanceOf(address(this));
        uint256[] memory targetBalances = new uint256[](strategies.length);

        // Calculate target balances
        for (uint256 i = 0; i < strategies.length; i++) {
            if (totalScore > 0) {
                targetBalances[i] = (totalVal * scores[i]) / totalScore;
            }
        }

        // Withdraw from over-allocated strategies
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 currentBal = strategies[i].balanceOf();
            if (currentBal > targetBalances[i]) {
                uint256 withdrawAmt = currentBal - targetBalances[i];
                strategies[i].withdraw(withdrawAmt);
                availableAssets += withdrawAmt;
            }
        }

        // Deposit to under-allocated strategies
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 currentBal = strategies[i].balanceOf();
            // Note: currentBal might have changed if strategies share state, but usually they don't.
            // We re-check balance to be safe or assume it's same as before if we didn't withdraw.
            // If we withdrew, we are now at target.
            // If we didn't withdraw, we might be under.

            if (currentBal < targetBalances[i]) {
                uint256 deficit = targetBalances[i] - currentBal;
                if (deficit > availableAssets) deficit = availableAssets;

                if (deficit > 0) {
                    strategies[i].deposit(deficit);
                    availableAssets -= deficit;
                }
            }
        }

        emit Rebalanced(block.timestamp, totalAssets());
    }

    // ============ Compound Logic ============

    function compound() external nonReentrant {
        uint256 totalEarned = 0;

        // Harvest from all strategies
        for (uint256 i = 0; i < strategies.length; i++) {
            totalEarned += strategies[i].harvest();
        }

        if (totalEarned > 0) {
            // Calculate fee
            uint256 fee = (totalEarned * performanceFee) / BASIS_POINTS;

            // Send fee
            if (fee > 0) {
                asset.safeTransfer(feeRecipient, fee);
            }

            // Reinvest remainder (already in Vault, will be deployed next deposit or rebalance)
            // For now, we just leave it in float or auto-deploy
            uint256 reinvestAmount = totalEarned - fee;
            _deploy(reinvestAmount);

            emit Compounded(totalEarned, fee, block.timestamp);
        }
    }

    // ============ Internal Functions ============

    function _deploy(uint256 amount) internal {
        if (strategies.length == 0) return;

        // Simple equal deployment if no history, or proportional to current balances
        // For simplicity in this version, we deploy equally if empty, or proportional

        uint256 totalStratBal = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            totalStratBal += strategies[i].balanceOf();
        }

        if (totalStratBal == 0) {
            // Split equally
            uint256 amountPerStrat = amount / strategies.length;
            for (uint256 i = 0; i < strategies.length; i++) {
                strategies[i].deposit(amountPerStrat);
            }
        } else {
            // Proportional to current holdings (maintains current weight)
            for (uint256 i = 0; i < strategies.length; i++) {
                uint256 stratBal = strategies[i].balanceOf();
                uint256 alloc = (amount * stratBal) / totalStratBal;
                if (alloc > 0) {
                    strategies[i].deposit(alloc);
                }
            }
        }
    }

    function _withdrawFromStrategies(uint256 amount) internal {
        uint256 totalStratBal = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            totalStratBal += strategies[i].balanceOf();
        }

        require(totalStratBal >= amount, "Insufficient funds in strategies");

        // Withdraw proportionally
        uint256 amountLeft = amount;
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 withdrawAmount;

            if (i == strategies.length - 1) {
                // Last strategy covers the remaining amount (including rounding dust)
                withdrawAmount = amountLeft;
            } else {
                uint256 stratBal = strategies[i].balanceOf();
                withdrawAmount = (amount * stratBal) / totalStratBal;
            }

            if (withdrawAmount > 0) {
                strategies[i].withdraw(withdrawAmount);
                amountLeft -= withdrawAmount;
            }
        }
    }

    function _withdrawAllFromStrategies() internal {
        for (uint256 i = 0; i < strategies.length; i++) {
            strategies[i].withdrawAll();
        }
    }

    // ============ View Functions ============

    function totalAssets() public view returns (uint256) {
        uint256 total = asset.balanceOf(address(this));
        for (uint256 i = 0; i < strategies.length; i++) {
            total += strategies[i].balanceOf();
        }
        return total;
    }

    function sharePrice() external view returns (uint256) {
        if (totalSupply() == 0) return 1e6; // 1:1 initial
        return (totalAssets() * 1e18) / totalSupply(); // Scaled to 18 decimals for precision
    }
}
