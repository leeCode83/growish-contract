// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStrategy
 * @notice Interface untuk Strategy contract
 * @dev Interface ini digunakan oleh Vault untuk berinteraksi dengan Strategy
 */
interface IStrategy {
    /**
     * @notice Deposit USDC ke protocol
     * @param amount Jumlah USDC yang akan di-deposit
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Withdraw USDC dari protocol
     * @param amount Jumlah USDC yang akan di-withdraw
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Claim earned interest dari protocol
     * @return interest Amount of interest harvested
     */
    function harvest() external returns (uint256 interest);

    /**
     * @notice Emergency withdraw semua dana dari protocol
     */
    function withdrawAll() external;

    /**
     * @notice Get total USDC value di protocol (principal + yield)
     * @return Total value
     */
    function balanceOf() external view returns (uint256);

    /**
     * @notice Return address USDC token
     * @return Address of USDC
     */
    function asset() external view returns (address);

    /**
     * @notice Get current APY from protocol
     * @return APY in basis points
     */
    function getAPY() external view returns (uint256);
}
