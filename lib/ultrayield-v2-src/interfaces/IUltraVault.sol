// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { IBaseVault, IBaseVaultEvents, IBaseVaultErrors } from "uyv2/interfaces/IBaseVault.sol";
import { IPriceSource } from "uyv2/interfaces/IPriceSource.sol";
import { Fees } from "uyv2/interfaces/Types.sol";
import { ICompliance, IComplianceEvents, IComplianceErrors } from "uyv2/interfaces/ICompliance.sol";

interface IUltraVaultEvents is IBaseVaultEvents, IComplianceEvents {
    event FeesRecipientUpdated(address oldRecipient, address newRecipient);
    event FeesUpdated(Fees oldFees, Fees newFees);
    event FeesCollected(
        uint256 shares,
        uint256 managementFee,
        uint256 performanceFee,
        uint256 totalAssets,
        uint256 totalShares,
        uint256 sharePrice
    );
    event WithdrawalFeeCollected(uint256 amount);
    event InstantRedeem(
        address indexed controller,
        address indexed receiver,
        address indexed asset,
        uint256 shares,
        uint256 assets,
        uint256 fee
    );
}

interface IUltraVaultErrors is IBaseVaultErrors, IComplianceErrors {
    error ZeroFeeRecipientAddress();
    error CannotSetBalancesInNonEmptyVault();
    error InvalidFees();
    error InsufficientLiquidity(address asset, uint256 requested, uint256 available);
    error InstantRedeemSlippageExceeded(uint256 received, uint256 minAssets);
}

/// @title IUltraVault
/// @notice A simplified interface for use in other contracts
interface IUltraVault is IBaseVault, ICompliance {
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
    function accruedFees() external view returns (uint256 managementFee, uint256 performanceFee);

    /// @notice Get the withdrawal fee
    function calculateWithdrawalFee(uint256 assets) external view returns (uint256);

    /// @notice Returns the instant redeem exitpoint address
    function instantRedeemExitpoint() external view returns (address);

    ////////////////////
    // Instant Redeem //
    ////////////////////

    /// @notice Returns the available liquidity for instant redeem of a given asset
    /// @param asset The asset address to check liquidity for
    /// @return liquidity The available liquidity (minimum of exitpoint balance and allowance to this vault)
    function getLiquidity(address asset) external view returns (uint256 liquidity);

    /// @notice Returns the maximum shares a controller can instant-redeem for a given asset
    /// @dev Considers both the controller's share balance and available liquidity (min of exitpoint balance and allowance)
    /// @param asset The asset address to redeem for
    /// @param controller The address whose shares would be redeemed
    /// @return shares The maximum redeemable shares
    function maxInstantRedeem(
        address asset,
        address controller
    ) external view returns (uint256 shares);

    /// @notice Previews the net assets a receiver would get for instant-redeeming a given number of shares
    /// @dev Returns gross assets minus the additive fee (withdrawalFee + instantRedeemPremium)
    /// @param _asset The asset address to receive
    /// @param shares The number of shares to redeem
    /// @return assets The net asset amount after fee deduction
    function previewInstantRedeem(
        address _asset,
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Instantly redeems shares for assets, bypassing the async redemption queue
    /// @dev Burns shares from controller, transfers net assets to receiver, transfers fee to feeRecipient.
    ///      Collects accrued fees before processing. Reverts if insufficient liquidity.
    ///      Reverts with InstantRedeemSlippageExceeded if netAssets < minAssets.
    /// @param asset The asset address to receive
    /// @param shares The number of shares to redeem
    /// @param minAssets Minimum net assets the receiver must receive; reverts InstantRedeemSlippageExceeded if not met. Pass 0 to disable.
    /// @param receiver The address to receive the net assets
    /// @param controller The address whose shares are burned
    /// @return assets The net asset amount transferred to receiver (after fee deduction)
    function instantRedeem(
        address asset,
        uint256 shares,
        uint256 minAssets,
        address receiver,
        address controller
    ) external returns (uint256 assets);

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

    /// @notice Setup initial balances in the vault without depositing the funds
    /// @notice We expect the funds to be separately sent to funds holder
    /// @param users Array of users to setup balances
    /// @param shares Shares of respective users
    /// @dev Reverts if arrays length mismatch
    function setupInitialBalances(
        address[] memory users,
        uint256[] memory shares
    ) external;

    /// @notice Cancel a user's pending redeem and return the locked shares to the controller's wallet
    /// @dev Bypasses compliance restrictions so cleanup works even when the controller is blocklisted or frozen.
    /// @param asset The asset originally requested for redemption
    /// @param controller The user whose pending redeem is being cancelled
    /// @return shares The amount of shares returned to the controller
    function cancelRedeemRequestByOperator(
        address asset,
        address controller
    ) external returns (uint256 shares);
}
