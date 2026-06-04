// SPDX-FileCopyrightText: 2025 P2P Validator <info@p2p.org>
// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @notice Minimal ERC-7540 async-redeem surface used by `UltraYieldFeeCollector` against UltraYield's
///         `UltraVault`. (Deposit/convertToAssets/asset are inherited via the ERC-4626 base type.)
interface IUltraVault7540 {
    function requestRedeem(uint256 _shares, address _controller, address _owner) external returns (uint256 requestId);
    function redeem(uint256 _shares, address _receiver, address _controller) external returns (uint256 assets);
    function maxRedeem(address _controller) external view returns (uint256);
}
