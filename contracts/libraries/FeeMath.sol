// SPDX-FileCopyrightText: 2026 P2P Validator <info@p2p.org>
// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeeMath
/// @notice Minimal partner-fee arithmetic for the curated-vault fee collector: a percentage
///         deposit/withdrawal fee and a per-block AUM fee. All fees round UP (partner-favoring).
library FeeMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @notice `_amount * _rateBps / 10_000`, rounded up. Zero if amount or rate is zero.
    function bpsFee(uint256 _amount, uint256 _rateBps) internal pure returns (uint256) {
        if (_amount == 0 || _rateBps == 0) return 0;
        return Math.mulDiv(_amount, _rateBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice AUM fee = `_amount * _aumFeePerBlock * _blocksElapsed / 1e18`, rounded up.
    /// @param _amount         asset value being charged (the redeemed gross amount).
    /// @param _aumFeePerBlock fraction of AUM charged per block, in 1e18 (WAD) scale.
    /// @param _blocksElapsed  number of blocks the assets were under management.
    function aumFee(uint256 _amount, uint256 _aumFeePerBlock, uint256 _blocksElapsed) internal pure returns (uint256) {
        if (_amount == 0 || _aumFeePerBlock == 0 || _blocksElapsed == 0) return 0;
        return Math.mulDiv(_amount, _aumFeePerBlock * _blocksElapsed, WAD, Math.Rounding.Ceil);
    }
}
