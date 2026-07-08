// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/// @title IUltraFrontendHelper
/// @notice Interface for the UltraFrontendHelper contract that provides helper functions for frontend integration
interface IUltraFrontendHelper {
    ////////////
    // Events //
    ////////////

    event AssetAdded(address indexed asset);
    event AssetRemoved(address indexed asset);

    /////////////
    // Structs //
    /////////////

    /// @notice Struct describing the aggregated state of the vault
    struct VaultState {
        uint256 totalAssets;
        uint256 totalShares;
        uint256 sharePrice;
    }

    /// @notice Struct describing a pending redeem
    struct Redeem {
        address user;
        address asset;
        uint256 shares;
    }

    ////////////////////
    // View Functions //
    ////////////////////

    /// @notice Get the vault address
    /// @return vault The vault address
    function getVault() external view returns (address);

    /// @notice Get the vault state
    /// @return vaultState State of the vault
    function getVaultState() external view returns (VaultState memory);

    /// @notice Preview the number of shares that will be received for a deposit
    /// @param asset The asset to deposit
    /// @param amount The amount of asset to deposit
    /// @return shares The number of shares that will be received
    function previewDeposit(address asset, uint256 amount) external view returns (uint256 shares);

    /// @notice Preview the amount of assets that will be received for a redeem
    /// @param asset The asset to receive
    /// @param shares The number of shares to redeem
    /// @return assets The amount of assets that will be received (after withdrawal fees)
    function previewRedeem(address asset, uint256 shares) external view returns (uint256 assets);

    /// @notice Collect all pending redeems for a list of users
    /// @param users The list of users to collect pending redeems for
    /// @return redeems Array of pending redeems
    function collectPendingRedeems(address[] calldata users) external view returns (Redeem[] memory redeems);

    /////////////////////
    // Admin Functions //
    /////////////////////

    /// @notice Add an additional asset to track
    /// @param asset The asset address to add
    function addAsset(address asset) external;

    /// @notice Remove an asset from tracking
    /// @param asset The asset address to remove
    function removeAsset(address asset) external;
}

