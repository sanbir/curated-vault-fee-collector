// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

interface IPriceSource {
    /// @notice Get current price of the share
    /// @return Current price of the share in terms of the asset (18 decimals scale)
    function currentSharePrice() external view returns (uint256);

    /// @notice Get share price at a specific timestamp
    /// @param timestamp Target timestamp for historical lookup
    /// @return Share price in terms of the asset (18 decimals scale)
    function historicalSharePrice(uint256 timestamp) external view returns (uint256);
}
