// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/// @title IERC20Supply
/// @notice Concise interface of the ERC-20 token to allow balance fetching
interface IERC20Supply {
    /// @notice Returns the total supply of the token
    /// @return totalSupply The total supply of the token
    function totalSupply() external view returns (uint256);
}
