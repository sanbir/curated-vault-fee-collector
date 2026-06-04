// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal ERC-7540 async-redeem surface used by `UltraYieldFeeCollector` against UltraYield's
///         `UltraVault`. (Deposit/convertToAssets/asset are inherited via the ERC-4626 base type.)
interface IUltraVault7540 {
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);
    function cancelRedeemRequest(address controller) external returns (uint256 shares);
    function maxRedeem(address controller) external view returns (uint256);
    function setOperator(address operator, bool approved) external returns (bool);
}
