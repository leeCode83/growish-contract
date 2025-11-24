// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVault.sol";

/**
 * @title Router
 * @notice Entry point untuk semua user interactions dengan StableYield protocol
 * @dev Mengelola batching deposits/withdrawals untuk gas optimization
 */
contract Router is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum RiskLevel {
        Conservative, // 0
        Balanced, // 1
        Aggressive // 2
    }

    // ============ Structs ============

    struct UserDeposit {
        uint256 amount;
        uint256 timestamp;
    }

    struct UserWithdraw {
        uint256 shares;
        uint256 timestamp;
    }

    // ============ State Variables ============

    // USDC stablecoin address
    IERC20 public immutable usdc;

    // Vault addresses per risk level
    mapping(RiskLevel => IVault) public vaults;

    // Pending deposits: user => RiskLevel => deposit info
    mapping(address => mapping(RiskLevel => UserDeposit))
        public pendingDeposits;

    // Pending withdraws: user => RiskLevel => withdraw info
    mapping(address => mapping(RiskLevel => UserWithdraw))
        public pendingWithdraws;

    // Total pending amounts per risk level
    mapping(RiskLevel => uint256) public totalPendingDeposits;
    mapping(RiskLevel => uint256) public totalPendingWithdraws;

    // List of users dengan pending deposits/withdraws (untuk batch processing)
    mapping(RiskLevel => address[]) public depositUsers;
    mapping(RiskLevel => address[]) public withdrawUsers;

    // Pointers for FIFO processing
    mapping(RiskLevel => uint256) public depositBatchPointer;
    mapping(RiskLevel => uint256) public withdrawBatchPointer;

    // Track if user sudah di list (untuk avoid duplicates)
    mapping(address => mapping(RiskLevel => bool)) public isInDepositList;
    mapping(address => mapping(RiskLevel => bool)) public isInWithdrawList;

    // Claimable amounts: user => RiskLevel => amount
    mapping(address => mapping(RiskLevel => uint256)) public claimableShares;
    mapping(address => mapping(RiskLevel => uint256)) public claimableUSDC;

    // Batch timing - deposits/withdraws executed setiap X hours
    uint256 public batchInterval = 6 hours;
    mapping(RiskLevel => uint256) public lastBatchTime;

    // Minimum deposit amount (e.g., $10)
    uint256 public minDepositAmount = 10e6; // 10 USDC (6 decimals)

    // ============ Events ============

    event DepositQueued(
        address indexed user,
        RiskLevel indexed riskLevel,
        uint256 amount,
        uint256 nextBatchTime
    );

    event WithdrawQueued(
        address indexed user,
        RiskLevel indexed riskLevel,
        uint256 shares,
        uint256 nextBatchTime
    );

    event BatchDepositsExecuted(
        RiskLevel indexed riskLevel,
        uint256 totalAmount,
        uint256 userCount,
        uint256 timestamp
    );

    event BatchWithdrawsExecuted(
        RiskLevel indexed riskLevel,
        uint256 totalShares,
        uint256 totalAssets,
        uint256 userCount,
        uint256 timestamp
    );

    event VaultSet(RiskLevel indexed riskLevel, address vaultAddress);
    event MinDepositAmountUpdated(uint256 newAmount);
    event BatchIntervalUpdated(uint256 newInterval);
    event DepositClaimed(
        address indexed user,
        RiskLevel indexed riskLevel,
        uint256 shares
    );
    event WithdrawClaimed(
        address indexed user,
        RiskLevel indexed riskLevel,
        uint256 assets
    );

    // ============ Constructor ============

    /**
     * @notice Initialize Router contract
     * @param _usdc Address of USDC stablecoin contract
     */
    constructor(address _usdc) Ownable(msg.sender) {
        require(_usdc != address(0), "Invalid USDC address");
        usdc = IERC20(_usdc);
    }

    // ============ User Functions ============

    /**
     * @notice User deposit USDC ke batching queue
     * @param amount Jumlah USDC yang akan di-deposit (6 decimals)
     * @param riskLevel Risk level vault (Conservative/Balanced/Aggressive)
     * @dev USDC akan masuk pending queue sampai executeBatch() dipanggil
     * @dev User harus approve Router untuk spend USDC terlebih dahulu
     */
    function deposit(
        uint256 amount,
        RiskLevel riskLevel
    ) external nonReentrant whenNotPaused {
        require(amount >= minDepositAmount, "Amount below minimum");
        require(address(vaults[riskLevel]) != address(0), "Vault not set");

        // Transfer USDC from user to Router
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Update atau add pending deposit
        if (pendingDeposits[msg.sender][riskLevel].amount == 0) {
            // First deposit untuk risk level ini
            if (!isInDepositList[msg.sender][riskLevel]) {
                depositUsers[riskLevel].push(msg.sender);
                isInDepositList[msg.sender][riskLevel] = true;
            }
        }

        // Add to pending deposits
        pendingDeposits[msg.sender][riskLevel].amount += amount;
        pendingDeposits[msg.sender][riskLevel].timestamp = block.timestamp;
        totalPendingDeposits[riskLevel] += amount;

        // Calculate next batch time
        uint256 nextBatch = lastBatchTime[riskLevel] + batchInterval;

        emit DepositQueued(msg.sender, riskLevel, amount, nextBatch);
    }

    /**
     * @notice User request withdraw shares dari vault
     * @param shares Jumlah vault shares yang akan di-withdraw
     * @param riskLevel Risk level vault yang akan di-withdraw
     * @dev Shares akan masuk pending queue sampai executeBatch() dipanggil
     * @dev User harus memiliki shares di vault tersebut
     */
    function withdraw(
        uint256 shares,
        RiskLevel riskLevel
    ) external nonReentrant whenNotPaused {
        require(shares > 0, "Shares must be > 0");
        IVault vault = vaults[riskLevel];
        require(address(vault) != address(0), "Vault not set");

        // Check user has enough shares
        uint256 userShares = vault.balanceOf(msg.sender);
        require(userShares >= shares, "Insufficient shares");

        // Transfer shares from user to Router
        vault.transferFrom(msg.sender, address(this), shares);

        // Update atau add pending withdraw
        if (pendingWithdraws[msg.sender][riskLevel].shares == 0) {
            // First withdraw untuk risk level ini
            if (!isInWithdrawList[msg.sender][riskLevel]) {
                withdrawUsers[riskLevel].push(msg.sender);
                isInWithdrawList[msg.sender][riskLevel] = true;
            }
        }

        // Add to pending withdraws
        pendingWithdraws[msg.sender][riskLevel].shares += shares;
        pendingWithdraws[msg.sender][riskLevel].timestamp = block.timestamp;
        totalPendingWithdraws[riskLevel] += shares;

        // Calculate next batch time
        uint256 nextBatch = lastBatchTime[riskLevel] + batchInterval;

        emit WithdrawQueued(msg.sender, riskLevel, shares, nextBatch);
    }

    // ============ Claim Functions ============

    /**
     * @notice User claim shares setelah deposit batch executed
     * @param riskLevel Risk level vault
     * @dev Shares sudah di-mint ke Router saat batch, user claim untuk transfer ke wallet
     */
    function claimDepositShares(RiskLevel riskLevel) external nonReentrant {
        IVault vault = vaults[riskLevel];
        require(address(vault) != address(0), "Vault not set");

        uint256 shares = claimableShares[msg.sender][riskLevel];
        require(shares > 0, "No shares to claim");

        // Reset claimable amount first (reentrancy protection pattern)
        claimableShares[msg.sender][riskLevel] = 0;

        // Transfer shares to user
        vault.transfer(msg.sender, shares);

        emit DepositClaimed(msg.sender, riskLevel, shares);
    }

    /**
     * @notice User claim USDC setelah withdraw batch executed
     * @param riskLevel Risk level vault
     */
    function claimWithdrawAssets(RiskLevel riskLevel) external nonReentrant {
        uint256 amount = claimableUSDC[msg.sender][riskLevel];
        require(amount > 0, "No USDC to claim");

        // Reset claimable amount first
        claimableUSDC[msg.sender][riskLevel] = 0;

        // Transfer USDC to user
        usdc.safeTransfer(msg.sender, amount);

        emit WithdrawClaimed(msg.sender, riskLevel, amount);
    }

    // ============ View Functions ============

    /**
     * @notice Get user's pending deposit amount untuk risk level tertentu
     * @param user Address of user
     * @param riskLevel Risk level to check
     * @return amount Pending deposit amount dalam USDC
     */
    function getPendingDeposit(
        address user,
        RiskLevel riskLevel
    ) external view returns (uint256 amount) {
        return pendingDeposits[user][riskLevel].amount;
    }

    /**
     * @notice Get user's pending withdraw shares untuk risk level tertentu
     * @param user Address of user
     * @param riskLevel Risk level to check
     * @return shares Pending withdraw shares amount
     */
    function getPendingWithdraw(
        address user,
        RiskLevel riskLevel
    ) external view returns (uint256 shares) {
        return pendingWithdraws[user][riskLevel].shares;
    }

    /**
     * @notice Check kapan next batch akan di-execute untuk risk level tertentu
     * @param riskLevel Risk level to check
     * @return nextBatchTime Timestamp kapan batch bisa di-execute
     */
    function getNextBatchTime(
        RiskLevel riskLevel
    ) external view returns (uint256 nextBatchTime) {
        return lastBatchTime[riskLevel] + batchInterval;
    }

    /**
     * @notice Check apakah batch ready untuk di-execute
     * @param riskLevel Risk level to check
     * @return ready True jika batch interval sudah lewat
     */
    function isBatchReady(
        RiskLevel riskLevel
    ) public view returns (bool ready) {
        return block.timestamp >= lastBatchTime[riskLevel] + batchInterval;
    }

    /**
     * @notice Get jumlah users dalam deposit queue
     * @param riskLevel Risk level to check
     * @return count Number of users
     */
    function getDepositUserCount(
        RiskLevel riskLevel
    ) external view returns (uint256 count) {
        return depositUsers[riskLevel].length - depositBatchPointer[riskLevel];
    }

    /**
     * @notice Get jumlah users dalam withdraw queue
     * @param riskLevel Risk level to check
     * @return count Number of users
     */
    function getWithdrawUserCount(
        RiskLevel riskLevel
    ) external view returns (uint256 count) {
        return
            withdrawUsers[riskLevel].length - withdrawBatchPointer[riskLevel];
    }

    // ============ Keeper Functions ============

    /**
     * @notice Execute batch deposits untuk risk level tertentu
     * @param riskLevel Risk level vault yang akan diprocess
     * @dev Hanya bisa dipanggil setelah batch interval berlalu
     * @dev Function ini akan dipanggil oleh keeper bot atau Chainlink Automation
     */
    function executeBatchDeposits(
        RiskLevel riskLevel
    ) public nonReentrant whenNotPaused {
        require(isBatchReady(riskLevel), "Batch not ready yet");
        uint256 pointer = depositBatchPointer[riskLevel];
        uint256 queueLength = depositUsers[riskLevel].length;
        require(queueLength > pointer, "No pending deposits");

        IVault vault = vaults[riskLevel];
        require(address(vault) != address(0), "Vault not set");

        uint256 batchSize = 20;
        uint256 batchAmount = 0;

        // Temp array to store users processed in this batch
        address[] memory batchUsers = new address[](batchSize);
        uint256 actualUserCount = 0;

        // Process users FIFO
        {
            uint256 processedCount = 0;
            while (processedCount < batchSize && pointer < queueLength) {
                address user = depositUsers[riskLevel][pointer];

                // Clear storage to refund gas
                delete depositUsers[riskLevel][pointer];
                pointer++;

                uint256 userAmount = pendingDeposits[user][riskLevel].amount;

                if (userAmount > 0) {
                    batchAmount += userAmount;
                    batchUsers[actualUserCount] = user;
                    actualUserCount++;
                } else {
                    isInDepositList[user][riskLevel] = false;
                }
                processedCount++;
            }
            // Update pointer
            depositBatchPointer[riskLevel] = pointer;
        }

        if (batchAmount > 0) {
            // Approve vault to spend USDC
            usdc.approve(address(vault), batchAmount);

            // Record shares before deposit
            uint256 sharesBefore = vault.balanceOf(address(this));

            // Call vault's deposit function
            vault.deposit(batchAmount);

            // Calculate shares minted
            uint256 sharesAfter = vault.balanceOf(address(this));
            uint256 sharesMinted = sharesAfter - sharesBefore;

            require(sharesMinted > 0, "No shares minted");

            // Distribute shares
            for (uint256 i = 0; i < actualUserCount; i++) {
                address user = batchUsers[i];
                uint256 userAmount = pendingDeposits[user][riskLevel].amount;

                uint256 userShares = (sharesMinted * userAmount) / batchAmount;
                claimableShares[user][riskLevel] += userShares;

                delete pendingDeposits[user][riskLevel];
                isInDepositList[user][riskLevel] = false;
            }

            totalPendingDeposits[riskLevel] -= batchAmount;
        }

        // Reset queue if empty
        if (depositBatchPointer[riskLevel] == depositUsers[riskLevel].length) {
            delete depositUsers[riskLevel];
            depositBatchPointer[riskLevel] = 0;
            lastBatchTime[riskLevel] = block.timestamp;
        }

        emit BatchDepositsExecuted(
            riskLevel,
            batchAmount,
            actualUserCount,
            block.timestamp
        );
    }

    /**
     * @notice Execute batch withdraws untuk risk level tertentu
     * @param riskLevel Risk level vault yang akan diprocess
     * @dev Hanya bisa dipanggil setelah batch interval berlalu
     */
    function executeBatchWithdraws(
        RiskLevel riskLevel
    ) public nonReentrant whenNotPaused {
        require(isBatchReady(riskLevel), "Batch not ready yet");
        uint256 pointer = withdrawBatchPointer[riskLevel];
        uint256 queueLength = withdrawUsers[riskLevel].length;
        require(queueLength > pointer, "No pending withdraws");

        IVault vault = vaults[riskLevel];
        require(address(vault) != address(0), "Vault not set");

        uint256 batchSize = 20;
        uint256 batchShares = 0;

        // Temp array to store users processed in this batch
        address[] memory batchUsers = new address[](batchSize);
        uint256 actualUserCount = 0;

        // Process users FIFO
        {
            uint256 processedCount = 0;
            while (processedCount < batchSize && pointer < queueLength) {
                address user = withdrawUsers[riskLevel][pointer];

                // Clear storage
                delete withdrawUsers[riskLevel][pointer];
                pointer++;

                uint256 userShares = pendingWithdraws[user][riskLevel].shares;

                if (userShares > 0) {
                    batchShares += userShares;
                    batchUsers[actualUserCount] = user;
                    actualUserCount++;
                } else {
                    isInWithdrawList[user][riskLevel] = false;
                }
                processedCount++;
            }
            // Update pointer
            withdrawBatchPointer[riskLevel] = pointer;
        }

        if (batchShares > 0) {
            // Record USDC before redeem
            uint256 usdcBefore = usdc.balanceOf(address(this));

            // Call vault's redeem function
            vault.redeem(batchShares);

            // Calculate USDC received
            uint256 usdcAfter = usdc.balanceOf(address(this));
            uint256 usdcReceived = usdcAfter - usdcBefore;

            require(usdcReceived > 0, "No USDC received");

            // Distribute USDC proporsional ke users
            for (uint256 i = 0; i < actualUserCount; i++) {
                address user = batchUsers[i];
                uint256 userShares = pendingWithdraws[user][riskLevel].shares;

                uint256 userUSDC = (usdcReceived * userShares) / batchShares;
                claimableUSDC[user][riskLevel] += userUSDC;

                delete pendingWithdraws[user][riskLevel];
                isInWithdrawList[user][riskLevel] = false;
            }

            totalPendingWithdraws[riskLevel] -= batchShares;
        }

        // Reset queue if empty
        if (
            withdrawBatchPointer[riskLevel] == withdrawUsers[riskLevel].length
        ) {
            delete withdrawUsers[riskLevel];
            withdrawBatchPointer[riskLevel] = 0;
            lastBatchTime[riskLevel] = block.timestamp;
        }

        emit BatchWithdrawsExecuted(
            riskLevel,
            batchShares,
            0,
            actualUserCount,
            block.timestamp
        );
    }

    /**
     * @notice Execute both deposits and withdraws dalam satu transaction (gas efficient)
     * @param riskLevel Risk level to process
     */
    function executeBatch(
        RiskLevel riskLevel
    ) external nonReentrant whenNotPaused {
        require(isBatchReady(riskLevel), "Batch not ready yet");

        bool hasDeposits = totalPendingDeposits[riskLevel] > 0;
        bool hasWithdraws = totalPendingWithdraws[riskLevel] > 0;

        require(hasDeposits || hasWithdraws, "No pending transactions");

        if (hasDeposits) {
            executeBatchDeposits(riskLevel);
        }

        if (hasWithdraws) {
            executeBatchWithdraws(riskLevel);
        }
    }

    /**
     * @notice Execute batch untuk semua risk levels sekaligus
     * @dev Untuk efficiency, execute semua yang ready dalam 1 transaction
     */
    function executeBatchAll() external nonReentrant whenNotPaused {
        for (uint256 i = 0; i < 3; i++) {
            RiskLevel risk = RiskLevel(i);

            if (isBatchReady(risk)) {
                bool hasDeposits = totalPendingDeposits[risk] > 0;
                bool hasWithdraws = totalPendingWithdraws[risk] > 0;

                if (hasDeposits) {
                    executeBatchDeposits(risk);
                }

                if (hasWithdraws) {
                    executeBatchWithdraws(risk);
                }
            }
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Set vault address untuk risk level tertentu
     * @param riskLevel Risk level (Conservative/Balanced/Aggressive)
     * @param vaultAddress Address of vault contract
     * @dev Only owner can call this
     */
    function setVault(
        RiskLevel riskLevel,
        address vaultAddress
    ) external onlyOwner {
        require(vaultAddress != address(0), "Invalid vault address");
        vaults[riskLevel] = IVault(vaultAddress);

        // Initialize last batch time jika belum di-set
        if (lastBatchTime[riskLevel] == 0) {
            lastBatchTime[riskLevel] = block.timestamp;
        }

        emit VaultSet(riskLevel, vaultAddress);
    }

    /**
     * @notice Update minimum deposit amount
     * @param newAmount New minimum amount dalam USDC (6 decimals)
     */
    function setMinDepositAmount(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "Amount must be > 0");
        minDepositAmount = newAmount;
        emit MinDepositAmountUpdated(newAmount);
    }

    /**
     * @notice Update batch interval
     * @param newInterval New interval in seconds
     */
    function setBatchInterval(uint256 newInterval) external onlyOwner {
        require(newInterval >= 1 hours, "Interval too short");
        require(newInterval <= 24 hours, "Interval too long");
        batchInterval = newInterval;
        emit BatchIntervalUpdated(newInterval);
    }

    /**
     * @notice Force execute batch bahkan sebelum interval (untuk testing/emergency)
     * @param riskLevel Risk level to force execute
     */
    function forceExecuteBatch(RiskLevel riskLevel) external onlyOwner {
        bool hasDeposits = totalPendingDeposits[riskLevel] > 0;
        bool hasWithdraws = totalPendingWithdraws[riskLevel] > 0;

        require(hasDeposits || hasWithdraws, "No pending transactions");

        if (hasDeposits) {
            executeBatchDeposits(riskLevel);
        }

        if (hasWithdraws) {
            executeBatchWithdraws(riskLevel);
        }
    }

    /**
     * @notice Pause contract (emergency)
     * @dev Stops all deposits and withdraws
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency withdraw stuck tokens
     * @param token Address of token to rescue
     * @param amount Amount to withdraw
     * @dev Only untuk emergency jika ada token yang stuck
     */
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Cancel pending deposit (emergency untuk user) - Admin version
     * @param user User address
     * @param riskLevel Risk level
     * @dev Only owner untuk handle emergency user requests
     */
    function cancelPendingDeposit(
        address user,
        RiskLevel riskLevel
    ) external onlyOwner {
        uint256 amount = pendingDeposits[user][riskLevel].amount;
        require(amount > 0, "No pending deposit");

        // Return USDC to user
        usdc.safeTransfer(user, amount);

        // Update totals
        totalPendingDeposits[riskLevel] -= amount;

        // Clear pending
        delete pendingDeposits[user][riskLevel];
        isInDepositList[user][riskLevel] = false;
    }

    /**
     * @notice Cancel pending withdraw (emergency untuk user) - Admin version
     * @param user User address
     * @param riskLevel Risk level
     * @dev Only owner untuk handle emergency user requests
     */
    function cancelPendingWithdraw(
        address user,
        RiskLevel riskLevel
    ) external onlyOwner {
        uint256 shares = pendingWithdraws[user][riskLevel].shares;
        require(shares > 0, "No pending withdraw");

        IVault vault = vaults[riskLevel];

        // Return shares to user
        vault.transfer(user, shares);

        // Update totals
        totalPendingWithdraws[riskLevel] -= shares;

        // Clear pending
        delete pendingWithdraws[user][riskLevel];
        isInWithdrawList[user][riskLevel] = false;
    }
}
