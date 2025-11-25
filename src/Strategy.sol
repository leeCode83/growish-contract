// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IMockProtocol.sol";

/**
 * @title Strategy
 * @notice Jembatan antara Vault dan MockProtocol
 * @dev Handle interaksi teknis dengan protocol (deposit, withdraw, harvest yield)
 */
contract Strategy is Ownable {
    using SafeERC20 for IERC20;

    // ============ State Variables ============

    IERC20 public immutable usdc;
    IMockProtocol public immutable protocol;
    address public immutable conservativeVault;
    address public immutable balancedVault;
    address public immutable aggressiveVault;

    // ============ Constructor ============

    /**
     * @notice Initialize Strategy contract
     * @param _usdc Address of USDC stablecoin contract
     * @param _protocol Address of MockProtocol contract
     */
    constructor(address _usdc, address _protocol, address _conservativeVault, address _balancedVault, address _aggressiveVault) Ownable(msg.sender) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_protocol != address(0), "Invalid protocol address");
        usdc = IERC20(_usdc);
        protocol = IMockProtocol(_protocol);
        conservativeVault = _conservativeVault;
        balancedVault = _balancedVault;
        aggressiveVault = _aggressiveVault;
    }

    modifier onlyVault(){
        require(msg.sender == conservativeVault || msg.sender == balancedVault || msg.sender == aggressiveVault, "Not authorized");
        _;
    }

    // ============ Core Functions ============

    /**
     * @notice Deposit USDC ke protocol
     * @param amount Jumlah USDC yang akan di-deposit
     * @dev Hanya bisa dipanggil oleh owner (Vault)
     */
    function deposit(uint256 amount) external onlyVault {
        require(amount > 0, "Amount must be > 0");

        // Transfer USDC dari Vault ke Strategy
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Approve Protocol untuk spend USDC
        usdc.approve(address(protocol), amount);

        // Supply ke Protocol
        protocol.supply(address(usdc), amount, address(this));
    }

    /**
     * @notice Withdraw USDC dari protocol
     * @param amount Jumlah USDC yang akan di-withdraw
     * @dev Hanya bisa dipanggil oleh owner (Vault)
     */
    function withdraw(uint256 amount) external onlyVault {
        require(amount > 0, "Amount must be > 0");

        // Withdraw dari Protocol ke Strategy
        protocol.withdraw(address(usdc), amount, address(this));

        // Transfer USDC ke Vault
        usdc.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Claim earned interest dari protocol
     * @return interest Amount of interest harvested
     * @dev Hanya bisa dipanggil oleh owner (Vault)
     */
    function harvest() external onlyVault returns (uint256 interest) {
        // Get pending interest
        interest = protocol.getPendingInterest(address(this));

        if (interest > 0) {
            // Withdraw interest only
            protocol.withdraw(address(usdc), interest, address(this));

            // Transfer interest ke Vault
            usdc.safeTransfer(msg.sender, interest);
        }

        return interest;
    }

    /**
     * @notice Emergency withdraw semua dana dari protocol
     * @dev Hanya bisa dipanggil oleh owner (Vault)
     */
    function withdrawAll() external onlyVault {
        uint256 totalBalance = protocol.getSuppliedBalance(address(this));

        if (totalBalance > 0) {
            // Withdraw semua dari Protocol
            protocol.withdraw(address(usdc), totalBalance, address(this));

            // Transfer semua USDC yang ada di Strategy ke Vault
            uint256 balance = usdc.balanceOf(address(this));
            if (balance > 0) {
                usdc.safeTransfer(msg.sender, balance);
            }
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get total USDC value di protocol (principal + yield)
     * @return Total value
     */
    function balanceOf() external view returns (uint256) {
        return protocol.getSuppliedBalance(address(this));
    }

    /**
     * @notice Return address USDC token
     * @return Address of USDC
     */
    function asset() external view returns (address) {
        return address(usdc);
    }

    /**
     * @notice Get current APY from protocol
     * @return APY in basis points
     */
    function getAPY() external view returns (uint256) {
        return protocol.getAPY();
    }
}
