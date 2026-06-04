// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/**
 * @title IRateProvider
 * @notice Interface for rate provider contracts
 */
interface IRateProvider {

    /**
     * @notice Convert from specific asset to base asset
     * @param asset The asset to get rate for
     * @return result The rate in terms of base asset (18 decimals)
     */
    function convertToUnderlying(address asset, uint256 assets) external view returns (uint256 result);

    /**
     * @notice Convert from base asset to specific asset
     * @param asset The asset to convert to
     * @param baseAssets Amount in base asset units
     * @return result The amount in asset units
     */
    function convertFromUnderlying(address asset, uint256 baseAssets) external view returns (uint256 result);
}
