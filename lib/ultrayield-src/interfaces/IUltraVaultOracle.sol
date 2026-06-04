// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { IPriceSource } from "./IPriceSource.sol";

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

/// @title IUltraVaultOracle
/// @notice Interface for push-based price oracle
/// @dev Extends IPriceSource with price setting capabilities
interface IUltraVaultOracle is IPriceSource {
    ////////////
    // Events //
    ////////////

    event PriceUpdated(
        address indexed base,
        address indexed quote,
        uint256 price,
        uint256 targetPrice,
        uint256 timestampForFullVesting
    );

    ////////////
    // Errors //
    ////////////

    error NoPriceData(address base, address quote);
    error InputLengthMismatch();
    error InvalidVestingTime(address base, address quote, uint256 vestingTime);
    error ZeroVestingStartPrice(address base, address quote);
    error InvalidAssetsDecimals();

    ////////////////////
    // View Functions //
    ////////////////////

    /// @notice Get current price for base/quote pair
    /// @param base The base asset
    /// @param quote The quote asset
    /// @return Current price of base in terms of quote
    function getCurrentPrice(
        address base,
        address quote
    ) external view returns (uint256);

    /// @notice Get price data for base/quote pair
    /// @param base The base asset
    /// @param quote The quote asset
    /// @return Price data for the pair
    function prices(
        address base,
        address quote
    ) external view returns (Price memory);

    /////////////////////
    // Write Functions //
    /////////////////////

    /// @notice Set base/quote pair price
    /// @param base The base asset
    /// @param quote The quote asset
    /// @param price The price of the base in terms of the quote
    function setPrice(
        address base,
        address quote,
        uint256 price
    ) external;

    /// @notice Set multiple base/quote pair prices
    /// @param bases The base assets
    /// @param quotes The quote assets
    /// @param prices The prices of the bases in terms of the quotes
    /// @dev Array lengths must match
    function setPrices(
        address[] memory bases,
        address[] memory quotes,
        uint256[] memory prices
    ) external;

    /// @notice Set base/quote pair price with gradual change
    /// @param base The base asset
    /// @param quote The quote asset
    /// @param targetPrice The target price of the base in terms of the quote
    /// @param vestingTime The time over which vesting would occur
    function scheduleLinearPriceUpdate(
        address base,
        address quote,
        uint256 targetPrice,
        uint256 vestingTime
    ) external;

    /// @notice Set multiple base/quote pair prices with gradual changes
    /// @param bases The base assets
    /// @param quotes The quote assets
    /// @param targetPrices The target prices of the bases in terms of the quotes
    /// @param vestingTimes The times over which vesting would occur
    /// @dev Array lengths must match
    function scheduleLinearPricesUpdates(
        address[] memory bases,
        address[] memory quotes,
        uint256[] memory targetPrices,
        uint256[] memory vestingTimes
    ) external;
}
