// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { IPriceSource } from "uyv2/interfaces/IPriceSource.sol";
import { IPriceSourceV1 } from "uyv2/legacy/v1/interfaces/IPriceSourceV1.sol";

/// @notice A single price update recorded by the oracle. Packs into one slot.
struct PriceUpdate {
    uint88 startPrice;       // +88
    uint88 targetPrice;      // +88=176
    uint40 vestingDuration;  // +40=216; 0 = instant
    uint40 startTimestamp;   // +40=256; absolute activation time
}

/// @title IUltraVaultOracle
/// @notice Push-based share-price oracle. Stores curves supplied by the price manager
///         and prices purely off `block.timestamp`; identical on every chain.
interface IUltraVaultOracle is IPriceSource, IPriceSourceV1 {
    ////////////
    // Events //
    ////////////

    /// @notice Emitted once per recorded price update.
    event PriceUpdated(
        uint256 startPrice,
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 startTimestamp
    );

    ////////////
    // Errors //
    ////////////

    error ZeroAddress();
    error VaultMismatch();
    error AssetMismatch();
    error DecimalsMismatch();
    error NoPriceData();
    error InvalidVestingDuration();
    error DrawdownVestingNotAllowed();
    error Overflow();
    error NonMonotonicTimestamp();

    //////////////
    // View Fns //
    //////////////

    /// @notice Vault priced by this oracle.
    function vault() external view returns (address);

    /// @notice Share price at an arbitrary timestamp (past history or future projection).
    function sharePriceAt(uint256 timestamp) external view returns (uint256);

    /// @notice The most recently recorded price update.
    function lastUpdate() external view returns (PriceUpdate memory);

    /// @notice Number of recorded price updates (including the initial seed).
    function updatesCount() external view returns (uint256);

    ///////////////
    // Write Fns //
    ///////////////

    /// @notice Record a price update verbatim with an absolute `startTimestamp` (no delay).
    /// @dev `startTimestamp` must be monotonic; `vestingDuration == 0` is instant, otherwise
    ///      a linear vest requiring `targetPrice > startPrice` and a duration within bounds.
    function applyPriceUpdate(
        uint256 startPrice,
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 startTimestamp
    ) external;
}
