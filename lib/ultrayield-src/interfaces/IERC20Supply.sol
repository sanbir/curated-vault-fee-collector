// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/**
 * @dev Concise interface of the ERC-20 token to allow balance fetching
 */
interface IERC20Supply {
    /**
     * @dev Returns the total supply of the token
     */
    function totalSupply() external view returns (uint256);
}
