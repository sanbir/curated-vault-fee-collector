// SPDX-FileCopyrightText: 2026 P2P Validator <info@p2p.org>
// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @notice Minimal UltraYield **V2** surface used by `UltraYieldV2FeeCollector`.
///         V2 changes vs V1 that matter to the collector:
///           - `requestRedeem` gained a leading `asset` param and a trailing `autoClaim` flag,
///           - per-request fulfilment is operator-driven via `fulfillMultipleRedeems` (no single `fulfillRedeem`),
///           - a new synchronous `instantRedeem` path exists (exitpoint-funded, charges the vault's
///             withdrawal fee + instant premium).
///         Deposit / convertToAssets / asset / redeem keep their ERC-4626 shapes (inherited via IERC4626).
interface IUltraVaultV2 {
    /// @notice Whether an account currently passes the deployed UltraYield vault's KYC allowlist.
    function isAllowed(address account) external view returns (bool);

    /// @notice Request an async redeem. `autoClaim=false` so the collector claims explicitly and can
    ///         charge its partner fees at claim time.
    function requestRedeem(address asset, uint256 shares, address controller, address owner, bool autoClaim)
        external
        returns (uint256 requestId);

    /// @notice Redeem fulfilled (claimable) shares to `receiver`.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /// @notice Claimable (operator-fulfilled) shares for `controller`.
    function maxRedeem(address controller) external view returns (uint256);

    /// @notice Synchronous exit (V2). Burns `shares` from `controller`, pays net assets to `receiver`
    ///         from the exitpoint, and routes the vault's own (withdrawal + premium) fee to the vault's
    ///         fee recipient. `minAssets` bounds the net the receiver gets (0 to disable).
    function instantRedeem(address asset, uint256 shares, uint256 minAssets, address receiver, address controller)
        external
        returns (uint256 netAssets);

    /// @notice Asset liquidity currently available for instant redeems (min of exitpoint balance & allowance).
    function getLiquidity(address asset) external view returns (uint256);
}
