// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title HwmFeeMath
/// @notice Pure arithmetic for the curated-vault fee layer: deposit/withdrawal fees and a
///         per-position high-water-mark (HWM) performance fee.
/// @dev    `hwm` and `curRatio` are both expressed as "asset base-units per one whole underlying
///         share", i.e. `underlying.convertToAssets(SHARE_UNIT)` where `SHARE_UNIT = 10**shareDec`.
///         Because they share that unit, `curRatio - hwm` is an exact per-whole-share gain.
///         Fee *components* round up (protocol-favoring); position *value* rounds down (user-favoring).
library HwmFeeMath {
    uint256 internal constant BPS = 10_000;

    /// @notice Fee on `amount` at `rateBps`, rounded UP.
    function feeUp(uint256 amount, uint256 rateBps) internal pure returns (uint256) {
        if (amount == 0 || rateBps == 0) return 0;
        return Math.mulDiv(amount, rateBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice Split `amount` into (fee, net) at `rateBps`; fee rounded UP.
    function splitFeeUp(uint256 amount, uint256 rateBps) internal pure returns (uint256 fee, uint256 net) {
        fee = feeUp(amount, rateBps);
        net = amount - fee;
    }

    /// @notice Performance fee in ASSET units for a position. Zero at/below the position's HWM.
    /// @param shares    Underlying shares held for the position.
    /// @param hwm       Position high-water price (asset units per whole share).
    /// @param curRatio  Current price (asset units per whole share).
    /// @param shareUnit 10**underlyingShareDecimals.
    /// @param perfBps   Performance fee rate in BPS.
    function perfFeeAssets(uint256 shares, uint256 hwm, uint256 curRatio, uint256 shareUnit, uint256 perfBps)
        internal
        pure
        returns (uint256)
    {
        if (perfBps == 0 || shares == 0 || curRatio <= hwm) return 0;
        // gain (asset units) = (curRatio - hwm) * shares / SHARE_UNIT  -> round down (user-favoring on value)
        uint256 gainAssets = Math.mulDiv(curRatio - hwm, shares, shareUnit);
        // fee = gain * perfBps / BPS -> round down
        return Math.mulDiv(gainAssets, perfBps, BPS);
    }

    /// @notice Underlying shares worth `assets` at `curRatio`, rounded UP so the skim fully covers the fee.
    function assetsToSharesUp(uint256 assets, uint256 curRatio, uint256 shareUnit) internal pure returns (uint256) {
        if (assets == 0) return 0;
        return Math.mulDiv(assets, shareUnit, curRatio, Math.Rounding.Ceil);
    }

    /// @notice HWM ratchet: never decreases.
    function maxHwm(uint256 hwm, uint256 curRatio) internal pure returns (uint256) {
        return curRatio > hwm ? curRatio : hwm;
    }
}
