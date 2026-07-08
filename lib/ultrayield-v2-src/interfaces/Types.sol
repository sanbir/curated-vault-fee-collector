// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/// @notice Adjustment type for asset conversion
enum Adjustment {
    DOWN,
    UP
}

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
    // Instant redeem premium fee rate (on top of withdrawal fee) (100% = 1e18)
    uint64 instantRedeemPremium;
}

/// @notice Price data for base/quote pair
/// @param price Current price
/// @param targetPrice Target price for gradual changes
/// @param timestampForFullVesting Target timestamp for full vesting
/// @param lastUpdatedTimestamp Last timestamp price was updated
struct Price {
    uint256 price;
    uint256 targetPrice;
    uint256 timestampForFullVesting;
    uint256 lastUpdatedTimestamp;
}

/// @notice Pending redeem details
/// @param shares Amount of shares
/// @param requestTime Last timestamp of request
struct PendingRedeem {
    uint256 shares;
    uint256 requestTime;
}

/// @notice Claimable redeem details
/// @param assets Amount of assets
/// @param shares Amount of shares
struct ClaimableRedeem {
    uint256 assets;
    uint256 shares;
}
