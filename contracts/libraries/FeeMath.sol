// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeeMath
/// @notice Minimal partner-fee arithmetic for the curated-vault fee collector: a percentage
///         deposit/withdrawal fee and a per-block AUM fee. All fees round UP (partner-favoring).
library FeeMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @notice `amount * rateBps / 10_000`, rounded up. Zero if amount or rate is zero.
    function bpsFee(uint256 amount, uint256 rateBps) internal pure returns (uint256) {
        if (amount == 0 || rateBps == 0) return 0;
        return Math.mulDiv(amount, rateBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice AUM fee = `amount * aumFeePerBlock * blocksElapsed / 1e18`, rounded up.
    /// @param amount          asset value being charged (the redeemed gross amount).
    /// @param aumFeePerBlock  fraction of AUM charged per block, in 1e18 (WAD) scale.
    /// @param blocksElapsed   number of blocks the assets were under management.
    function aumFee(uint256 amount, uint256 aumFeePerBlock, uint256 blocksElapsed) internal pure returns (uint256) {
        if (amount == 0 || aumFeePerBlock == 0 || blocksElapsed == 0) return 0;
        return Math.mulDiv(amount, aumFeePerBlock * blocksElapsed, WAD, Math.Rounding.Ceil);
    }
}
