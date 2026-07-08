// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { Adjustment } from "uyv2/interfaces/Types.sol";

/// @title IUltraVaultRateProvider
/// @notice Handles rate calculations between assets for UltraVault
interface IUltraVaultRateProvider {
    ////////////
    // Events //
    ////////////

    /// @notice Emitted when a new asset is added
    /// @param asset Asset that was added
    /// @param isPegged Whether the asset is pegged to base asset
    /// @param rateProvider External rate provider if not pegged
    /// @param adjustmentRate Adjustment rate (1e16 = 1%)
    event AssetAdded(address indexed asset, bool isPegged, address rateProvider, uint56 adjustmentRate);

    /// @notice Emitted when an asset is removed
    /// @param asset Asset that was removed
    event AssetRemoved(address indexed asset);

    /// @notice Emitted when the rate provider for an asset is updated
    /// @param asset Asset that was updated
    /// @param oldRateProvider Old rate provider
    /// @param newRateProvider New rate provider
    event RateProviderUpdated(address indexed asset, address oldRateProvider, address newRateProvider);

    /// @notice Emitted when the adjustment for an asset is updated
    /// @param asset Asset that was updated
    /// @param oldAdjustmentRate Old adjustment rate (1e16 = 1%)
    /// @param newAdjustmentRate New adjustment rate (1e16 = 1%)
    event AdjustmentRateUpdated(address indexed asset, uint56 oldAdjustmentRate, uint56 newAdjustmentRate);

    ////////////
    // Errors //
    ////////////

    /// @notice Thrown when an asset is not supported
    error AssetNotSupported();

    /// @notice Thrown when an asset is already supported
    error AssetAlreadySupported();

    /// @notice Thrown when an invalid rate provider is provided
    error InvalidRateProvider();

    /// @notice Thrown when an asset has invalid decimals
    error InvalidDecimals();

    /// @notice Thrown when an adjustment rate is too high
    error AdjustmentRateTooHigh();

    /// @notice Thrown when an unknown adjustment is provided
    error UnknownAdjustment();
    
    /// @notice Thrown when trying to update settings for the base asset
    error CannotUpdateBaseAsset();

    ////////////////////
    // View Functions //
    ////////////////////

    /// @notice The base asset used for rate calculations
    function baseAsset() external view returns (address);

    /// @notice The number of decimals of the base asset
    function baseDecimals() external view returns (uint8);

    /// @notice Get the info for a supported asset
    /// @param asset The asset to get info for
    /// @return isPegged Whether the asset is pegged to base asset
    /// @return decimals The number of decimals of the asset
    /// @return rateProvider The external rate provider if not pegged
    /// @return adjustmentRate The adjustment rate (1e16 = 1%)
    function getAssetInfo(address asset) external view returns (bool isPegged, uint8 decimals, address rateProvider, uint56 adjustmentRate);

    /// @notice Get the list of supported assets
    /// @return assets List of supported assets
    function getSupportedAssets() external view returns (address[] memory);

    /// @notice Check if an asset is supported
    /// @param asset The asset to check
    /// @return True if asset is supported
    function isSupported(address asset) external view returns (bool);

    /// @notice Get the rate between an asset and the base asset
    /// @param asset The asset to get rate for
    /// @param assets Amount to covert
    /// @param adjustment The adjustment to apply
    /// @return result The rate in terms of base asset (18 decimals)
    function convertToUnderlying(address asset, uint256 assets, Adjustment adjustment) external view returns (uint256 result);

    /// @notice V1-compatible convertToUnderlying with no adjustment
    /// @dev Allows a V1 vault to use this V2 rate provider before the vault is upgraded
    /// @param asset The asset to get rate for
    /// @param assets Amount to convert
    /// @return result The rate in terms of base asset (18 decimals)
    function convertToUnderlying(address asset, uint256 assets) external view returns (uint256 result);

    /// @notice Convert from base asset to specific asset
    /// @param asset The asset to convert to
    /// @param baseAssets Amount in base asset units
    /// @param adjustment The adjustment to apply
    /// @return result The amount in asset units
    function convertFromUnderlying(address asset, uint256 baseAssets, Adjustment adjustment) external view returns (uint256 result);

    /// @notice V1-compatible convertFromUnderlying with no adjustment
    /// @dev Allows a V1 vault to use this V2 rate provider before the vault is upgraded
    /// @param asset The asset to convert to
    /// @param baseAssets Amount in base asset units
    /// @return result The amount in asset units
    function convertFromUnderlying(address asset, uint256 baseAssets) external view returns (uint256 result);

    /////////////////////
    // Write Functions //
    /////////////////////

    /// @notice Add a new supported asset
    /// @param asset The asset to add
    /// @param isPegged Whether the asset is pegged to base asset
    /// @param rateProvider External rate provider if not pegged
    /// @param adjustmentRate Adjustment rate (1e16 = 1%)
    function addAsset(address asset, bool isPegged, address rateProvider, uint56 adjustmentRate) external;

    /// @notice Remove a supported asset
    /// @param asset The asset to remove
    function removeAsset(address asset) external;

    /// @notice Update rate provider for an asset
    /// @param asset The asset to update
    /// @param isPegged Whether the asset is pegged to base asset
    /// @param newRateProvider New rate provider
    function updateRateProvider(address asset, bool isPegged, address newRateProvider) external;

    /// @notice Update adjustment for an asset
    /// @param asset The asset to update
    /// @param newAdjustmentRate New adjustment rate (1e16 = 1%)
    function updateAdjustmentRate(address asset, uint56 newAdjustmentRate) external;
} 
