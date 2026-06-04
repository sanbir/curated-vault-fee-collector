// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { IBaseVault, IBaseVaultEvents, IBaseVaultErrors } from "src/interfaces/IBaseVault.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";

/// @dev Vault fee configuration
struct Fees {
    // Performance fee rate (100% = 1e18)
    uint64 performanceFee;
    // Management fee rate (100% = 1e18)
    uint64 managementFee;
    // Withdrawal fee rate (100% = 1e18)
    uint64 withdrawalFee;
    // Last fee update timestamp
    uint64 lastUpdateTimestamp;
    // High water mark for performance fees
    uint256 highwaterMark;
}

interface IUltraVaultEvents {
    event FundsHolderProposed(address indexed proposedFundsHolder);
    event FundsHolderChanged(address indexed oldFundsHolder, address indexed newFundsHolder);
    event OracleProposed(address indexed proposedOracle);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event FeesRecipientUpdated(address oldRecipient, address newRecipient);
    event FeesUpdated(Fees oldFees, Fees newFees);
    event FeesCollected(uint256 shares, uint256 managementFee, uint256 performanceFee);
    event WithdrawalFeeCollected(uint256 amount);
}

interface IUltraVaultErrors {
    error ZeroFundsHolderAddress();
    error ZeroOracleAddress();
    error ZeroFeeRecipientAddress();
    error NoPendingFundsHolderUpdate();
    error ProposedFundsHolderMismatch();
    error CannotAcceptFundsHolderYet();
    error FundsHolderUpdateExpired();
    error NoOracleProposed();
    error ProposedOracleMismatch();
    error CannotAcceptOracleYet();
    error OracleUpdateExpired();
    error CannotSetBalancesInNonEmptyVault();
    error InvalidFees();
}

/// @title IUltraVault
/// @notice A simplified interface for use in other contracts
interface IUltraVault is IBaseVault, IUltraVaultEvents, IUltraVaultErrors {
    ////////////////////
    // View Functions //
    ////////////////////

    /// @notice Returns the funds holder address of the vault
    /// @return fundsHolder The address of the funds holder
    function fundsHolder() external view returns (address);

    /// @notice Returns the oracle address of the vault
    /// @return oracle The address of the oracle
    function oracle() external view returns (IPriceSource);

    /// @notice Returns the current fees configuration
    /// @return fees The current fees configuration
    function getFees() external view returns (Fees memory);

    /// @notice Get vault fee recipient
    function feeRecipient() external view returns (address);

    /// @notice Get total accrued fees
    function accruedFees() external view returns (uint256);

    /// @notice Get accrued management fees
    function accruedManagementFees() external view returns (uint256);

    /// @notice Get accrued performance fees
    function accruedPerformanceFees() external view returns (uint256);

    /// @notice Get the withdrawal fee
    function calculateWithdrawalFee(uint256 assets) external view returns (uint256);

    /// @notice Get the proposed funds holder
    function proposedFundsHolder() external view returns (address, uint256);
    
    /// @notice Get the proposed oracle
    function proposedOracle() external view returns (address, uint256);

    /////////////////////
    // Admin Functions //
    /////////////////////

    /// @notice Update vault's fee recipient
    /// @param newFeeRecipient New fee recipient
    function setFeeRecipient(address newFeeRecipient) external;

    /// @notice Update vault fees
    /// @param fees New fee configuration
    function setFees(Fees memory fees) external;

    /// @notice Mint fees as shares to fee recipient
    function collectFees() external;

    /// @notice Propose fundsHolder change, can be accepted after delay
    /// @param newFundsHolder New fundsHolder address
    /// @dev changing the holder should be used only in case of multisig upgrade after funds transfer
    function proposeFundsHolder(address newFundsHolder) external;

    /// @notice Accept proposed fundsHolder
    /// @dev Pauses vault to ensure oracle setup and prevent deposits with faulty prices
    /// @dev Oracle must be switched before unpausing
    function acceptFundsHolder(address newFundsHolder) external;

    /// @notice Propose new oracle for owner acceptance after delay
    /// @param newOracle Address of the new oracle
    function proposeOracle(address newOracle) external;

    /// @notice Accept proposed oracle
    /// @dev Pauses vault to ensure oracle setup and prevent deposits with faulty prices
    /// @dev Oracle must be switched before unpausing
    function acceptProposedOracle(address newOracle) external;

    /// @notice Setup initial balances in the vault without depositing the funds
    /// @notice We expect the funds to be separately sent to funds holder
    /// @param users Array of users to setup balances
    /// @param shares Shares of respective users
    /// @dev Reverts if arrays length mismatch
    function setupInitialBalances(
        address[] memory users,
        uint256[] memory shares
    ) external;
} 
