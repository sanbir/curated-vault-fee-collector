// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/// @title IPriceSourceV1
/// @notice Interface for price source for legacy v1 vaults
interface IPriceSourceV1 {
    /// @notice Get one-sided price quote
    /// @param inAmount Amount of base token to convert
    /// @param base Token being priced
    /// @param quote Token used as unit of account
    /// @return outAmount Amount of quote token equivalent to inAmount of base
    /// @dev Assumes no price spread
    function getQuote(
        uint256 inAmount,
        address base,
        address quote
    ) external view returns (uint256 outAmount);
}
