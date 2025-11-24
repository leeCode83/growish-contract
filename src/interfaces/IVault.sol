// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IVault
 * @notice Interface untuk Vault contract
 * @dev Inherits IERC20 karena Vault adalah token (shares)
 */
interface IVault is IERC20 {
    // ============ Events ============

    event Deposit(address indexed user, uint256 assets, uint256 shares);
    event Redeem(address indexed user, uint256 shares, uint256 assets);
    event StrategyAdded(address strategy);
    event StrategyRemoved(address strategy);
    event Rebalanced(uint256 timestamp, uint256 totalAssets);
    event Compounded(uint256 earned, uint256 fee, uint256 timestamp);

    // ============ View Functions ============

    /**
     * @notice Get underlying asset (USDC)
     */
    function asset() external view returns (IERC20);

    /**
     * @notice Get minimum gap for rebalancing
     */
    function minRebalanceGap() external view returns (uint256);

    /**
     * @notice Get fee recipient address
     */
    function feeRecipient() external view returns (address);

    /**
     * @notice Get performance fee in basis points
     */
    function performanceFee() external view returns (uint256);

    /**
     * @notice Get total assets managed by vault (Vault + Strategies)
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Get current share price in assets
     */
    function sharePrice() external view returns (uint256);

    // ============ Core Functions ============

    /**
     * @notice Deposit assets and receive shares
     * @param assets Amount of assets to deposit
     */
    function deposit(uint256 assets) external;

    /**
     * @notice Redeem shares for assets
     * @param shares Amount of shares to redeem
     */
    function redeem(uint256 shares) external;

    // ============ Strategy Management ============

    /**
     * @notice Add a new strategy
     * @param _strategy Address of the strategy contract
     */
    function addStrategy(address _strategy) external;

    /**
     * @notice Remove a strategy by index
     * @param index Index of the strategy to remove
     */
    function removeStrategy(uint256 index) external;

    // ============ Operations ============

    /**
     * @notice Rebalance funds across strategies based on APY-Weighted algorithm
     */
    function rebalance() external;

    /**
     * @notice Harvest yield from strategies and reinvest
     */
    function compound() external;
}
